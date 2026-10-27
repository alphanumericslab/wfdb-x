// WfdbFile: an open file with C stdio semantics (C's FILE * and the WFDB
// library's WFDB_FILE), the buffered file type used by the library and the
// tools (port of the WfdbFile of rust/src/wfdbio.rs).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of lib/wfdbio.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: a remote file is read into memory (type WFDB_NET)
// by wfdb-x's own code; the HTTP and FTP code of the original (NETFILES) is
// not translated; an output file of the library that cannot be written counts
// as a write error (see wfdbx_write_errors). Each change is marked "wfdb-x:"
// in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C code: lib/wfdbio.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by
//   Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

import wfdbx.cstd.ByteVec
import wfdbx.cstd.EOF
import wfdbx.cstd.ExitFlush
import wfdbx.cstd.OpenMode
import wfdbx.cstd.Platform
import wfdbx.cstd.RawFile
import wfdbx.cstd.SEEK_CUR
import wfdbx.cstd.SEEK_END
import wfdbx.cstd.SEEK_SET
import wfdbx.cstd.Stdout
import wfdbx.cstd.FileId
import wfdbx.cstd.ewrite
import wfdbx.cstd.latin1
import wfdbx.cstd.openStreams
import wfdbx.cstd.withGlobalLock
import wfdbx.cstd.sprintfInto
import wfdbx.cstd.stdinPushback

/** Default size of a [WfdbFile] write buffer. */
const val WFDB_BUFSIZE: Int = 32768

/** Size of the read buffer when the file system does not give one (glibc's st_blksize, usually 4096). */
private const val RBUFSIZE = 4096

private enum class Kind { FILE, STDIN, STDOUT, STDERR, MEM }

/**
 * An open file with C stdio semantics (C's FILE * and the WFDB library's
 * WFDB_FILE).
 *
 * * Reads and writes are buffered; [getc] and [putc] are fast paths.
 * * End of file and errors set sticky flags ([eof], [error]) as glibc does:
 *   after end of file, reads return EOF until [clearerr] or a seek.
 * * A file opened on the standard input ([stdin], or wfdb_open of "-")
 *   never closes it; bytes it buffered but did not consume are given back to
 *   the next reader of the standard input when it is closed.
 * * A file opened on the standard output writes into the shared buffered
 *   standard output ([Stdout]), so its output is ordered with printf.
 * * An open file with buffered output is flushed by [wfdbx.cstd.exit]; a
 *   file must otherwise be closed ([close], C's fclose) for its buffered
 *   output to be written (there are no destructors).
 */
class WfdbFile private constructor(private val kind: Kind, private var raw: RawFile?, canRead: Boolean, canWrite: Boolean) {
    private var rbuf = ByteArray(0)
    private var rpos = 0
    private var rlen = 0
    private val wbuf = ByteVec(64)

    /** Ready for buffered writes (a file, not in read mode). */
    private var wready = false
    private var bufsize = WFDB_BUFSIZE

    /** Read buffer size (glibc reads blocks of st_blksize bytes), so that the file is read when, and as far as, C reads it. */
    private var rbufsize = RBUFSIZE

    /** Offset of the underlying descriptor (-1 if unknown/unseekable). */
    private var fpos = 0L
    private var eofFlag = false
    private var errFlag = false
    private val canRead = canRead
    private val canWrite = canWrite
    private var append = false
    private var closed = false

    /** wfdb-x: a remote file (a URL fetched in full, read from memory). */
    internal var remote = false

    /** wfdb-x: an output file of the library (see [wfdbx_write_errors]). */
    internal var out = false

    private val exitHook = object : ExitFlush {
        override fun flushAtExit() {
            flush()
        }
    }

