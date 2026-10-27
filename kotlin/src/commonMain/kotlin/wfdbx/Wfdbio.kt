// Low-level I/O of the WFDB library (port of lib/wfdbio.c, from
// rust/src/wfdbio.rs and cpp/src/wfdbio.cpp): finding and opening WFDB
// files (wfdb_open, wfdb_fopen, wfdbfile), the input and output directories
// and network access (WFDB-x), the WFDB path of legacy mode (getwfdb,
// setwfdb, ...), error reporting (wfdb_error, wfdberror, wfdbquiet), and the
// legacy-mode switch (wfdbx_set_legacy, wfdbx_legacy_args). WfdbFile, the
// buffered file type, is in WfdbFile.kt.
//
// wfdb-x: files are found by explicit names (see wfdb_open): a relative
// name is read under the input directory (wfdbx_set_input_dir,
// WFDBX_INPUT_DIR) and written under the output directory
// (wfdbx_set_output_dir, WFDBX_OUTPUT_DIR); by default, the current
// directory. An absolute name, a ~ name or a URL is used as given; nothing
// else is searched. A URL is opened only with network access
// (wfdbx_set_network, WFDBX_NETWORK); it is then read in full (on the JVM
// with HttpURLConnection, on Linux by the curl program). Legacy mode
// searches the WFDB path as the C library does, without network access.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of lib/wfdbio.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: files are found only where they are named, not by
// a search of the WFDB path: a relative name is read under the input directory
// and written under the output directory (by default, the current directory),
// and an absolute name, a ~ name or a URL is used as given; setwfdb, getwfdb
// and resetwfdb set and return the input directory, and the WFDB environment
// variable is ignored; a URL is opened only if network access is turned on
// (wfdbx_set_network or WFDBX_NETWORK), and is then read in full by the
// platform's HTTP client; the original's HTTP and FTP code (NETFILES) is not
// translated; ".." is accepted in names, and only the last component of a
// record name is checked; write errors are counted (wfdbx_write_errors);
// additions: wfdbx_set_input_dir, wfdbx_get_input_dir, wfdbx_set_output_dir,
// wfdbx_get_output_dir, wfdbx_set_network, wfdbx_get_network,
// wfdbx_write_errors, wfdbx_note_write_error and wfdbx_fclose_output, and
// legacy mode: wfdbx_set_legacy, wfdbx_get_legacy, wfdbx_legacy_args; legacy mode (wfdbx_set_legacy) restores the original
// behavior (the WFDB path, without network access). Each change is marked
// "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
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
import wfdbx.cstd.FileId
import wfdbx.cstd.Platform
import wfdbx.cstd.at
import wfdbx.cstd.bcat
import wfdbx.cstd.beq
import wfdbx.cstd.cformat
import wfdbx.cstd.cstr
import wfdbx.cstd.eprintf
import wfdbx.cstd.ewrite
import wfdbx.cstd.exitCheckInit
import wfdbx.cstd.getenv
import wfdbx.cstd.indexOf
import wfdbx.cstd.isalnum
import wfdbx.cstd.latin1
import wfdbx.cstd.setenv
import wfdbx.cstd.startsWith
import wfdbx.cstd.strtol
import wfdbx.cstd.withGlobalLock

/** The date reported by wfdberror (that of the 10.7.0 release; the C library reports the date on which it was compiled). */
private const val WFDB_BUILD_DATE = "Jun 10 2022"

/** Directory separator. */
private const val DSEP = '/'.code

/** A component of the WFDB path (legacy mode). */
internal class PathComponent(val prefix: ByteArray, val ptype: Int)

/** The state of wfdbio.c (part of [Wfdb]). */
internal class IoState {
    var wfdbpath: ByteArray? = null
    var wfdbpathInit: ByteArray? = null
    val pathList = ArrayList<PathComponent>()
    var errorPrint = true
    var errorFlag = false
    var errorMessage = ByteArray(0)

    /** Name of the file most recently opened by wfdb_open. */
    var filename = ByteArray(0)

    /** Current record name (for %r in the WFDB path). */
    var irec = ByteArray(0)
    var memBehavior = 1

    /** wfdb-x: the directory in which wfdb_open creates output files (null: files are created as named). */
    var outputDir: ByteArray? = null

    /** wfdb-x: the value of WFDBX_OUTPUT_DIR (read on first use). */
    var envOutputDir: ByteArray? = null
    var outputDirInit = false

    /** WFDB-x (normal mode): the directory under which relative names are read (null: the current directory). */
    var inputDir: ByteArray? = null

    /** wfdb-x: the value of WFDBX_INPUT_DIR (read on first use). */
    var envInputDir: ByteArray? = null
    var inputDirInit = false

    /** WFDB-x (normal mode): the input directory set by the last setwfdb (for resetwfdb), and whether setwfdb was called. */
    var setwfdbInputDir: ByteArray? = null
    var setwfdbCalled = false

    /** wfdb-x: network access allowed (null until first needed: then from WFDBX_NETWORK, whose value is envNetwork). */
    var network: Boolean? = null
    var envNetwork = false
}

// ---------------------------------------------------------------------------
// Process-wide state (messages printed once, fetched URLs)

private var wfdbWarned = false
private var networkWarned = false
private var curlWarned = false

/** The remote files fetched by this process, by URL (null value: the fetch failed). */
private val fetched = HashMap<String, ByteArray?>()

private const val OUTPUT_URL_ERROR = "wfdbx_set_output_dir: the output directory must be a local directory\n"

/** `record.type`, or `record` if the type is empty (C spr1). */
private fun spr1(record: ByteArray, ftype: ByteArray): ByteArray =
    if (ftype.isEmpty()) record.copyOf() else bcat(record, byteArrayOf('.'.code.toByte()), ftype)

/** `record.typ`, the type truncated to 3 characters (C "%s.%.3s", the MS-DOS form of the file name). */
private fun spr2(record: ByteArray, ftype: ByteArray): ByteArray =
    bcat(record, byteArrayOf('.'.code.toByte()), ftype.copyOf(minOf(ftype.size, 3)))

/**
 * wfdb-x: whether [s] is an absolute local path: one beginning with "/"
 * (and, on Windows-style names, "X:\", "X:/" or "\\").
 */
internal fun isAbsolutePath(s: ByteArray): Boolean {
    if (s.isEmpty()) return false
    return s.at(0) == '/'.code
}

/** Whether [s] is an http:// or https:// URL. */
internal fun isUrl(s: ByteArray): Boolean = s.startsWith("http://") || s.startsWith("https://")

private fun isDsep(c: Int): Boolean = c == '/'.code

