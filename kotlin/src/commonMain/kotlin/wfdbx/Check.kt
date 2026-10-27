// Checking a record: checkRecord reads a record's header, signal files and
// annotation files with the library's functions, and reports every
// problem it finds, each with a Severity (port of
// python/src/wfdbx/check.py, through rust/src/check.rs).
//
// | Severity | Meaning |
// |---|---|
// | error | the record is damaged or does not follow the WFDB format: programs will read wrong data or fail |
// | warning | the record can be read, but something is missing or unusual, and may give wrong results |
// | info | a fact worth knowing, such as invalid (missing) samples |
//
// It checks for problems similar to those found by Benjamin Moody's
// wfdbcheck (https://github.com/bemoody/wfdbcheck).
//
// checkRecord is specified in the same way for the seven languages (the
// messages, their order and the formatting of numbers are identical); the
// Python implementation (python/src/wfdbx/check.py) is the reference. The
// checks were designed for wfdb-x; no code or text of wfdbcheck was used. The
// header file's text is read only for the checks of its lines and of the
// record name.
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

package wfdbx

import wfdbx.cstd.Platform
import wfdbx.cstd.cformat
import wfdbx.cstd.cstr
import wfdbx.cstd.latin1

/** The severity of an [Issue]. */
enum class Severity(
    /** "error", "warning" or "info". */
    val text: String,
) {
    /** The record is damaged or does not follow the WFDB format: programs will read wrong data or fail. */
    ERROR("error"),

    /** The record can be read, but something is missing or unusual, and may give wrong results. */
    WARNING("warning"),

    /** A fact worth knowing, such as invalid (missing) samples. */
    INFO("info"),
    ;

    override fun toString(): String = text
}

/** A problem found by [checkRecord]. */
data class Issue(
    /** Error, warning or info. */
    val severity: Severity,
    /** A stable identifier, such as "checksum" or "gain_missing". */
    val code: String,
    /** Where the problem is: "" (the record), "signal N", "segment SEG", "segment SEG, signal N" or "annotator ANN". */
    val where: String,
    /** The description of the problem. */
    val message: String,
) {
    /** `SEVERITY: WHERE: MESSAGE` (without `WHERE: ` for the record itself). */
    override fun toString(): String = if (where.isEmpty()) "$severity: $message" else "$severity: $where: $message"
}

/**
 * The result of [checkRecord]. [toString] gives the text form: one line per
 * issue (`SEVERITY: WHERE: MESSAGE`), or `no problems found`; [lines] gives
 * the lines.
 */
data class CheckReport(
    /** The record name, as given. */
    val record: String,
    /** True if no issue has the severity [Severity.ERROR]. */
    val ok: Boolean,
    /** The problems, in the order of the checks. */
    val issues: List<Issue>,
) {
    /** The text form of the report, as a list of lines. */
    fun lines(): List<String> = if (issues.isEmpty()) listOf("no problems found") else issues.map { it.toString() }

    override fun toString(): String = lines().joinToString("\n")
}

// ---------------------------------------------------------------------------
// Text of the messages

private const val INT32_MAX = 2147483647L

/** Values read at a time. */
private const val CHUNK_SAMPLES = 1 shl 20

/** A name quoted for a message: in double quotes, with each byte below 32 or above 126 shown as `\xHH`. */
internal fun checkQuote(name: ByteArray?): String {
    val sb = StringBuilder("\"")
    for (b in name ?: ByteArray(0)) {
        val c = b.toInt() and 0xff
        if (c < 32 || c > 126) {
            sb.append("\\x").append(c.toString(16).padStart(2, '0'))
        } else {
            sb.append(c.toChar())
        }
    }
    return sb.append('"').toString()
}

private fun q(name: ByteArray?): String = checkQuote(name)

/** "1 frame", "2 frames". */
private fun n(k: Long, word: String): String = "$k $word" + if (k == 1L) "" else "s"

/** A message about k items: "1 NOUN VERB WHAT: X" or "K NOUNs VERB WHAT; the first is X". */
private fun count(k: Long, noun: String, verbOne: String, verbMany: String, what: String, x: String): String =
    if (k == 1L) "1 $noun $verbOne $what: $x" else "$k ${noun}s $verbMany $what; the first is $x"

