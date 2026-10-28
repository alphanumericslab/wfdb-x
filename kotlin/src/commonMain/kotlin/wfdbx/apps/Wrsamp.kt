// wrsamp: select fields or columns from a file and generate a WFDB record
// (port of app/wrsamp.c, through rust/src/bin/wrsamp.rs).
//
// Where the C program's behavior is undefined (input lines that end with a
// field separator, lines with fewer fields than the selected columns), the
// behavior described in docs/KNOWN_C_BEHAVIORS.md is used.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/wrsamp.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency, gain, ADC
// resolution or units: when a record is written (-o), -F, -G and the new
// option -R BITS are required, and the new option -U UNITS for calibrated
// signals unless the input gives the units (the original assumed 250 Hz, 200
// adu/mV, a resolution based on the format, and millivolts); -G 0 declares the
// signals uncalibrated; -G, -R and -U take one value per signal; --legacy, as
// the first argument, restores the original behavior. Each change is marked
// "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/wrsamp.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1993-2014 George B. Moody; revised 2020 by Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

/** The ADC resolution of the C program (legacy mode): from the format, or WFDB_DEFRES. */
private fun legacyAdcres(format: Int): Int = when (format) {
    508, 80 -> 8
    310, 311 -> 10
    212 -> 12
    516, 16, 160, 61 -> 16
    524, 24 -> 24
    32 -> 32
    // resolution for unknown future formats
    else -> if (format > 100 && format % 100 > 0 && format % 100 <= 32) format % 100 else WFDB_DEFRES
}

/** The dither generator (triangular PDF in (-1,1)). */
private fun dither(rng: GlibcRand): Double {
    val a = rng.rand().toDouble()
    val b = rng.rand().toDouble()
    return (a + b) / RAND_MAX.toDouble() - 1.0
}

/**
 * Read a line delimited by [rsep] (an unterminated last line is discarded).
 * Returns null at the end of the input. As in C, the line is a C string (it
 * ends at its first null character, if any).
 */
private fun readLine(ifile: WfdbFile, rsep: Int): ByteArray? {
    val buf = ByteVec(128)
    while (true) {
        val c = ifile.getc()
        if (c == rsep) break
        if (c == EOF) return null
        buf.add(c)
    }
    return cstr(buf.toByteArray())
}

private fun lineHasAlpha(line: ByteArray?): Boolean {
    if (line == null) return false
    var p = 0
    while (line.at(p) != 0) {
        val c = line.at(p)
        if (c == 'e'.code || c == 'E'.code) {
            // might be a number in printf %f form: ignore 'e' or 'E' if
            // followed by a digit or a sign
            p++
            val d = line.at(p)
            if (d.toByte() <= '9'.code.toByte() || d == '-'.code || d == '+'.code) {
                if (d == 0) break
                p++
                continue
            }
        }
        if (isalpha(line.at(p))) return true
        p++
    }
    return false
}

private fun lineHasTab(line: ByteArray): Boolean = line.contains('\t'.code.toByte())

/**
 * Parse a line into tokens (as parseline() in wrsamp.c, with consecutive
 * delimiters collapsed and '\\' as the escape character). Quoted tokens
 * ('...', "...", or <...>) may contain delimiters.
 */
private fun parseline(line: ByteArray, delim: ByteArray): List<ByteArray> {
    val esc = '\\'.code.toByte()
    val tokens = ArrayList<ByteArray>()
    val n = line.size
    var p = 0
    while (p < n) {
        while (p < n && delim.contains(line[p])) p++
        if (p >= n) break
        var q: Byte = 0
        if (line[p] == '"'.code.toByte() || line[p] == '\''.code.toByte()) {
            q = line[p]
            p++
        } else if (line[p] == '<'.code.toByte()) {
            p++
            q = '>'.code.toByte()
        }
        val tok = ByteVec(16)
        while (p < n && (q.toInt() != 0 || !delim.contains(line[p]))) {
            val c = line[p]
            if (c == esc) {
                if (p + 1 >= n) break // escape at end of line -- ignore
                tok.add(line[p + 1])
                p += 2
                continue
            }
            if (c == q) {
                // found the closing quote
                p++
                break
            }
            tok.add(c)
            p++
        }
        tokens.add(tok.toByteArray())
    }
    return tokens
}