    companion object {
        /**
         * C `fopen(path, mode)` (no WFDB path search or name checks; see
         * wfdb_fopen for the library's version). [mode] is a C mode string
         * ("rb", "wb", "ab", "r+b", ...; "b" is ignored).
         */
        fun fopen(path: ByteArray, mode: String): WfdbFile? {
            val m = mode.filter { it != 'b' && it != 't' }
            val plus = m.contains('+')
            val om = when (m.firstOrNull()) {
                'r' -> if (plus) OpenMode.READ_WRITE else OpenMode.READ
                'w' -> if (plus) OpenMode.WRITE_READ else OpenMode.WRITE
                'a' -> if (plus) OpenMode.APPEND_READ else OpenMode.APPEND
                else -> return null
            }
            val raw = Platform.open(path, om) ?: return null
            val f = WfdbFile(Kind.FILE, raw, om.read, om.write)
            f.append = om == OpenMode.APPEND || om == OpenMode.APPEND_READ
            // (glibc positions append-mode streams at the end of the file.)
            f.fpos = if (f.append) raw.seek(0, SEEK_END) else 0
            f.rbufsize = raw.blksize()
            if (om.write) f.register()
            return f
        }

        /** C `fopen` with a string path. */
        fun fopen(path: String, mode: String): WfdbFile? = fopen(path.latin1(), mode)

        /** A file on the standard input (C's stdin; the file attached by freopenStdin, if any). */
        fun stdin(): WfdbFile {
            val raw = Platform.stdin()
            val f = WfdbFile(Kind.STDIN, raw, true, false)
            f.fpos = raw?.position() ?: -1
            return f
        }

        /** A file on the standard output (C's stdout; writes go to the shared buffer of [Stdout]). */
        fun stdout(): WfdbFile {
            val f = WfdbFile(Kind.STDOUT, null, false, true)
            f.fpos = -1
            return f
        }

        /** A file on the standard error (C's stderr, unbuffered). */
        fun stderr(): WfdbFile {
            val f = WfdbFile(Kind.STDERR, null, false, true)
            f.fpos = -1
            return f
        }

        /** An input file reading from memory (seekable). */
        fun fromBytes(data: ByteArray): WfdbFile {
            val f = WfdbFile(Kind.MEM, null, true, false)
            f.rbuf = data
            f.rlen = data.size
            f.fpos = data.size.toLong()
            return f
        }
    }

    private fun register() {
        withGlobalLock { openStreams.add(exitHook) }
    }

    /** Whether this is the standard input, output, or error. */
    fun isStd(): Boolean = kind == Kind.STDIN || kind == Kind.STDOUT || kind == Kind.STDERR

    /** wfdb-x: whether this is a remote file (a URL, fetched in full). */
    fun isRemote(): Boolean = remote

    /** wfdb-x: the identity of an open local file (null for the standard streams, memory and remote files). */
    internal fun fileId(): FileId? = if (kind == Kind.FILE && !remote) raw?.fileId() else null

    /** wfdb-x: the size in bytes of an open local file (-1 for the standard streams, memory and remote files). */
    internal fun localSize(): Long = if (kind == Kind.FILE && !remote) raw?.size() ?: -1 else -1

    /** The type of the file: [WFDB_NET] for a remote file (wfdb-x: a URL, fetched in full), otherwise [WFDB_LOCAL]. */
    fun fileType(): Int = if (remote) WFDB_NET else WFDB_LOCAL

    /** Sets the buffer size (C setvbuf, before any I/O). */
    fun setBufsize(n: Int) {
        bufsize = if (n < 1) 1 else n
    }

    // ------------------------------------------------------------------ input

    private fun rawRead(b: ByteArray, off: Int, len: Int): Int {
        if (kind == Kind.STDIN && !stdinPushback.isEmpty()) {
            val n = minOf(stdinPushback.size, len)
            stdinPushback.bytes.copyInto(b, off, 0, n)
            val rest = stdinPushback.slice(n)
            stdinPushback.clear()
            stdinPushback.addAll(rest)
            return n
        }
        val r = raw ?: return 0
        return r.read(b, off, len)
    }

    /** Refills the read buffer; false at end of file or on error. */
    private fun fill(): Boolean {
        if (eofFlag || errFlag) return false
        if (!canRead) {
            errFlag = true
            return false
        }
        if (kind == Kind.MEM) {
            eofFlag = true
            return false
        }
        if (!wbuf.isEmpty() && flushWbuf() != 0) return false
        wready = false
        if (rbuf.size < rbufsize) rbuf = ByteArray(rbufsize)
        val n = rawRead(rbuf, 0, rbufsize)
        if (n == 0) {
            rpos = 0
            rlen = 0
            eofFlag = true
            return false
        }
        if (n < 0) {
            errFlag = true
            return false
        }
        rpos = 0
        rlen = n
        if (fpos >= 0) fpos += n
        return true
    }