/** [x] with C's `%g`. */
internal fun checkG(x: Double): String = cformat("%g", x).latin1()

private fun g(x: Double): String = checkG(x)

/** The low 16 bits of [x], as a signed value. */
internal fun checkInt16(x: Long): Long {
    val v = x and 0xFFFF
    return if (v and 0x8000L != 0L) v - 0x10000 else v
}

private fun hasControl(s: ByteArray): Boolean = s.any { val c = it.toInt() and 0xff; c < 32 || c == 127 }

private fun isDigit(c: Int): Boolean = c in '0'.code..'9'.code

/** True if [s] is only a number: an optional sign, digits with at most one '.', and at least one digit. */
internal fun checkIsNumber(s0: ByteArray): Boolean {
    var s = s0
    if (s.isNotEmpty() && (s[0] == '+'.code.toByte() || s[0] == '-'.code.toByte())) s = s.copyOfRange(1, s.size)
    if (s.count { it == '.'.code.toByte() } > 1) return false
    val digits = s.filter { it != '.'.code.toByte() }
    return digits.isNotEmpty() && digits.all { isDigit(it.toInt()) }
}

/** "segment s1" + "signal 0" -> "segment s1, signal 0". */
private fun at(prefix: String, sub: String): String = when {
    prefix.isNotEmpty() && sub.isNotEmpty() -> "$prefix, $sub"
    prefix.isEmpty() -> sub
    else -> prefix
}

/** The bits that a storage format can store (formats 8 and 0: no limit). */
private fun capacity(fmt: Int): Int? = when (fmt) {
    80, 508 -> 8
    310, 311 -> 10
    212 -> 12
    16, 61, 160, 516 -> 16
    24, 524 -> 24
    32 -> 32
    else -> null
}

private fun fileChar(c: Int): Boolean =
    c in 'a'.code..'z'.code || c in 'A'.code..'Z'.code || isDigit(c) || c == '_'.code || c == '-'.code ||
        c == '.'.code || c == '/'.code

private fun adcRange(info: Siginfo): LongArray {
    val half = 1L shl (info.adcres - 1)
    val z = info.adczero.toLong()
    return longArrayOf(z - half, z + half - 1)
}

private class Report {
    val issues = ArrayList<Issue>()
    fun add(severity: Severity, code: String, where: String, message: String) {
        issues.add(Issue(severity, code, where, message))
    }
}

private val E = Severity.ERROR
private val W = Severity.WARNING
private val I = Severity.INFO

// ---------------------------------------------------------------------------
// The header file

/**
 * The header file that the library reads for a record: its bytes, the
 * record name that its file name gives (without directory and ".hea"), and
 * its path.
 */
internal class HeaderText(val text: ByteArray, val base: ByteArray, val path: ByteArray)

private fun ByteArray.splitAt(c: Int): List<ByteArray> {
    val out = ArrayList<ByteArray>()
    var start = 0
    for (i in indices) {
        if (this[i].toInt() == c) {
            out.add(copyOfRange(start, i))
            start = i + 1
        }
    }
    out.add(copyOfRange(start, size))
    return out
}

/** The fields of a header line, separated by spaces, tabs and CRs. */
private fun fields(line: ByteArray): List<ByteArray> {
    val out = ArrayList<ByteArray>()
    var start = -1
    for (i in 0..line.size) {
        val sep = i == line.size || line[i] == ' '.code.toByte() || line[i] == '\t'.code.toByte() ||
            line[i] == '\r'.code.toByte()
        if (sep) {
            if (start >= 0) out.add(line.copyOfRange(start, i))
            start = -1
        } else if (start < 0) {
            start = i
        }
    }
    return out
}

/** The fields of the record line of a header (the first line whose first field does not begin with '#'). */
private fun recordLine(text: ByteArray): List<ByteArray>? =
    text.splitAt('\n'.code).map { fields(it) }.firstOrNull { it.isNotEmpty() && it[0][0] != '#'.code.toByte() }

/** The length (number of samples) on the record line: 0 if not given. */
private fun headerLength(text: ByteArray): Long {
    val f = recordLine(text) ?: return 0
    if (f.size < 4) return 0
    var v = 0L
    for (b in f[3]) {
        val c = b.toInt()
        if (!isDigit(c)) break
        // (saturating, as the Rust implementation)
        v = if (v > (Long.MAX_VALUE - 9) / 10) Long.MAX_VALUE else v * 10 + (c - '0'.code)
    }
    return v
}

