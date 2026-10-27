// rdsamp: print an arbitrary number of samples from each signal (port of
// app/rdsamp.c, through rust/src/bin/rdsamp.rs).
//
// The output is identical to that of the C program. Samples are read in
// blocks with getvecs (equivalent to repeated getvec calls) except when the
// time column is printed with timstr or mstimstr, whose results could depend
// on library state changed while reading (e.g., at the start of a new
// segment); integers are formatted without printf (with identical results)
// for speed.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/rdsamp.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency or gain: the
// sampling frequency is required for time arguments, time columns and XML
// output (-X), and the gain of each selected signal for physical units (-p,
// -P) (the original assumed 250 Hz and 200 adu/mV); unspecified units are
// shown as "nd" (the original showed "mV"); --legacy, as the first argument,
// restores the original behavior. Each change is marked "wfdb-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/rdsamp.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2010 George B. Moody; revised 2017-2020 by
//   Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

// values for timeunits
private const val SECONDS = 1
private const val MINUTES = 2
private const val HOURS = 3
private const val TIMSTR = 4
private const val MSTIMSTR = 5
private const val SHORTTIMSTR = 6
private const val HHMMSS = 7
private const val SAMPLES = 8

// Column widths of the tab-separated output (those of the formats used):
// the time column, and the sample columns (with -P, high precision).
private const val TWIDTH = 15
private const val VWIDTH = 7
private const val VWIDTH_HI = 15

/** What the library puts in a default signal description ("record xxx, signal n"). */
private val DEFAULT_DESC = ", signal ".latin1()

private const val WFDBXMLPROLOG = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
    "<?xml-stylesheet type=\"text/xsl\" href=\"wfdb.xsl\"?>\n" +
    "<!DOCTYPE wfdbsampleset PUBLIC \"-//PhysioNet//DTD WFDB 1.0//EN\" \"http://physionet.org/physiobank/database/XML/wfdb.dtd\">\n"

private val RDSAMP_HELP = arrayOf(
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -c          use CSV (comma-separated value) output format",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -l INTERVAL truncate output after the specified time interval (hh:mm:ss)",
    " -p          print times and samples in physical units (default: raw units)",
    " -P          same as -p, but with greater precision",
    "              -p and -P may be followed by a character to choose a time",
    "              format;  choices are:",
    "  -pd (or -Pd)  print time of day and date if known",
    "  -pe (or -Pe)  print elapsed time as <hours>:<minutes>:<seconds>",
    "  -ph (or -Ph)  print elapsed time in hours",
    "  -pm (or -Pm)  print elapsed time in minutes",
    "  -ps (or -Ps)  print elapsed time in seconds",
    "  -pS (or -PS)  print elapsed time in sample intervals",
    " -s SIGNAL [SIGNAL ...]  print only the specified signal(s)",
    " -S SIGNAL   search for a valid sample of the specified SIGNAL at or after",
    "\t\tthe time specified with -f, and begin printing then",
    " -t TIME     stop at specified time",
    " -v          print column headings",
    " -X          output in WFDB-XML format",
)

private fun rdsampHelp(pname: ByteArray) {
    eprintf("usage: %s -r RECORD [OPTIONS ...]\n", pname)
    for (s in RDSAMP_HELP) eprintf("%s\n", s)
}

/**
 * Escape quotes and backslashes for CSV column headings. (The C version of
 * this function does not terminate for most strings that contain these
 * characters; see docs/KNOWN_C_BEHAVIORS.md.)
 */
private fun escapify(s: ByteArray): ByteArray {
    val r = ByteVec(s.size + 8)
    for (c in cstr(s)) {
        if (c == '\''.code.toByte() || c == '\\'.code.toByte()) r.add('\\'.code)
        r.add(c)
    }
    return r.toByteArray()
}

/** Output buffer (written to the standard output in large pieces). */
private class RdOut {
    val buf = ByteVec(LIMIT + 1024) // (+ a line or so)
    private val tmp = ByteArray(20) // a sign and the 19 digits of a long

    fun maybeFlush() {
        if (buf.size >= LIMIT) flush()
    }

    fun flush() {
        if (!buf.isEmpty()) {
            Stdout.write(buf.bytes, 0, buf.size)
            buf.clear()
        }
    }

    fun puts(s: ByteArray) = buf.addAll(s)

    fun puts(s: String) = buf.addString(s)

    fun printf(fmt: String, vararg args: Any?) {
        sprintfInto(buf, fmt, args)
    }