    /** C `getc`: the next byte (0..255), or EOF (-1). */
    fun getc(): Int {
        if (rpos < rlen) return rbuf[rpos++].toInt() and 0xff
        return if (fill()) rbuf[rpos++].toInt() and 0xff else EOF
    }

    /** C `ungetc(c, fp)`: pushes a byte back (returns c, or EOF if c is EOF). */
    fun ungetc(c: Int): Int {
        if (c == EOF) return EOF
        if (rpos > 0) {
            rpos--
            rbuf[rpos] = c.toByte()
        } else {
            val nb = ByteArray(maxOf(rlen + 1, rbuf.size))
            rbuf.copyInto(nb, 1, 0, rlen)
            nb[0] = c.toByte()
            rbuf = nb
            rlen += 1
        }
        eofFlag = false
        return c
    }

    /**
     * C `fread(b + off, 1, len, fp)`: returns the number of bytes read. As in
     * glibc, a request for less than a buffer refills the buffer, and larger
     * ones read whole blocks directly into [b].
     */
    fun read(b: ByteArray, off: Int = 0, len: Int = b.size - off): Int {
        var done = 0
        while (done < len) {
            val avail = rlen - rpos
            if (avail > 0) {
                val n = minOf(avail, len - done)
                rbuf.copyInto(b, off + done, rpos, rpos + n)
                rpos += n
                done += n
                continue
            }
            val want = len - done
            if (want < rbufsize || !(kind == Kind.FILE || kind == Kind.STDIN)) {
                if (!fill()) break
                continue
            }
            val count = want - want % rbufsize
            val n = readDirect(b, off + done, count)
            if (n == 0) break
            done += n
        }
        return done
    }

    /** One read into b (the read buffer being empty), as glibc does for large requests; 0 at end of file or on error. */
    private fun readDirect(b: ByteArray, off: Int, len: Int): Int {
        if (eofFlag || errFlag) return 0
        if (!canRead) {
            errFlag = true
            return 0
        }
        if (!wbuf.isEmpty() && flushWbuf() != 0) return 0
        wready = false
        val n = rawRead(b, off, len)
        if (n == 0) {
            eofFlag = true
            return 0
        }
        if (n < 0) {
            errFlag = true
            return 0
        }
        if (fpos >= 0) fpos += n
        return n
    }

    /**
     * C `fread(p, size, n, fp)`: reads up to n items of size bytes into b
     * (which must hold size * n bytes) and returns the number of complete
     * items read.
     */
    fun fread(b: ByteArray, size: Int, n: Int): Int {
        if (size == 0 || n == 0) return 0
        return read(b, 0, size * n) / size
    }

    /** Reads a line, including its newline if any, into [line] (cleared first). Returns the number of bytes read (0 at end of file). */
    fun getline(line: ByteVec): Int {
        line.clear()
        while (true) {
            if (rpos < rlen) {
                var k = rpos
                while (k < rlen && rbuf[k] != '\n'.code.toByte()) k++
                if (k < rlen) {
                    line.addAll(rbuf, rpos, k + 1 - rpos)
                    rpos = k + 1
                    return line.size
                }
                line.addAll(rbuf, rpos, rlen - rpos)
                rpos = rlen
            }
            if (!fill()) return line.size
        }
    }

    /**
     * C `fgets(s, size, fp)`: reads at most size - 1 bytes, up to and
     * including a newline, into [s] (cleared first). Returns false (C's
     * NULL) if end of file (or an error) occurs before any byte is read.
     */
    fun fgets(s: ByteVec, size: Int): Boolean {
        s.clear()
        val lim = size - 1
        if (lim <= 0) return size == 1
        while (true) {
            if (rpos < rlen) {
                val want = lim - s.size
                val end = minOf(rpos + want, rlen)
                var k = rpos
                while (k < end && rbuf[k] != '\n'.code.toByte()) k++
                if (k < end) {
                    s.addAll(rbuf, rpos, k + 1 - rpos)
                    rpos = k + 1
                    return true
                }
                s.addAll(rbuf, rpos, end - rpos)
                rpos = end
                if (s.size >= lim) return true
            }
            if (!fill()) return !s.isEmpty()
        }
    }