/** Checks 1.5-1.7: the lines of the header file and its record name. */
internal fun checkText(hdr: HeaderText, where: String, issues: MutableList<Issue>) {
    val rep = Report()
    checkText(hdr, where, rep)
    issues.addAll(rep.issues)
}

private fun checkText(hdr: HeaderText, where: String, rep: Report) {
    val lines = hdr.text.splitAt('\n'.code).toMutableList()
    if (lines.isNotEmpty() && lines.last().isEmpty()) lines.removeAt(lines.size - 1) // (after the final newline)
    for ((k, line0) in lines.withIndex()) {
        val len = if (line0.isNotEmpty() && line0.last() == '\r'.code.toByte()) line0.size - 1 else line0.size
        if (len > 255) rep.add(E, "header_line_long", where, "line ${k + 1} of the header is longer than 255 characters")
    }
    val k = lines.indexOfFirst { l -> l.any { (it.toInt() and 0xff) > 127 } }
    if (k >= 0) rep.add(W, "header_not_ascii", where, "line ${k + 1} of the header contains non-ASCII characters")
    val f = recordLine(hdr.text)
    if (f != null) {
        val f0 = f[0]
        // (up to the first '/' after the first character)
        var j = -1
        for (i in 1 until f0.size) {
            if (f0[i] == '/'.code.toByte()) {
                j = i
                break
            }
        }
        val x = if (j >= 0) f0.copyOf(j) else f0
        if (!x.contentEquals(hdr.base)) {
            rep.add(W, "header_name", where, "the header names the record ${q(x)}, but its file name is ${q(hdr.base)}")
        }
    }
}

/** The header of a record, as read by the library. */
private class HeaderInfo(val nsig: Int, val si: Array<Siginfo>, val fs: Double, val nsamples: Long, val segs: List<Seginfo>)

/**
 * The header file that the library reads for record [name]; null if there
 * is none (no such file, or a record read from another format, such as
 * EDF).
 */
private fun Wfdb.checkHeaderText(name: ByteArray): HeaderText? {
    var p = maxOf(name.size - 1, 0)
    while (p > 0 && name[p].toInt().toChar() !in "./:\\") p--
    val f = if (name.isNotEmpty() && name[p] == '.'.code.toByte()) {
        if (!name.copyOfRange(p + 1, name.size).contentEquals("hea".latin1())) return null // (EDF: no WFDB header)
        wfdb_open(null as ByteArray?, name, WFDB_READ)
    } else {
        wfdb_open("hea".latin1(), name, WFDB_READ)
    } ?: return null
    val fnm = wfdb_filename()
    val path = if (fnm.isNotEmpty()) cstr(fnm) else name
    val text = f.readToEnd()
    f.close()
    var base = path.copyOfRange(wfdbx_dirname(path).size, path.size)
    val hea = ".hea".latin1()
    if (base.size >= 4 && base.copyOfRange(base.size - 4, base.size).contentEquals(hea)) {
        base = base.copyOf(base.size - 4)
    } else if (base.size >= 4 && base.copyOf(4).contentEquals("hea.".latin1())) {
        base = base.copyOfRange(4, base.size)
    }
    return HeaderText(text, base, path)
}

/** Opens the header of record [name] (wfdbquit first); null if it cannot be read. */
private fun Wfdb.checkOpenHeader(name: ByteArray): HeaderInfo? {
    wfdbquit()
    val nsig = isigopen(name, null, 0)
    if (nsig < 0) {
        wfdbquit()
        return null
    }
    val si = Array(nsig) { Siginfo() }
    if (nsig > 0) isigopen(name, si, -nsig)
    val segs = ArrayList<Seginfo>()
    getseginfo(segs)
    val nsamples = wfdbxRecordNsamples(segs.isNotEmpty())
    val fs = sampfreq(null as ByteArray?)
    wfdbquit()
    return HeaderInfo(nsig, si, fs, nsamples, segs)
}

// ---------------------------------------------------------------------------
// Signal data (section 3)