    /** printf("<lead>%<width>.<prec>f", x) (lead may be 0); fmt is that format (without the lead). */
    fun fixed(lead: Int, x: Double, width: Int, prec: Int, fmt: String) {
        if (lead != 0) buf.add(lead)
        if (!fixedFast(buf, x, width, prec)) sprintfInto(buf, fmt, arrayOf<Any?>(x))
    }

    /** printf("<lead>%<width>ld", v) (lead may be 0). */
    fun integer(lead: Int, v: Long, width: Int) {
        var p = tmp.size
        var u = v
        if (u >= 0) u = -u // (digits from the negative value: no overflow at Long.MIN_VALUE)
        do {
            tmp[--p] = ('0'.code - (u % 10).toInt()).toByte()
            u /= 10
        } while (u != 0L)
        if (v < 0) tmp[--p] = '-'.code.toByte()
        val len = tmp.size - p
        if (lead != 0) buf.add(lead)
        for (k in len until width) buf.add(' '.code)
        buf.addAll(tmp, p, len)
    }

    companion object {
        const val LIMIT = 1 shl 16 // bytes buffered before writing
    }
}

private fun skipSpaces(s: ByteArray): ByteArray {
    var k = 0
    while (k < s.size && s[k] == ' '.code.toByte()) k++
    return s.copyOfRange(k, s.size)
}

