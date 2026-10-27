// sortann: rearrange annotations in canonical order (port of app/sortann.c,
// through rust/src/bin/sortann.rs).
//
// This program rewrites annotation files with the annotations in time order.
// Any simultaneous annotations are written in num and chan order. If the
// input contains two or more annotations with the same time, num, and chan
// fields, only the last one is copied (and none, if that one has anntyp =
// NOTQRS) -- but only when the duplicates are found while repairing
// out-of-order input, as in the C version.
//
// The sorted (output) annotation file is always written to the current
// directory. If the input annotations are already in the correct order, no
// output is written unless the -o option is used.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/sortann.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the new option -F
// FREQ gives it when the record has no header or its header gives none, and is
// then required for the -f and -t times (the original assumed 250 Hz); an
// out-of-order annotation at time 0 (num 0, chan 0) is no longer lost, nor are
// those inserted after it; --legacy, as the first argument, restores the
// original behavior. Each change is marked "wfdb-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/sortann.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1997-2010 George B. Moody; revised 2017-2018 by
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

private val SORTANN_HELP = arrayOf(
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -f TIME    start at specified TIME",
    " -F FREQ    sampling frequency, if the record header does not specify one",
    " -h         print this usage summary",
    " -o OUTANN  write output as annotator OUTANN (required with -f or -t)",
    " -t TIME    stop at specified TIME",
    "The sorted output replaces the input if -o is omitted, the input is in",
    "the current directory, and the input is not already sorted.",
)

/** wfdb-x: the help lines added by wfdb-x (left out in legacy mode). */
private val SORTANN_WFDBX_HELP = setOf(
    " -F FREQ    sampling frequency, if the record header does not specify one",
)

private fun Wfdb.sortannHelp(pname: ByteArray) {
    val legacy = wfdbx_get_legacy() != 0
    eprintf(SORTANN_HELP[0], pname)
    for (k in 1 until SORTANN_HELP.size) {
        val s = SORTANN_HELP[k]
        if (!(legacy && s in SORTANN_WFDBX_HELP)) eprintf("%s\n", s)
    }
}

/** The sortann tool. */
fun Wfdb.sortannMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    var ain0: ByteArray? = null
    var ain1: ByteArray? = null
    var record: ByteArray? = null
    var from = 0L
    var to = 0L
    val ffreq = CDouble(0.0) // -F (wfdb-x)
    val annot = Annotation()

    // Interpret command-line options.
    var i = 1
    while (i < argc) {
        val a = argv[i]
        if (a.at(0) == '-'.code) {
            when (a.at(1).toChar()) {
                'a' -> { // (input) annotator follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: annotator must follow -a\n", pname)
                        exit(1)
                    }
                    ain0 = argv[i]
                }
                'f' -> { // starting time follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: starting time must follow -f\n", pname)
                        exit(1)
                    }
                    from = i.toLong() // to be converted to sample intervals below
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
                'h' -> { // print usage summary and quit
                    sortannHelp(pname)
                    exit(0)
                }
                'o' -> { // output annotator follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: annotator must follow -o\n", pname)
                        exit(1)
                    }
                    ain1 = argv[i]
                }
                'r' -> {
                    // input record name follows. If -r is followed by a
                    // non-empty string (with no intervening space), use that
                    // string as the WFDB path. (The WFDB library invokes
                    // sortann with '-r.'.)
                    val p = cstr(a.copyOfRange(minOf(2, a.size), a.size))
                    if (p.isNotEmpty()) setwfdb(p)
                    i++
                    if (i >= argc) {
                        eprintf("%s: input record name must follow -r\n", pname)
                        exit(1)
                    }
                    record = argv[i]
                }
                't' -> { // ending time follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: end time must follow -t\n", pname)
                        exit(1)
                    }
                    to = i.toLong()
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

    if (record == null || ain0 == null) {
        sortannHelp(pname)
        exit(1)
    }
    if ((from != 0L || to != 0L) && ain1 == null) {
        eprintf("%s: -o required when using -f or -t options\n", pname)
        exit(1)
    }
    if (ain1 != null && beq(cstr(ain0), cstr(ain1))) {
        eprintf("%s: must specify different annotator names after -a and -o\n", pname)
        exit(1)
    }

    // By setting WFDBANNSORT, we ensure that wfdbquit won't invoke this
    // program recursively if something goes wrong.
    setenv("WFDBANNSORT", "0", true)

    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    // the record had no header); -F specifies one. It is needed only to
    // convert the -f and -t times.
    var sps = sampfreq(record)
    if (legacy) {
        if (sps < 0.0) {
            sps = WFDB_DEFFREQ
            setsampfreq(sps)
        }
    } else if (sps <= 0.0 && ffreq.v > 0.0) {
        sps = ffreq.v
        setsampfreq(sps)
    }
    fun needsFreq(k: Long) = k != 0L && wfdbx_time_needs_freq(argv[k.toInt()]) != 0
    if (!legacy && sps <= 0.0 && (needsFreq(from) || needsFreq(to))) {
        eprintf("%s: sampling frequency of record %s is not specified (use -F)\n", pname, record)
        exit(1)
    }

    if (annopen(record, arrayOf(Anninfo(ain0, WFDB_READ)), 1) < 0) exit(2) // open input annotation file

    if (from != 0L) {
        from = strtim(argv[from.toInt()])
        if (from < 0) from = -from
    }
    if (to != 0L) {
        to = strtim(argv[to.toInt()])
        if (to < 0) to = -to
    }

    val tps = getiaorigfreq(0)
    if (tps > 0.0) {
        setafreq(tps)
        setiafreq(0, tps)
        if (legacy || sps > 0.0) {
            from = d2l(from.toDouble() * tps / sps + 0.5)
            to = d2l(to.toDouble() * tps / sps + 0.5)
        } else if (from != 0L || to != 0L) {
            // wfdb-x: no default sampling frequency
            eprintf("%s: sampling frequency of record %s is not specified (use -F)\n", pname, record)
            exit(1)
        }
    }

    // Build a linked list of annotations in memory (wfdbx.AnnList; wfdb-x:
    // it no longer loses annotations at time 0, except in legacy mode).
    val list = AnnList(legacy)
    while (getann(0, annot) == 0) {
        if (annot.time < from || (to > 0 && annot.time >= to)) continue
        list.insert(annot)
    }
    iannclose(0)

    if (list.inOrder() && ain1 == null) {
        // If all of the annotations were in order, don't copy them unless
        // another annotator name was specified (using -o).
        eprintf("%s: input is already ordered -- no output written\n", pname)
        exit(0)
    }

    // In this case, we are processing the entire input file, and it's
    // acceptable to overwrite it.
    if (from == 0L && to == 0L && ain1 == null) ain1 = ain0

    if (annopen(record, arrayOf(Anninfo(ain1 ?: ByteArray(0), WFDB_WRITE)), 1) < 0) exit(2) // open output annotation file
    for (a in list.toList()) {
        if (a.anntyp != NOTQRS) putann(0, a)
    }
    wfdbquit()
    exit(0)
}