/** dir + sep + name, with exactly one separator between them ("/" in a URL). */
private fun join(dir: ByteArray, name: ByteArray, sep0: Int): ByteArray {
    val sep = if (isUrl(dir)) '/'.code else sep0
    val r = ByteVec(dir.size + name.size + 1)
    r.addAll(dir)
    if (r.size > 0 && r.last() != sep && !isDsep(r.last())) r.add(sep)
    r.addAll(name)
    return r.toByteArray()
}

/**
 * Whether a file name found in a header names a file in the header's
 * directory or below it: a relative name that does not begin with "~" and
 * has no ".." component.
 */
internal fun inHeaderDir(name: ByteArray): Boolean {
    if (isAbsolutePath(name) || isUrl(name) || name.at(0) == '~'.code) return false
    var start = 0
    for (i in 0..name.size) {
        if (i == name.size || isDsep(name.at(i))) {
            if (i - start == 2 && name[start] == '.'.code.toByte() && name[start + 1] == '.'.code.toByte()) return false
            start = i + 1
        }
    }
    return true
}

/**
 * The directory part of the file name or URL [s], including its final separator
 * (empty if it has none).
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_dirname(s: ByteArray): ByteArray {
    var n = s.size
    while (n > 0 && !isDsep(s.at(n - 1))) n--
    return s.copyOf(n)
}

/** [record] with a final "/" expanded by another copy of the final element ("abc/123/" becomes "abc/123/123"). */
private fun expandRecord(record: ByteArray): ByteArray {
    val rlen = record.size
    if (rlen > 1 && record.at(rlen - 1) == '/'.code) {
        val p = rlen - 1
        var q = p - 1
        while (q > 0) {
            if (record.at(q) == '/'.code) {
                q++
                break
            }
            q--
        }
        if (q < p) return bcat(record, record.copyOfRange(q, p))
    }
    return record.copyOf()
}

/**
 * [s] with a leading "~" or "~/" replaced by the home directory (HOME, or,
 * if it is not set, that of the user running the process), and "~user" by
 * the home directory of that user (if there is no such user, s is
 * unchanged), as Python's os.path.expanduser does. (The users' home
 * directories are those of /etc/passwd.)
 */
internal fun expandHome(s: ByteArray): ByteArray {
    if (s.at(0) != '~'.code) return s
    var i = 1
    while (i < s.size && !isDsep(s.at(i))) i++
    val home = if (i == 1) getenv("HOME") ?: passwdHome(null) else passwdHome(s.copyOfRange(1, i))
    home ?: return s
    val r = ByteVec(home.size + s.size)
    r.addAll(home)
    while (r.size > 0 && isDsep(r.last())) r.pop()
    r.addAll(s, i, s.size - i)
    if (r.isEmpty()) r.add('/'.code)
    return r.toByteArray()
}

/** The home directory of [user] (or of the user running the process) in /etc/passwd. */
private fun passwdHome(user: ByteArray?): ByteArray? {
    val uid = if (user == null) {
        val u = Platform.currentUid()
        if (u < 0) return null
        u.toString().latin1()
    } else {
        null
    }
    val data = Platform.readFile("/etc/passwd".latin1()) ?: return null
    var start = 0
    for (i in 0..data.size) {
        if (i == data.size || data[i] == '\n'.code.toByte()) {
            val f = ArrayList<ByteArray>()
            var fs = start
            for (k in start..i) {
                if (k == i || data[k] == ':'.code.toByte()) {
                    f.add(data.copyOfRange(fs, k))
                    fs = k + 1
                }
            }
            val found = if (user != null) beq(f[0], user) else (f.size > 2 && beq(f[2], uid))
            if (found && f.size >= 7) return f[5]
            start = i + 1
        }
    }
    return null
}

/**
 * The next component of the WFDB path string [s], from position q (after
 * any whitespace): its start, its end (the position of the character that
 * follows it) and its type ([WFDB_LOCAL] or [WFDB_NET]).
 */
private fun pathComponent(s: ByteArray, q0: Int): IntArray {
    val n = s.size
    var q = q0
    while (q < n && s.at(q).toChar() in " \t\n\r") q++
    val start = q
    var ptype = WFDB_LOCAL
    var slashes = 0
    while (true) {
        val c = if (q < n) s.at(q) else 0
        if (c == ':'.code) {
            if (s.at(q + 1) == '/'.code && s.at(q + 2) == '/'.code) {
                ptype = WFDB_NET
            } else if (ptype != WFDB_NET || slashes > 2) {
                // ':' ends a component, except in the host part of a URL
                // (before the third '/': "host:port")
                break
            }
        } else if (c == ';'.code || c == ' '.code || c == '\t'.code || c == '\n'.code || c == '\r'.code || c == 0) {
            break
        } else if (c == '/'.code) {
            slashes++
        }
        q++
    }
    return intArrayOf(start, q, ptype)
}

/**
 * C `freopen(name, "rb", stdin)`: attaches the file [name] to the standard
 * input, so that later readers of the standard input (WfdbFile.stdin(),
 * wfdb_open of "-") read it from its beginning. Bytes of the previous
 * standard input that were buffered but not consumed are discarded.
 * Returns false (and leaves the standard input unchanged) if the file
 * cannot be opened.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun freopen_stdin(name: ByteArray): Boolean {
    if (!Platform.freopenStdin(name)) return false
    wfdbx.cstd.stdinPushback.clear()
    return true
}

/**
 * The local part of wfdb_fopen: a directory cannot be opened for reading;
 * when a file cannot be created ("wb" or "ab"), the missing directories in
 * its path are created and the file is opened again. With [legacy], as in
 * the C library (built without network support), names containing ".." or
 * "://" are rejected.
 */
internal fun localFopen(fname0: ByteArray, mode: String, legacy: Boolean): WfdbFile? {
    val fname = cstr(fname0)
    if (legacy && (fname.indexOf("..".latin1()) >= 0 || fname.indexOf("://".latin1()) >= 0)) return null
    if (mode.startsWith("r") && Platform.isDirectory(fname)) return null
    val out = !mode.startsWith("r") // wfdb-x: see wfdbx_write_errors
    WfdbFile.fopen(fname, mode)?.let {
        it.out = out
        return it
    }
    if (mode == "wb" || mode == "ab") {
        // Try to create any missing directories in the path.
        var ok = false
        var tried = false
        for (i in fname.indices) {
            if (fname[i] == '/'.code.toByte()) {
                tried = true
                ok = Platform.mkdir(fname.copyOf(i))
            }
        }
        if (tried && ok) return WfdbFile.fopen(fname, mode)?.also { it.out = out }
    }
    return null
}

// wfdb-x: write errors. Decided by Reza Sameni, Oct 2026: a program must not
// report success when its output was not written.
private var writeErrors = 0