    /** Reads everything up to the end of the file. */
    fun readToEnd(): ByteArray {
        val v = ByteVec(4096)
        while (true) {
            if (rpos < rlen) {
                v.addAll(rbuf, rpos, rlen - rpos)
                rpos = rlen
            }
            if (!fill()) return v.toByteArray()
        }
    }

    /** `wfdb_g16`: a 16-bit integer in PDP-11 (little-endian) byte order, sign-extended. At end of file the missing bytes read as 0xff (EOF). */
    fun g16(): Int {
        val x = getc()
        val y = getc()
        return ((y shl 8) or (x and 0xff)).toShort().toInt()
    }

    /** `wfdb_g32`: a 32-bit integer in PDP-11 byte order (high 16-bit word first, each word little-endian), as a C long. */
    fun g32(): Long {
        val x = g16().toLong()
        val y = g16().toLong()
        return (x shl 16) or (y and 0xffff)
    }

    // ----------------------------------------------------------------- output

    private fun flushWbuf(): Int {
        if (wbuf.isEmpty()) return 0
        val r = raw
        val ok = r?.write(wbuf.bytes, 0, wbuf.size) ?: true
        val n = wbuf.size
        wbuf.clear()
        if (!ok) {
            errFlag = true
            return EOF
        }
        if (append) {
            fpos = r?.position() ?: -1
        } else if (fpos >= 0) {
            fpos += n
        }
        return 0
    }

    /** Prepares for writing (leaves read mode); false if not writable. */
    private fun prepareWrite(): Boolean {
        if (!canWrite) {
            errFlag = true
            return false
        }
        if (rpos < rlen && kind == Kind.FILE) {
            // Reposition the descriptor at the logical position.
            val back = (rlen - rpos).toLong()
            val p = raw!!.seek(-back, SEEK_CUR)
            if (p < 0) {
                errFlag = true
                return false
            }
            fpos = p
        }
        rpos = 0
        rlen = 0
        if (kind == Kind.FILE) wready = true
        return true
    }

    /** C `putc`: writes a byte; returns it (0..255), or EOF on error. */
    fun putc(c: Int): Int {
        if (wready && wbuf.size < bufsize) {
            wbuf.add(c)
            return c and 0xff
        }
        val one = byteArrayOf(c.toByte())
        return if (write(one) == 1) c and 0xff else EOF
    }

    /** C `fwrite(b + off, 1, len, fp)`: returns the number of bytes written. */
    fun write(b: ByteArray, off: Int = 0, len: Int = b.size - off): Int {
        if (!wready && !prepareWrite()) return 0
        when (kind) {
            Kind.STDOUT -> {
                Stdout.write(b, off, len)
                return len
            }
            Kind.STDERR -> {
                ewrite(b, off, len)
                return len
            }
            else -> {
                if (wbuf.size + len > bufsize) {
                    if (flushWbuf() != 0) return 0
                    if (len >= bufsize) {
                        val r = raw
                        val ok = r?.write(b, off, len) ?: true
                        if (!ok) {
                            errFlag = true
                            return 0
                        }
                        if (append) fpos = r?.position() ?: -1 else if (fpos >= 0) fpos += len
                        return len
                    }
                }
                wbuf.addAll(b, off, len)
                return len
            }
        }
    }

    /** Writes the ISO-8859-1 bytes of [s]. */
    fun write(s: String): Int = write(s.latin1())

    /** C `fprintf(fp, fmt, ...)`: returns the number of bytes written (or -1 on error). */
    fun printf(fmt: String, vararg args: Any?): Int = printfBytes(fmt.latin1(), args)

    /** C `fprintf` with a byte format. */
    fun printf(fmt: ByteArray, vararg args: Any?): Int = printfBytes(fmt, args)

    private fun printfBytes(fmt: ByteArray, args: Array<out Any?>): Int {
        when (kind) {
            Kind.STDOUT -> return Stdout.printf(fmt, args)
            Kind.STDERR -> {
                val v = ByteVec(fmt.size + 32)
                val n = sprintfInto(v, fmt, args)
                ewrite(v.bytes, 0, v.size)
                return n
            }
            else -> {
                if (!wready && !prepareWrite()) return -1
                val n = sprintfInto(wbuf, fmt, args)
                if (wbuf.size >= bufsize && flushWbuf() != 0) return -1
                return n
            }
        }
    }

