// ad2m: convert an AHA format signal file to MIT format (port of
// convert/ad2m.c, through rust/src/bin/ad2m.rs).
//
// The input is either an AHA DB distribution tape format file (read as
// record 16, two signals in format 16 on the standard input), or a
// compressed (*.CMP) file from an AHA DB CD-ROM or floppy diskette.
//
// Where the C program has undefined behavior (an input file name ending in
// / without -r, a record name of more than 7 characters, or a directory as
// input file), this port uses an empty record name, the full signal file
// name, and reports the directory as unreadable (see
// docs/KNOWN_C_BEHAVIORS.md).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of convert/ad2m.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in signal parameters: the new options -F
// FREQ, -G GAIN, -R BITS and -U UNITS give the sampling frequency, gain, ADC
// resolution and units, and are required (-U unless the gain is 0; the
// original assumed those of the AHA database: 250 Hz, 400 adu/mV, 12 bits and
// millivolts); the -f and -t times are converted at the -F frequency;
// --legacy, as the first argument, restores the original behavior. Each change
// is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/ad2m.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2007 George B. Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private const val AD2M_EODF = 0x8000 // AHA data file end-of-data marker (0100000)

private val AD2M_HELP = arrayOf(
    "usage: %s -i AHAFILE [ OPTIONS ... ]\n",
    "where AHAFILE is the name of the AHA-format input signal file,",
    "and OPTIONS may include:",
    " -c         process a compressed input file (default if AHAFILE ends",
    "             with .CMP or .cmp;  otherwise old AHA tape format assumed)",
    " -f TIME    begin at specified TIME (default: 0, i.e., the beginning",
    "             of the input file)",
    " -F FREQ    sampling frequency in Hz (required; AHA database: 250)",
    " -G GAIN    gain in adu per physical unit (required; AHA database: 400)",
    " -h         print this usage summary",
    // (two strings concatenated by a misplaced comma in C)
    " -r RECORD  specify the name of the output RECORD (default: use the,            input file name, less path info and extension, as RECORD)",
    " -R BITS    ADC resolution in bits (required; AHA database: 12)",
    " -t TIME    stop at specified TIME (default: 35 minutes after the",
    "             starting time if RECORD=x2xx or x3xx, 3 hours if",
    "             RECORD=x0xx or x1xx, or the end of the input file)",
    " -U UNITS   physical units (required unless the gain is 0; AHA: mV)",
)

/** wfdb-x: the help lines added by WFDB-x (left out in legacy mode). */
private val AD2M_WFDBX_HELP = setOf(
    " -F FREQ    sampling frequency in Hz (required; AHA database: 250)",
    " -G GAIN    gain in adu per physical unit (required; AHA database: 400)",
    " -R BITS    ADC resolution in bits (required; AHA database: 12)",
    " -U UNITS   physical units (required unless the gain is 0; AHA: mV)",
)

private fun Wfdb.ad2mHelp(pname: ByteArray) {
    val legacy = wfdbx_get_legacy() != 0
    eprintf(AD2M_HELP[0], pname)
    for (k in 1 until AD2M_HELP.size) {
        val s = AD2M_HELP[k]
        if (!(legacy && s in AD2M_WFDBX_HELP)) eprintf("%s\n", s)
    }
}

// The AHA Database: two ECG signals sampled at 250 Hz, with 12-bit
// resolution and 400 adu/mV (the parameters of the C program, legacy mode).
private const val AD2M_AHA_FREQ = 250.0
private const val AD2M_AHA_GAIN = 400.0
private const val AD2M_AHA_ADCRES = 12

/**
 * Reader of compressed-format input (the static variables of C's getcvec).
 *
 * The compressed format stores first differences of the two signals: if the
 * high bit of the first byte is 0, its other 7 bits are the (signed)
 * difference for signal 0 and the next byte that for signal 1; otherwise
 * the next 15 bits are the difference for signal 0, and the following 16
 * bits that for signal 1.
 */
private class Ad2mCmp(val input: WfdbFile) {
    var v0 = 0
    var v1 = 0

