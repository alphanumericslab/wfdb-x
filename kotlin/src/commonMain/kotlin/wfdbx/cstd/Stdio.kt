// The process's standard streams and environment, as a C program sees them
// (port of rust/src/cstd/stdio.rs): a buffered standard output shared by
// everything that writes to it ([Stdout], [printf], wfdbx.WfdbFile.stdout),
// an unbuffered standard error, exit (which flushes every open output
// stream, as C's exit does), and environment variables as byte strings.
//
// The standard streams are process-wide; like C's, they are meant to be
// used from one thread at a time.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.cstd

/** C's EOF. */
const val EOF: Int = -1

/** C's INT_MAX. */
const val INT_MAX: Int = Int.MAX_VALUE

/** C's INT_MIN. */
const val INT_MIN: Int = Int.MIN_VALUE

/** C's LONG_MAX (64-bit long). */
const val LONG_MAX: Long = Long.MAX_VALUE

/** C's LONG_MIN. */
const val LONG_MIN: Long = Long.MIN_VALUE

/** fseek origin: start of file. */
const val SEEK_SET: Int = 0

/** fseek origin: current position. */
const val SEEK_CUR: Int = 1

/** fseek origin: end of file. */
const val SEEK_END: Int = 2

/** C integer division of longs (truncation toward zero; wraps on MIN / -1). */
fun cdiv(a: Long, b: Long): Long = if (b == -1L) -a else a / b

/** C remainder (the sign follows the dividend). */
fun cmod(a: Long, b: Long): Long = if (b == -1L) 0L else a % b

private const val STDOUT_BUFSIZE = 1 shl 16

/**
 * The buffered standard output (C's stdout).
 *
 * All output to the standard output (from [printf], and from WfdbFiles
 * opened on "-") goes through this buffer, which is written out when it is
 * full, by [flush] (or [flushStdout]), and by [exit]. If the standard
 * output is a terminal, it is written out after each call (C line-buffers
 * it).
 */
object Stdout {
    private val buf = ByteVec(STDOUT_BUFSIZE)
    private var err = false
    private var tty = -1

    private fun isTty(): Boolean {
        if (tty < 0) tty = if (Platform.stdoutIsTty()) 1 else 0
        return tty == 1
    }

    private fun afterWrite() {
        if (buf.size >= STDOUT_BUFSIZE || isTty()) flush()
    }

    /** C `fwrite(b, 1, len, stdout)`. */
    fun write(b: ByteArray, off: Int = 0, len: Int = b.size - off) {
        buf.addAll(b, off, len)
        afterWrite()
    }

    /** Writes the ISO-8859-1 bytes of [s]. */
    fun write(s: String) {
        buf.addString(s)
        afterWrite()
    }

    /** C `putchar`. */
    fun putc(c: Int) {
        buf.add(c)
        if (buf.size >= STDOUT_BUFSIZE) flush()
    }

    /** C `printf`: returns the number of bytes written. */
    fun printf(fmt: ByteArray, args: Array<out Any?>): Int {
        val n = sprintfInto(buf, fmt, args)
        afterWrite()
        return n
    }

    /** C `printf`. */
    fun printf(fmt: String, vararg args: Any?): Int = printf(fmt.latin1(), args)

    /** A sink for formatting directly into the buffer (then call [written]). */
    internal fun buffer(): ByteVec = buf

    /** To be called after writing into [buffer]. */
    internal fun written() = afterWrite()

    /** C `fflush(stdout)`: 0, or -1 (EOF) on a write error. */
    fun flush(): Int {
        if (buf.isEmpty()) return if (err) -1 else 0
        val r = Platform.writeStdout(buf.bytes, 0, buf.size)
        buf.clear()
        if (r != 0) {
            err = true
            return -1
        }
        return 0
    }

    /** C `ferror(stdout)`. */
    fun error(): Boolean = err
}

/** C `printf` (to the buffered standard output); returns the number of bytes written. */
fun printf(fmt: String, vararg args: Any?): Int = Stdout.printf(fmt.latin1(), args)

/** C `printf` with a byte format. */
fun printf(fmt: ByteArray, vararg args: Any?): Int = Stdout.printf(fmt, args)

/** Same as [printf] (the name of the Rust macro). */
fun cprintf(fmt: String, vararg args: Any?): Int = Stdout.printf(fmt.latin1(), args)

/** C `fflush(stdout)`. */
fun flushStdout(): Int = Stdout.flush()

/** Writes bytes to the standard error (unbuffered, as C's stderr). */
fun ewrite(b: ByteArray, off: Int = 0, len: Int = b.size - off) = Platform.writeStderr(b, off, len)

/** Writes the ISO-8859-1 bytes of [s] to the standard error. */
fun ewrite(s: String) = ewrite(s.latin1())

/** C `fprintf(stderr, ...)`; returns the number of bytes written. */
fun eprintf(fmt: String, vararg args: Any?): Int {
    val v = ByteVec(fmt.length + 32)
    val n = sprintfInto(v, fmt.latin1(), args)
    ewrite(v.bytes, 0, v.size)
    return n
}

/** Same as [eprintf] (the name of the Rust macro). */
fun ceprintf(fmt: String, vararg args: Any?): Int = eprintf(fmt, *args)

/** An open output stream that must be flushed when the process exits (as C's exit flushes every stream). */
internal interface ExitFlush {
    fun flushAtExit()
}

/** The open output streams (registered by wfdbx.WfdbFile while open). */
internal val openStreams: MutableSet<ExitFlush> = LinkedHashSet()

/** Bytes read from the standard input by a WfdbFile that was closed before they were consumed. */
internal val stdinPushback = ByteVec(64)

/**
 * C `exit(status)`: flushes every open output file (as C's exit does,
 * without closing records or annotators: no annotation end marks, no header
 * updates), then the standard output, and ends the process.
 */
fun exit(status: Int): Nothing {
    for (s in withGlobalLock { openStreams.toList() }) s.flushAtExit()
    Stdout.flush()
    Platform.exit(status)
}

/** The last component of a program path (argv[0]), as the C tools compute their name for messages. */
fun progName(argv0: ByteArray): ByteArray {
    val p = argv0.lastIndexOf('/'.code.toByte())
    return if (p < 0) argv0 else argv0.copyOfRange(p + 1, argv0.size)
}

/** C `getenv(name)`: the value of an environment variable, as bytes. */
fun getenv(name: String): ByteArray? = Platform.getenv(name)

/** C `setenv(name, value, overwrite)`. */
fun setenv(name: String, value: ByteArray, overwrite: Boolean = true) {
    if (!overwrite && Platform.getenv(name) != null) return
    Platform.setenv(name, value)
}

/** C `setenv` with a string value. */
fun setenv(name: String, value: String, overwrite: Boolean = true) = setenv(name, value.latin1(), overwrite)

/** C `unsetenv(name)`. */
fun unsetenv(name: String) = Platform.setenv(name, null)
