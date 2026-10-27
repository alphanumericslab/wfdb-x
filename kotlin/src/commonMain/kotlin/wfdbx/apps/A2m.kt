// a2m: convert an AHA format annotation file to MIT format (port of
// convert/a2m.c, through rust/src/bin/a2m.rs).
//
// This program converts four types of AHA format annotation files to MIT
// format:
//
//  0  AHA-format annotation files produced by WFDB library-based programs
//     that use AHA_WRITE mode and putann (m2a is an example). Time is
//     measured in sample intervals from the beginning of the record, and
//     MIT annotation codes are included and read into the chan field of the
//     annotation by getann; if such codes are present (chan non-zero), the
//     AHA code is ignored.
//  1  Standard AHA annotation files from short-format AHA DB distribution
//     tapes. Time is measured in milliseconds from the beginning of the test
//     period (five minutes after the first sample); wfdb-x converts
//     milliseconds at the sampling frequency of the record (or -F), where
//     the C program assumed 4 ms per sample interval (250 Hz).
//  2  Standard AHA annotation files from long-format AHA DB distribution
//     tapes. Time is measured as for type 1, except that the test period
//     begins 2.5 hours after the first sample.
//  3  "Compressed" (*.ANO) annotation files from AHA DB CD-ROMs or floppy
//     diskettes. Time is measured as for files of type 1 or 2, depending on
//     the record name (x2xx or x3xx: short format, x0xx or x1xx: long
//     format).
//
// Where the C program has undefined behavior (an input file name ending in
// / without -r, or a directory as input file), this port uses an empty
// record name, and reports the directory as unreadable (see
// docs/KNOWN_C_BEHAVIORS.md).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of convert/a2m.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the new option -F
// FREQ gives it when the record has no header or its header gives none, and is
// then required (the original assumed 250 Hz, or 1 sample per second without a
// header); annotation times given in milliseconds (AHA file types 1 to 3) are
// converted at the record's sampling frequency (the original assumed 4 ms per
// sample); --legacy, as the first argument, restores the original behavior.
// Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the
// reasons.
//
// Original C program: convert/a2m.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2010 George B. Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.Annotation
import wfdbx.cstd.*

private val A2M_HELP = arrayOf(
    "usage: %s -i AHAFILE [ OPTIONS ... ]\n",
    "where AHAFILE is the name of the AHA-format input annotation file,",
    "and OPTIONS may include:",
    " -a ANNOTATOR  specify the output annotator name (default: 'atr')",
    " -F FREQ       sampling frequency, if the record header does not specify",
    "                one (AHA database: 250)",
    " -h            print this usage summary",
    " -r RECORD     specify the name of the output RECORD (default: use the",
    "                input file name, less path info and extension, as RECORD)",
    " -s TIME       shift annotations by TIME",
    "                (defaults: 0 for TYPE 0,",
    "                      5:0 for TYPE 1, (or TYPE 3 if RECORD=x2xx or x3xx)",
    "                   2:30:0 for TYPE 2, (or TYPE 3 if RECORD=x0xx or x1xx)",
    " -t TYPE       specify type of file to be converted:",
    "                0 for files produced by WFDB applications in AHA format,",
    "                1 for short-format tape files,",
    "                2 for long-format tape files, or",
    "                3 for compressed files from AHA DB CD-ROMs or diskettes",
    "                (defaults: 3 if AHAFILE ends in .ANO or .ano, else 0)",
)

/** wfdb-x: the help lines added by wfdb-x (left out in legacy mode). */
private val A2M_WFDBX_HELP = setOf(
    " -F FREQ       sampling frequency, if the record header does not specify",
    "                one (AHA database: 250)",
)

private fun Wfdb.a2mHelp(pname: ByteArray) {
    val legacy = wfdbx_get_legacy() != 0
    eprintf(A2M_HELP[0], pname)
    for (k in 1 until A2M_HELP.size) {
        val s = A2M_HELP[k]
        if (!(legacy && s in A2M_WFDBX_HELP)) eprintf("%s\n", s)
    }
}

// Input file types (-t; see the table above).
private const val FT_WFDB = 0
private const val FT_SHORT = 1
private const val FT_LONG = 2
private const val FT_COMPRESSED = 3

/** Sampling frequency of the AHA Database (legacy mode). */
private const val AHA_FREQ = 250.0

/** Size of a compressed AHA annotation. */
private const val CANNLEN = 6

/** Reads a compressed AHA annotation; -1 at end of file. */
private fun getcann(input: WfdbFile, ap: Annotation): Int {
    val buf = ByteArray(CANNLEN)
    if (input.fread(buf, 1, CANNLEN) != CANNLEN) return -1 // hard EOF
    // Compressed AHA format:
    //  buf[0]  AHA label (`N', `V', `F', `R', `E', `P', `Q', `[', `]', or `U')
    //  buf[1]  high byte of ahatime, or 0xff if at soft EOF
    //  buf[2]  middle byte of ahatime
    //  buf[3]  low byte of ahatime
    //  buf[4]  high byte of annotation serial number (ignored here)
    //  buf[5]  low byte of serial number
    if (buf.at(1) == 0xff) return -1 // soft EOF

    // convert AHA label to annotation code (C char is signed)
    ap.anntyp = ammap(buf[0].toInt())
    if (ap.anntyp == 0) return -1 // alternate soft EOF, used in a few AHA DB CD-ROM files
    // AHA `U' (unreadable data) label: decode as NOISE, subtype -1; all
    // others have subtype 0
    ap.subtyp = if (buf.at(0) == 'U'.code) -1 else 0

    val h = buf.at(1).toLong()
    val m = buf.at(2).toLong()
    val l = buf.at(3).toLong()
    // time in milliseconds from the start of the annotated segment
    ap.time = (h shl 16) or (m shl 8) or l
    return 0
}