/**
 * The number of write errors since the program started: the output files
 * that the library could not write, flush or close (found when they are
 * closed, as by wfdbquit), and the errors reported with
 * [wfdbx_note_write_error]. The count is process-wide.
 *
 * The high-level writers throw a [WfdbException] when they meet one, and
 * the command-line tools then exit with status 1.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_write_errors(): Int = withGlobalLock { writeErrors }

/**
 * Counts a write error (see [wfdbx_write_errors]): for an application that
 * writes a file itself.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_note_write_error() {
    withGlobalLock { writeErrors++ }
}

/**
 * `wfdbx_fclose_output(fp, pname, name)` on the default instance (see
 * [Wfdb.wfdbx_fclose_output]).
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_fclose_output(fp: WfdbFile, pname: ByteArray, name: ByteArray): Int =
    wfdbDefault().wfdbx_fclose_output(fp, pname, name)

/**
 * `wfdb_striphea(record)`: the record name without a trailing ".hea".
 *
 * Translation of the C function wfdb_striphea() (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
 */
fun wfdb_striphea(record: ByteArray): ByteArray {
    val r = cstr(record)
    return if (r.size > 4 && r.copyOfRange(r.size - 4, r.size).contentEquals(".hea".latin1())) r.copyOf(r.size - 4) else r
}

/**
 * Runs `sortann --legacy -r. RECORD -a ANNOTATOR` to sort an annotation
 * file (used by oannclose in legacy mode; wfdb-x: the program is run
 * without a shell, with --legacy so that it behaves as the original, and
 * in the output directory [dir], if one is set). Returns the exit status
 * (-1 if it could not be run).
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun run_sortann(record: ByteArray, annotator: ByteArray, dir: ByteArray?): Int =
    Platform.runSortann(record, annotator, dir)

/** The identity of the existing file [path] (null if it does not exist). */
internal fun pathId(path: ByteArray): FileId? = Platform.pathId(path)

/**
 * C `wfdbversion()`: the version of the WFDB library implemented ("10.7.0").
 *
 * Translation of the C function wfdbversion() (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
 */
fun wfdbversion(): ByteArray = "10.7.0".latin1()

/**
 * C `wfdbldflags`: the linker flags needed to build WFDB applications (none:
 * "").
 *
 * Translation of the C function wfdbldflags() (lib/wfdbio.c, WFDB 10.7.0): same
 * arguments and results. Differences: the result is always empty; see
 * docs/KNOWN_C_BEHAVIORS.md.
 */
fun wfdbldflags(): ByteArray = ByteArray(0)

/**
 * C `wfdbcflags`: the compiler flags needed to build WFDB applications (none:
 * "").
 *
 * Translation of the C function wfdbcflags() (lib/wfdbio.c, WFDB 10.7.0): same
 * arguments and results. Differences: the result is always empty; see
 * docs/KNOWN_C_BEHAVIORS.md.
 */
fun wfdbcflags(): ByteArray = ByteArray(0)

/**
 * C `wfdbdefwfdb`: the default WFDB path ([DEFWFDB]).
 *
 * Translation of the C function wfdbdefwfdb() (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
 */
fun wfdbdefwfdb(): ByteArray = DEFWFDB.latin1()

/**
 * C `wfdbdefwfdbcal`: the default calibration file name ("wfdbcal").
 *
 * Translation of the C function wfdbdefwfdbcal() (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
 */
fun wfdbdefwfdbcal(): ByteArray = DEFWFDBCAL.latin1()

private fun exportConfig(p: ByteArray) {
    setenv("WFDB", p, true)
    setenv("WFDBCAL", DEFWFDBCAL.latin1(), false)
    setenv("WFDBANNSORT", "1".latin1(), false)
    setenv("WFDBGVMODE", "0".latin1(), false)
}

// ===========================================================================
// Library functions (extensions of Wfdb)

/** If [p0] begins with "@", reads the WFDB path from the named file (wfdb_getiwfdb). */
private fun Wfdb.getiwfdb(p0: ByteArray): ByteArray {
    val maxIndirect = 10 // levels of '@file' indirection followed
    var p = p0
    var i = 0
    while (i < maxIndirect && p.at(0) == '@'.code) {
        val data = Platform.readFile(p.copyOfRange(1, p.size))
        if (data == null) {
            p = ByteArray(0)
        } else {
            var n = data.size
            while (n > 0 && (data[n - 1] == '\r'.code.toByte() || data[n - 1] == '\n'.code.toByte())) n--
            p = data.copyOf(n)
        }
        i++
    }
    if (p.at(0) == '@'.code) {
        wfdb_error("getwfdb: files nested too deeply\n")
        p = ByteArray(0)
    }
    return p
}

/**
 * C `getwfdb()`: wfdb-x: in normal mode, the input directory (see
 * [wfdbx_set_input_dir]), or "." if none is set. In legacy mode, the WFDB
 * path (initialized from the WFDB environment variable, or [DEFWFDB], on
 * first use).
 *
 * Translation of the C function getwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
 * arguments and results. Differences: it returns the input directory (the WFDB
 * path in legacy mode); see docs/DIVERGENCES.md.
 */
fun Wfdb.getwfdb(): ByteArray {
    if (!legacy) {
        initInputDir()
        return io.inputDir ?: ".".latin1()
    }
    if (io.wfdbpath == null) {
        val p = getenv("WFDB") ?: DEFWFDB.latin1()
        val path = getiwfdb(p)
        io.wfdbpath = path
        io.wfdbpathInit = path
        wfdb_parse_path(path)
    }
    return io.wfdbpath ?: ByteArray(0)
}

/**
 * C `setwfdb(path)`: wfdb-x: in normal mode, [p], split into components as
 * the WFDB path is (at spaces, ";", and ":" outside URLs), must contain at
 * most one non-empty component, which becomes the input directory (none,
 * e.g. "" or ";": the default; see [wfdbx_set_input_dir]); with more, it
 * reports "setwfdb: wfdb-x reads from a single input directory; ..." and
 * changes nothing. Nothing is exported to the environment.
 *
 * In legacy mode, as in C: sets the WFDB path (null: from the environment
 * or the default), and exports WFDB (and defaults of WFDBCAL, WFDBANNSORT,
 * WFDBGVMODE) to the environment.
 *
 * Translation of the C function setwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
 * arguments and results. Differences: it sets a single input directory (the
 * WFDB path in legacy mode); see docs/DIVERGENCES.md.
 */
fun Wfdb.setwfdb(p: ByteArray?) {
    if (!legacy) {
        setwfdbNormal(p?.let { cstr(it) })
        return
    }
    val value = if (p != null) cstr(p) else getenv("WFDB") ?: DEFWFDB.latin1()
    exportConfig(value)
    val path = getiwfdb(value)
    io.wfdbpath = path
    wfdb_parse_path(path)
}

