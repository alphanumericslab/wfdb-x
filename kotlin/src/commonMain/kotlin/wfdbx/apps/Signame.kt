// signame: print signal names for signal numbers given as arguments (port
// of app/signame.c, through rust/src/bin/signame.rs).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/signame.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: app/signame.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2008 George B. Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private val SIGNAME_HELP = arrayOf(
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -h          print this usage summary",
    " -s SIGNAL [SIGNAL ...]  print signal name(s) for the specified signal(s)",
    "If no -s option is given, the names of all signals in the record are output.",
)

private fun signameHelp(pname: ByteArray) {
    eprintf(SIGNAME_HELP[0], pname)
    for (k in 1 until SIGNAME_HELP.size) eprintf("%s\n", SIGNAME_HELP[k])
}

/** The signame tool. */
fun Wfdb.signameMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val argc = argv.size
    val pname = progName(argv[0])
    var record: ByteArray? = null
    var isiglist = 0
    var nosig = 0

    var i = 1
    while (i < argc) {
        if (argv[i].at(0) == '-'.code) {
            when (argv[i].at(1).toChar()) {
                'h' -> { // help requested
                    signameHelp(pname)
                    exit(0)
                }
                'r' -> { // record name
                    if (++i >= argc) {
                        eprintf("%s: record name must follow -r\n", pname)
                        exit(1)
                    }
                    record = argv[i]
                }
                's' -> { // signal list follows
                    isiglist = i + 1 // index of 1st argument with a signal #
                    while (i + 1 < argc && argv[i + 1].at(0) != '-'.code) {
                        i++
                        nosig++ // number of elements in signal list
                    }
                    if (nosig == 0) {
                        eprintf("%s: signal list must follow -s\n", pname)
                        exit(1)
                    }
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
    if (record == null) {
        signameHelp(pname)
        exit(1)
    }
    var nsig = isigopen(record, null, 0)
    if (nsig <= 0) exit(2)
    val si = Array(nsig) { Siginfo() }
    nsig = isigopen(record, si, -nsig)
    if (nsig <= 0) exit(2)
    if (isiglist != 0) {
        for (k in isiglist until isiglist + nosig) {
            val j = atoi(argv[k])
            // (The C program also accepts j == nsig, reading past the end of
            // its array; see docs/KNOWN_C_BEHAVIORS.md.)
            val p: ByteArray? = if (0 <= j && j < nsig) si[j].desc?.let { cstr(it) } else "[INVALID]".latin1()
            printf("%s\n", p)
        }
    } else {
        for (k in 0 until nsig) printf("%s\n", si[k].desc?.let { cstr(it) })
    }
    wfdbquit()
    exit(0)
}
