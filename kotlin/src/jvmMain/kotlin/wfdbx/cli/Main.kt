// The command-line driver of the wfdb-x tools on the JVM:
//
//     java -cp wfdbx-all.jar wfdbx.cli.MainKt TOOL [ARGUMENTS ...]
//     java -cp wfdbx-all.jar wfdbx.cli.MainKt --list | --version
//
// (kotlin/bin/wfdbx runs it). TOOL is one of the 33 tools (wfdbx.apps); it
// runs with argv[0] = TOOL, as a C tool found in the PATH, and the process
// exits with its status. A first argument --legacy after TOOL selects the
// original behavior (each tool handles it: wfdbx_legacy_args).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.cli

import wfdbx.Wfdb
import wfdbx.apps.*
import wfdbx.cstd.Stdout
import wfdbx.cstd.ewrite
import wfdbx.cstd.exit
import wfdbx.cstd.jnuBytes
import wfdbx.wfdbDefault
import wfdbx.wfdbversion
import wfdbx.cstd.latin1

/** The tools, by name (sorted), and their main functions. */
val TOOLS: Map<String, Wfdb.(Array<ByteArray>) -> Int> = sortedMapOf(
    "a2m" to Wfdb::a2mMain,
    "ad2m" to Wfdb::ad2mMain,
    "ahaecg2mit" to Wfdb::ahaecg2mitMain,
    "ann2rr" to Wfdb::ann2rrMain,
    "edf2mit" to Wfdb::edf2mitMain,
    "m2a" to Wfdb::m2aMain,
    "makeid" to Wfdb::makeidMain,
    "md2a" to Wfdb::md2aMain,
    "mit2edf" to Wfdb::mit2edfMain,
    "mit2wav" to Wfdb::mit2wavMain,
    "parsescp" to Wfdb::parsescpMain,
    "rdann" to Wfdb::rdannMain,
    "rdedfann" to Wfdb::rdedfannMain,
    "rdsamp" to Wfdb::rdsampMain,
    "readid" to Wfdb::readidMain,
    "revise" to Wfdb::reviseMain,
    "rr2ann" to Wfdb::rr2annMain,
    "sampfreq" to Wfdb::sampfreqMain,
    "sigamp" to Wfdb::sigampMain,
    "signame" to Wfdb::signameMain,
    "signum" to Wfdb::signumMain,
    "snip" to Wfdb::snipMain,
    "sortann" to Wfdb::sortannMain,
    "time2sec" to Wfdb::time2secMain,
    "wav2mit" to Wfdb::wav2mitMain,
    "wfdb2mat" to Wfdb::wfdb2matMain,
    "wfdbcat" to Wfdb::wfdbcatMain,
    "wfdbdesc" to Wfdb::wfdbdescMain,
    "wfdbtime" to Wfdb::wfdbtimeMain,
    "wfdbwhich" to Wfdb::wfdbwhichMain,
    "wrann" to Wfdb::wrannMain,
    "wrsamp" to Wfdb::wrsampMain,
    "xform" to Wfdb::xformMain,
)

private const val USAGE = "usage: wfdbx TOOL [ARGUMENTS ...]\n       wfdbx --list\n       wfdbx --version\n"

/** Runs the tool named by args[0] with the other arguments, and exits with its status. */
fun main(args: Array<String>) {
    if (args.isEmpty() || args[0] == "-h" || args[0] == "--help") {
        ewrite(USAGE)
        exit(if (args.isEmpty()) 1 else 0)
    }
    when (args[0]) {
        "--list" -> {
            for (t in TOOLS.keys) Stdout.write("$t\n")
            exit(0)
        }
        "--version" -> {
            Stdout.write("wfdb-x 1.0.0 (WFDB " + wfdbversion().latin1() + ")\n")
            exit(0)
        }
    }
    val tool = args[0]
    val f = TOOLS[tool]
    if (f == null) {
        ewrite("wfdbx: unknown tool '$tool' (try 'wfdbx --list')\n")
        exit(1)
    }
    val argv = Array(args.size) { i -> if (i == 0) tool.latin1() else jnuBytes(args[i]) }
    val status = try {
        wfdbDefault().f(argv)
    } catch (e: OutOfMemoryError) {
        Stdout.flush()
        ewrite("wfdbx: out of memory\n")
        1
    } catch (e: Exception) {
        Stdout.flush()
        ewrite("wfdbx: error: " + (e.message ?: e.toString()) + "\n")
        if (System.getenv("WFDBX_DEBUG") != null) e.printStackTrace()
        1
    }
    exit(status)
}