private val WRSAMP_HELP = arrayOf(
    "usage: %s [OPTIONS ...] [COLUMN ...]\n",
    "where COLUMN selects a field to be copied (leftmost field is column 0),",
    "and OPTIONS may include:",
    " -c          check that each input line contains the same number of fields",
    " -d          add dither to the input",
    " -f N        start copying with line N (default: 0)",
    " -F FREQ     specify frequency to be written to header file (required",
    "              with -o)",
    " -G GAIN     specify gain(s) to be written to header file (required with",
    "              -o; 0 means uncalibrated)",
    " -h          print this usage summary",
    " -i FILE     read input from FILE (default: standard input)",
    " -o RECORD   save output in RECORD.dat, and generate a header file for",
    "              RECORD (default: write to standard output in format 16, do",
    "              not generate a header file)",
    " -O FORMAT   save output in the specified FORMAT (default: 16)",
    " -r RSEP     interpret RSEP as the input line separator (default: linefeed)",
    " -R BITS     specify ADC resolution(s) in bits (required with -o)",
    " -s FSEP     interpret any character in FSEP as an input field separator",
    "             (default: space, tab, carriage-return, or comma)  ",
    " -t N        stop copying at line N (default: end of input file)",
    " -U UNITS    specify units (required with -o for calibrated signals, unless",
    "              the input gives them)",
    " -x SCALE    multiply inputs by SCALE factor(s) (default: 1)",
    " -z          don't copy column 0 unless explicitly specified",
    "",
    "The input is a text file with a sample of each signal on each line. Samples",
    "can be separated by tabs, spaces, commas, or any combination of these.",
    "Consecutive separators are equivalent to single separators.",
    "",
    "To specify different GAIN or SCALE values for each output signal, provide",
    "a quoted list of values, e.g., -G \"100 50\" defines the gain for signal 0",
    "as 100, and the gain for signal 1 (and any additional signals) as 50.",
    "",
    "If the first input line contains any alphabetic characters, it is assumed",
    "to contain column headings, which are copied as signal descriptions into",
    "RECORD.hea.  If the second input line also contains alphabetic characters,",
    "it is assumed to specify the physical units for each column, which are",
    "copied as units strings into RECORD.hea.  The first line containing samples",
    "is line 0.",
    "",
    "If no COLUMN is specified, all fields are copied in order; column 0 can be",
    "omitted in this case by using the '-z' option.",
)

/** Lines of the usage summary shown before each "--More--" prompt. */
private const val PAGELINES = 23

/**
 * WFDB-x: the lines of WRSAMP_HELP that differ in the help text of the
 * original program (printed in legacy mode): each is replaced by the
 * original line, or left out (null).
 */
private val LEGACY_HELP_EDITS: List<Pair<String, String?>> = listOf(
    " -F FREQ     specify frequency to be written to header file (required" to
        " -F FREQ     specify frequency to be written to header file (default: 250)",
    "              with -o)" to null,
    " -G GAIN     specify gain(s) to be written to header file (required with" to
        " -G GAIN     specify gain(s) to be written to header file (default: 200)",
    "              -o; 0 means uncalibrated)" to null,
    " -R BITS     specify ADC resolution(s) in bits (required with -o)" to null,
    " -U UNITS    specify units (required with -o for calibrated signals, unless" to null,
    "              the input gives them)" to null,
)

private fun Wfdb.wrsampHelp(pname: ByteArray) {
    val legacy = wfdbx_get_legacy() != 0
    eprintf(WRSAMP_HELP[0], pname)
    var i = 0
    for (k in 1 until WRSAMP_HELP.size) {
        val s0 = WRSAMP_HELP[k]
        val e = if (legacy) LEGACY_HELP_EDITS.find { it.first == s0 } else null
        val s = if (e != null) e.second ?: continue else s0
        i++
        eprintf("%s\n", s)
        if (i % PAGELINES == 0) {
            eprintf("--More--")
            val stdin = WfdbFile.stdin()
            stdin.fgets(ByteVec(8), 5) // (C: a 5-byte buffer)
            stdin.close()
            eprintf("\u001b[A\u001b[2K") // erase "--More--"
        }
    }
}