/** Checks 3.1-3.9: reads the signals of the record opened as [name] (header signals [si], header length [ns]). */
private fun Wfdb.checkData(name: ByteArray, si: Array<Siginfo>, prefix: String, ns: Long, lengthMissing: Boolean, rep: Report) {
    val nsig = si.size
    if (nsig == 0) return
    if (si.any { beqb(it.fname, "-") && it.fmt != 0 }) return // (the standard input: not read)
    wfdbquit()
    val opened = Array(nsig) { Siginfo() }
    val k = isigopen(name, opened, nsig)
    if (k < nsig) {
        val have = opened.take(maxOf(k, 0)).map { it.fname }
        val reported = ArrayList<ByteArray?>()
        for (s in si) {
            if (s.fmt != 0 && have.none { bytesEq(it, s.fname) } && reported.none { bytesEq(it, s.fname) }) {
                reported.add(s.fname)
                rep.add(E, "file_unreadable", prefix, "the signal file ${q(s.fname)} cannot be read")
            }
        }
        if (reported.isEmpty()) rep.add(E, "file_unreadable", prefix, "the signal file ${q(si[0].fname)} cannot be read")
        wfdbquit()
        return
    }
    for ((grp, size0) in wfdbxGroupFileSizes().withIndex()) {
        val size = checkSimulatedFileSize ?: size0
        if (size > INT32_MAX) {
            val fname = si.firstOrNull { it.group == grp }?.fname
            rep.add(
                W, "file_large", prefix,
                "the signal file ${q(fname)} has more than 2147483647 bytes, which 32-bit applications cannot handle",
            )
        }
    }
    setgvmode(WFDB_LOWRES)
    val inv = WFDB_INVALID_SAMPLE
    val ranges: Array<LongArray?> = Array(nsig) { if (si[it].adcres in 1..32 && si[it].fmt != 0) adcRange(si[it]) else null }
    val nOut = LongArray(nsig)
    val firstOut = arrayOfNulls<LongArray>(nsig) // (sample, value)
    val nInv = LongArray(nsig)
    val firstInv = LongArray(nsig) { -1 }
    val rows = maxOf(CHUNK_SAMPLES / nsig, 1024)
    val buf = IntArray(rows * nsig)
    var m = 0L // frames read
    var stat: Int
    var residual: IntArray? = null // after ns frames
    // (the checksums: not for EDF, nor for a record with skewed signals,
    // whose samples the library reads ahead)
    val checked = ns > 0 && !wfdbxIsEdf() && (0 until nsig).all { wfdbgetskew(it) == 0 }
    while (true) {
        var want = rows.toLong()
        if (checked && residual == null) want = minOf(want, ns - m)
        val r = getvecs_status(buf, want) // (at most want vectors)
        stat = r.status
        var got = maxOf(r.count, 0L)
        if (stat == -4) got++ // (a checksum error: the frame was read completely)
        for (j in 0 until got.toInt()) {
            val base = j * nsig
            for (s in 0 until nsig) {
                if (si[s].fmt == 0) continue // (a null signal: no data)
                val v = buf[base + s]
                if (v == inv) {
                    nInv[s]++
                    if (firstInv[s] < 0) firstInv[s] = m + j
                } else {
                    val rg = ranges[s] ?: continue
                    val x = v.toLong()
                    if (x < rg[0] || x > rg[1]) {
                        nOut[s]++
                        if (firstOut[s] == null) firstOut[s] = longArrayOf(m + j, x)
                    }
                }
            }
        }
        m += got
        if (checked && residual == null && m >= ns) residual = wfdbxCksumResiduals()
        if (stat == -4) continue
        if (got < want) break
    }
    // (with skewed signals, getvec returns the frames of the files less the
    // largest skew)
    val skew = (0 until nsig).maxOfOrNull { wfdbgetskew(it) } ?: 0
    wfdbquit()
    if (skew != 0 && m > 0) m += skew.toLong()
    for (s in 0 until nsig) {
        val where = at(prefix, "signal $s")
        val fo = firstOut[s]
        val rg = ranges[s]
        if (fo != null && rg != null) {
            rep.add(
                E, "sample_range", where,
                count(nOut[s], "sample", "is", "are", "outside the ADC range (${rg[0]} to ${rg[1]})", "sample ${fo[0]} (value ${fo[1]})"),
            )
        }
        if (firstInv[s] >= 0) {
            rep.add(I, "invalid_samples", where, count(nInv[s], "sample", "is", "are", "invalid (missing data)", "sample ${firstInv[s]}"))
        }
    }
    if (residual != null) {
        for ((s, info) in si.withIndex()) {
            val r = residual.getOrElse(s) { 0 }.toLong()
            if (info.nsamp > 0 && info.fmt != 0 && (r and 0xFFFF) != 0L) {
                rep.add(
                    E, "checksum", at(prefix, "signal $s"),
                    "the checksum does not match: the header gives ${checkInt16(info.cksum.toLong())}, " +
                        "the samples sum to ${checkInt16(info.cksum.toLong() - r)}",
                )
            }
        }
    }
    val endOk = stat == -1 || stat >= 0
    val short = ns > 0 && m < ns && (stat == -1 || stat == -3)
    if (short) rep.add(E, "length_short", prefix, "the signal files end after ${n(m, "frame")}, before the $ns given in the header")
    if (ns > 0 && m > ns) rep.add(W, "length_long", prefix, "the signal files hold ${n(m, "frame")}, more than the $ns given in the header")
    if (lengthMissing && endOk) rep.add(I, "length_unspecified_frames", prefix, "the signal files hold ${n(m, "frame")}")
    if (!endOk && !short) {
        rep.add(E, "read_error", prefix, "the signal data cannot be read after ${n(m, "frame")} (getvec status $stat)")
    }
}