/** The rdsamp tool. */
fun Wfdb.rdsampMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    var recordIdx = -1
    var search = -1
    var cflag = 0
    var highres = 0
    var isiglist = 0
    var nosig = 0
    var pflag = 0
    var timeunits = SECONDS
    var vflag = 0
    var xflag = 0
    var from = 0L
    var maxl = 0L
    var to = 0L

    var i = 1
    while (i < argc) {
        val a = argv[i]
        if (a.at(0) == '-'.code) {
            val c1 = a.at(1).toChar()
            val c2 = a.at(2).toChar()
            when (c1) {
                'c' -> cflag = 1 // output in CSV format
                'f' -> { // starting time
                    if (++i >= argc) {
                        eprintf("%s: time must follow -f\n", pname)
                        exit(1)
                    }
                    from = i.toLong()
                }
                'h' -> { // help requested
                    rdsampHelp(pname)
                    exit(0)
                }
                'H' -> highres = 1 // select high-resolution mode
                'l' -> { // maximum length of output follows
                    if (++i >= argc) {
                        eprintf("%s: max output length must follow -l\n", pname)
                        exit(1)
                    }
                    maxl = i.toLong()
                }
                'P', 'p' -> { // output in (high-precision) physical units
                    if (c1 == 'P') pflag++
                    pflag++
                    timeunits = when (c2) {
                        'd' -> TIMSTR
                        'e' -> HHMMSS
                        'h' -> HOURS
                        'm' -> MINUTES
                        'S' -> SAMPLES
                        else -> SECONDS
                    }
                }
                'r' -> { // record name
                    if (++i >= argc) {
                        eprintf("%s: record name must follow -r\n", pname)
                        exit(1)
                    }
                    recordIdx = i
                }
                's' -> { // signal list follows
                    isiglist = i + 1 // index of first argument with a signal #
                    while (i + 1 < argc && argv[i + 1].at(0) != '-'.code) {
                        i++
                        nosig++ // number of elements in signal list
                    }
                    if (nosig == 0) {
                        eprintf("%s: signal list must follow -s\n", pname)
                        exit(1)
                    }
                }
                'S' -> { // search for valid sample of specified signal
                    if (++i >= argc) {
                        eprintf("%s: signal name or number must follow -S\n", pname)
                        exit(1)
                    }
                    search = i
                }
                't' -> { // end time
                    if (++i >= argc) {
                        eprintf("%s: time must follow -t\n", pname)
                        exit(1)
                    }
                    to = i.toLong()
                }
                'v' -> vflag = 1 // verbose output -- include column headings
                'X' -> { // output in WFDB-XML format
                    xflag = 1
                    cflag = 1
                    vflag = 1 // CSV inside an XML wrapper
                }
                else -> {
                    eprintf("%s: unrecognized option %s\n", pname, argv[i])
                    exit(1)
                }
            }
        } else {
            eprintf("%s: unrecognized argument %s\n", pname, argv[i])
            exit(1)
        }
        i++
    }
    if (recordIdx < 0) {
        rdsampHelp(pname)
        exit(1)
    }
    val record = argv[recordIdx].copyOf()
    var nsig = isigopen(record, null, 0)
    if (nsig <= 0) exit(2)
    val navail = nsig
    val si = Array(nsig) { Siginfo() }
    nsig = isigopen(record, si, nsig)
    if (nsig <= 0) exit(2)
    if (legacy) {
        // wfdb-x: the C program's default gain (legacy mode)
        for (k in 0 until nsig) if (si[k].gain == 0.0) si[k].gain = WFDB_DEFGAIN
    }
    if (highres != 0) setgvmode(WFDB_HIGHRES)
    var freq = sampfreq(null)
    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    // the header did not specify one, as legacy mode does).
    fun needsFreq(k: Long) = k > 0 && wfdbx_time_needs_freq(argv[k.toInt()]) != 0
    if (!legacy && freq <= 0.0 &&
        (needsFreq(from) || needsFreq(to) || needsFreq(maxl) || xflag != 0 ||
            (pflag != 0 && (timeunits != SAMPLES || vflag != 0)))
    ) {
        eprintf("%s: sampling frequency of record %s is not specified\n", pname, record)
        exit(2)
    }
    if (from > 0) {
        from = strtim(argv[from.toInt()])
        if (from < 0) from = -from
    }
    if (isigsettime(from) < 0) exit(2)
    if (to > 0) {
        to = strtim(argv[to.toInt()])
        if (to < 0) to = -to
    }
    // number of samples returned by getvec
    val nvec = nsig
    val sig: IntArray = if (nosig > 0) {
        // print samples only from specified signals
        IntArray(nosig) { k ->
            val s = findsig(argv[isiglist + k])
            if (s < 0) {
                eprintf("%s: can't read signal '%s'\n", pname, argv[isiglist + k])
                exit(2)
            }
            s
        }
    } else {
        // print samples from all signals
        IntArray(nsig) { it }
    }

    // wfdb-x: no default gain (the C program assumed 200 adu/mV for
    // uncalibrated signals, as legacy mode does).
    if (pflag != 0 && !legacy) {
        for (s in sig) {
            if (si[s].gain == 0.0) {
                eprintf("%s: signal %d of record %s is uncalibrated\n", pname, s, record)
                exit(2)
            }
        }
    }

    // Reset 'from' if a search was requested.
    if (search >= 0) {
        val s = findsig(argv[search])
        var ok = false
        if (s >= 0) {
            from = tnextvec(s, from)
            ok = from >= 0
        }
        if (!ok) {
            eprintf("%s: can't read signal '%s'\n", pname, argv[search])
            exit(2)
        }
    }

    // Reset 'to' if a duration limit was specified.
    if (maxl > 0) {
        maxl = strtim(argv[maxl.toInt()])
        if (maxl < 0) maxl = -maxl
    }
    if (maxl != 0L && (to == 0L || to > from + maxl)) to = from + maxl

    // Adjust timeunits if starting time or date is undefined.
    if (timeunits == TIMSTR) {
        val p = timstr(0)
        if (p.at(0) != '['.code) {
            timeunits = HHMMSS
        } else if (cstrlen(p) < 16) {
            // "[hh:mm:ss.sss]": no date
            timeunits = SHORTTIMSTR
        } else if (freq > 1.0) {
            timeunits = MSTIMSTR
        }
    }
    if (timeunits == HOURS) freq *= 3600.0
    else if (timeunits == MINUTES) freq *= 60.0

    // Set formats for output.
    var invalid = ""
    val snfmt: String
    val tnfmt: String
    var tufmt: ByteArray = ByteArray(0)
    if (cflag != 0) {
        // CSV output selected
        snfmt = ",'%s'"
        if (pflag != 0) {
            // output in physical units
            when (timeunits) {
                SAMPLES -> {
                    tnfmt = "'sample interval'"
                    tufmt = cformat("'%g sec'", 1.0 / freq)
                    if (tufmt.size > 20) tufmt = tufmt.copyOf(20) // (tustr has 21 bytes)
                }
                SHORTTIMSTR -> { tnfmt = "'Time'"; tufmt = "'hh:mm:ss.mmm'".latin1() }
                TIMSTR -> { tnfmt = "'Time and date'"; tufmt = "'hh:mm:ss dd/mm/yyyy'".latin1() }
                MSTIMSTR -> { tnfmt = "'Time and date'"; tufmt = "'hh:mm:ss.mmm dd/mm/yyyy'".latin1() }
                HHMMSS -> { tnfmt = "'Elapsed time'"; tufmt = "'hh:mm:ss.mmm'".latin1() }
                HOURS -> { tnfmt = "'Elapsed time'"; tufmt = "'hours'".latin1() }
                MINUTES -> { tnfmt = "'Elapsed time'"; tufmt = "'minutes'".latin1() }
                else -> { tnfmt = "'Elapsed time'"; tufmt = "'seconds'".latin1() }
            }
            invalid = ",-"
        } else {
            // output in raw units
            tnfmt = "'sample #'"
        }
    } else {
        // output in tab-separated columns selected
        if (pflag != 0) {
            // output in physical units
            when (timeunits) {
                SAMPLES -> {
                    tnfmt = "sample interval"
                    var speriod = cformat("(%g", 1.0 / freq)
                    if (speriod.size > 10) speriod = speriod.copyOf(10) // (C: speriod[10] = '\0')
                    tufmt = cformat("%10s sec)", speriod)
                    if (tufmt.size > 20) tufmt = tufmt.copyOf(20) // (tustr has 21 bytes)
                }
                SHORTTIMSTR -> { tnfmt = "     Time"; tufmt = "(hh:mm:ss.mmm)".latin1() }
                TIMSTR -> { tnfmt = "   Time      Date    "; tufmt = "(hh:mm:ss dd/mm/yyyy)".latin1() }
                MSTIMSTR -> { tnfmt = "      Time      Date    "; tufmt = "(hh:mm:ss.mmm dd/mm/yyyy)".latin1() }
                HHMMSS -> { tnfmt = "   Elapsed time"; tufmt = "   hh:mm:ss.mmm".latin1() }
                HOURS -> { tnfmt = "   Elapsed time"; tufmt = "        (hours)".latin1() }
                MINUTES -> { tnfmt = "   Elapsed time"; tufmt = "      (minutes)".latin1() }
                else -> { tnfmt = "   Elapsed time"; tufmt = "      (seconds)".latin1() }
            }
            if (pflag > 1) {
                // output in high-precision physical units
                snfmt = "\t%15s"
                invalid = "\t              -"
            } else {
                snfmt = "\t%7s"
                invalid = "\t      -"
            }
        } else {
            // output in raw units
            snfmt = "\t%7s"
            tnfmt = "       sample #"
        }
    }
    val invalidB = invalid.latin1()

    val out = RdOut()

    // Print WFDB-XML prolog if '-X' option selected.
    if (xflag != 0) {
        out.puts(WFDBXMLPROLOG)
        out.printf(
            "<wfdbsampleset>\n<samplingfrequency>%g</samplingfrequency>\n<signals>%d</signals>\n<description>",
            freq, sig.size,
        )
    }
    // Print column headers if '-v' option selected.
    if (vflag != 0) {
        out.puts(tnfmt)
        for (s in sig) {
            // Check if a default signal description was provided by looking
            // for the string ", signal " in the desc field. If so, replace it
            // with a shorter string.
            var d = cstr(si[s].desc ?: ByteArray(0))
            if (d.indexOf(DEFAULT_DESC) >= 0) d = cformat("sig %d", s)
            val p = if (cflag == 0) {
                val l = d.size
                val lim = if (pflag > 1) VWIDTH_HI else VWIDTH
                if (l > lim) d.copyOfRange(l - lim, l) else d
            } else {
                escapify(d)
            }
            out.printf(snfmt, p)
        }
        if (xflag != 0) out.puts("</description>")
        out.puts("\n")
    }

    val chunk = 4096L // frames read at a time
    val width = maxOf(nvec, navail)
    // (with room to spare after the last frame, so that getvecs never has to
    // read a frame into a temporary buffer)
    val vbuf = IntArray(chunk.toInt() * width + width + 64)

    if (pflag != 0) {
        // Print units as a second line of column headers if '-v' selected.
        if (vflag != 0) {
            if (xflag != 0) out.puts("<units>")
            out.puts(tufmt)
            for (s in sig) {
                // wfdb-x: unspecified units are shown as "nd" (C, legacy mode: mV)
                val u = cstr(si[s].units ?: (if (legacy) "mV" else "nd").latin1())
                if (cflag == 0) {
                    // The units, in parentheses, fill the column.
                    var len = u.size
                    if (pflag > 1) {
                        if (len > VWIDTH_HI - 2) len = VWIDTH_HI - 2
                    } else if (len > VWIDTH - 2) {
                        len = VWIDTH - 2
                    }
                    val ustring = bcat("(".latin1(), u.copyOf(len))
                    out.printf(if (pflag > 1) "\t%14s)" else "\t%6s)", ustring)
                } else {
                    out.printf(",'%s'", escapify(u))
                }
            }
            if (xflag != 0) out.puts("</units>")
            out.puts("\n")
        }

        if (xflag != 0) out.puts("<samplevectors>\n")
        // Frames are read in blocks unless timstr() or mstimstr() is used.
        val block = timeunits == SAMPLES || timeunits == SECONDS || timeunits == MINUTES || timeunits == HOURS
        val vlead = if (cflag != 0) ','.code else '\t'.code
        val vprec = if (pflag > 1) 8 else 3
        val vwidth = if (cflag != 0) 0 else if (pflag > 1) VWIDTH_HI else VWIDTH
        val tprec = when (timeunits) {
            MINUTES -> 5
            HOURS -> 7
            else -> 3
        }
        val twidth = if (cflag != 0) 0 else TWIDTH
        val vfmt = if (cflag != 0) (if (pflag > 1) "%.8f" else "%.3f") else (if (pflag > 1) "%15.8f" else "%7.3f")
        val tfmt = if (cflag == 0) {
            when (timeunits) {
                MINUTES -> "%15.5f"
                HOURS -> "%15.7f"
                else -> "%15.3f"
            }
        } else {
            when (timeunits) {
                MINUTES -> "%.5f"
                HOURS -> "%.7f"
                else -> "%.3f"
            }
        }
        val gains = DoubleArray(sig.size) { si[sig[it]].gain }
        val bases = DoubleArray(sig.size) { si[sig[it]].baseline.toDouble() }
        while (to == 0L || from < to) {
            var k = if (block) chunk else 1L
            if (to != 0L && to - from < k) k = to - from
            val m = if (block) getvecs(vbuf, k) else if (getvec(vbuf) >= 0) 1L else 0L
            for (f in 0 until maxOf(m, 0L).toInt()) {
                val off = f * nvec
                if (cflag == 0) {
                    when (timeunits) {
                        TIMSTR -> out.puts(cstr(timstr(-from)))
                        SHORTTIMSTR, MSTIMSTR -> out.puts(cstr(mstimstr(-from)))
                        HHMMSS -> {
                            val t = if (from == 0L) "0:00.000".latin1() else mstimstr(from)
                            out.printf("%15s", t)
                        }
                        SAMPLES -> out.integer(0, from, TWIDTH)
                        else -> out.fixed(0, from.toDouble() / freq, twidth, tprec, tfmt)
                    }
                } else {
                    when (timeunits) {
                        TIMSTR -> out.printf("'%s'", skipSpaces(timstr(-from)))
                        SHORTTIMSTR, MSTIMSTR -> out.printf("'%s'", skipSpaces(mstimstr(-from)))
                        HHMMSS -> {
                            if (from == 0L) out.puts("'0:00.000'")
                            else out.printf("'%s'", skipSpaces(mstimstr(from)))
                        }
                        SAMPLES -> out.integer(0, from, 0)
                        else -> out.fixed(0, from.toDouble() / freq, twidth, tprec, tfmt)
                    }
                }

                from++
                for (j in sig.indices) {
                    val x = vbuf[off + sig[j]]
                    if (x != WFDB_INVALID_SAMPLE) {
                        out.fixed(vlead, (x.toDouble() - bases[j]) / gains[j], vwidth, vprec, vfmt)
                    } else {
                        out.puts(invalidB)
                    }
                }
                out.buf.add('\n'.code)
                out.maybeFlush()
            }
            if (m < k) break
        }
    } else {
        // output in raw units
        if (xflag != 0) out.puts("<samplevectors>\n")
        val vlead = if (cflag != 0) ','.code else '\t'.code
        val twidth = if (cflag != 0) 0 else TWIDTH
        val vwidth = if (cflag != 0) 0 else VWIDTH
        while (to == 0L || from < to) {
            var k = chunk
            if (to != 0L && to - from < k) k = to - from
            val m = getvecs(vbuf, k)
            for (f in 0 until maxOf(m, 0L).toInt()) {
                val off = f * nvec
                out.integer(0, from, twidth)
                from++
                for (s in sig) out.integer(vlead, vbuf[off + s].toLong(), vwidth)
                out.buf.add('\n'.code)
            }
            out.maybeFlush()
            if (m < k) break
        }
    }

    // print trailer if WFDB-XML output was selected
    if (xflag != 0) out.puts("</samplevectors>\n</wfdbsampleset>\n")

    out.flush()
    wfdbquit()
    exit(0)
}