    /** `wfdb_p16`: writes a 16-bit integer in PDP-11 byte order. */
    fun p16(x: Int) {
        putc(x)
        putc(x shr 8)
    }

    /** `wfdb_p32`: writes a 32-bit integer in PDP-11 byte order (high word first). */
    fun p32(x: Long) {
        p16((x shr 16).toInt())
        p16(x.toInt())
    }

    /** C `fflush`: 0, or EOF on error. */
    fun flush(): Int = if (kind == Kind.STDOUT) Stdout.flush() else flushWbuf()

    // -------------------------------------------------------------- positions

    /** C `ftell`: the current position, or -1 if it is unknown (a pipe). */
    fun tell(): Long {
        if (kind == Kind.STDOUT) {
            Stdout.flush()
            return Platform.stdoutTell()
        }
        return if (fpos >= 0) fpos - (rlen - rpos) + wbuf.size else -1
    }

    /**
     * C `fseek(fp, offset, whence)` ([SEEK_SET], [SEEK_CUR], [SEEK_END]):
     * returns 0, or -1 on error (e.g. on a pipe). Clears the end-of-file
     * flag.
     */
    fun seek(offset: Long, whence: Int): Int {
        if (kind == Kind.STDOUT || kind == Kind.STDERR) return -1
        if (flushWbuf() != 0) return -1
        wready = false
        if (fpos < 0) return -1
        val cur = fpos - (rlen - rpos)
        val target = when (whence) {
            SEEK_SET -> offset
            SEEK_CUR -> cur + offset
            SEEK_END -> {
                if (kind == Kind.MEM) {
                    rbuf.size + offset
                } else {
                    val r = raw ?: return -1
                    val p = r.seek(offset, SEEK_END)
                    if (p < 0) return -1
                    fpos = p
                    rpos = 0
                    rlen = 0
                    eofFlag = false
                    return 0
                }
            }
            else -> return -1
        }
        if (target < 0) return -1
        if (kind == Kind.MEM) {
            rpos = minOf(target, rbuf.size.toLong()).toInt()
            eofFlag = false
            return 0
        }
        // Within the current read buffer: just move.
        val bstart = fpos - rlen
        if (rlen > 0 && target >= bstart && target <= fpos) {
            rpos = (target - bstart).toInt()
            eofFlag = false
            return 0
        }
        val r = raw ?: return -1
        val p = r.seek(target, SEEK_SET)
        if (p < 0) return -1
        fpos = p
        rpos = 0
        rlen = 0
        eofFlag = false
        return 0
    }

    /** C `feof`. */
    fun eof(): Boolean = eofFlag

    /** C `ferror`. */
    fun error(): Boolean = errFlag || (kind == Kind.STDOUT && Stdout.error())

    /** C `clearerr`. */
    fun clearerr() {
        eofFlag = false
        errFlag = false
    }

    /**
     * C `fclose` (the standard streams are flushed, not closed): returns 0,
     * or EOF if an error occurred (including earlier write errors).
     *
     * wfdb-x: an output file opened by the library (wfdb_open, wfdb_fopen)
     * that could not be written, flushed or closed counts as a write error
     * (see [wfdbx_write_errors]).
     */
    fun close(): Int {
        val status = release()
        if (out && status != 0) wfdbx_note_write_error()
        return status
    }

    private fun release(): Int {
        if (closed) return 0
        closed = true
        withGlobalLock { openStreams.remove(exitHook) }
        var status = if (errFlag) EOF else 0
        when (kind) {
            Kind.STDIN -> {
                if (rpos < rlen) {
                    val rest = rbuf.copyOfRange(rpos, rlen)
                    val old = stdinPushback.toByteArray()
                    stdinPushback.clear()
                    stdinPushback.addAll(rest)
                    stdinPushback.addAll(old)
                }
                raw?.close()
            }
            Kind.STDOUT -> if (Stdout.flush() != 0) status = EOF
            else -> {
                if (flushWbuf() != 0) status = EOF
                if (raw?.close() == false) status = EOF
            }
        }
        raw = null
        rpos = 0
        rlen = 0
        return status
    }
}