private fun beqb(a: ByteArray?, s: String): Boolean = a != null && a.contentEquals(s.latin1())

private fun bytesEq(a: ByteArray?, b: ByteArray?): Boolean = if (a == null || b == null) a == null && b == null else a.contentEquals(b)

/** wfdb-x (for the tests): a simulated size of the signal files (null: their real sizes). */
internal var checkSimulatedFileSize: Long? = null

// ---------------------------------------------------------------------------
// A record (sections 1-4)

/** Sections 1-4. Returns the record length in samples for the annotation checks (0 if unknown), or null if the header cannot be read. */
private fun Wfdb.checkRecordSignals(record: ByteArray, rep: Report): Long? {
    val hdr = checkHeaderText(record)
    val info = checkOpenHeader(record)
    if (info == null) {
        rep.add(E, "header_unreadable", "", "the header cannot be read")
        if (hdr != null) checkText(hdr, "", rep)
        return null
    }
    val nsig = info.nsig
    val si = info.si
    val fs = info.fs
    val nsamples = info.nsamples
    val segs = info.segs
    if (nsig == 0) rep.add(I, "no_signals", "", "the record has no signals")
    if (fs == 0.0) rep.add(W, "fs_missing", "", "the sampling frequency is not specified")
    val given = if (segs.isEmpty()) nsamples else hdr?.let { headerLength(it.text) } ?: nsamples
    if (given == 0L) rep.add(W, "length_missing", "", "the record length is not specified")
    if (hdr != null) checkText(hdr, "", rep)
    if (nsamples > INT32_MAX) lengthLarge(rep, "")
    if (segs.isEmpty()) {
        if (nsig > 0) {
            checkSpecs(si, record, "", rep, false)
            checkData(record, si, "", nsamples, nsamples == 0L, rep)
        }
        return nsamples
    }
    // A multi-segment record: the segments, next to the master header
    val hpath = hdr?.path ?: (wfdbfile("hea".latin1(), record) ?: ByteArray(0))
    var d = wfdbx_dirname(hpath)
    if (d.isEmpty() || (!isUrl(d) && !isAbsolutePath(d))) {
        var abs = Platform.currentDir() ?: ByteArray(0)
        abs += '/'.code.toByte()
        abs += d
        d = abs
    }
    val variable = segs[0].nsamp == 0L
    var layoutDescs: List<ByteArray?> = emptyList()
    val done = HashSet<String>()
    for ((k, seg) in segs.withIndex()) {
        val sname = cstr(seg.recname)
        val skey = sname.latin1()
        if (skey == "~" || !done.add(skey)) continue
        val prefix = "segment $skey"
        val isLayout = variable && k == 0
        if (!inHeaderDir(sname)) {
            rep.add(E, "segment_unreadable", prefix, "the segment cannot be read")
            continue
        }
        val path = d + sname
        val segHdr = checkHeaderText(path)
        val sinfo = checkOpenHeader(path)
        if (sinfo == null) {
            rep.add(E, "segment_unreadable", prefix, "the segment cannot be read")
            continue
        }
        if (sinfo.segs.isNotEmpty()) {
            rep.add(E, "nested", prefix, "the segment is itself a multi-segment record")
            continue
        }
        if (sinfo.fs > 0.0 && fs > 0.0 && sinfo.fs != fs) {
            rep.add(E, "segment_fs", prefix, "the segment's sampling frequency (${g(sinfo.fs)}) differs from the record's (${g(fs)})")
        }
        if (sinfo.nsig == 0) rep.add(I, "no_signals", prefix, "the record has no signals")
        if (segHdr != null) checkText(segHdr, prefix, rep)
        if (sinfo.nsamples > INT32_MAX) lengthLarge(rep, prefix)
        if (sinfo.nsig > 0) checkSpecs(sinfo.si, path, prefix, rep, !isLayout)
        if (isLayout) {
            layoutDescs = sinfo.si.map { it.desc }
            continue
        }
        if (variable) {
            for ((s, x) in sinfo.si.withIndex()) {
                if (x.fmt != 0 && layoutDescs.none { bytesEq(it, x.desc) }) {
                    rep.add(E, "layout_missing_signal", at(prefix, "signal $s"), "the signal ${q(x.desc)} is not in the layout")
                }
            }
        } else {
            checkLayout(sinfo.si, si, prefix, rep)
        }
        if (sinfo.nsig > 0) checkData(path, sinfo.si, prefix, sinfo.nsamples, false, rep)
    }
    val total = segs.sumOf { it.nsamp }
    if (given > 0 && total != given) {
        rep.add(W, "segment_lengths", "", "the segment lengths add up to ${n(total, "sample")}, but the master header gives $given")
    }
    return total // (the end of the signals)
}