/** sscanf(s, "%lf", &x): the number of conversions, the value in [x] (unchanged if none). */
private fun scanF64(s: ByteArray, x: CDouble): Int = sscanf(s, "%lf", x)

/** A suffix of [s] from [p] (empty if p is past the end). */
private fun from(s: ByteArray, p: Int): ByteArray = if (p >= s.size) ByteArray(0) else s.copyOfRange(p, s.size)

/** The wrsamp tool. */
fun Wfdb.wrsampMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    var gain = ByteArray(0)
    var scale = ByteArray(0)
    var res = ByteArray(0) // WFDB-x: -R
    var uopt: ByteArray? = null // WFDB-x: -U
    var record: ByteArray? = null
    var delim = " \t\r\n,".latin1() // defpmode.delim
    var rsep = '\n'.code
    var sflag = false
    var xflag = false
    var dstrings: List<ByteArray> = emptyList()
    var ustrings: List<ByteArray> = emptyList()
    var haveDstrings = false
    var haveUstrings = false
    // WFDB-x: no default frequency (legacy mode: that of the C program)
    var freq = if (legacy) WFDB_DEFFREQ else 0.0
    var dflag = false
    var format = 16
    var zflag = 0
    var ifile = WfdbFile.stdin()
    var ifileIsStdin = true
    var t0 = 0L
    var t1 = 0L
    val rng = GlibcRand()
    var ncols: Int

    var i = 1
    while (i < argc && argv[i].at(0) == '-'.code) {
        val c = argv[i].at(1).toChar()
        when {
            c == 'c' -> {}
            c == 'd' -> {
                dflag = true
                rng.srand(0) // seed for dither RNG
            }
            c == 'f' -> {
                if (++i < argc) t0 = atol(argv[i])
                if (i >= argc || t0 <= 0) {
                    eprintf("%s: starting line # must follow -f\n", pname)
                    exit(1)
                }
            }
            c == 'F' -> {
                if (++i < argc) freq = atof(argv[i])
                if (i >= argc || freq <= 0.0) {
                    eprintf("%s: sampling frequency must follow -F\n", pname)
                    exit(1)
                }
            }
            c == 'G' -> {
                if (++i >= argc) {
                    eprintf("%s: gain(s) must follow -G\n", pname)
                    exit(1)
                }
                gain = cstr(argv[i])
            }
            c == 'h' -> {
                wrsampHelp(pname)
                exit(1)
            }
            c == 'R' && !legacy -> { // WFDB-x: ADC resolution(s) in bits
                if (++i >= argc) {
                    eprintf("%s: ADC resolution(s) must follow -R\n", pname)
                    exit(1)
                }
                res = cstr(argv[i])
            }
            c == 'U' && !legacy -> { // WFDB-x: units
                if (++i >= argc) {
                    eprintf("%s: units must follow -U\n", pname)
                    exit(1)
                }
                uopt = cstr(argv[i])
            }
            c == 'i' -> {
                if (++i >= argc) {
                    eprintf("%s: input file name must follow -i\n", pname)
                    exit(1)
                }
                if (beq(argv[i], "-")) {
                    if (!ifileIsStdin) {
                        ifile.close()
                        ifile = WfdbFile.stdin()
                        ifileIsStdin = true
                    }
                } else {
                    val f = WfdbFile.fopen(argv[i], "r")
                    if (f == null) {
                        eprintf("%s: can't read `%s'\n", pname, argv[i])
                        exit(2)
                    }
                    ifile.close()
                    ifile = f
                    ifileIsStdin = false
                }
            }
            c == 'l' -> {
                if (++i >= argc) i--
                eprintf("%s: -l is obsolete, ignored\n", pname)
            }
            c == 'o' -> {
                if (++i >= argc) {
                    eprintf("%s: record name must follow -o\n", pname)
                    exit(1)
                }
                record = cstr(argv[i])
            }
            c == 'O' -> {
                if (++i >= argc) {
                    eprintf("%s: output format must follow -O\n", pname)
                    exit(1)
                }
                format = atoi(argv[i])
            }
            c == 'r' -> {
                if (++i >= argc) {
                    eprintf("%s: line separator must follow -r\n", pname)
                    exit(1)
                }
                rsep = argv[i].at(0)
            }
            c == 's' -> {
                if (++i >= argc) {
                    eprintf("%s: field separator(s) must follow -s\n", pname)
                    exit(1)
                }
                sflag = true
                delim = cstr(argv[i])
            }
            c == 't' -> {
                if (++i < argc) t1 = atol(argv[i])
                if (i >= argc || t1 <= 0) {
                    eprintf("%s: ending line # must follow -t\n", pname)
                    exit(1)
                }
            }
            c == 'x' -> {
                if (++i >= argc) {
                    eprintf("%s: scaling factor(s) must follow -x\n", pname)
                    exit(1)
                }
                scale = cstr(argv[i])
            }
            c == 'z' -> zflag = 1 // ignore column 0
            else -> {
                eprintf("%s: unrecognized option %s\n", pname, argv[i])
                exit(1)
            }
        }
        i++
    }

    // WFDB-x: the sampling frequency, the gains, the ADC resolutions, and the
    // units (of calibrated signals) must be specified when a header is
    // written (the C program assumed 250 Hz, 200 adu/mV, a resolution based
    // on the format, and millivolts), as legacy mode does.
    val check = record != null && !legacy
    if (check && freq <= 0.0) {
        eprintf("%s: the sampling frequency must be specified (-F)\n", pname)
        exit(1)
    }
    if (check && gain.isEmpty()) {
        eprintf("%s: the gain(s) must be specified (-G)\n", pname)
        exit(1)
    }
    if (check && res.isEmpty()) {
        eprintf("%s: the ADC resolution(s) must be specified (-R)\n", pname)
        exit(1)
    }

    var nosig = argc - i // any remaining arguments are column numbers

    // Determine the number of input columns, and (if present) the signal
    // names and the units for each signal. Start by reading the first line
    // of the input file.
    var line = readLine(ifile, rsep)
    if (line == null) {
        if (rsep != '\n'.code) {
            if (record == null) {
                eprintf("%s: use -o to specify the output record name", pname)
            } else {
                eprintf(
                    "%s: no record separators in input\nTry specifying a different separator after the -r option.\n",
                    pname,
                )
            }
        } else {
            eprintf("%s: no newlines in input\n", pname)
        }
        exit(3)
    }
    val first: ByteArray = line
    // Recognize WFDB-XML format if present.
    if (first.startsWith("<?xml ")) {
        xflag = true
        zflag = 1 // ignore column 0
        ncols = 0
        while (true) {
            line = readLine(ifile, rsep)
            if (line == null) {
                eprintf("%s: XML input, but no <wfdbsampleset> found\n", pname)
                exit(1)
            }
            if (beq(line, "<wfdbsampleset>")) break
        }
        while (true) {
            val l = readLine(ifile, rsep)
            if (l == null) {
                eprintf("%s: empty <wfdbsampleset>\n", pname)
                exit(1)
            }
            line = l
            // strip `open` and `close` tags from the line
            fun strip(open: String, close: String): ByteArray =
                if (l.size >= open.length + close.length) l.copyOfRange(open.length, l.size - close.length)
                else ByteArray(0)
            if (l.startsWith("<samplingfrequency>")) {
                val fd = CDouble(freq)
                scanF64(from(l, "<samplingfrequency>".length), fd)
                freq = fd.v
            } else if (l.startsWith("<description>")) {
                val ta = parseline(strip("<description>", "</description>"), delim)
                ncols = ta.size
                dstrings = ta
                haveDstrings = true
            } else if (l.startsWith("<units>")) {
                ustrings = parseline(strip("<units>", "</units>"), delim)
                haveUstrings = true
            }
            if (beq(l, "<samplevectors>")) break
        }
        val next = readLine(ifile, rsep)
        if (next == null) {
            eprintf("%s: empty <wfdbsampleset>\n", pname)
            exit(1)
        }
        line = next
    } else {
        // non-XML input
        // Unless -s was given, note if line 0 contains any tab characters.
        if (!sflag && lineHasTab(first)) delim = "\t".latin1()
        val ta = parseline(first, delim)
        ncols = ta.size
        // If it contains any alphabetic characters, save the signal names.
        if (lineHasAlpha(first)) {
            haveDstrings = true
            dstrings = ta.map { skipLeadingSpaces(it) }
            // Read the second line.
            line = readLine(ifile, rsep)
            if (line == null) {
                eprintf("%s: no data\n", pname)
                exit(1)
            }
            if (lineHasAlpha(line)) {
                // If it has any alphabetic characters, save the unit strings.
                val tu = parseline(line, delim)
                haveUstrings = true
                ustrings = tu.map { tk ->
                    var u = skipLeadingSpaces(tk)
                    if (u.at(0) == '('.code) {
                        val last = u[u.size - 1]
                        u = u.copyOfRange(1, u.size)
                        if (last == ')'.code.toByte()) u = u.copyOf(u.size - 1)
                    }
                    u
                }
                // Read the third line.
                line = readLine(ifile, rsep)
                if (line == null) {
                    eprintf("%s: no data\n", pname)
                    exit(1)
                }
            }
        }
    }

    // read selected column numbers into fv[...]
    val fv: IntArray
    if (nosig != 0) {
        fv = IntArray(nosig)
        for (j in 0 until nosig) {
            val k = argc - nosig + j
            val d = CInt(0)
            val r = sscanf(argv[k], "%d", d)
            fv[j] = d.v
            if (r != 1 || fv[j] < 0 || fv[j] >= ncols) {
                eprintf("%s: unrecognized argument %s\n", pname, argv[k])
                exit(1)
            }
        }
    } else {
        // copy all column numbers (or all except 0) into fv[...]
        val ns = ncols.toLong() - zflag
        if (ns < 0) {
            eprintf("WFDB: can't allocate (%lu*%lu) bytes for fv\n", ns and 0xffffffffL, 4L)
            exit(1)
        }
        nosig = ns.toInt()
        fv = IntArray(nosig) { it + zflag }
    }

    val n = nosig
    val vout = IntArray(n)
    val si = Array(n) { Siginfo() }
    val scalef = DoubleArray(n)

    // open the output record
    val ofname = if (record == null) "-".latin1() else bcat(record, ".dat".latin1())

    var gp = 0 // position in gain
    var sp = 0 // position in scale
    var rp = 0 // position in res
    var up = 0 // position in the -U string
    var prevUnits = ByteArray(0)
    var prevAdcres = 0
    for (k in 0 until n) {
        val s = si[k]
        s.fname = ofname.copyOf()
        s.desc = if (haveDstrings) dstrings.getOrNull(fv[k])?.copyOf() ?: ByteArray(0) else cformat("col %d", fv[k])
        val u = uopt
        if (u != null) {
            // WFDB-x: -U (the last one applies to the rest)
            var q = up
            while (u.at(q) == ' '.code) q++
            up = q
            if (q < u.size) {
                while (q < u.size && u[q] != ' '.code.toByte()) q++
                s.units = u.copyOfRange(up, q)
                up = q
            } else {
                s.units = prevUnits.copyOf()
            }
        } else {
            s.units = if (haveUstrings) ustrings.getOrNull(fv[k])?.copyOf() ?: ByteArray(0) else ByteArray(0)
        }
        prevUnits = s.units ?: ByteArray(0)
        s.group = 0
        s.fmt = format
        s.spf = 1
        s.bsize = 0
        // WFDB-x: the ADC resolutions are given by -R (the last one applies to
        // the remaining signals); the C program inferred them from the format
        // or assumed WFDB_DEFRES, as legacy mode does.
        if (legacy) {
            s.adcres = legacyAdcres(format) // WFDB-x: legacy mode
        } else {
            while (res.at(rp) == ' '.code) rp++
            val r = CInt(0)
            if (sscanf(from(res, rp), "%d", r) < 1) {
                s.adcres = if (k == 0) 0 else prevAdcres
            } else {
                s.adcres = r.v
                while (rp < res.size && res[rp] != ' '.code.toByte()) rp++
            }
        }
        prevAdcres = s.adcres
        if (check && s.adcres < 1) {
            eprintf("%s: the ADC resolution(s) must be specified (-R)\n", pname)
            exit(1)
        }
        s.adczero = 0
        s.baseline = 0
        while (gain.at(gp) == ' '.code) gp++
        val g = CDouble(0.0)
        if (scanF64(from(gain, gp), g) < 1) {
            // WFDB-x: C (legacy mode): WFDB_DEFGAIN
            val g0 = if (legacy) WFDB_DEFGAIN else 0.0
            s.gain = if (k == 0) g0 else si[k - 1].gain
        } else {
            s.gain = g.v
            while (gp < gain.size && gain[gp] != ' '.code.toByte()) gp++
        }
        // WFDB-x: the units of a calibrated signal must be specified, by -U
        // or by the input (the C program left them out: millivolts).
        if (check && s.gain != 0.0 && (s.units?.isEmpty() ?: true)) {
            eprintf("%s: the units must be specified (-U)\n", pname)
            exit(1)
        }
        while (scale.at(sp) == ' '.code) sp++
        val x = CDouble(0.0)
        if (scanF64(from(scale, sp), x) < 1) {
            scalef[k] = if (k == 0) 1.0 else scalef[k - 1]
        } else {
            scalef[k] = x.v
            while (sp < scale.size && scale[sp] != ' '.code.toByte()) sp++
        }
    }

    // discard any additional lines containing text
    while (lineHasAlpha(line)) line = readLine(ifile, rsep)

    // (As in C, the result of osigfopen is compared with an unsigned number,
    // so that errors are not detected here.)
    if (osigfopen(si, nosig).toUInt() < nosig.toUInt() || setsampfreq(freq) < 0) exit(2)

    // skip any unwanted samples at the beginning
    var t = 0L
    while (t < t0) {
        line = readLine(ifile, rsep)
        t++
    }

    // pick up base time if it's there ("[hh:mm:ss.sss dd/mm/yyyy]", at most
    // BTIMELEN characters between the brackets)
    val btimelen = 23
    val l0 = line
    if (zflag != 0 && l0 != null) {
        if (l0.at(0) == '['.code) {
            val b = from(l0, 1)
            setbasetime(b.copyOf(minOf(b.size, btimelen)))
        } else if (l0.size > 1 && l0[1] == '['.code.toByte()) {
            val b = from(l0, 2)
            setbasetime(b.copyOf(minOf(b.size, btimelen)))
        }
    }

    // read and copy samples
    val v = CDouble(0.0)
    while (true) {
        val l = line ?: break
        if (t1 != 0L) {
            val ok = t < t1
            t++
            if (!ok) break
        }
        val ta = parseline(l, delim)

        for (k in 0 until n) {
            val tok = ta.getOrNull(fv[k]) ?: ByteArray(0)
            v.v = 0.0
            if (scanF64(tok, v) == 1) {
                var y = v.v * scalef[k]
                if (dflag) y += dither(rng)
                vout[k] = if (y >= 0.0) d2i(y + 0.5) else d2i(y - 0.5)
            } else {
                vout[k] = WFDB_INVALID_SAMPLE
            }
        }
        if (putvec(vout) < 0) break

        line = readLine(ifile, rsep)
        if (xflag) {
            val l2 = line
            if (l2 != null && l2.startsWith("</samplevectors>")) {
                line = readLine(ifile, rsep)
                val l3 = line
                if (l3 != null && !beq(l3, "</wfdbsampleset>")) {
                    eprintf("%s: (warning) unexpected EOF in XML input\n", pname)
                }
                break
            }
        }
    }

    // write the header
    setsampfreq(freq)
    if (record != null) newheader(record)
    wfdbquit()
    ifile.close()
    exit(0)
}

private fun skipLeadingSpaces(tk: ByteArray): ByteArray {
    var k = 0
    while (k < tk.size && tk[k] == ' '.code.toByte()) k++
    return tk.copyOfRange(k, tk.size)
}
