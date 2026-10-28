// rr2ann: create an annotation file from an RR interval list (port of
// app/rr2ann.c, through rust/src/bin/rr2ann.rs).
//
// The input contains RR intervals (or times of occurrence, with -T) in text
// format, one per line. The first token on each line is taken to be an RR
// interval; any additional tokens on the same line are ignored. The output
// is an annotation file in which all beats are marked NORMAL (or have the
// types given in the second column of the input, with -w).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/rr2ann.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: -F FREQ is
// required when the record has no header or its header gives none (the
// original assumed 250 Hz); --legacy, as the first argument, restores the
// original behavior. Each change is marked "WFDB-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/rr2ann.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2000 George B. Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private const val RR2ANN_MAXLINELEN = 1024 // longer input lines will be silently split

private val RR2ANN_HELP = arrayOf(
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...] <TEXT-FILE\n",
    "where RECORD and ANNOTATOR specify the output, and OPTIONS may include:",
    " -F FREQ     use FREQ as the sampling frequency (effective only if the               header file does not exist or does not specify it)",
    " -h          print this usage summary",
    " -T          TEXT-FILE contains times of occurrence, not RR intervals",
    " -x N        multiply input by N to obtain RR in sample intervals",
    "               (default: N = 1)",
    " -w          copy annotation types from second column of input",
    "TEXT-FILE should contain a column of RR intervals (or times of occurrence,",
    "if the -T option is specified), in units of sample intervals (unless the",
    "-x option is used to specify a conversion factor).   The first token on",
    "each line is taken as an RR interval, and (if the -w option is specified)",
    "the second token is taken as an annotation mnemonic (N, V, etc.);  anything",
    "else on the same line is ignored, as are empty lines, spaces and tabs at",
    "the beginning of a line non-numeric tokens and anything following them on",
    "the same line, negative intervals, and zero intervals.  The output consists",
    "of a binary annotation file (RECORD.ANNOTATOR), and (if it does not exist",
    "already) a text header file (RECORD.hea).",
)

/** WFDB-x: the -F line of the original help text (printed in legacy mode in place of RR2ANN_HELP[2]). */
private const val RR2ANN_LEGACY_HELP_F =
    " -F FREQ     use FREQ as the sampling frequency (effective only if no               header file exists;  default: 250)"

private fun Wfdb.rr2annHelp(pname: ByteArray) {
    val legacy = wfdbx_get_legacy() != 0
    eprintf(RR2ANN_HELP[0], pname)
    for (k in 1 until RR2ANN_HELP.size) {
        eprintf("%s\n", if (legacy && k == 2) RR2ANN_LEGACY_HELP_F else RR2ANN_HELP[k])
    }
}

/** The rr2ann tool. */
fun Wfdb.rr2annMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    val annot = Annotation()
    var sps = 0.0
    val rr = CDouble(0.0)
    var t = 0.0
    var xfactor = 1.0
    var record: ByteArray? = null
    var ainame: ByteArray? = null
    var tflag = false
    var wflag = false

    // Interpret command-line options.
    var i = 1
    while (i < argc) {
        val a = argv[i]
        if (a.at(0) == '-'.code) {
            when (a.at(1).toChar()) {
                'a' -> { // annotator follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: annotator must follow -a\n", pname)
                        exit(1)
                    }
                    ainame = argv[i]
                }
                'F' -> { // sampling frequency in Hz
                    i++
                    if (i < argc) sps = atof(argv[i])
                    if (i >= argc || sps <= 0.0) {
                        eprintf("%s: sampling frequency (> 0) must follow -F\n", pname)
                        exit(1)
                    }
                }
                'h' -> { // print usage summary and quit
                    rr2annHelp(pname)
                    exit(0)
                }
                'r' -> { // record name follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: record name must follow -r\n", pname)
                        exit(1)
                    }
                    record = argv[i]
                }
                'T' -> tflag = true // data are times of occurrence, not RR intervals
                'x' -> { // multiplier to convert input to sample intervals
                    i++
                    if (i < argc) xfactor = atof(argv[i])
                    if (i >= argc || xfactor <= 0.0) {
                        eprintf("%s: an input multiplier (> 0) must follow -x\n", pname)
                        exit(1)
                    }
                }
                'w' -> wflag = true // copy annotation types from second column of input
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
    if (record == null || ainame == null) {
        rr2annHelp(pname)
        exit(1)
    }

    // sampfreq is likely to fail, since the header probably doesn't exist.
    // Suppress its error message.
    wfdbquiet()
    // WFDB-x: no default sampling frequency (the C program assumed 250 Hz);
    // -F specifies one if the record header does not.
    val f = sampfreq(record)
    if (f <= 0.0) {
        wfdbverbose() // re-enable error reporting
        if (sps == 0.0 && legacy) {
            sps = WFDB_DEFFREQ // WFDB-x: legacy mode (original behavior)
        } else if (sps == 0.0) {
            eprintf("%s: sampling frequency of record %s is not specified (use -F)\n", pname, record)
            exit(1)
        }
        setsampfreq(sps)
        // no header: create one (the C program: in any case)
        if ((f < 0.0 || legacy) && newheader(record) < 0) exit(2)
    } else {
        wfdbverbose() // re-enable error reporting
        if (sps != 0.0) {
            eprintf(
                "%s (warning): -F option ignored (using %g for sampling frequency)\n",
                pname, sampfreq(null as ByteArray?),
            )
        }
    }

    if (annopen(record, arrayOf(Anninfo(ainame, WFDB_WRITE)), 1) < 0) exit(3) // open annotation file
    annot.anntyp = NORMAL

    // Read input, write an annotation for each line beginning with a
    // positive number.
    val input = WfdbFile.stdin()
    val line = ByteVec(RR2ANN_MAXLINELEN)
    val astring = CBytes(ByteArray(0))
    while (input.fgets(line, RR2ANN_MAXLINELEN)) {
        val l = cstr(line.toByteArray())
        if (!wflag) { // write all annotations as NORMAL
            if (sscanf(l, "%lf", rr) == 0) continue
        } else { // copy annotation type from input
            if (sscanf(l, "%lf%s", rr, astring) < 2) continue
            annot.anntyp = strann(astring.v)
            if (annot.anntyp == NOTQRS) continue
        }
        if (rr.v <= 0.0) {
            continue
        } else if (tflag) {
            t = rr.v * xfactor
        } else {
            t += rr.v * xfactor
        }
        annot.time = d2l(t + 0.5)
        putann(0, annot)
    }

    // Flush buffered output.
    wfdbquit()
    exit(0)
}