private fun lengthLarge(rep: Report, where: String) {
    rep.add(I, "length_large", where, "the record has more than 2147483647 samples, which 32-bit applications cannot handle")
}

// ---------------------------------------------------------------------------
// Signal specifications (section 2)

/**
 * Checks 2.1-2.13 of the signals [si] of a record opened under the name
 * [openedAs]. [skipNull]: signals of format 0 are not checked (a segment of
 * a multi-segment record).
 */
private fun checkSpecs(si: Array<Siginfo>, openedAs: ByteArray, prefix: String, rep: Report, skipNull: Boolean) {
    val descs = ArrayList<ByteArray>() // of the signals checked
    for ((s, info) in si.withIndex()) {
        val nul = info.fmt == 0
        if (nul && skipNull) continue
        val where = at(prefix, "signal $s")
        val dflt = "record ".latin1() + openedAs + ", signal $s".latin1()
        val d = info.desc
        if (d == null || d.isEmpty() || d.contentEquals(dflt)) {
            rep.add(W, "desc_missing", where, "the signal has no description")
        } else {
            descs.add(d)
            if (checkIsNumber(d)) rep.add(W, "desc_number", where, "the description ${q(d)} is only a number")
            if (hasControl(d)) rep.add(E, "desc_control", where, "the description ${q(d)} contains control characters")
        }
        if (info.fmt == 8) rep.add(W, "format_difference", where, "format 8 stores first differences, which cannot follow steep slopes")
        if (info.gain == 0.0) {
            rep.add(W, "gain_missing", where, "the signal is uncalibrated (no gain is given)")
        } else if (info.gain < 0.0) {
            rep.add(I, "gain_negative", where, "the gain is negative (${g(info.gain)})")
        }
        val units = info.units ?: ByteArray(0)
        if (info.gain != 0.0 && units.isEmpty()) rep.add(W, "units_missing", where, "the units are not specified")
        if (hasControl(units)) rep.add(E, "units_control", where, "the units ${q(units)} contain control characters")
        val b = info.adcres
        val cap = if (nul) null else capacity(info.fmt)
        if (b == 0) {
            rep.add(W, "adcres_missing", where, "the ADC resolution is not specified")
        } else if (cap != null) {
            if (b > cap) {
                rep.add(E, "adcres_too_large", where, "the ADC resolution ($b bits) exceeds what format ${info.fmt} can store ($cap bits)")
            } else if (b >= 1) {
                val rg = adcRange(info)
                val fmin = -(1L shl (cap - 1))
                val fmax = (1L shl (cap - 1)) - 1
                if (rg[0] < fmin || rg[1] > fmax) {
                    rep.add(
                        E, "adc_range", where,
                        "the ADC range (${rg[0]} to ${rg[1]}) does not fit in format ${info.fmt} ($fmin to $fmax)",
                    )
                }
            }
        }
        val fname = info.fname ?: ByteArray(0)
        if (!nul && !beqb(fname, "-") && !beqb(fname, "~") && !fname.all { fileChar(it.toInt() and 0xff) }) {
            rep.add(
                W, "filename", where,
                "the signal file name ${q(fname)} contains characters other than letters, digits, '_', '-' and '.'",
            )
        }
    }
    val seen = ArrayList<Pair<ByteArray, IntArray>>()
    for (d in descs) {
        val e = seen.firstOrNull { it.first.contentEquals(d) }
        if (e != null) e.second[0]++ else seen.add(Pair(d, intArrayOf(1)))
    }
    for ((d, k) in seen) {
        if (k[0] > 1) rep.add(W, "desc_duplicate", prefix, "${k[0]} signals have the description ${q(d)}")
    }
}