/** C `setwfdb` with a string. */
fun Wfdb.setwfdb(p: String) = setwfdb(p.latin1())

/**
 * C `resetwfdb()`: wfdb-x: in normal mode, restores the input directory set
 * by the last setwfdb, if any (wfdbquit does not call it in normal mode).
 * In legacy mode, restores the WFDB path to its initial value (only if
 * getwfdb was called before any setwfdb).
 *
 * Translation of the C function resetwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
 * arguments and results. Differences: it restores the input directory set by
 * the last setwfdb() (the WFDB path in legacy mode); see docs/DIVERGENCES.md.
 */
fun Wfdb.resetwfdb() {
    if (!legacy) {
        if (io.setwfdbCalled) putInputDir(io.setwfdbInputDir)
        return
    }
    io.wfdbpathInit?.let { io.wfdbpath = it }
}

/**
 * C `wfdbquiet()`: suppresses error messages.
 *
 * Translation of the C function wfdbquiet() (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdbquiet() {
    io.errorPrint = false
}

/**
 * C `wfdbverbose()`: prints error messages (the default).
 *
 * Translation of the C function wfdbverbose() (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdbverbose() {
    io.errorPrint = true
}

/** wfdb-x: turns the printing of error messages on or off; returns the previous setting. */
internal fun Wfdb.wfdbxSetErrorPrint(on: Boolean): Boolean {
    val p = io.errorPrint
    io.errorPrint = on
    return p
}

/**
 * C `wfdberror()`: the most recent error message (or, before any error, the
 * library version string).
 *
 * Translation of the C function wfdberror() (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdberror(): ByteArray {
    if (!io.errorFlag) {
        io.errorMessage = cformat("WFDB library version %d.%d.%d (%s).\n", WFDB_MAJOR, WFDB_MINOR, WFDB_RELEASE, WFDB_BUILD_DATE)
    }
    return io.errorMessage.copyOf()
}

/**
 * C `wfdb_error(format, ...)`, with the message already formatted (use
 * [cformat]): records it as the latest error and prints it on the standard
 * error unless wfdbquiet() was called.
 *
 * Translation of the C function wfdb_error() (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdb_error(msg: ByteArray) {
    io.errorFlag = true
    io.errorMessage = msg.copyOf()
    if (io.errorPrint) ewrite(io.errorMessage)
}

/** C `wfdb_error` with a message given as a string (one byte per character). */
fun Wfdb.wfdb_error(msg: String) = wfdb_error(msg.latin1())

/** C `wfdb_error` with a C format and arguments. */
fun Wfdb.wfdb_error_fmt(fmt: String, vararg args: Any?) = wfdb_error(cformat(fmt, *args))

/**
 * Records [msg] as the latest error (as wfdb_error does), without printing
 * it (wfdb-x: for a message that a high-level function replaces with its
 * own).
 */
internal fun Wfdb.wfdbErrorUnprinted(msg: ByteArray) {
    val print = io.errorPrint
    io.errorPrint = false
    wfdb_error(msg)
    io.errorPrint = print
}

/**
 * C `wfdbmemerr(behavior)`: whether a memory allocation error is fatal
 * (nonzero) or not (0).
 *
 * Translation of the C function wfdbmemerr() (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdbmemerr(behavior: Int) {
    io.memBehavior = behavior
}

/**
 * C `wfdb_me_fatal()`: the behavior set by [wfdbmemerr] (1 by default).
 *
 * Translation of the C function wfdb_me_fatal() (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdb_me_fatal(): Int = io.memBehavior

/** Reads WFDBX_INPUT_DIR on first use, and (once per process, in normal mode) warns that WFDB is ignored. */
private fun Wfdb.initInputDir() {
    if (!io.inputDirInit) {
        io.inputDirInit = true
        val p = getenv("WFDBX_INPUT_DIR")
        if (p != null && p.isNotEmpty()) {
            io.envInputDir = p
            io.inputDir = p
        }
    }
    if (!legacy && !wfdbWarned) {
        val w = getenv("WFDB")
        if (w != null && w.isNotEmpty()) {
            wfdbWarned = true
            wfdb_error("wfdb-x: the WFDB environment variable is ignored; set WFDBX_INPUT_DIR instead (or use legacy mode)\n")
        }
    }
}

/** Replaces the input directory (the default if [dir] is null or empty). */
private fun Wfdb.putInputDir(dir: ByteArray?) {
    initInputDir()
    io.inputDir = if (dir != null && dir.isNotEmpty()) dir else io.envInputDir
}

/** setwfdb in normal mode: [p] must name at most one input directory. */
private fun Wfdb.setwfdbNormal(p0: ByteArray?): Int {
    val p = p0 ?: ByteArray(0)
    val found = ArrayList<ByteArray>()
    var q = 0
    while (q < p.size) {
        val c = pathComponent(p, q)
        if (c[1] > c[0]) found.add(p.copyOfRange(c[0], c[1]))
        q = c[1] + 1
    }
    if (found.size > 1) {
        wfdb_error(
            "setwfdb: wfdb-x reads from a single input directory; use " +
                "wfdbx_set_input_dir (or legacy mode for the WFDB search path)\n"
        )
        return -1
    }
    val d = found.firstOrNull()
    putInputDir(d)
    io.setwfdbInputDir = d
    io.setwfdbCalled = true
    return 0
}

/**
 * Sets the input directory, from which files with a relative name are read:
 * NAME is read as DIR/NAME.
 *
 * [dir] is a local directory, a ~ path or the URL of a directory. A URL is
 * opened only when network access is on (see [wfdbx_set_network]). null or
 * an empty string restores the default: the value of the environment
 * variable WFDBX_INPUT_DIR, or the current directory if it is not set.
 * Returns the previous setting (null if none was set). Legacy mode does not
 * use this setting.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbx_set_input_dir(dir: ByteArray?): ByteArray? {
    initInputDir()
    val previous = io.inputDir
    io.inputDir = null
    putInputDir(dir?.let { cstr(it) })
    return previous
}

/** [wfdbx_set_input_dir] with a string. */
fun Wfdb.wfdbx_set_input_dir(dir: String): ByteArray? = wfdbx_set_input_dir(dir.latin1())

/**
 * Returns the input directory (see [wfdbx_set_input_dir]), or null if none is
 * set.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbx_get_input_dir(): ByteArray? {
    initInputDir()
    return io.inputDir
}

/** Reads WFDBX_OUTPUT_DIR on first use (a URL is refused). */
private fun Wfdb.initOutputDir() {
    if (io.outputDirInit) return
    io.outputDirInit = true
    val p = getenv("WFDBX_OUTPUT_DIR")
    if (p != null && p.isNotEmpty()) {
        if (isUrl(p)) {
            wfdb_error(OUTPUT_URL_ERROR)
        } else {
            io.envOutputDir = p
            io.outputDir = p
        }
    }
}