    /** Reads a pair of samples; 2 on success, 0 at end of file. */
    fun getcvec(v: IntArray): Int {
        var x = input.getc()
        if (x == EOF) return 0
        var y = input.getc()
        if (y == EOF) {
            eprintf("unexpected EOF in input file\n")
            return 0
        }
        if ((x and 0x80) == 0) {
            v0 += x and 0x7f
            if (x and 0x40 != 0) v0 += -128
            v1 += y
            if (y and 0x80 != 0) v1 += -256
        } else {
            x = if (x and 0x40 != 0) x or 0x3f.inv() else x and 0x7f
            v0 += x * 256 + y
            x = input.getc()
            if (x != EOF) y = input.getc()
            if (x == EOF || y == EOF) {
                eprintf("unexpected EOF in input file\n")
                return 0
            }
            if (x and 0x80 != 0) x = x or 0xff.inv()
            v1 += x * 256 + y
        }
        v[0] = v0
        v[1] = v1
        return 2
    }
}

/** The ad2m tool. */
fun Wfdb.ad2mMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    var ifname: ByteArray? = null
    var record0: ByteArray? = null
    var cflag = false
    val v = IntArray(2)
    var t = 0L
    var startTime = 0L
    var endTime = 0L
    // wfdb-x: the signal parameters (-F, -G, -R, -U), and the -f and -t
    // arguments (converted once -F is known)
    var uunits: ByteArray? = null
    var fstr: ByteArray? = null
    var tstr: ByteArray? = null
    val ffreq = CDouble(0.0)
    val ggain = CDouble(0.0)
    var gset = false
    val rres = CInt(0)
    if (legacy) {
        // wfdb-x: in legacy mode, the parameters of the AHA database, set by
        // the C program (250 Hz, 400 adu/mV, 12 bits, and no units, i.e.,
        // millivolts); -F, -G, -R and -U are not options then.
        ffreq.v = AD2M_AHA_FREQ
        ggain.v = AD2M_AHA_GAIN
        gset = true
        rres.v = AD2M_AHA_ADCRES
        setsampfreq(AD2M_AHA_FREQ)
    }

    var i = 1
    while (i < argc) {
        val a = argv[i]
        if (a.at(0) == '-'.code) {
            val opt = a.at(1).toChar()
            if (legacy && (opt == 'F' || opt == 'G' || opt == 'R' || opt == 'U')) {
                eprintf("%s: unrecognized option %s\n", pname, a)
                exit(1)
            }
            when (opt) {
                'c' -> cflag = true
                'f' -> {
                    i++
                    if (i >= argc) {
                        eprintf("%s: start time must follow -f\n", pname)
                        exit(1)
                    }
                    if (legacy) {
                        startTime = strtim(argv[i]) // as in the C program
                    } else {
                        fstr = argv[i] // converted once -F is known (WFDB-x)
                    }
                }
                'h' -> { // help requested
                    ad2mHelp(pname)
                    exit(1)
                }
                'i' -> { // input file name follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: name of AHA-format input file must follow -i\n", pname)
                        exit(1)
                    }
                    ifname = cstr(argv[i])
                }
                'r' -> {
                    i++
                    if (i >= argc) {
                        eprintf("%s: record name must follow -r\n", pname)
                        exit(1)
                    }
                    record0 = cstr(argv[i])
                }
                't' -> {
                    i++
                    if (i >= argc) {
                        eprintf("%s: end time must follow -t\n", pname)
                        exit(1)
                    }
                    if (legacy) {
                        endTime = strtim(argv[i]) // as in the C program
                    } else {
                        tstr = argv[i] // converted once -F is known (WFDB-x)
                    }
                }
                'F' -> { // sampling frequency (WFDB-x)
                    i++
                    if (i >= argc || sscanf(argv[i], "%lf", ffreq) != 1 || ffreq.v <= 0.0) {
                        eprintf("%s: sampling frequency (> 0) must follow -F\n", pname)
                        exit(1)
                    }
                }
                'G' -> { // gain in adu per physical unit (WFDB-x)
                    i++
                    if (i >= argc || sscanf(argv[i], "%lf", ggain) != 1 || ggain.v < 0.0) {
                        eprintf("%s: gain (>= 0) must follow -G\n", pname)
                        exit(1)
                    }
                    gset = true
                }
                'R' -> { // ADC resolution in bits (WFDB-x)
                    i++
                    if (i >= argc || sscanf(argv[i], "%d", rres) != 1 || rres.v !in 1..32) {
                        eprintf("%s: ADC resolution (1-32 bits) must follow -R\n", pname)
                        exit(1)
                    }
                }
                'U' -> { // physical units (WFDB-x)
                    i++
                    if (i >= argc) {
                        eprintf("%s: units must follow -U\n", pname)
                        exit(1)
                    }
                    uunits = cstr(argv[i])
                }
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
    if (ifname == null) {
        ad2mHelp(pname)
        exit(1)
    }
    // wfdb-x: the signal parameters must be given explicitly; the C program
    // assumed those of the AHA database (250 Hz, 400 adu/mV, 12 bits, and no
    // units, i.e., millivolts), as legacy mode does (the values set above
    // for legacy mode pass these checks, and no units are required then).
    if (ffreq.v <= 0.0) {
        eprintf("%s: the sampling frequency must be specified (-F)\n", pname)
        exit(1)
    }
    if (!gset) {
        eprintf("%s: the gain must be specified (-G)\n", pname)
        exit(1)
    }
    if (rres.v < 1) {
        eprintf("%s: the ADC resolution must be specified (-R)\n", pname)
        exit(1)
    }
    if (ggain.v != 0.0 && uunits == null && !legacy) {
        eprintf("%s: the units must be specified (-U)\n", pname)
        exit(1)
    }
    setsampfreq(ffreq.v)
    fstr?.let { startTime = strtim(it) }
    tstr?.let { endTime = strtim(it) }
    if (0 < endTime && endTime <= startTime) {
        ad2mHelp(pname)
        exit(1)
    }
    if (!cflag && ifname.size > 4 && (ifname.endsWith(".CMP") || ifname.endsWith(".cmp"))) cflag = true

    // Attach the input file to the standard input.
    // (C reads a directory forever; WFDB-x reports it as unreadable)
    if (!beq(ifname, "-") && (Platform.isDirectory(ifname) || !freopen_stdin(ifname))) {
        eprintf("%s: can't read input file `%s'\n", pname, ifname)
        exit(2)
    }

    // If no output record name was specified, use the basename of the input
    // file, less any extension.
    val record: ByteArray = record0 ?: run {
        val r = progName(ifname)
        var p = -1
        for (k in 1 until r.size) {
            if (r[k] == '.'.code.toByte()) {
                p = k
                break
            }
        }
        if (p >= 0) r.copyOf(p) else r
    }

    if (endTime == 0L && record.size == 4) { // assume AHA DB input
        if (record.at(1) == '2'.code || record.at(1) == '3'.code) {
            endTime = strtim("35:0") // short format record
        } else if (record.at(1) == '0'.code || record.at(1) == '1'.code) {
            endTime = strtim("3:0:0") // long format record
        }
    }

    if (endTime == 0L) {
        eprintf("%s: warning: end time not specified, output may be truncated\n", pname)
        eprintf("               rerun with -t TIME to override\n")
        endTime = startTime + strtim("100:0:0")
    }

    val dfname = bcat(record, ".dat".latin1())
    fun sig() = Siginfo(fname = dfname, desc = ByteArray(0), gain = ggain.v, units = uunits, fmt = 212, adcres = rres.v)
    val dfarray = arrayOf(sig(), sig())
    if (osigfopen(dfarray, 2) < 0) exit(3)

    if (!cflag) { // process tape-format input file
        if (isigopen("16", dfarray, 2) < 2) exit(2)
        if (startTime > 0) {
            t = startTime
            if (isigsettime(t) < 0) exit(2)
        }
        // continue to soft EOF, hard error, or specified time
        while (getvec(v) == 2 && v[0] != AD2M_EODF && putvec(v) > 0 && ++t < endTime) {
            // copy
        }
        // write header with correct signal length and checksums
        newheader(record)
        // continue to hard EOF (to position tape properly if reading from
        // tape)
        while (getvec(v) >= 0) {
            // skip
        }
    } else { // process compressed-format input file
        val cmp = Ad2mCmp(WfdbFile.stdin())
        while (t < startTime && cmp.getcvec(v) == 2) t++
        // continue to hard EOF, hard error, or specified time
        while (cmp.getcvec(v) == 2 && putvec(v) > 0 && ++t < endTime) {
            // copy
        }
        // write header with correct signal length and checksums
        newheader(record)
        cmp.input.close()
    }

    wfdbquit()
    exit(0)
}