/** Check 4.6: the signals of a segment of a fixed-layout record match the record's signals. */
private fun checkLayout(ssi: Array<Siginfo>, si: Array<Siginfo>, prefix: String, rep: Report) {
    if (ssi.size != si.size) {
        rep.add(E, "layout_signals", prefix, "the segment has ${n(ssi.size.toLong(), "signal")}, but the record has ${si.size}")
    }
    for (s in 0 until minOf(ssi.size, si.size)) {
        val a = ssi[s]
        val b = si[s]
        if (a.fmt == 0) continue
        val where = at(prefix, "signal $s")
        val flds = listOf(
            Triple("description", q(a.desc), q(b.desc)),
            Triple("units", q(a.units), q(b.units)),
            Triple("gain", g(a.gain), g(b.gain)),
            Triple("baseline", a.baseline.toString(), b.baseline.toString()),
            Triple("samples per frame", a.spf.toString(), b.spf.toString()),
        )
        for ((field, x, y) in flds) {
            if (x != y) {
                rep.add(E, "layout_mismatch", where, "the signal differs from the record's signal $s in its $field ($x, expected $y)")
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Annotators (section 5)

private fun Wfdb.checkAnnotator(record: ByteArray, an: String, length: Long?, rep: Report) {
    val where = "annotator $an"
    if (an.isNotEmpty() && an.all { it in '0'..'9' }) rep.add(W, "annotator_name", where, "the annotator name consists only of digits")
    wfdbquit()
    if (length != null) sampfreq(record) // (the record's frequency, for getann)
    val saved = wfdbxSaveAnnDefs()
    if (annopen(record, arrayOf(Anninfo(fname(an), WFDB_READ)), 1) < 0) {
        wfdbquit()
        wfdbxRestoreAnnDefs(saved)
        rep.add(E, "annotations_unreadable", where, "the annotation file cannot be read")
        return
    }
    val len = length ?: 0L
    val a = Annotation()
    var nread = 0L
    var prev: Long? = null
    var nOrder = 0L
    var order: LongArray? = null
    var nCode = 0L
    var code: LongArray? = null
    var nNull = 0L
    var nul: Long? = null
    var nUndef = 0L
    var undef: LongArray? = null
    var nAfter = 0L
    var after: Long? = null
    var stat: Int
    while (true) {
        stat = getann(0, a)
        if (stat != 0) break
        nread++
        val t = a.time
        val c = a.anntyp
        val p = prev
        if (p != null && t < p) {
            nOrder++
            if (order == null) order = longArrayOf(t, p)
        }
        prev = t
        if (c > ACMAX) {
            nCode++
            if (code == null) code = longArrayOf(t, c.toLong())
        } else if (c == 0) {
            nNull++
            if (nul == null) nul = t
        } else if (annstr(c).contentEquals(cformat("[%d]", c))) {
            nUndef++
            if (undef == null) undef = longArrayOf(t, c.toLong())
        }
        if (len > 0 && t >= len) {
            nAfter++
            if (after == null) after = t
        }
    }
    wfdbquit()
    wfdbxRestoreAnnDefs(saved)
    if (stat != -1) rep.add(E, "annotations_truncated", where, "the annotation file ends unexpectedly after ${n(nread, "annotation")}")
    if (order != null) {
        rep.add(E, "annotations_order", where, count(nOrder, "annotation", "is", "are", "out of order", "at sample ${order[0]}, after sample ${order[1]}"))
    }
    if (code != null) {
        rep.add(E, "annotation_code", where, count(nCode, "annotation", "has", "have", "an invalid code", "at sample ${code[0]} (code ${code[1]})"))
    }
    if (nul != null) rep.add(W, "annotation_null", where, count(nNull, "annotation", "has", "have", "code 0 (NOTQRS)", "at sample $nul"))
    if (undef != null) {
        val x = "at sample ${undef[0]} (code ${undef[1]})"
        val msg = if (nUndef == 1L) "1 annotation uses a code without a mnemonic: $x" else "$nUndef annotations use codes without a mnemonic; the first is $x"
        rep.add(W, "annotation_undefined", where, msg)
    }
    if (after != null) {
        rep.add(
            W, "annotations_after_end", where,
            count(nAfter, "annotation", "is", "are", "after the end of the record (${n(len, "sample")})", "at sample $after"),
        )
    }
}

// ---------------------------------------------------------------------------

/**
 * Checks a record and its annotation files, and reports every problem.
 *
 * The header, the signal specifications, the signal files (every sample is
 * read) and the annotation files of [annotators] are checked. Problems in
 * the record are reported, never thrown. The checks run in normal mode,
 * even if legacy mode is on, and the library prints no messages during the
 * call. It checks for problems similar to those found by Benjamin Moody's
 * wfdbcheck (https://github.com/bemoody/wfdbcheck).
 *
 * Part of wfdb-x; not in the original WFDB package.
 *
 * @param record record name: a name in the input directory, or a full
 *   path, `~` path or URL
 * @param annotators the annotators to check, such as `listOf("atr")`
 * @param inputDir input directory for this call only (null: the current
 *   setting)
 * @param network network access for this call only (null: the current
 *   setting)
 * @return the [CheckReport]: `ok` is true if there is no error; printed,
 *   it has one line per problem, such as `error: signal 1: the checksum
 *   does not match: the header gives 12, the samples sum to 13`, or `no
 *   problems found`
 * @throws WfdbException if [record] is empty ("record must not be empty")
 *
 * ```
 * // 100s: the first minute of record 100 of the MIT-BIH Arrhythmia Database,
 * // included with wfdb-x in tests/data of a copy of the repository
 * val report = checkRecord("100s", listOf("atr"), inputDir = "tests/data")
 * println(report)
 * ```
 */
fun Wfdb.checkRecord(
    record: String,
    annotators: List<String> = emptyList(),
    inputDir: String? = null,
    network: Boolean? = null,
): CheckReport {
    if (record.isEmpty()) throw WfdbException("record must not be empty")
    val rec = fname(record)
    val rep = Report()
    val legacy = wfdbx_set_legacy(0)
    val printing = wfdbxSetErrorPrint(false)
    try {
        withInput(inputDir, network) {
            wfdbquit()
            val length = checkRecordSignals(rec, rep)
            for (a in annotators) checkAnnotator(rec, a, length, rep)
            wfdbquit()
        }
    } finally {
        wfdbxSetErrorPrint(printing)
        wfdbx_set_legacy(legacy)
    }
    return CheckReport(record, rep.issues.none { it.severity == Severity.ERROR }, rep.issues.toList())
}

/** [Wfdb.checkRecord] on the default instance of the thread. */
fun checkRecord(
    record: String,
    annotators: List<String> = emptyList(),
    inputDir: String? = null,
    network: Boolean? = null,
): CheckReport = wfdbDefault().checkRecord(record, annotators, inputDir, network)
