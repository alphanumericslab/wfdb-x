// wfdbwhich: find a WFDB file and print its pathname (port of
// app/wfdbwhich.c, through rust/src/bin/wfdbwhich.rs).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/wfdbwhich.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior). Through
// the library, the file is looked for only where it is named (the input
// directory, a full path or a URL), not by a search of the WFDB path; see
// docs/DIVERGENCES.md.
//
// Original C program: app/wfdbwhich.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1999 George B. Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

/** The wfdbwhich tool. */
fun Wfdb.wfdbwhichMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    var argc = argv.size
    val pname = progName(argv[0])
    var status = 0

    if (argc == 2 && beq(argv[1], "-h")) argc = 0 // give usage instructions and quit
    when (argc) {
        2 -> {
            val filename = wfdbfile(argv[1], null as ByteArray?)
            if (filename != null) {
                printf("%s\n", filename)
            } else {
                eprintf("`%s' not found\n", argv[1])
                eprintf("(WFDB path = %s)\n", getwfdb())
                status = 2
            }
        }
        3 -> {
            wfdbquiet()
            isigopen(argv[2], null, 0)
            val filename = wfdbfile(argv[1], argv[2])
            if (filename != null) {
                printf("%s\n", filename)
            } else {
                eprintf("No file of type `%s' found for record `%s'\n", argv[1], argv[2])
                eprintf("(WFDB path = %s)\n", getwfdb())
                status = 2
            }
        }
        else -> {
            if (argc != 4 || !beq(argv[1], "-r")) {
                eprintf("usage: %s [-r RECORD ] FILENAME\n", pname)
                eprintf(" -or-  %s FILE-TYPE RECORD\n", pname)
                status = 1
            } else {
                isigopen(argv[2], null, 0)
                val filename = wfdbfile(argv[3], null as ByteArray?)
                if (filename != null) {
                    printf("%s\n", filename)
                } else {
                    eprintf("`%s' not found\n", argv[3])
                    eprintf("(WFDB path = %s)\n", getwfdb())
                    status = 2
                }
            }
        }
    }
    exit(status)
}