/**
 * Sets the output directory, in which files with a relative name are
 * created: NAME is written as DIR/NAME.
 *
 * [dir] is a local directory or a ~ path. Missing directories are created
 * when a file is written. null or an empty string restores the default: the
 * value of the environment variable WFDBX_OUTPUT_DIR, or the current
 * directory if it is not set. Returns the previous setting (null if none
 * was set). The setting is kept by wfdbquit, and also applies in legacy
 * mode.
 *
 * A URL is refused with the message "wfdbx_set_output_dir: the output
 * directory must be a local directory"; the setting is then unchanged, and
 * the current value is returned.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbx_set_output_dir(dir0: ByteArray?): ByteArray? {
    initOutputDir()
    val dir = dir0?.let { cstr(it) }
    if (dir != null && isUrl(dir)) {
        wfdb_error(OUTPUT_URL_ERROR)
        return io.outputDir
    }
    val new = if (dir != null && dir.isNotEmpty()) dir else io.envOutputDir
    val previous = io.outputDir
    io.outputDir = new
    return previous
}

/** [wfdbx_set_output_dir] with a string. */
fun Wfdb.wfdbx_set_output_dir(dir: String): ByteArray? = wfdbx_set_output_dir(dir.latin1())

/**
 * Returns the output directory (see [wfdbx_set_output_dir]), or null if none is
 * set.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbx_get_output_dir(): ByteArray? {
    initOutputDir()
    return io.outputDir
}

/**
 * Turns network access on (on > 0) or off (on == 0). With network access
 * on, names that are http:// or https:// URLs are read. A negative [on]
 * restores the default: on if the environment variable WFDBX_NETWORK is a
 * nonzero number, otherwise off. Returns the previous setting (1: on, 0:
 * off). Legacy mode has no network access.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbx_set_network(on: Int): Int {
    val previous = wfdbx_get_network()
    io.network = if (on < 0) io.envNetwork else on != 0
    return previous
}

/**
 * Returns 1 if network access is on, 0 otherwise (see [wfdbx_set_network]).
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbx_get_network(): Int {
    if (io.network == null) {
        val p = getenv("WFDBX_NETWORK")
        io.envNetwork = p != null && strtol(p, 10).value != 0L
        io.network = io.envNetwork
    }
    return if (io.network == true) 1 else 0
}

/**
 * Turns legacy mode on (on != 0) or off, and returns the previous setting
 * (1: on, 0: off).
 *
 * In legacy mode, the library behaves exactly as the original WFDB library
 * 10.7.0, including its assumed signal parameters and its search for
 * files. Legacy mode is off by default. Use it only to reproduce old
 * results. See docs/DIVERGENCES.md for what changes.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbx_set_legacy(on: Int): Int {
    val previous = if (legacy) 1 else 0
    legacy = on != 0
    return previous
}

/**
 * Returns 1 if legacy mode is on, 0 otherwise (see [wfdbx_set_legacy]).
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbx_get_legacy(): Int = if (legacy) 1 else 0

/**
 * WFDB-x addition (C `wfdbx_legacy_args(&argc, &argv)`), called by the
 * tools before anything else: if the first argument after the program name
 * (argv[1]) is exactly "--legacy", removes it from [argv], turns legacy
 * mode on and returns 1; otherwise changes nothing and returns 0. Only the
 * first argument is recognized. It also enables the check of write errors
 * at [wfdbx.cstd.exit] (the exit status of the tools).
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbx_legacy_args(argv: MutableList<ByteArray>): Int {
    if (argv.isNotEmpty()) exitCheckInit(argv[0], this) // wfdb-x: see wfdbx.cstd.exit
    if (argv.size < 2 || !beq(argv[1], "--legacy")) return 0
    argv.removeAt(1)
    wfdbx_set_legacy(1)
    return 1
}

/**
 * Closes [fp], a file named [name] that an application has written itself,
 * and returns the status of [WfdbFile.close]. In normal mode, if the file
 * could not be written or closed, prints "PNAME: write error on NAME" and
 * counts a write error (see [wfdbx_write_errors]); legacy mode prints and
 * counts nothing.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbx_fclose_output(fp: WfdbFile, pname: ByteArray, name: ByteArray): Int {
    val status = fp.close()
    if (status != 0 && !legacy) {
        eprintf("%s: write error on %s\n", pname, name)
        wfdbx_note_write_error()
    }
    return status
}

/**
 * wfdb-x: the name of the local file that wfdb_open(name, NULL, WFDB_WRITE)
 * creates in normal mode, or null if it creates none (the standard output,
 * or a URL).
 */
internal fun Wfdb.wfdbxOutputFile(name0: ByteArray): ByteArray? {
    val name = cstr(name0)
    if (name.isEmpty() || beq(name, "-")) return null
    val r = expandRecord(name)
    if (isUrl(r)) return null
    return resolve(r, true)
}

/**
 * The location of the file [name] in normal mode: an absolute name or a URL
 * as given, a ~ name expanded, and a relative name under the input
 * directory (for reading) or the output directory ([output]), if one is set.
 */
private fun Wfdb.resolve(name: ByteArray, output: Boolean): ByteArray {
    if (name.at(0) == '~'.code) return expandHome(name)
    if (isAbsolutePath(name) || isUrl(name)) return name
    val dir = if (output) {
        initOutputDir()
        io.outputDir
    } else {
        initInputDir()
        io.inputDir
    }
    return if (dir == null) name else join(expandHome(dir), name, if (output) DSEP else '/'.code)
}

/**
 * The name of the file most recently opened by [wfdb_open] (C's wfdb_filename).
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdb_filename(): ByteArray = io.filename

/**
 * `wfdb_open(type, record, mode)`: opens a WFDB file, named RECORD.TYPE (or
 * TYPE, if [record] is empty or null; "-" is the standard input or output;
 * a record name ending in "/" names the record of that directory, "a/b/"
 * meaning "a/b/b").
 *
 * WFDB-x, normal mode: the file is opened at the one location its name
 * designates; nothing is searched. An absolute name, or a URL (read only,
 * and only with network access, see [wfdbx_set_network]), is used as given;
 * a name beginning with ~ is expanded (the home directory); any other
 * (relative) name is read under the input directory and written under the
 * output directory, if one is set, otherwise relative to the current
 * directory. For reading, the type truncated to 3 characters is also tried
 * there.
 *
 * Legacy mode, as in C: for input ([WFDB_READ]), the file is looked for in
 * each directory of the WFDB path (with %r in a path component replaced by
 * the current record name, %Nr by its first N characters), then with the
 * type truncated to 3 characters, and the directory where it was found is
 * added to the path; URLs are not opened. For output ([WFDB_WRITE],
 * [WFDB_APPEND]), it is created in the current directory (or the directory
 * given in the record name), within the output directory if one is set.
 *
 * Translation of the C function wfdb_open() (lib/wfdbio.c, WFDB 10.7.0): same
 * arguments and results. Differences: a file is opened only where its name says
 * (under the input or output directory, or as given), never searched for, and a
 * URL is read only if network access is on; see docs/DIVERGENCES.md.
 */
