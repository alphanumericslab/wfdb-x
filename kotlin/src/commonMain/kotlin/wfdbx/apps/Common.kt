// Common definitions of the command-line tools (package wfdbx.apps).
//
// The tool contract: each of the 33 tools is a function
//
//     fun Wfdb.<tool>Main(argv: Array<ByteArray>): Int
//
// in src/commonMain/kotlin/wfdbx/apps/<Tool>.kt (e.g. Wfdb.rdsampMain in
// Rdsamp.kt), a port of rust/src/bin/<tool>.rs. argv is C's argv: argv[0]
// is the program name (the tool name, as for a C tool found in the PATH),
// then the arguments, as bytes. The function returns the exit status, or
// ends the process with wfdbx.cstd.exit(status) (C's exit: open output
// files and the standard output are flushed), as the C program does. The
// tool handles --legacy itself, first thing (toolArgv). The driver
// (wfdbx.cli.MainKt, jvmMain) calls it on the default instance
// (wfdbDefault()), so library calls written with or without the receiver
// reach the same state; then it flushes and exits with the returned status.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.Wfdb
import wfdbx.cstd.ewrite
import wfdbx.cstd.latin1
import wfdbx.wfdbx_legacy_args

/**
 * C's argv as a mutable list (the Rust tools' `cstd::args()`), after
 * `wfdbx_legacy_args` (a first argument `--legacy` is removed and turns
 * legacy mode on).
 */
fun Wfdb.toolArgv(argv: Array<ByteArray>): MutableList<ByteArray> {
    val v = argv.toMutableList()
    wfdbx_legacy_args(v)
    return v
}

/** The body of a tool that has not been ported yet. */
internal fun notImplemented(tool: String): Int {
    ewrite("$tool: not implemented\n".latin1())
    return 1
}