/**
 * A time in milliseconds, in sample intervals at the record's sampling
 * frequency (wfdb-x; C, and legacy mode, assumed 4 ms per sample interval).
 */
private fun Wfdb.msToSamples(t: Long, legacy: Boolean): Long {
    if (legacy) return t shr 2 // wfdb-x: legacy mode: 4 msec/sample
    return d2l(t.toDouble() * sampfreq(null as ByteArray?) / 1000.0)
}

/** The a2m tool. */
fun Wfdb.a2mMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    var ifname: ByteArray? = null
    var record0: ByteArray? = null
    var oann = "atr".latin1()
    var ftype = -1
    var offsetArg = 0
    var nann = 2
    val annot = Annotation()
    val ffreq = CDouble(0.0) // wfdb-x: -F

    // Read and interpret command-line arguments.
    var i = 1
    while (i < argc) {
        val a = argv[i]
        if (a.at(0) == '-'.code) {
            when (a.at(1).toChar()) {
                'a' -> { // annotator name follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: output annotator name must follow -a\n", pname)
                        exit(1)
                    }
                    oann = argv[i]
                }
                'F' -> {
                    if (legacy) {
                        eprintf("%s: unrecognized option %s\n", pname, a)
                        exit(1)
                    }
                    // sampling frequency follows (wfdb-x)
                    i++
                    if (i >= argc || sscanf(argv[i], "%lf", ffreq) != 1 || ffreq.v <= 0.0) {
                        eprintf("%s: sampling frequency (> 0) must follow -F\n", pname)
                        exit(1)
                    }
                }
                'h' -> { // help requested
                    a2mHelp(pname)
                    exit(1)
                }
                'i' -> { // input file name follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: name of AHA-format input file must follow -i\n", pname)
                        exit(1)
                    }
                    val f = cstr(argv[i])
                    ifname = f
                    if (ftype < 0 && f.size > 4 && (f.endsWith(".ANO") || f.endsWith(".ano"))) {
                        ftype = FT_COMPRESSED
                    }
                }
                'r' -> { // record name follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: record name must follow -a\n", pname)
                        exit(1)
                    }
                    record0 = cstr(argv[i])
                }
                's' -> { // time shift follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: time shift must follow -s\n", pname)
                        exit(1)
                    }
                    // save position in arg list, convert to time later when
                    // sampling frequency is known
                    offsetArg = i
                }
                't' -> { // file type follows
                    i++
                    if (i < argc) ftype = atoi(argv[i])
                    if (i >= argc || ftype !in FT_WFDB..FT_COMPRESSED) {
                        eprintf("%s: file type (0-3) must follow -t\n", pname)
                        exit(1)
                    }
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

    // Quit if input filename was not specified.
    if (ifname == null) {
        a2mHelp(pname)
        exit(1)
    }

    // Attach the input file to the standard input.
    // (C reads a directory forever; wfdb-x reports it as unreadable)
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

    if (ftype < 0) ftype = FT_WFDB

    // Open the annotation files.
    val afarray = if (ftype != FT_COMPRESSED) {
        arrayOf(Anninfo(oann, WFDB_WRITE), Anninfo("-".latin1(), WFDB_AHA_READ))
    } else {
        nann = 1
        arrayOf(Anninfo(oann, WFDB_WRITE))
    }
    if (annopen(record, afarray, nann) < 0) exit(2)

    // Set the time shift.
    // wfdb-x: if the record header does not give the sampling frequency, -F
    // must give it. (The C program assumed the rate of the AHA database,
    // 250 Hz, if a header without a frequency existed, and 1 sample per
    // second if there was no header, as legacy mode does.)
    if (legacy) {
        if (sampfreq(record) == 0.0) setsampfreq(AHA_FREQ)
    } else if (sampfreq(record) <= 0.0) {
        if (ffreq.v > 0.0) {
            setsampfreq(ffreq.v)
        } else {
            eprintf("%s: sampling frequency of record %s is not specified (use -F)\n", pname, record)
            exit(1)
        }
    }
    var offset = 0L
    if (offsetArg != 0) {
        offset = strtim(argv[offsetArg])
    } else {
        when (ftype) {
            FT_SHORT -> offset = strtim("5:0")
            FT_LONG -> offset = strtim("2:30:0")
            FT_COMPRESSED -> {
                if (record.size == 4 && (record.at(1) == '0'.code || record.at(1) == '1'.code)) {
                    offset = strtim("2:30:0") // long format
                } else if (record.size == 4 && (record.at(1) == '2'.code || record.at(1) == '3'.code)) {
                    offset = strtim("5:0") // short format
                }
                // otherwise, leave offset at zero (unrecognized format)
            }
        }
    }

    // Reformat the annotations.
    when (ftype) {
        FT_WFDB -> {
            while (getann(0, annot) >= 0) {
                if (annot.chan != 0) { // MIT annotation code present
                    annot.anntyp = annot.chan
                    annot.chan = 0
                }
                annot.time = annot.time + offset
                if (putann(0, annot) < 0) break
            }
        }
        // Times in milliseconds are converted at the sampling frequency of
        // the record (wfdb-x; the C program assumed 4 ms per sample, i.e.,
        // 250 Hz, whatever the record's frequency, as legacy mode does).
        FT_SHORT, FT_LONG -> {
            while (getann(0, annot) >= 0) {
                annot.time = msToSamples(annot.time, legacy) + offset
                putann(0, annot)
            }
        }
        else -> {
            val input = WfdbFile.stdin()
            while (getcann(input, annot) >= 0) {
                annot.time = msToSamples(annot.time, legacy) + offset
                putann(0, annot)
            }
            input.close()
        }
    }

    wfdbquit()
    exit(0)
}