fun Wfdb.wfdb_open(s0: ByteArray?, record0: ByteArray?, mode: Int): WfdbFile? {
    var s = s0?.let { cstr(it) } ?: ByteArray(0)
    val rc = record0?.let { cstr(it) }
    val record: ByteArray
    if (rc != null && rc.isNotEmpty()) {
        record = rc
    } else if (s.isNotEmpty()) {
        record = s
        s = ByteArray(0)
    } else {
        return null
    }
    if (beq(record, "-")) {
        // wfdb-x: the standard output is an output file (see wfdbx_write_errors)
        return if (mode == WFDB_READ) WfdbFile.stdin() else WfdbFile.stdout().also { it.out = true }
    }
    // If the record name ends with '/', append the last component of the
    // directory name ("foo/bar/" becomes "foo/bar/bar").
    val r = expandRecord(record)

    if (mode == WFDB_WRITE || mode == WFDB_APPEND) {
        var name = spr1(r, s)
        initOutputDir()
        if (!legacy) {
            // wfdb-x: a relative name in the output directory, if one is
            // set; a URL cannot be written
            if (isUrl(name)) {
                io.filename = name
                return null
            }
            name = resolve(name, true)
        } else {
            val dir = io.outputDir
            // wfdb-x: legacy mode: any name in the output directory
            if (dir != null) name = bcat(dir, byteArrayOf(DSEP.toByte()), name)
        }
        io.filename = name
        return wfdb_fopen(name, if (mode == WFDB_WRITE) "wb" else "ab")
    }

    // wfdb-x: in normal mode, the file is opened at the one location that
    // its name designates (see resolve); nothing is searched.
    if (!legacy) return openAt(resolve(r, false), s)

    if (io.pathList.isEmpty()) getwfdb()
    val plist = io.pathList.toList()
    for (c in plist) {
        // Substitute the record name for %r (or its first N characters for
        // %Nr) in the path component.
        val b = ByteVec(64)
        val pr = c.prefix
        val n = pr.size
        var i = 0
        while (i < n) {
            val ch = pr.at(i)
            if (ch == '%'.code) {
                i++
                val ch2 = if (i < n) pr.at(i) else 0
                if (ch2 == 'r'.code) {
                    b.addAll(io.irec)
                    i++
                } else if (ch2 >= '1'.code && ch2 <= '9'.code && i + 1 < n && pr.at(i + 1) == 'r'.code) {
                    val k = minOf(ch2 - '0'.code, io.irec.size)
                    b.addAll(io.irec, 0, k)
                    i += 2
                } else {
                    if (ch2 != 0) b.add(ch2)
                    i++
                }
            } else {
                b.add(ch)
                i++
            }
        }
        if (c.ptype == WFDB_NET) continue // remote files: not in legacy mode
        if (b.size > 0 && b.last() != DSEP) b.add(DSEP)
        b.addAll(r)
        val base = b.toByteArray()
        io.filename = spr1(base, s)
        localFopen(io.filename, "rb", true)?.let {
            wfdb_addtopath(io.filename)
            return it
        }
        val longFilename = io.filename
        io.filename = spr2(base, s)
        if (!io.filename.contentEquals(longFilename)) {
            localFopen(io.filename, "rb", true)?.let {
                wfdb_addtopath(io.filename)
                return it
            }
        }
    }
    return null
}

/** [wfdb_open] with strings. */
fun Wfdb.wfdb_open(s: String?, record: String?, mode: Int): WfdbFile? = wfdb_open(s?.latin1(), record?.latin1(), mode)

/**
 * wfdb-x: opens the file at location [p] (as resolved, or in the directory
 * of a header) for reading, trying the two forms of the name (P.TYPE, then
 * P.TYP) there.
 */
private fun Wfdb.openAt(p: ByteArray, s: ByteArray): WfdbFile? {
    val name = spr1(p, s)
    io.filename = name
    wfdb_fopen(name, "rb")?.let { return it }
    val short = spr2(p, s)
    io.filename = short
    if (!short.contentEquals(name)) return wfdb_fopen(short, "rb")
    return null
}

/**
 * wfdb-x: opens, for reading, a file named in the header of record
 * [record] (a signal file, or a segment of a multi-segment record, of type
 * [s]): [name], in the directory [dir] of that header (as returned by
 * [wfdbx_dirname]; null if unknown, for a header read from the standard
 * input: then name is resolved as any relative name). name must be in that
 * directory or below it (otherwise "init: file NAME named in the header of
 * record RECORD is not in the header's directory" is reported); the signal
 * file name "-" (the standard input) is also accepted.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun Wfdb.wfdbx_open_in(dir: ByteArray?, s: ByteArray?, name0: ByteArray, record: ByteArray): WfdbFile? {
    val name = cstr(name0)
    if (beq(name, "-")) return wfdb_open(s, name, WFDB_READ)
    if (!inHeaderDir(name)) {
        wfdb_error(cformat("init: file %s named in the header of record %s is not in the header's directory\n", name, record))
        return null
    }
    if (dir == null) return wfdb_open(s, name, WFDB_READ)
    return openAt(bcat(dir, name), s?.let { cstr(it) } ?: ByteArray(0))
}

/**
 * `wfdb_fopen(fname, mode)`: opens a file as the WFDB library does: a
 * directory cannot be opened for reading; when a file cannot be created
 * ("wb" or "ab"), the missing directories in its path are created and the
 * file is opened again.
 *
 * WFDB-x, normal mode: an http:// or https:// URL is fetched (read only;
 * see [wfdbx_set_network]), and names containing ".." are accepted. Legacy
 * mode, as in C (built without network support): names containing ".." or
 * "://" are rejected.
 *
 * Translation of the C function wfdb_fopen() (lib/wfdbio.c, WFDB 10.7.0): same
 * arguments and results. Differences: a URL is read only if network access is
 * on, and names containing ".." are accepted; see docs/DIVERGENCES.md.
 */
