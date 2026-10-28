// xform: sampling frequency, amplitude, and format conversion for WFDB
// records (port of app/xform.c, through rust/src/bin/xform.rs).
//
// Dither uses an exact emulation of glibc's rand() (after srand(0)), so that
// the output is the same on all platforms. Conversions of out-of-range
// doubles to int yield INT_MIN (as on x86), and int additions and
// subtractions wrap around.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/xform.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency, gain, ADC
// resolution or units: the input record must give its sampling frequency, and
// an output frequency of 0 is refused; rescaling an uncalibrated signal to a
// given gain, and rescaling by ADC resolution when a resolution is
// unspecified, are refused; an ADC resolution is offered only if it comes from
// the input (or the previous output signal) and suits the output format;
// unspecified units are shown as "nd" (the original assumed 250 Hz, 200
// adu/mV, a resolution based on the format, and millivolts); when an output
// signal file would be one of the input files, the message says so; --legacy,
// as the first argument, restores the original behavior. Each change is marked
// "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/xform.c, WFDB Software Package 10.7.0.
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

private val XFORM_HELP = arrayOf(
    "usage: %s -i IREC [OPTIONS ...]\n",
    "where IREC is the name of the record to be converted, and OPTIONS may",
    " include any of:",
    " -a ANNOTATOR [ANNOTATOR ...]  copy annotations for the specified ANNOTATOR",
    "              from IREC;  two or more ANNOTATORs may follow -a",
    " -c          clip output (default: wrap around if out-of-range)",
    " -d          add dither to the input if changing sampling frequency or gain",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          open the input record in `high resolution' mode",
    " -M          process multifrequency record without changing frequencies",
    " -n NREC     create a header file, using record name NREC and signal",
    "              descriptions from IREC",
    " -N NREC     as for -n, but copy signal descriptions from OREC",
    " -o OREC     produce output signal file(s) as specified by the header file",
    "              for record OREC",
    " -s SIGNAL [SIGNAL ...]  write only the specified signal(s)",
    " -S SCRIPT   take answers to prompts from SCRIPT (a text file)",
    " -t TIME     stop at specified time",
    " -u          adjust annotation times if needed to make them unique",
    "Unless you use `-o' to specify an *existing* header that describes the",
    "desired signal files, you will be asked for output specifications.  Use",
    "`-n' to name the record to be created.  Use `-s' to select a subset of the",
    "input signals, or to re-order them in the output file;  arguments that",
    "follow `-s' are *input* signal numbers (0,1,2,...) or names.",
)

private fun xformHelp(pname: ByteArray) {
    eprintf(XFORM_HELP[0], pname)
    for (k in 1 until XFORM_HELP.size) eprintf("%s\n", XFORM_HELP[k])
}

/** The dither generator: triangular PDF in (-1,1). */
private fun xdither(rng: GlibcRand): Double {
    val a = rng.rand().toDouble()
    val b = rng.rand().toDouble()
    return (a + b) / RAND_MAX.toDouble() - 1.0
}

/** C fgets on the prompt input, with xform's handling of end of file. */
private fun scriptFgets(ttyin: WfdbFile, length: Int, pname: ByteArray, script: ByteArray?): ByteArray {
    val buffer = ByteVec(64)
    if (!ttyin.fgets(buffer, length)) {
        if (script != null) {
            eprintf("\n%s: unexpected end of file in %s\n", pname, script)
            exit(1)
        } else {
            return "\n".latin1()
        }
    }
    // (The C program treats the buffer as a C string.)
    return cstr(buffer.toByteArray())
}

/**
 * Calculate the greatest common divisor of x and y. This function uses
 * Euclid's algorithm, modified so that an exact answer is not required if
 * the (possibly non-integral) arguments do not have a common divisor that
 * can be represented exactly.
 */
private fun gcd(x0: Double, y0: Double): Double {
    var x = x0
    var y = y0
    val tol = if (x > y) 0.001 * y else 0.001 * x // relative tolerance 0.1%
    while (true) {
        if (x > y && x - y > tol) x -= y
        else if (y > x && y - x > tol) y -= x
        else return x
    }
}

/** Round as xform does. */
private fun xround(vd: Double): Int = if (vd >= 0.0) d2i(vd + 0.5) else d2i(vd - 0.5)

/** Report (and clip, or widen the range for) an out-of-range sample; returns the sample. */
private fun check(vout: Int, i: Int, vmax: IntArray, vmin: IntArray, clip: Boolean): Int {
    if (vout > vmax[i]) {
        eprintf("v[%d] = %d (out of range)\n", i, vout)
        if (clip) return vmax[i] else vmax[i] = vout
    } else if (vout < vmin[i]) {
        eprintf("v[%d] = %d (out of range)\n", i, vout)
        if (clip) return vmin[i] else vmin[i] = vout
    }
    return vout
}

