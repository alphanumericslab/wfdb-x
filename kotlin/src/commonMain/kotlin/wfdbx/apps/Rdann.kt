// rdann: print an annotation file in ASCII form (port of app/rdann.c,
// through rust/src/bin/rdann.rs).
//
// Caution: if the output format of rdann is modified, wrann will require
// modification as well!
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/rdann.c from the WFDB Software Package
// 10.7.0, by T. Baker and George B. Moody. The translation follows the logic
// and behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: no built-in sampling frequency: the new option -F
// FREQ gives it when the record has no header or its header gives none, and is
// then required (the original assumed 250 Hz); --legacy, as the first
// argument, restores the original behavior. Each change is marked "wfdb-x:" in
// the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/rdann.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1981-2010 George B. Moody; revised 2017-2018 by
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

private val RDANN_HELP = arrayOf(
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -c CHAN             print annotations with specified CHAN only",
    " -e                  * show annotation times as elapsed times",
    " -f TIME             start at specified TIME",
    " -F FREQ             sampling frequency, if the record header does not",
    "                      specify one",
    " -h                  print this usage summary",
    " -n NUM              print annotations with specified NUM only",
    " -p TYPE [TYPE ...]  print annotations of specified TYPEs only",
    " -s SUBTYPE          print annotations with specified SUBTYPE only",
    " -t TIME             stop at specified TIME",
    " -v                  print column headings",
    " -x                  * use alternate time format (seconds, minutes, hours)",
    "* Only one of -e and -x can be used.",
)

/** wfdb-x: the help lines added by WFDB-x (left out in legacy mode). */
private val RDANN_WFDBX_HELP = setOf(
    " -F FREQ             sampling frequency, if the record header does not",
    "                      specify one",
)

private fun Wfdb.rdannHelp(pname: ByteArray) {
    val legacy = wfdbx_get_legacy() != 0
    eprintf(RDANN_HELP[0], pname)
    for (k in 1 until RDANN_HELP.size) {
        val s = RDANN_HELP[k]
        if (!(legacy && s in RDANN_WFDBX_HELP)) eprintf("%s\n", s)
    }
}