fun Wfdb.wfdb_fopen(fname0: ByteArray, mode: String): WfdbFile? {
    val fname = cstr(fname0)
    if (legacy) return localFopen(fname, mode, true)
    if (isUrl(fname)) return if (mode.startsWith("r")) fetchOpen(fname) else null
    return localFopen(fname, mode, false)
}

/**
 * wfdb-x: opens a URL for reading: if network access is allowed, the file
 * is read in full (once per process: the contents, or the failure, are
 * kept), and read from memory.
 */
private fun Wfdb.fetchOpen(url: ByteArray): WfdbFile? {
    if (wfdbx_get_network() == 0) {
        if (!networkWarned) {
            networkWarned = true
            wfdb_error(cformat("wfdb-x: network access is disabled; set WFDBX_NETWORK=1 or call wfdbx_set_network(1) to open %s\n", url))
        }
        return null
    }
    val key = url.latin1()
    val cached = withGlobalLock { if (fetched.containsKey(key)) Pair(true, fetched[key]) else Pair(false, null) }
    val data: ByteArray?
    if (cached.first) {
        data = cached.second
    } else {
        val r = Platform.fetchUrl(url)
        if (r.data == null && r.toolMissing && !curlWarned) {
            curlWarned = true
            wfdb_error("wfdb-x: network access needs the curl program, which was not found\n")
        }
        data = r.data
        withGlobalLock { fetched[key] = data }
    }
    val f = WfdbFile.fromBytes(data ?: return null)
    f.remote = true
    return f
}

/**
 * `wfdb_checkname(name, description)`: 0 if [name] contains only letters,
 * digits, "_", "~", "-" and "/"; otherwise prints "init: illegal character
 * N in DESCRIPTION name" and returns -1.
 *
 * wfdb-x: a record name (description "record") may be a path; outside
 * legacy mode only its last component (the record's own name) is checked,
 * so that directories with other characters (such as "my.data/rec") can be
 * written.
 *
 * Translation of the C function wfdb_checkname() (lib/wfdbio.c, WFDB 10.7.0):
 * same arguments and results. Differences: only the last component of a record
 * name is checked; see docs/DIVERGENCES.md.
 */
fun Wfdb.wfdb_checkname(name0: ByteArray, desc: String): Int {
    var name = cstr(name0)
    if (desc == "record" && !legacy) {
        val k = name.lastIndexOf(DSEP.toByte())
        if (k >= 0) name = name.copyOfRange(k + 1, name.size)
    }
    var i = 0
    while (true) {
        val c = name.at(i)
        if (isalnum(c) || c == '_'.code || c == '~'.code || c == '-'.code || c == DSEP) {
            i++
        } else {
            wfdb_error(cformat("init: illegal character %d in %s name\n", c.toByte().toInt(), desc))
            return -1
        }
        if (i >= name.size) return 0
    }
}

/**
 * `wfdb_setirec(record)`: sets the current record name (its last path
 * component, at most [WFDB_MAXRNL] bytes), used for %r in the WFDB path.
 * "-" is ignored.
 *
 * Translation of the C function wfdb_setirec() (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdb_setirec(p0: ByteArray) {
    val p = cstr(p0)
    val k = p.lastIndexOf(DSEP.toByte())
    val r = if (k >= 0) p.copyOfRange(k + 1, p.size) else p
    if (!beq(r, "-")) io.irec = r.copyOf(minOf(r.size, WFDB_MAXRNL))
}

/**
 * `wfdb_getirec()`: the current record name (null if not set).
 *
 * Translation of the C function wfdb_getirec() (lib/wfdbio.c, WFDB 10.7.0): same arguments and results.
 */
fun Wfdb.wfdb_getirec(): ByteArray? = if (io.irec.isEmpty()) null else io.irec.copyOf()

/**
 * `wfdb_parse_path(path)`: splits a WFDB path into its components
 * (separated by ";", spaces, tabs or newlines; ":" also separates local
 * components, but not the "://" of URLs).
 *
 * Translation of the C function wfdb_parse_path() (lib/wfdbio.c, WFDB 10.7.0):
 * same arguments and results. Differences: it is used only in legacy mode; see
 * docs/DIVERGENCES.md.
 */
fun Wfdb.wfdb_parse_path(p: ByteArray?): Int {
    io.pathList.clear()
    val s = cstr(p ?: return 0)
    val n = s.size
    var q = 0
    while (q < n) {
        val c = pathComponent(s, q)
        io.pathList.add(PathComponent(s.copyOfRange(c[0], c[1]), c[2]))
        q = c[1]
        if (q < n) q++
    }
    return 0
}

/** The prefixes of the WFDB path components (for tests). */
internal fun Wfdb.pathPrefixes(): List<ByteArray> = io.pathList.map { it.prefix }

/**
 * `wfdb_addtopath(pathname)`: moves (or adds) the directory of [pathname]
 * to the front of the WFDB path (after ".", if "." is first), so that other
 * files of the same record are found quickly.
 *
 * Translation of the C function wfdb_addtopath() (lib/wfdbio.c, WFDB 10.7.0):
 * same arguments and results. Differences: it is used only in legacy mode; see
 * docs/DIVERGENCES.md.
 */
fun Wfdb.wfdb_addtopath(s0: ByteArray) {
    val s = cstr(s0)
    if (s.isEmpty()) return
    fun isSep(c: Int) = c == '/'.code || c == '\\'.code || c == ':'.code
    var p = s.size - 1
    while (p >= 0 && !isSep(s.at(p))) p--
    if (p == 0 && isSep(s.at(0))) p++
    if (p < 0) return
    if (io.wfdbpath == null) getwfdb()
    if (io.pathList.isEmpty()) return
    val plist = io.pathList
    var found: PathComponent? = null
    for (idx in plist.indices) {
        // strncmp(prefix, s, p) == 0
        val pre = plist[idx].prefix
        if (pre.size >= p && pre.copyOf(p).contentEquals(s.copyOf(p))) {
            if (idx == 0 || (idx == 1 && beq(plist[0].prefix, "."))) return // no changes needed
            found = plist.removeAt(idx)
            break
        }
    }
    val c = found ?: run {
        val prefix = s.copyOf(p)
        PathComponent(prefix, if (prefix.indexOf("://".latin1()) >= 0) WFDB_NET else WFDB_LOCAL)
    }
    if (beq(plist[0].prefix, ".")) plist.add(1, c) else plist.add(0, c)
}

/**
 * C `wfdbfile(type, record)`: the pathname of a WFDB file (found as
 * [wfdb_open] finds it), or null. With both arguments null, the name of the
 * file most recently opened.
 *
 * Translation of the C function wfdbfile() (lib/wfdbio.c, WFDB 10.7.0): same
 * arguments and results. Differences: the file is found as wfdb_open() finds
 * it, not by a search of the WFDB path; see docs/DIVERGENCES.md.
 */