/**
 * The largest ADC resolution (bits) of a storage format, and the resolution
 * the C program assumed for it (legacy mode; for historical compatibility,
 * WFDB_DEFRES for 16-bit formats, although 16 would make more sense).
 */
private fun formatRes(fmt: Int): Pair<Int, Int> = when (fmt) {
    80, 508 -> 8 to 8
    212 -> 12 to 12
    310 -> 10 to 10
    24, 524 -> 24 to 24
    32 -> 32 to 32
    else -> 16 to WFDB_DEFRES // 16, 61, 160, 516, and others
}

/** The xform tool. */
fun Wfdb.xformMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    var script: ByteArray? = null
    val rng = GlibcRand(1)
    var irec0: ByteArray? = null
    var orec: ByteArray? = null
    var nrec: ByteArray? = null
    var startp: ByteArray = "0:0".latin1()
    var ofreq: Double
    var clip = false
    var dflag = false
    var hflag = false
    var mflag = false
    var sflag = false
    var uflag = false
    var useIrecDesc = true
    var fflag = false
    var gflag = false
    var reopen = false
    var nminutes = 0
    var nosig = 0
    val siglist = ArrayList<Int>()
    var from = 0L
    var it = 0L
    var ot = 0L
    var to = 0L
    var nsamp = -1L
    var nsm = 0L
    val ainames = ArrayList<ByteArray>()
    var dfin: Array<Siginfo> = emptyArray()
    var dfout: Array<Siginfo> = emptyArray()

    // Interpret the command-line arguments.
    fun startsDash(k: Int) = argv[k].at(0) == '-'.code
    var i = 1
    while (i < argc) {
        val a = argv[i]
        if (a.at(0) == '-'.code) {
            when (a.at(1).toChar()) {
                'a' -> { // annotator(s)
                    // Count the number of annotators. Accept the next argument
                    // unconditionally as an annotator name; accept additional
                    // arguments until we find one beginning with `-', or the
                    // end of the argument list.
                    var j = 0
                    while (true) {
                        i++
                        if (!(i < argc && (j == 0 || !startsDash(i)))) break
                        j++
                    }
                    if (j == 0) {
                        eprintf("%s: annotator(s) must follow -a\n", pname)
                        exit(1)
                    }
                    i -= j
                    j = 0
                    while (i < argc && (j == 0 || !startsDash(i))) {
                        ainames.add(argv[i].copyOf())
                        i++
                        j++
                    }
                    i--
                }
                'c' -> clip = true // clip (limit) output
                'd' -> {
                    dflag = true
                    rng.srand(0) // seed for dither RNG
                }
                'f' -> { // starting time
                    if (++i >= argc) {
                        eprintf("%s: time must follow -f\n", pname)
                        exit(1)
                    }
                    from = i.toLong()
                }
                'h' -> { // help requested
                    xformHelp(pname)
                    exit(0)
                }
                'H' -> hflag = true // open the input record in high resolution mode
                'i' -> { // input record name follows
                    if (++i >= argc) {
                        eprintf("%s: input record name must follow -i\n", pname)
                        exit(1)
                    }
                    irec0 = argv[i]
                }
                'M' -> mflag = true // multifrequency mode (no frequency changes)
                'n' -> { // new record name follows
                    if (++i >= argc) {
                        eprintf("%s: new record name must follow -n\n", pname)
                        exit(1)
                    }
                    nrec = argv[i].copyOf()
                }
                'N' -> {
                    // new record name follows; use signal descriptions from
                    // output record header file in new header file
                    useIrecDesc = false
                    if (++i >= argc) {
                        eprintf("%s: new record name must follow -N\n", pname)
                        exit(1)
                    }
                    nrec = argv[i].copyOf()
                }
                'o' -> { // output record name follows
                    if (++i >= argc) {
                        eprintf("%s: output record name must follow -o\n", pname)
                        exit(1)
                    }
                    orec = argv[i]
                }
                's' -> { // signal list follows
                    sflag = true
                    // count the number of output signals
                    var j = 0
                    while (true) {
                        i++
                        if (!(i < argc && !startsDash(i))) break
                        j++
                    }
                    if (j == 0) {
                        eprintf("%s: signal list must follow -s\n", pname)
                        exit(1)
                    }
                    // fill the signal list (with argument indices for now)
                    i -= j
                    while (i < argc && !startsDash(i)) {
                        siglist.add(i)
                        nosig++
                        i++
                    }
                    i--
                }
                'S' -> { // script name follows
                    if (++i >= argc) {
                        eprintf("%s: script name must follow -S\n", pname)
                        exit(1)
                    }
                    script = argv[i]
                }
                't' -> { // end time
                    if (++i >= argc) {
                        eprintf("%s: time must follow -t\n", pname)
                        exit(1)
                    }
                    to = i.toLong()
                }
                'u' -> uflag = true // make annotation times unique
                else -> {
                    eprintf("%s: unrecognized option %s\n", pname, a)
                    exit(1)
                }
            }
        } else {
            eprintf("%s: unrecognized argument %s\n", pname, a)
            exit(1)
        }
        i++
    }

    // Check that an input record was specified.
    val irec: ByteArray = irec0 ?: run {
        xformHelp(pname)
        exit(1)
    }

    // Check that nrec and orec differ if both were specified.
    run {
        val n = nrec
        val o = orec
        if (n != null && o != null && cstr(n).contentEquals(cstr(o))) {
            eprintf("%s: arguments of -n (or -N) and -o cannot be identical\n", pname)
            exit(1)
        }
    }

    // Determine the number of input signals. If isigopen returns a negative
    // value, quit (isigopen will have emitted an error message).
    val nisig = isigopen(irec, null, 0)
    if (nisig < 0) exit(2)

    // If the input record contains no signals, we won't write any -- but we
    // might still read and write annotations.
    if (nisig == 0) {
        nosig = 0
    } else {
        // Otherwise, prepare to read and write signals.
        // Allocate storage for variables related to the input signals.
        dfin = Array(nisig) { Siginfo() }

        // Open the input signals.
        if (isigopen(irec, dfin, nisig) != nisig) exit(2)

        // If a signal list was specified using -s, check that the specified
        // signal numbers or names are legal.
        if (sflag) {
            var k = 0
            while (k < nosig && nosig > 0) {
                val s = argv[siglist[k]]
                siglist[k] = findsig(s)
                if (siglist[k] < 0) {
                    eprintf("%s: warning: record %s doesn't have a signal '%s'\n", pname, irec, s)
                    // Delete illegal signal numbers from the list.
                    siglist.removeAt(k)
                    nosig--
                } else {
                    k++
                }
            }
            // If the signal list contained no valid signal numbers, treat
            // this situation as if no signal list was specified.
            if (nosig == 0) sflag = false
        }

        // If the signal list was not specified using -s, initialize it now.
        if (!sflag) {
            nosig = nisig
            siglist.clear()
            for (k in 0 until nosig) siglist.add(k)
        }

        // Allocate storage for variables related to the output signals.
        dfout = Array(nosig) { Siginfo() }
    }
    val nosigAlloc = maxOf(nosig, 0)
    val gain = DoubleArray(nosigAlloc)
    val deltav = IntArray(nosigAlloc)
    val msiglist = IntArray(nosigAlloc)
    val v = IntArray(nosigAlloc)
    val vmax = IntArray(nosigAlloc)
    val vmin = IntArray(nosigAlloc)
    val vv = IntArray(nosigAlloc)

    // Determine the input sampling frequency.
    if (mflag) setgvmode(WFDB_LOWRES)
    else if (hflag) setgvmode(WFDB_HIGHRES)
    val ifreq = sampfreq(null)
    // WFDB-x: no default sampling frequency (the C program assumed 250 Hz if
    // the input header did not specify one, as legacy mode does).
    if (ifreq <= 0.0 && !legacy) {
        eprintf("%s: sampling frequency of record %s is not specified\n", pname, irec)
        wfdbquit()
        exit(2)
    }
    var spf = getspf()

    val iframelen: Int
    val oframelen: Int
    if (mflag) {
        iframelen = dfin.sumOf { it.spf }
        var s = 0
        for (k in 0 until nosigAlloc) s += dfin[siglist[k]].spf
        oframelen = s
    } else {
        iframelen = nisig
        oframelen = nosig
    }
    var vin = IntArray(maxOf(iframelen, 1))
    var vout = IntArray(maxOf(oframelen, 1))

    val orecV = orec
    if (orecV != null) {
        // an output record was specified
        // If a new record name was specified, check that it can be created.
        val n = nrec
        if (n != null && newheader(n) < 0) exit(2)

        // Determine the output sampling frequency.
        ofreq = sampfreq(orecV)
        if (ofreq == 0.0 && !legacy) {
            // WFDB-x: no default sampling frequency
            eprintf("%s: sampling frequency of record %s is not specified\n", pname, orecV)
            wfdbquit()
            exit(2)
        }
        setsampfreq(ifreq / spf.toDouble())

        if (ifreq != ofreq && mflag) {
            eprintf("%s: -M option may not be used if sampling frequency is to be changed\n", pname)
            wfdbquit()
            exit(1)
        }
    } else {
        // If no output record was specified, get signal specs interactively.
        var format = 0
        var answer: ByteArray
        val tty = script ?: "/dev/tty".latin1()
        val ttyin = WfdbFile.fopen(tty, "r") ?: WfdbFile.stdin()
        fun sfgets(len: Int) = scriptFgets(ttyin, len, pname, script)
        val anslen = 32 // size of C's answer and directory buffers
        if (nrec == null) {
            var record: ByteArray
            while (true) {
                eprintf("Choose a name for the output record (up to %d characters): ", WFDB_MAXRNL)
                record = sfgets(WFDB_MAXRNL + 2)
                if (record.isNotEmpty()) record = record.copyOf(record.size - 1)
                if (record.isNotEmpty() && newheader(record) >= 0) break
            }
            nrec = record
        }
        if (!sflag) {
            do {
                nosig = nisig
                eprintf("Number of signals to be written (1-%d) [%d]: ", nisig, nosig)
                answer = sfgets(anslen)
                val d = CInt(nosig)
                sscanf(answer, "%d", d)
                nosig = d.v
                if (nosig == 0) {
                    eprintf("No signals will be written.  Are you sure? [n]: ")
                    answer = sfgets(anslen)
                    if (answer.at(0) != 'y'.code && answer.at(0) != 'Y'.code) nosig = -1
                }
            } while (nosig < 0 || nosig > nisig)
        }
        if (mflag) {
            ofreq = ifreq
            eprintf("Sampling frequency (%g frames/sec) will be unchanged\n", ofreq)
        } else {
            while (true) {
                ofreq = ifreq
                eprintf("Output sampling frequency (Hz per signal, > 0) [%g]: ", ofreq)
                answer = sfgets(anslen)
                val d = CDouble(ofreq)
                sscanf(answer, "%lf", d)
                ofreq = d.v
                if (ofreq >= 0.0 || ofreq.isNaN()) break
            }
        }
        if (ofreq == 0.0 && legacy) {
            ofreq = WFDB_DEFFREQ // WFDB-x: as in the C program (legacy mode)
        } else if (ofreq == 0.0) {
            // WFDB-x: the C program assumed 250 Hz
            eprintf("%s: the output sampling frequency must be > 0\n", pname)
            wfdbquit()
            exit(1)
        }
        val nrecS = nrec ?: ByteArray(0)
        if (nosig > 0) {
            eprintf("Specify the name of the directory in which the output\n")
            eprintf(" signals should be written, or press <return> to write\n")
            eprintf(" them in the current directory: ")
            var directory = sfgets(anslen - 1)
            if (directory.at(0) == '\n'.code) {
                directory = ByteArray(0)
            } else if (directory.isNotEmpty()) {
                directory = directory.copyOf()
                directory[directory.size - 1] = '/'.code.toByte()
            }
            eprintf("Any of these output formats may be used:\n")
            eprintf("    8   8-bit first differences\n")
            eprintf("   16   16-bit two's complement amplitudes (LSB first)\n")
            eprintf("   61   16-bit two's complement amplitudes (MSB first)\n")
            eprintf("   80   8-bit offset binary amplitudes\n")
            eprintf("  160   16-bit offset binary amplitudes\n")
            eprintf("  212   2 12-bit amplitudes bit-packed in 3 bytes\n")
            eprintf("  310   3 10-bit amplitudes bit-packed in 15 LS bits of each of 2 words\n")
            eprintf("  311   3 10-bit amplitudes bit-packed in 30 LS bits of 4 bytes\n")
            eprintf("   24   24-bit two's complement amplitudes (LSB first)\n")
            eprintf("   32   32-bit two's complement amplitudes (LSB first)\n")
            eprintf("  508  8-bit amplitudes with FLAC compression\n")
            eprintf("  516  16-bit amplitudes with FLAC compression\n")
            eprintf("  524  24-bit amplitudes with FLAC compression\n")
            while (true) {
                format = dfin[0].fmt
                eprintf("Choose an output format from the list above [%d]: ", format)
                answer = sfgets(anslen)
                val d = CInt(format)
                sscanf(answer, "%d", d)
                format = d.v
                // skip format[0] (= 0)
                var ok = false
                for (k in 1 until WFDB_NFMTS) if (WFDB_FMT_LIST[k] == format) ok = true
                if (ok) break
            }
            var saveAnswer = ByteArray(0)
            if (nosig > 1) {
                eprintf("Save all signals in one file? [y]: ")
                saveAnswer = sfgets(anslen)
            }
            // Use the input signal specifications as defaults for output.
            for (k in 0 until nosig) dfout[k] = dfin[siglist[k]].copy()
            if (nosig <= 1 || (saveAnswer.at(0) != 'n'.code && saveAnswer.at(0) != 'N'.code)) {
                val filename = cformat("%s%s.dat", directory, nrecS)
                for (k in 0 until nosig) {
                    dfout[k].fname = filename.copyOf()
                    dfout[k].group = 0
                }
            } else {
                for (k in 0 until nosig) {
                    dfout[k].fname = cformat("%s%s.d%d", directory, nrecS, k)
                    dfout[k].group = k
                }
            }
        }
        for (k in 0 until maxOf(nosig, 0)) {
            // Make sure output signals are written in the chosen format.
            dfout[k].fmt = format
            if (!mflag) dfout[k].spf = 1
            dfout[k].bsize = 0 // no block size is defined
            if (!useIrecDesc) {
                eprintf("Signal %d description (up to %d characters): ", k, WFDB_MAXDSL)
                var description = sfgets(WFDB_MAXDSL + 2)
                if (description.isNotEmpty()) description = description.copyOf(description.size - 1)
                dfout[k].desc = description
                eprintf("Signal %d units (up to %d characters): ", k, WFDB_MAXUSL)
                var units = sfgets(WFDB_MAXUSL + 2).copyOf()
                for (q in units.indices) {
                    val c = units[q].toInt()
                    if (c == ' '.code || c == '\t'.code) {
                        units[q] = '_'.code.toByte()
                    } else if (c == '\n'.code) {
                        units = units.copyOf(q)
                        break
                    }
                }
                dfout[k].units = if (units.isEmpty()) null else units
            }
            // WFDB-x: C (legacy mode) showed "mV"
            val ushow = dfout[k].units?.let { cstr(it) } ?: (if (legacy) "mV" else "nd").latin1()
            eprintf(" Signal %d gain (adu/%s) [%g]: ", k, ushow, dfout[k].gain)
            answer = sfgets(anslen)
            run {
                val d = CDouble(dfout[k].gain)
                sscanf(answer, "%lf", d)
                dfout[k].gain = d.v
            }
            // WFDB-x: a resolution is offered only if it comes from the input
            // (or the previous output signal) and suits the output format;
            // the C program otherwise offered one based on the format (12 bits
            // for 16-bit formats). Without one, the user must give it. Legacy
            // mode: as in the C program.
            while (true) {
                if (k > 0) dfout[k].adcres = dfout[k - 1].adcres
                val d = dfout[k]
                val (maxres, legacyRes) = formatRes(d.fmt)
                if (legacy && (d.adcres < 8 || d.adcres > maxres)) d.adcres = legacyRes // WFDB-x: legacy mode
                if (d.adcres >= 8 && d.adcres <= maxres) {
                    eprintf(" Signal %d ADC resolution in bits (8-32) [%d]: ", k, d.adcres)
                } else {
                    eprintf(" Signal %d ADC resolution in bits (8-32): ", k)
                    d.adcres = 0
                }
                answer = sfgets(anslen)
                val r = CInt(d.adcres)
                sscanf(answer, "%d", r)
                d.adcres = r.v
                if (d.adcres == 0 && !legacy) {
                    eprintf("%s: the ADC resolution of signal %d must be specified\n", pname, k)
                    wfdbquit()
                    exit(1)
                }
                if (!(d.adcres < 8 || d.adcres > 32)) break
            }
            eprintf(" Signal %d ADC zero level (adu) [%d]: ", k, dfout[k].adczero)
            answer = sfgets(anslen)
            val z = CInt(dfout[k].adczero)
            sscanf(answer, "%d", z)
            dfout[k].adczero = z.v
        }
        if (!ttyin.isStd()) ttyin.close()
    }

    // Check the starting and ending times.
    if (from != 0L) startp = argv[from.toInt()]
    from = strtim(startp)
    if (from < 0) from = -from
    var btstring = mstimstr(-from)
    if (btstring.size > 29) btstring = btstring.copyOf(29) // (C: snprintf into a 30-byte buffer)
    if (to != 0L) {
        to = strtim(argv[to.toInt()])
        if (to < 0) to = -to
        if (to > 0) {
            nsamp = to - from
            if (nsamp <= 0) {
                eprintf("%s: 'to' time must be later than 'from' time\n", pname)
                exit(1)
            }
        }
    }
    val spm = strtim("1:0")

    if (mflag) {
        // In multifrequency mode, the preceding calculations are performed in
        // low-resolution mode (so that 'from' and 'to' are rounded to the
        // nearest frame number, and 'nsamp' is the number of frames to copy.)
        // For annotation processing, switch to high-resolution mode, convert
        // 'from' and 'to' into high-resolution sample numbers, and set the
        // output annotation resolution accordingly.
        setgvmode(WFDB_HIGHRES)
        spf = getspf()
        from *= spf.toLong()
        to *= spf.toLong()
        setafreq(ofreq * spf.toDouble())
    } else {
        // For a single-frequency record, the time resolution for output
        // annotations is equal to the output frame frequency (ofreq), so we
        // do not need an explicit time resolution. If a default time
        // resolution is set by isigopen, remove it.
        setafreq(0.0)
    }

    // Process the annotation file(s), if any.
    val nann = ainames.size
    if (nann > 0) {
        val annot = Annotation()
        val ai = Array(nann) { Anninfo(ainames[it], WFDB_READ) }

        // Check that the input annotation files are readable.
        if (annopen(irec, ai, nann) < 0 || iannsettime(from) < -1) exit(2)

        // Associate the output annotation files with the new record, if a new
        // record name was specified. Otherwise, associate them with the
        // existing output record.
        val p0 = nrec ?: orec ?: "(null)".latin1()

        // Check that the output annotation files are writeable, without
        // closing the input annotation files.
        val p1 = bcat("+".latin1(), cstr(p0))
        for (x in ai) x.stat = WFDB_WRITE
        if (annopen(p1, ai, nann) < 0) exit(2)

        // Write the annotation files.
        for (k in 0 until nann) {
            var tt = 0L
            var cc = -129 // (less than any chan)
            while (getann(k, annot) == 0 && (to == 0L || annot.time <= to)) {
                if (annot.time == 0L && annot.subtyp == 0 && annot.chan == 0 && annot.num == 0 &&
                    (annot.anntyp == NOTQRS || annot.anntyp == NOTE)
                ) continue
                annot.time = d2l((annot.time - from).toDouble() * ofreq / ifreq)
                // If the -u option was specified, make sure that the corrected
                // annotation time is positive and that it is later than the
                // previous annotation time (exception: if it matches the
                // previous annotation time, but the chan field is greater
                // than that of the previous annotation, no time adjustment is
                // performed).
                if (uflag && (annot.time < tt || (annot.time == tt && annot.chan <= cc))) {
                    tt++
                    annot.time = tt
                } else {
                    tt = annot.time
                }
                cc = annot.chan
                putann(k, annot)
            }
        }

        // Close the annotation files.
        for (k in nann - 1 downTo 0) {
            iannclose(k)
            oannclose(k)
        }
    }

    // Quit if no signals are to be written.
    if (nosig == 0) exit(0)

    // Check that the input signals are readable.
    eprintf("Checking input signals ...")
    if (isigsettime(from) < 0) exit(2)
    eprintf(" done\n")

    // If an output record was specified using `-o', check that the output
    // signals are writable. Suppress warning messages about possible
    // sampling frequency differences.
    wfdbquiet()
    if (orecV != null) {
        if (osigopen(orecV, dfout, nosig) != nosig) {
            // WFDB-x: say why if an output file is one of the input files
            // (the library's message, quieted above, is the last error)
            val e = cstr(wfdberror())
            val tail = " is also an input file\n"
            if (!legacy && e.startsWith("osigopen: output file ") && e.size > 22 + tail.length && e.endsWith(tail)) {
                eprintf("%s: can't write output signals (%s)\n", pname, e.copyOf(e.size - 1))
            } else {
                eprintf("%s: can't write output signals\n", pname)
            }
            exit(2)
        }
    }
    wfdbverbose()

    // Make sure that signal file format is not 0 (putvec cannot write to a
    // null record).
    for (k in 0 until nosig) {
        if (dfout[k].fmt == 0) {
            eprintf("%s: signal %d format cannot be 0 (changing to format 16)\n", pname, k)
            dfout[k].fmt = 16
            reopen = true // record must be (re)opened using osigfopen to make the change effective
        }
    }

    // Without -M, the output frames hold one sample of each signal (as for
    // output signals specified interactively), so signals of the -o record
    // with more than one sample per frame are (re)opened with one. (C reads
    // past the end of its output array; see "Undefined behaviors" in
    // docs/KNOWN_C_BEHAVIORS.md.)
    if (!mflag) {
        for (k in 0 until nosig) {
            if (dfout[k].spf > 1) {
                dfout[k].spf = 1
                reopen = true
            }
        }
    }

    // If the `-n' option was specified, copy the signal descriptions from the
    // input record header file into the WFDB_Siginfo structures for the
    // output record (for eventual storage in the new output header file). To
    // make the changes effective, the output signals must be (re)opened using
    // osigfopen.
    if (nrec != null && useIrecDesc) {
        for (k in 0 until nosig) dfout[k].desc = dfin[siglist[k]].desc?.copyOf()
        reopen = true
    }

    // Determine relative gains and offsets of the signals. If any output gain
    // must be adjusted, the output signals must be reopened (to ensure that
    // the correct gains are written to the output header).
    for (k in 0 until nosig) {
        val j = siglist[k]
        // A signal may be rescaled by xform depending on the gains and ADC
        // resolutions specified. The rules for doing so are as follows:
        // 1. If the output gain has not been specified, the signal is scaled
        //    only if the input and output ADC resolutions differ. In this
        //    case, the scale factor (gain[]) is determined so that the
        //    appropriate number of bits will be dropped from or added to each
        //    signal.
        // 2. If the output gain has been specified, the signal is scaled by
        //    the ratio of the output and input gains. (WFDB-x: if the input
        //    signal is uncalibrated, this is an error; the C program, and
        //    legacy mode, assumed an input gain of WFDB_DEFGAIN.)
        // These rules differ from those used by earlier versions of xform,
        // although the default behavior remains the same in most cases.
        if (dfout[k].gain == 0.0) {
            // output gain not specified
            // WFDB-x: rescaling by ADC resolution needs both resolutions (the
            // C program guessed an unspecified input resolution from the
            // format, assuming WFDB_DEFRES for 16-bit formats, as legacy mode
            // does).
            if (legacy) {
                if (dfin[j].adcres == 0) dfin[j].adcres = formatRes(dfin[j].fmt).second
            } else if (dfin[j].adcres == 0 || dfout[k].adcres == 0) {
                val n: Int
                val r: ByteArray
                if (dfin[j].adcres == 0) {
                    n = j
                    r = irec
                } else {
                    n = k
                    r = orecV ?: nrec ?: ByteArray(0)
                }
                eprintf("%s: ADC resolution of signal %d of record %s is not specified\n", pname, n, r)
                wfdbquit()
                exit(2)
            }
            gain[k] = (1L shl dfout[k].adcres).toDouble() / (1L shl dfin[j].adcres).toDouble()
        } else if (dfin[j].gain == 0.0) {
            // output gain specified, but input gain not specified
            if (legacy) {
                // WFDB-x: as in the C program (legacy mode)
                gain[k] = dfout[k].gain / WFDB_DEFGAIN
            } else {
                eprintf(
                    "%s: signal %d of record %s is uncalibrated; it cannot be rescaled to the specified gain\n",
                    pname, j, irec,
                )
                wfdbquit()
                exit(2)
            }
        } else {
            // input and output gains specified
            gain[k] = dfout[k].gain / dfin[j].gain
        }

        if (gain[k] != 1.0) gflag = true
        deltav[k] = d2i(dfout[k].adczero.toDouble() - gain[k] * dfin[j].adczero.toDouble())
        if (dfout[k].gain != dfin[j].gain * gain[k] ||
            dfout[k].baseline.toDouble() != dfin[j].baseline.toDouble() * gain[k]
        ) {
            dfout[k].gain = dfin[j].gain * gain[k]
            dfout[k].baseline = d2i(dfin[j].baseline.toDouble() * gain[k])
            reopen = true
        }
        // Note that dfout[i].gain is 0 (indicating that the signal is
        // uncalibrated) if dfin[j].gain is 0. This is a *feature*, not a bug:
        // we don't want to create output signals that appear to have been
        // calibrated if the inputs weren't calibrated.
    }

    // Reopen output signals if necessary.
    if (reopen && osigfopen(dfout, nosig) != nosig) exit(2)

    // Determine the legal range of sample values for each output signal.
    for (k in 0 until nosig) {
        val half = 1L shl (dfout[k].adcres - 1)
        val z = dfout[k].adczero.toLong()
        vmax[k] = (z + half - 1).toInt()
        vmin[k] = (z - half).toInt()
    }

    // If resampling is required, initialize the interpolation/decimation
    // parameters.
    var m = 0
    var n = 0
    var mn = 0
    if (ifreq != ofreq) {
        val f = gcd(ifreq, ofreq)

        fflag = true
        m = d2i(ifreq / f)
        n = d2i(ofreq / f)
        mn = m * n
        getvec(vin)
        for (k in 0 until nosig) {
            val x = vin[siglist[k]]
            vv[k] = if (x != WFDB_INVALID_SAMPLE) d2i(x.toDouble() * gain[k] + deltav[k].toDouble()) else WFDB_INVALID_SAMPLE
        }
    }

    // If in multifrequency mode, set msiglist offsets.
    if (mflag) {
        for (k in 0 until nosig) {
            var s = 0
            for (q in 0 until siglist[k]) s += dfin[q].spf
            msiglist[k] = s
        }
        // WFDB-x: room for every output sample of a frame, and for every
        // input sample that they read (C sizes vout for the input frame and
        // writes past its end when the output frame is larger; the samples
        // read beyond the input frame are 0 here)
        var ospf = 0
        var need = 0
        for (k in 0 until nosig) {
            ospf += dfout[k].spf
            need = maxOf(need, msiglist[k] + dfout[k].spf)
        }
        if (vout.size < ospf) vout = vout.copyOf(ospf)
        if (vin.size < need) vin = vin.copyOf(need)
    }

    fun more(): Boolean {
        if (nsamp == -1L) return true
        val r = nsamp > 0
        nsamp--
        return r
    }

    /** Progress indicator: a dot per minute of input, a newline per hour. */
    fun tick() {
        if (++nsm >= spm) {
            nsm = 0
            eprintf(".")
            if (++nminutes >= 60) {
                nminutes = 0
                eprintf("\n")
            }
        }
    }

    // Process the signals.
    if (!fflag) {
        // no frequency changes; gain changes if gflag
        while (true) {
            val stat = if (mflag) getframe(vin) else getvec(vin)
            if (!(stat >= nisig && more())) break
            tick()
            if (!mflag) {
                // standard mode
                for (k in 0 until nosig) {
                    val vt = vin[siglist[k]]
                    if (vt == WFDB_INVALID_SAMPLE) {
                        vout[k] = vt
                    } else {
                        if (gflag) {
                            var vd = vt.toDouble() * gain[k] + deltav[k].toDouble()
                            if (dflag) vd += xdither(rng)
                            vout[k] = xround(vd)
                        } else {
                            vout[k] = vt + deltav[k]
                        }
                        vout[k] = check(vout[k], k, vmax, vmin, clip)
                    }
                }
            } else {
                // multifrequency mode
                var j = 0
                for (k in 0 until nosig) {
                    for (q in 0 until maxOf(dfout[k].spf, 0)) {
                        val vt = vin[msiglist[k] + q]
                        if (vt == WFDB_INVALID_SAMPLE) {
                            vout[j] = vt
                        } else {
                            if (gflag) {
                                var vd = vt.toDouble() * gain[k] + deltav[k].toDouble()
                                if (dflag) vd += xdither(rng)
                                vout[j] = xround(vd)
                            } else {
                                vout[j] = vt + deltav[k]
                            }
                            vout[j] = check(vout[j], k, vmax, vmin, clip)
                        }
                        j++
                    }
                }
            }
            if (putvec(vout) < 0) break
        }
    } else {
        // change frequency (and gain, if gflag)
        while (getvec(vin) >= nisig && more()) {
            tick()
            for (k in 0 until nosig) {
                val vt = vin[siglist[k]]
                v[k] = if (vt == WFDB_INVALID_SAMPLE) {
                    vt
                } else if (gflag) {
                    var vd = vt.toDouble() * gain[k] + deltav[k].toDouble()
                    if (dflag) vd += xdither(rng)
                    xround(vd)
                } else {
                    vt + deltav[k]
                }
            }
            while (ot <= it) {
                val r = ot % n.toLong()
                val x = if (r == 0L) 1.0 else r.toDouble() / n.toDouble()
                for (k in 0 until nosig) {
                    if (v[k] == WFDB_INVALID_SAMPLE || vv[k] == WFDB_INVALID_SAMPLE) {
                        vout[k] = WFDB_INVALID_SAMPLE
                    } else {
                        var vd = vv[k].toDouble() + x * (v[k] - vv[k]).toDouble()
                        if (dflag) vd += xdither(rng)
                        vout[k] = check(xround(vd), k, vmax, vmin, clip)
                    }
                }
                if (putvec(vout) < 0) {
                    nsamp = 0
                    break
                }
                ot += m.toLong()
            }
            v.copyInto(vv, 0, 0, nosig)
            if (it > mn.toLong()) {
                it -= mn.toLong()
                ot -= mn.toLong()
            }
            it += n.toLong()
        }
    }
    if (nminutes > 0) eprintf("\n")

    // Generate a new header file, if so requested.
    val nrecV = nrec
    if (nrecV != null) {
        setsampfreq(ofreq)
        if (btstring.at(0) == '['.code) {
            // discard final ']'
            val bt = cstr(btstring)
            setbasetime(bt.copyOfRange(1, bt.size - 1))
        }
        newheader(nrecV)

        // Copy info strings from the input header file into the new one.
        // Suppress error messages from the WFDB library.
        wfdbquiet()
        var info = getinfo(irec)
        while (info != null) {
            putinfo(info)
            info = getinfo(null as ByteArray?)
        }

        // Append additional info summarizing what xform has done.
        putinfo(cformat("Produced by %s from record %s, beginning at %s", pname, irec, startp))
        for (k in 0 until nosig) {
            if (siglist[k] != k) {
                val xinfo = ByteVec(64)
                xinfo.addAll(cformat("record %s, signal %d <- record %s, signal %d", nrecV, k, irec, siglist[k]))
                if (gain[k] != 1.0) xinfo.addAll(cformat(" * %g", gain[k]))
                if (deltav[k] != 0) {
                    xinfo.addAll(cformat(" %c %d", if (deltav[k] > 0) '+' else '-', if (deltav[k] > 0) deltav[k] else -deltav[k]))
                }
                putinfo(xinfo.toByteArray())
            }
        }
        wfdbverbose()
    }
    wfdbquit()
    exit(0)
}