/** The rdann tool. */
fun Wfdb.rdannMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    fun c0(k: Int) = argv[k].at(0)
    fun c1(k: Int) = argv[k].at(1)

    val ffreq = CDouble(0.0) // -F (WFDB-x)
    var record: ByteArray? = null
    var ainame: ByteArray? = null
    var cflag = false
    var chanmatch = 0
    var nflag = false
    var nummatch = 0
    var sflag = false
    var submatch = 0
    var eflag = false
    var vflag = false
    var xflag = false
    var anum = 0L
    var ato = 0L
    var bnum = 0L
    var bto = 0L
    var from = 0L
    var to = 0L
    val flag = BooleanArray(ACMAX + 1)
    val annot = Annotation()
    var i: Int

    // Accept old syntax.
    if (argc >= 3 && c0(1) != '-'.code) {
        ainame = argv[1]
        record = argv[2]
        i = 3
        if (argc > 3) {
            from = 3
            i = 4
        }
        if (argc > 4) {
            to = 4
            i = 5
        }
        if (argc <= 5) {
            flag[0] = true
        } else {
            while (i < argc && c0(i) != '-'.code) {
                val j = strann(argv[i])
                if (wfdb_isann(j) != 0) flag[j] = true
                i++
            }
        }
    } else {
        i = 1
        flag[0] = true
    }

    // Interpret command-line options.
    while (i < argc) {
        if (c0(i) == '-'.code) {
            when (c1(i).toChar()) {
                'a' -> { // annotator follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: annotator must follow -a\n", pname)
                        exit(1)
                    }
                    ainame = argv[i]
                }
                'c' -> { // chan value follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: chan value (between -128 and 127) must follow -c\n", pname)
                        exit(1)
                    }
                    chanmatch = atoi(argv[i]).toByte().toInt()
                    cflag = true
                }
                'e' -> { // show elapsed time
                    eflag = true
                    xflag = false
                }
                'f' -> { // starting time follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: starting time must follow -f\n", pname)
                        exit(1)
                    }
                    from = i.toLong()
                }
                'F' -> {
                    if (legacy) {
                        eprintf("%s: unrecognized option %s\n", pname, argv[i])
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
                    rdannHelp(pname)
                    exit(0)
                }
                'n' -> { // num value follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: num value (between -128 and 127) must follow -n\n", pname)
                        exit(1)
                    }
                    nummatch = atoi(argv[i]).toByte().toInt()
                    nflag = true
                }
                'p' -> { // annotation mnemonic(s) follow
                    i++
                    val j = if (i < argc) strann(argv[i]) else 0
                    if (i >= argc || wfdb_isann(j) == 0) {
                        eprintf("%s: annotation mnemonic(s) must follow -p\n", pname)
                        exit(1)
                    }
                    flag[j] = true
                    // Pick up any other mnemonics (arguments beginning with
                    // `-' are assumed to be options, not mnemonics).
                    i++
                    while (i < argc && c0(i) != '-'.code) {
                        val k = strann(argv[i])
                        if (wfdb_isann(k) != 0) flag[k] = true
                        i++
                    }
                    if (i == argc || c0(i) == '-'.code) i--
                    flag[0] = false
                }
                'r' -> { // input record name follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: input record name must follow -r\n", pname)
                        exit(1)
                    }
                    record = argv[i]
                }
                's' -> { // subtyp value follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: subtyp value (between -128 and 127) must follow -s\n", pname)
                        exit(1)
                    }
                    submatch = atoi(argv[i]).toByte().toInt()
                    sflag = true
                }
                't' -> { // ending time follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: end time must follow -t\n", pname)
                        exit(1)
                    }
                    to = i.toLong()
                }
                'v' -> vflag = true // show column headings
                'x' -> { // use alternate time format
                    xflag = true
                    eflag = false
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
    if (record == null || ainame == null) {
        rdannHelp(pname)
        exit(1)
    }

    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    // the record had no header); -F specifies one.
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
    if (!legacy && sps <= 0.0) {
        eprintf("%s: sampling frequency of record %s is not specified (use -F)\n", pname, record)
        exit(1)
    }

    val ai = arrayOf(Anninfo(ainame, WFDB_READ))
    if (annopen(record, ai, 1) < 0) exit(2) // open annotation file

    var tps = getiaorigfreq(0)
    if (tps < sps) tps = sps

    // Decimal places of the times in seconds, minutes and hours printed by
    // -x: enough to resolve a tick, and at least those of a millisecond.
    var sprec = 3
    var n = 1000.0
    while (n < tps) {
        sprec++
        n *= 10.0
    }
    val tpm = 60.0 * tps
    var mprec = 5
    n = 100000.0
    while (n < tpm) {
        mprec++
        n *= 10.0
    }
    val tph = 60.0 * tpm
    var hprec = 7
    n = 10000000.0
    while (n < tph) {
        hprec++
        n *= 10.0
    }

    if (from != 0L) {
        val fs = argv[from.toInt()]
        val rest = if (fs.isEmpty()) fs else fs.copyOfRange(1, fs.size)
        when (fs.at(0).toChar()) {
            'a' -> {
                var afrom = atol(rest)
                if (afrom < 0) afrom = 0
                while (anum < afrom && getann(0, annot) == 0) {
                    anum++
                    if (wfdb_isqrs(annot.anntyp) != 0) bnum++
                }
                if (anum < afrom) exit(2)
            }
            'b', '#' -> {
                var bfrom = atol(rest)
                if (bfrom < 0) bfrom = 0
                while (bnum < bfrom && getann(0, annot) == 0) {
                    anum++
                    if (wfdb_isqrs(annot.anntyp) != 0) bnum++
                }
                if (bnum < bfrom) exit(2)
            }
            else -> if (iannsettime(strtim(fs)) < 0) exit(2)
        }
    }
    if (to != 0L) {
        val ts = argv[to.toInt()]
        val rest = if (ts.isEmpty()) ts else ts.copyOfRange(1, ts.size)
        when (ts.at(0).toChar()) {
            'a' -> {
                ato = atol(rest)
                if (ato < 0) ato = 0
                bto = 0
                to = 0
            }
            'b' -> {
                bto = atol(rest)
                if (bto < 0) bto = 0
                ato = 0
                to = 0
            }
            '#' -> {
                bto = atol(rest)
                if (bto < 1) bto = 1
                bto += bnum
                ato = 0
                to = 0
            }
            else -> {
                ato = 0
                bto = 0
                to = strtim(ts)
                if (to < 0) to = -to
            }
        }
    }

    if (vflag) { // print column headings
        if (eflag) {
            printf("Elapsed time  Sample #  ")
        } else if (xflag) {
            printf("  Seconds   Minutes     Hours  ")
        } else {
            val m = mstimstr(-1)
            if (m.contains('/'.code.toByte())) {
                printf("      Time       Date     Sample #  ")
            } else if (m.at(0) == '['.code) {
                printf("      Time     Sample #  ")
            } else {
                printf("      Time   Sample #  ")
            }
        }
        printf("Type  Sub Chan  Num\tAux\n")
    }

    setifreq(tps)
    setiafreq(0, tps)
    while (getann(0, annot) == 0) {
        val sampleNum = if (tps == sps) {
            annot.time
        } else {
            val x = annot.time.toDouble() * sps / tps + 0.5
            var s = d2l(x)
            if (s.toDouble() > x) s--
            s
        }
        if (to != 0L && sampleNum > to) break
        val a = annot.anntyp
        if ((flag[0] || (wfdb_isann(a) != 0 && flag[a])) &&
            (!cflag || annot.chan == chanmatch) &&
            (!nflag || annot.num == nummatch) &&
            (!sflag || annot.subtyp == submatch)
        ) {
            if (eflag) {
                printf("%s  %7lld", mstimstr(annot.time), sampleNum)
            } else if (xflag) {
                printf(
                    "%*.*f %*.*f %*.*f",
                    sprec + 6, sprec, annot.time.toDouble() / tps,
                    mprec + 4, mprec, annot.time.toDouble() / tpm,
                    hprec + 2, hprec, annot.time.toDouble() / tph,
                )
            } else {
                printf("%s  %7lld", mstimstr(-annot.time), sampleNum)
            }
            printf("%6s%5d%5d%5d", annstr(a), annot.subtyp, annot.chan, annot.num)
            val aux = annot.aux
            if (aux != null) {
                val s = if (aux.isEmpty()) aux else aux.copyOfRange(1, aux.size)
                printf("\t%s", cstr(s))
            }
            printf("\n")
        }
        if (ato != 0L) {
            anum++
            if (anum >= ato) break
        }
        if (bto != 0L && wfdb_isqrs(a) != 0) {
            bnum++
            if (bnum >= bto) break
        }
    }
    exit(0)
}
