// time2sec: convert a time interval to seconds (port of app/time2sec.c,
// through rust/src/bin/time2sec.rs).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/time2sec.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: app/time2sec.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2003-2009 George B. Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

/** The time2sec tool. */
fun Wfdb.time2secMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val argc = argv.size

    if (argc == 4 && beq(argv[1], "-r")) {
        isigopen(argv[2], null, 0)
        var t = strtim(argv[3]).toDouble()
        if (t < 0.0) t = -t
        var seconds = d2l(t / sampfreq(null))
        t -= seconds.toDouble() * sampfreq(null)
        var milliseconds = d2l((t * 1000.0) / sampfreq(null) + 0.5).toInt()
        if (milliseconds >= 1000) {
            seconds++
            milliseconds -= 1000
        }
        printf("%ld", seconds)
        if (milliseconds != 0) printf(".%03d", milliseconds)
        printf("\n")
        exit(0)
    } else if (argc == 2 && argv[1].at(0) != '-'.code) {
        setsampfreq(1000.0)
        printf("%.12g\n", strtim(argv[1]).toDouble() / 1000.0)
        exit(0)
    }

    eprintf("usage: %s [-r RECORD] TIME\n", argv[0])
    eprintf(" where TIME (in hh:mm:ss format) is a time interval\n")
    eprintf(" to be converted into seconds.  Enclose TIME in\n")
    eprintf(" square brackets (e.g., [9:0:0]) to convert a time\n")
    eprintf(" of day to the elapsed time in seconds from the\n")
    eprintf(" beginning of the (optionally) specified RECORD.\n")
    exit(1)
}
