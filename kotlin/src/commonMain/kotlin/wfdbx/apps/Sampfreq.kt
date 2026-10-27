// sampfreq: print the sampling frequency of a record (port of
// app/sampfreq.c, through rust/src/bin/sampfreq.rs).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/sampfreq.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior). Through
// the library, a record whose header gives no sampling frequency has the
// frequency 0, which is printed (the original printed 250); see
// docs/DIVERGENCES.md.
//
// Original C program: app/sampfreq.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1998-2012 George B. Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private fun sampfreqHelp(pname: ByteArray) {
    eprintf("usage: %s [OPTION] RECORD\n", pname)
    eprintf(
        "%s",
        " where RECORD is the name of the input record\n" +
            " and OPTION may be either of:\n" +
            "  -a   list all signals and their sampling frequencies\n" +
            "  -h   show this help\n" +
            "  -H   show the maximum sampling frequency of a multifrequency record)\n" +
            " If no OPTION is used, show the base sampling frequency (frame rate).\n",
    )
}

/** The sampfreq tool. */
fun Wfdb.sampfreqMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val pname = argv[0]
    when (argv.size) {
        1 -> {
            sampfreqHelp(pname)
            exit(1)
        }
        2 -> {
            printf("%g\n", sampfreq(argv[1]))
            exit(0)
        }
        3 -> if (beq(argv[1], "-a") || beq(argv[1], "-H")) {
            var si: Array<Siginfo> = emptyArray()
            val nsig = isigopen(argv[2], null, 0)
            if (nsig > 0) {
                si = Array(nsig) { Siginfo() }
                isigopen(argv[2], si, nsig)
            }
            if (argv[1].at(1) == 'H'.code) {
                setgvmode(WFDB_HIGHRES)
                printf("%g\n", sampfreq(null))
                exit(0)
            } else {
                setgvmode(WFDB_LOWRES)
                val freq = sampfreq(null)
                for (k in 0 until maxOf(nsig, 0)) {
                    if (k >= si.size) break
                    printf("%s\t%g\n", si[k].desc, si[k].spf.toDouble() * freq)
                }
            }
        }
    }
    // (The C program falls off the end of main; its exit status is 0.)
    exit(0)
}