fun Wfdb.wfdbfile(s: ByteArray?, record: ByteArray?): ByteArray? {
    if (s == null && record == null) return io.filename.copyOf()
    val rec = record?.let { wfdb_striphea(it) }
    val f = wfdb_open(s, rec, WFDB_READ) ?: return null
    f.close()
    return io.filename.copyOf()
}

/** [wfdbfile] with strings. */
fun Wfdb.wfdbfile(s: String?, record: String?): ByteArray? = wfdbfile(s?.latin1(), record?.latin1())

/** C `wfdbversion()` (see the top-level [wfdbversion]). */
fun Wfdb.wfdbversion(): ByteArray = wfdbx.wfdbversion()

// ===========================================================================
// Top-level functions (default instance)

/** C `getwfdb()` on the default instance. */
fun getwfdb(): ByteArray = wfdbDefault().getwfdb()

/** C `setwfdb(path)` on the default instance. */
fun setwfdb(p: ByteArray?) = wfdbDefault().setwfdb(p)

/** C `setwfdb(path)` on the default instance. */
fun setwfdb(p: String) = wfdbDefault().setwfdb(p)

/** C `resetwfdb()` on the default instance. */
fun resetwfdb() = wfdbDefault().resetwfdb()

/** C `wfdbquiet()` on the default instance. */
fun wfdbquiet() = wfdbDefault().wfdbquiet()

/** C `wfdbverbose()` on the default instance. */
fun wfdbverbose() = wfdbDefault().wfdbverbose()

/** C `wfdberror()` on the default instance. */
fun wfdberror(): ByteArray = wfdbDefault().wfdberror()

/** C `wfdb_error` (message already formatted) on the default instance. */
fun wfdb_error(msg: ByteArray) = wfdbDefault().wfdb_error(msg)

/** C `wfdb_error` on the default instance. */
fun wfdb_error(msg: String) = wfdbDefault().wfdb_error(msg)

/** C `wfdbmemerr(behavior)` on the default instance. */
fun wfdbmemerr(behavior: Int) = wfdbDefault().wfdbmemerr(behavior)

/** C `wfdb_me_fatal()` on the default instance. */
fun wfdb_me_fatal(): Int = wfdbDefault().wfdb_me_fatal()

/** C `wfdbfile(type, record)` on the default instance. */
fun wfdbfile(s: ByteArray?, record: ByteArray?): ByteArray? = wfdbDefault().wfdbfile(s, record)

/** C `wfdbfile(type, record)` on the default instance. */
fun wfdbfile(s: String?, record: String?): ByteArray? = wfdbDefault().wfdbfile(s, record)

/**
 * Sets the output directory of the default instance (see
 * [Wfdb.wfdbx_set_output_dir]).
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_set_output_dir(dir: ByteArray?): ByteArray? = wfdbDefault().wfdbx_set_output_dir(dir)

/**
 * Sets the output directory of the default instance.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_set_output_dir(dir: String): ByteArray? = wfdbDefault().wfdbx_set_output_dir(dir)

/**
 * The output directory of the default instance.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_get_output_dir(): ByteArray? = wfdbDefault().wfdbx_get_output_dir()

/**
 * Sets the input directory of the default instance (see
 * [Wfdb.wfdbx_set_input_dir]).
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_set_input_dir(dir: ByteArray?): ByteArray? = wfdbDefault().wfdbx_set_input_dir(dir)

/**
 * Sets the input directory of the default instance.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_set_input_dir(dir: String): ByteArray? = wfdbDefault().wfdbx_set_input_dir(dir)

/**
 * The input directory of the default instance.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_get_input_dir(): ByteArray? = wfdbDefault().wfdbx_get_input_dir()

/**
 * Turns network access on or off for the default instance (see
 * [Wfdb.wfdbx_set_network]).
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_set_network(on: Int): Int = wfdbDefault().wfdbx_set_network(on)

/**
 * Whether network access is on for the default instance.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_get_network(): Int = wfdbDefault().wfdbx_get_network()

/**
 * Turns legacy mode on or off for the default instance (see
 * [Wfdb.wfdbx_set_legacy]).
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_set_legacy(on: Int): Int = wfdbDefault().wfdbx_set_legacy(on)

/**
 * Whether legacy mode is on for the default instance.
 *
 * Part of WFDB-x; not in the original WFDB package.
 */
fun wfdbx_get_legacy(): Int = wfdbDefault().wfdbx_get_legacy()

/** `wfdbx_legacy_args(&argc, &argv)` on the default instance (see [Wfdb.wfdbx_legacy_args]). */
fun wfdbx_legacy_args(argv: MutableList<ByteArray>): Int = wfdbDefault().wfdbx_legacy_args(argv)

/** `wfdb_open(type, record, mode)` on the default instance. */
fun wfdb_open(s: ByteArray?, record: ByteArray?, mode: Int): WfdbFile? = wfdbDefault().wfdb_open(s, record, mode)

/** `wfdb_open(type, record, mode)` on the default instance. */
fun wfdb_open(s: String?, record: String?, mode: Int): WfdbFile? = wfdbDefault().wfdb_open(s, record, mode)

/** `wfdb_fopen(fname, mode)` on the default instance. */
fun wfdb_fopen(fname: ByteArray, mode: String): WfdbFile? = wfdbDefault().wfdb_fopen(fname, mode)

/** `wfdb_checkname(name, description)` on the default instance. */
fun wfdb_checkname(name: ByteArray, desc: String): Int = wfdbDefault().wfdb_checkname(name, desc)

/** `wfdb_setirec(record)` on the default instance. */
fun wfdb_setirec(record: ByteArray) = wfdbDefault().wfdb_setirec(record)

/** `wfdb_getirec()` on the default instance. */
fun wfdb_getirec(): ByteArray? = wfdbDefault().wfdb_getirec()

/** `wfdb_parse_path(path)` on the default instance. */
fun wfdb_parse_path(p: ByteArray?): Int = wfdbDefault().wfdb_parse_path(p)

/** `wfdb_addtopath(pathname)` on the default instance. */
fun wfdb_addtopath(s: ByteArray) = wfdbDefault().wfdb_addtopath(s)

/** The name of the file most recently opened by wfdb_open on the default instance. */
fun wfdb_filename(): ByteArray = wfdbDefault().wfdb_filename()

/** `wfdbx_open_in(dir, type, name, record)` on the default instance. */
fun wfdbx_open_in(dir: ByteArray?, s: ByteArray?, name: ByteArray, record: ByteArray): WfdbFile? =
    wfdbDefault().wfdbx_open_in(dir, s, name, record)
