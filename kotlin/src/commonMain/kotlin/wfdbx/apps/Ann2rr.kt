// ann2rr: extract a list of intervals from an annotation file (port of
// app/ann2rr.c, through rust/src/bin/ann2rr.rs).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/ann2rr.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the new option -F
// FREQ gives it when the record has no header or its header gives none, and is
// then required for time arguments and for intervals and times in units of
// time (the original assumed 250 Hz); --legacy, as the first argument,
// restores the original behavior. Each change is marked "wfdb-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/ann2rr.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1995-2009 George B. Moody; revised 2018-2020 by
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

private val ANN2RR_HELP = arrayOf(
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -A      print all intervals between annotations (default: print only RR",
    "          intervals; overrides -c, -p)",
    " -c      print intervals between consecutive valid annotations only",
    " -f TIME start at specified TIME",
    " -F FREQ sampling frequency, if the record header does not specify one",
    " -h      print this usage summary",
    " -i FMT  print intervals using format FMT (see below for values of FMT)",
    " -p TYPE [TYPE ...]  print intervals ending with annotations of specified",
    "                      TYPEs only (use mnemonics such as N or V for TYPE)",
    " -P TYPE [TYPE ...]  print intervals beginning with specified types only",
    " -t TIME stop at specified TIME",
    " -v FMT  print times of ends of intervals using format FMT (see below)",
    " -V FMT  print times of beginnings of intervals using format FMT (see below)",
    " -w      print annotations that end intervals",
    " -W      print annotations that begin intervals",
    "By default, the output contains the RR intervals only, unless one or more",
    "of -v, -V, -w, or -W are used.  Intervals and times are printed in units of",
    "sample intervals, unless a format is specified using -i, -v, or -V.",
    "Formats can be 'h' (hours), 'm' (minutes), 's' (seconds), 't' (hh:mm:ss);",
    "when used with -v or -V, format 'T' yields dates and times if available,",
    "or the format can be omitted to obtain times in sample intervals.  Formats",
    "'h', 'm', and 's' may be followed by a number between 0 and 15, specifying",
    "the number of decimal places (default: 3).  For example, to obtain intervals",
    "in seconds with 8 decimal places, use '-i s8'.",
)

// Decimal places of times and intervals printed in hours, minutes or
// seconds: the default and the largest accepted.
private const val ANN2RR_DEFDIGITS = 3
private const val ANN2RR_MAXDIGITS = 15

// Lines of the usage summary shown before each "--More--" prompt.
private const val ANN2RR_PAGELINES = 23

/** wfdb-x: the help lines added by WFDB-x (left out in legacy mode). */
private val ANN2RR_WFDBX_HELP = setOf(
    " -F FREQ sampling frequency, if the record header does not specify one",
)

private fun Wfdb.ann2rrHelp(pname: ByteArray) {
    val legacy = wfdbx_get_legacy() != 0
    eprintf(ANN2RR_HELP[0], pname)
    var i = 0
    for (k in 1 until ANN2RR_HELP.size) {
        val s = ANN2RR_HELP[k]
        if (legacy && s in ANN2RR_WFDBX_HELP) continue
        i++
        eprintf("%s\n", s)
        if (i % ANN2RR_PAGELINES == 0) {
            eprintf("--More--")
            val b = ByteVec(8)
            val input = WfdbFile.stdin()
            input.fgets(b, 5) // (C: a 5-byte buffer)
            input.close()
            eprintf("\u001b[A\u001b[2K") // erase "--More--"; assumes ANSI terminal
        }
    }
}

/** wfdb-x: whether output format [c] (of -i, -v or -V) is a unit of time, which needs the sampling frequency. */
private fun ann2rrTimeFormatNeedsFreq(c: Int): Boolean =
    c == 'h'.code || c == 'm'.code || c == 's'.code || c == 't'.code || c == 'T'.code

/** The ann2rr tool. */
fun Wfdb.ann2rrMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    fun c0(k: Int) = argv[k].at(0)
    fun tail(k: Int) = if (argv[k].isEmpty()) argv[k] else argv[k].copyOfRange(1, argv[k].size)
    var record: ByteArray? = null
    var ainame: ByteArray? = null
    var aflagAll = false
    var a0flag = false
    var a1flag = false
    var cflag = false
    var previousAnnotValid = false
    val rrdigits = CInt(ANN2RR_DEFDIGITS)
    var rrformat = 0
    val t0digits = CInt(ANN2RR_DEFDIGITS)
    var t0flag = false
    var t0format = 0
    val t1digits = CInt(ANN2RR_DEFDIGITS)
    var t1flag = false
    var t1format = 0
    val a0f = BooleanArray(ACMAX + 1)
    val a1f = BooleanArray(ACMAX + 1)
    val annot = Annotation()
    var from = 0L
    var to = 0L
    val ffreq = CDouble(0.0) // -F (WFDB-x)

    // Interpret command-line options.
    a0f[0] = true
    a1f[0] = true
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
                'A' -> aflagAll = true // print intervals between annotations of all types
                'c' -> cflag = true // intervals between consecutive valid annotations only
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
                    // sampling frequency follows (WFDB-x)
                    i++
                    if (i >= argc || sscanf(argv[i], "%lf", ffreq) != 1 || ffreq.v <= 0.0) {
                        eprintf("%s: sampling frequency (> 0) must follow -F\n", pname)
                        exit(1)
                    }
                }
                'h' -> { // print usage summary and quit
                    ann2rrHelp(pname)
                    exit(0)
                }
                'i' -> { // specify interval output format
                    i++
                    if (i >= argc || c0(i) == '-'.code) {
                        eprintf("%s: interval output format must follow -i\n", pname)
                        exit(1)
                    }
                    rrformat = c0(i)
                    sscanf(tail(i), "%d", rrdigits)
                }
                'p', 'P' -> { // annotation mnemonic(s) follow
                    val tbl: BooleanArray
                    val other: Char
                    if (a.at(1) == 'p'.code) {
                        tbl = a1f
                        other = 'P'
                    } else {
                        tbl = a0f
                        other = 'p'
                    }
                    i++
                    val j = if (i < argc) strann(argv[i]) else 0
                    if (i >= argc || wfdb_isann(j) == 0) {
                        eprintf("%s: annotation mnemonic(s) must follow -%c\n", pname, other)
                        exit(1)
                    }
                    tbl[j] = true
                    // Pick up any other mnemonics (arguments beginning with
                    // `-' are assumed to be options, not mnemonics).
                    i++
                    while (i < argc && c0(i) != '-'.code) {
                        val k = strann(argv[i])
                        if (wfdb_isann(k) != 0) tbl[k] = true
                        i++
                    }
                    if (i == argc || c0(i) == '-'.code) i--
                    tbl[0] = false
                }
                'r' -> { // input record name follows
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
                'v' -> { // output times of ends of intervals
                    t1flag = true
                    i++
                    if (i >= argc || c0(i) == '-'.code) {
                        i--
                    } else {
                        t1format = c0(i)
                        sscanf(tail(i), "%d", t1digits)
                    }
                }
                'V' -> { // output times of beginnings of intervals
                    t0flag = true
                    i++
                    if (i >= argc || c0(i) == '-'.code) {
                        i--
                    } else {
                        t0format = c0(i)
                        sscanf(tail(i), "%d", t0digits)
                    }
                }
                'w' -> a1flag = true // output annotation types following intervals
                'W' -> a0flag = true // output annotation types preceding intervals
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
        ann2rrHelp(pname)
        exit(1)
    }

    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    // the record had no header); -F specifies one. It is needed for times
    // and intervals in units of time.
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
    if (!legacy && sps <= 0.0 &&
        (needsFreq(from) || needsFreq(to) || ann2rrTimeFormatNeedsFreq(rrformat) ||
            (t0flag && ann2rrTimeFormatNeedsFreq(t0format)) ||
            (t1flag && ann2rrTimeFormatNeedsFreq(t1format)))
    ) {
        eprintf("%s: sampling frequency of record %s is not specified (use -F)\n", pname, record)
        exit(1)
    }
    val spm = 60.0 * sps
    val sph = 60.0 * spm

    if (annopen(record, arrayOf(Anninfo(ainame, WFDB_READ)), 1) < 0) exit(2) // open annotation file

    if (rrdigits.v !in 0..ANN2RR_MAXDIGITS) rrdigits.v = ANN2RR_DEFDIGITS
    val rrfstr = cformat("%%.%dlf", rrdigits.v)
    if (t0digits.v !in 0..ANN2RR_MAXDIGITS) t0digits.v = ANN2RR_DEFDIGITS
    val t0fstr = cformat("%%.%dlf", t0digits.v)
    if (t1digits.v !in 0..ANN2RR_MAXDIGITS) t1digits.v = ANN2RR_DEFDIGITS
    val t1fstr = cformat("%%.%dlf", t1digits.v)

    if (from != 0L) {
        from = strtim(argv[from.toInt()])
        if (from < 0) from = -from
    }
    if (to != 0L) {
        to = strtim(argv[to.toInt()])
        if (to < 0) to = -to
    }
    if (to > 0 && to < from) {
        val x = from
        from = to
        to = x
    }
    if (from > 0 && iannsettime(from) < 0) exit(2)

    var a0 = NOTQRS
    var t0 = from

    fun flagged(table: BooleanArray, a: Int) = a in 0..ACMAX && table[a]

    while (getann(0, annot) == 0 && (to == 0L || annot.time <= to)) {
        val a1 = annot.anntyp
        var t1 = annot.time

        // Does t1 mark a valid interval end point?
        if (aflagAll || (a1f[0] && wfdb_isqrs(a1) != 0) || flagged(a1f, a1)) {
            // Does t0 mark a valid interval starting point?
            if (!cflag || previousAnnotValid) {
                // If requested, print time at beginning of interval.
                if (t0flag) {
                    when (t0format.toChar()) {
                        'h' -> printf(t0fstr, t0.toDouble() / sph)
                        'm' -> printf(t0fstr, t0.toDouble() / spm)
                        's' -> printf(t0fstr, t0.toDouble() / sps)
                        't' -> if (t0 == 0L) printf("    0:00.000") else printf("%s", mstimstr(t0))
                        'T' -> printf("%s", mstimstr(-t0))
                        else -> printf("%lld", t0)
                    }
                    printf("\t")
                }

                // If requested, print annotation at beginning of interval.
                if (a0flag) {
                    if (a0 == NOTQRS) printf("[0]\t") else printf("%s\t", annstr(a0))
                }

                // Print the interval, and update t0 and a0.
                val rr = t1 - t0
                fun rrout(div: Double): Double {
                    // snprintf into a 20-byte buffer, then read it back
                    var s = cformat(rrfstr, rr.toDouble() / div)
                    if (s.size > 19) s = s.copyOf(19)
                    printf("%s", s)
                    val frr = CDouble(0.0)
                    sscanf(s, "%lf", frr)
                    return frr.v
                }
                when (rrformat.toChar()) {
                    'h' -> {
                        val frr = rrout(sph)
                        t1 = d2l(t0.toDouble() + frr * sph + 0.5)
                    }
                    'm' -> {
                        val frr = rrout(spm)
                        t1 = d2l(t0.toDouble() + frr * spm + 0.5)
                    }
                    's' -> {
                        val frr = rrout(sps)
                        t1 = d2l(t0.toDouble() + frr * sps + 0.5)
                    }
                    't' -> printf("%s", mstimstr(t1))
                    else -> printf("%lld", rr)
                }

                // If requested, print annotation at end of interval.
                if (a1flag) printf("\t%s", annstr(a1))

                // If requested, print time at end of interval.
                if (t1flag) {
                    printf("\t")
                    when (t1format.toChar()) {
                        'h' -> printf(t1fstr, t1.toDouble() / sph)
                        'm' -> printf(t1fstr, t1.toDouble() / spm)
                        's' -> printf(t1fstr, t1.toDouble() / sps)
                        't' -> printf("%s", mstimstr(t1))
                        'T' -> printf("%s", mstimstr(-t1))
                        else -> printf("%lld", t1)
                    }
                }
                printf("\n")
            }
        }
        // Does t1 mark a valid interval starting point?
        if (aflagAll || (a0f[0] && wfdb_isqrs(a1) != 0) || flagged(a0f, a1)) {
            a0 = a1
            t0 = t1
            previousAnnotValid = true
        } else if (cflag) {
            previousAnnotValid = false
        }
    }
    exit(0)
}
