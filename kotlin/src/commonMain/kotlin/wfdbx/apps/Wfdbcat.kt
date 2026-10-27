// wfdbcat: copy WFDB files to the standard output (port of app/wfdbcat.c,
// through rust/src/bin/wfdbcat.rs).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/wfdbcat.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior). Through
// the library, each file is read from where it is named (the input directory,
// a full path or a URL), not found by a search of the WFDB path; see
// docs/DIVERGENCES.md.
//
// Original C program: app/wfdbcat.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2000 George B. Moody; revised 2018 by Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

/** The wfdbcat tool. */
fun Wfdb.wfdbcatMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val argc = argv.size
    val pname = progName(argv[0])
    val buf = ByteArray(1024) // bytes read at a time

    if (argc < 2 || (argc == 2 && beq(argv[1], "-h"))) {
        eprintf("usage: %s FILE [FILE ...]\n", pname)
        exit(1)
    }

    for (k in 1 until argc) {
        val arg = argv[k]
        val ifile = wfdb_open(arg, null, WFDB_READ)
        if (ifile == null) {
            flushStdout()
            eprintf("%s: `%s' not found\n", pname, arg)
        } else {
            while (true) {
                val n = ifile.read(buf, 0, buf.size)
                if (n <= 0) break
                Stdout.write(buf, 0, n)
                if (Stdout.error()) break
            }
            ifile.close()
        }
    }
    exit(0)
}
