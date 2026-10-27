// rdedfann: print annotations from an EDF+ file (port of
// convert/rdedfann.c, through rust/src/bin/rdedfann.rs).
//
// This program prints the annotations from an EDF+ file in the same format
// as rdann does for WFDB-compatible annotation files. As in the C program,
// an annotation without a duration repeats the duration of the previous one
// (see docs/KNOWN_C_BEHAVIORS.md). Where the C program would overflow its
// 1024-byte onset, duration, or text buffers, this port discards the excess
// characters.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of convert/rdedfann.c from the WFDB Software
// Package 10.7.0, by George B. Moody. The translation follows the logic and
// behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: convert/rdedfann.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2008-2014 George B. Moody; bug fix and -x option contributed
//   by Luca Citi, 2014.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private const val TAL_BUFLEN = 1024
private const val TAL_DURATION = 0x15 // 025
private const val TAL_SEP = 0x14 // 024

private const val TAL_START = 0
private const val TAL_ONSET = 1
private const val TAL_DURATION_TEXT = 2
private const val TAL_ANNOTATION = 3
private const val TAL_ANNOTATION_END = 4

/** A fixed-size character buffer with a write position (overflowing characters are discarded). */
private class TalBuf {
    val b = ByteArray(TAL_BUFLEN)
    var pos = 0

    fun put(c: Int) {
        if (pos < b.size) b[pos] = c.toByte()
        pos++
    }

    fun str(): ByteArray = cstr(b)
}

private class TalState(val wfdb: Wfdb, val pname: ByteArray, val sfreq: Double, val xflag: Boolean) {
    var state = TAL_START
    val onset = TalBuf()
    val duration = TalBuf()
    val text = TalBuf()

    fun proc(x0: Int) {
        var x = x0 and 0xff
        when (state) {
            TAL_START -> {
                if (x == 0) return
                if (x != '+'.code) {
                    eprintf("%s: unexpected character '%c' in input\n", pname, x)
                } else {
                    state = TAL_ONSET
                    onset.pos = 0
                    duration.pos = 0
                    text.pos = 0
                    text.b[0] = 0
                }
            }
            TAL_ONSET -> {
                if (x == TAL_DURATION) {
                    x = 0
                    state = TAL_DURATION_TEXT
                } else if (x == TAL_SEP) {
                    x = 0
                    state = TAL_ANNOTATION
                }
                onset.put(x)
            }
            TAL_DURATION_TEXT -> {
                if (x == TAL_SEP) {
                    x = 0
                    state = TAL_ANNOTATION
                }
                duration.put(x)
            }
            TAL_ANNOTATION -> {
                if (x == TAL_SEP) {
                    x = 0
                    state = TAL_ANNOTATION_END
                }
                text.put(x)
            }
            TAL_ANNOTATION_END -> {
                if (text.b[0].toInt() != 0) {
                    val os = onset.str()
                    val t = d2l(atof(os) * sfreq + 0.5)
                    val ts = text.str()
                    val ds = duration.str()
                    for (k in ts.indices) {
                        if (ts[k] == ' '.code.toByte() || ts[k] == '\t'.code.toByte()) {
                            ts[k] = '_'.code.toByte()
                            text.b[k] = '_'.code.toByte()
                        }
                    }
                    val tstr = if (t != 0L) wfdb.mstimstr(t) else "    0:00.000".latin1()
                    printf(
                        "%s  %7ld %5s%5d%5d%5d\t%s",
                        tstr, t, if (xflag) "\"".latin1() else ts, 0, 0, 0,
                        if (xflag) ts else ByteArray(0)
                    )
                    if (duration.b[0].toInt() != 0) {
                        printf("%cduration: %s", if (xflag) ' '.code else '\t'.code, ds)
                    }
                    printf("\n")
                }
                if (x != 0) {
                    text.b[0] = x.toByte()
                    text.pos = 1
                    state = TAL_ANNOTATION
                } else {
                    state = TAL_START
                }
            }
            else -> {}
        }
    }
}

private val RDEDFANN_HELP = arrayOf(
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input EDF+ record, and OPTIONS may include:",
    " -F FREQ     set the sampling frequency to FREQ Hz\n",
    " -h          print this usage summary",
    " -v          print column headings",
    " -x          print EDF+ annotation text in aux (default: print in anntyp)",
)

private fun rdedfannHelp(pname: ByteArray) {
    eprintf(RDEDFANN_HELP[0], pname)
    for (k in 1 until RDEDFANN_HELP.size) eprintf("%s\n", RDEDFANN_HELP[k])
}

/** The rdedfann tool. */
fun Wfdb.rdedfannMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val argc = argv.size
    val pname = progName(argv[0])
    var record: ByteArray? = null
    var sfreq = 0.0
    var vflag = false
    var xflag = false

    var i = 1
    while (i < argc) {
        if (argv[i].at(0) == '-'.code) {
            when (argv[i].at(1).toChar()) {
                'F' -> {
                    i++
                    if (i >= argc) {
                        eprintf("%s: sampling frequency must follow -F\n", pname)
                        exit(1)
                    }
                    val d = CDouble(sfreq)
                    sscanf(argv[i], "%lf", d)
                    sfreq = d.v
                    if (sfreq <= 0.0) sfreq = 1.0
                }
                'h' -> {
                    rdedfannHelp(pname)
                    exit(0)
                }
                'r' -> {
                    i++
                    if (i >= argc) {
                        eprintf("%s: record name must follow -r\n", pname)
                        exit(1)
                    }
                    record = cstr(argv[i])
                }
                'v' -> vflag = true
                'x' -> xflag = true
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
    if (record == null) {
        rdedfannHelp(pname)
        exit(1)
    }
    setgvmode(WFDB_HIGHRES)
    var nsig = isigopen(record, null, 0)
    if (nsig <= 0) exit(2)
    val si = Array(nsig) { Siginfo() }
    nsig = isigopen(record, si, nsig)
    if (nsig <= 0) exit(2)
    var aindex = 0
    var alen = 0
    var framelen = 0
    for (k in 0 until minOf(nsig, si.size)) {
        val s = si[k]
        if (beq(s.desc, "EDF Annotations")) {
            aindex = framelen
            alen = s.spf
        }
        framelen += s.spf
    }
    if (alen == 0) {
        eprintf("%s: record %s has no EDF annotations\n", pname, record)
        wfdbquit()
        exit(3)
    }
    val frame = IntArray(framelen)

    if (sfreq > 0.0) {
        setgvmode(WFDB_LOWRES)
        setsampfreq(sfreq)
    } else {
        sfreq = sampfreq(null as ByteArray?)
    }

    if (vflag) printf("      Time   Sample #  Type  Sub Chan  Num\tAux\n")

    val st = TalState(this, pname, sfreq, xflag)
    while (getframe(frame) > 0) {
        st.state = TAL_START
        for (k in aindex until aindex + alen) {
            val p = frame[k]
            if (p != 0 || st.state != TAL_START) {
                st.proc(p)
                st.proc(p shr 8)
            } else {
                break
            }
        }
    }

    wfdbquit()
    exit(0)
}
