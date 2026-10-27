// wfdbtime: convert between times and sample numbers (port of
// app/wfdbtime.c, through rust/src/bin/wfdbtime.rs).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/wfdbtime.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency: the record must
// give it (the original assumed 250 Hz); --legacy, as the first argument,
// restores the original behavior. Each change is marked "wfdb-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/wfdbtime.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2001 George B. Moody; revised 2017-2018 by Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

/** The wfdbtime tool. */
fun Wfdb.wfdbtimeMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    var record: ByteArray? = null

    var i = 1
    while (i < argc) {
        if (beq(argv[i], "-r")) {
            if (record != null) wfdbquit()
            i++
            if (i == argc) break
            record = argv[i]
            if (isigopen(argv[i], null, 0) < 0) exit(2)
            if (!legacy && sampfreq(null) <= 0.0) {
                // wfdb-x: no default sampling frequency (except in legacy mode)
                eprintf("%s: sampling frequency of record %s is not specified\n", argv[0], argv[i])
                exit(2)
            }
        } else if (record != null) {
            var t = strtim(argv[i])
            if (t < 0) t = -t
            var sbuf = cformat("s%lld", t)
            // (C: snprintf into a 32-byte buffer; at most 31 bytes are kept.)
            if (sbuf.size > 31) sbuf = sbuf.copyOf(31)
            val ts = if (t == 0L) "0:00.000".latin1() else mstimstr(t)
            printf("%15s\t%15s", sbuf, ts)
            printf("\t%15s\n", mstimstr(-t))
        }
        i++
    }
    if (record == null) {
        eprintf("usage: %s [ -r RECORD [ TIME ] ]\n", argv[0])
        eprintf(" where RECORD is the name of the input record\n")
        eprintf(" Each TIME is a time to be converted\n")
        exit(1)
    }
    wfdbquit()
    exit(0)
}
