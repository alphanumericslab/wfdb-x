// wrann: translate an ASCII annotation file to binary format (port of
// app/wrann.c, through rust/src/bin/wrann.rs).
//
// The input is in the format produced by rdann. Where the C program has
// undefined behavior (a line with no space after column 9, or a mnemonic
// longer than 9 characters), this port treats the remainder of the line as
// empty, and uses the full mnemonic (see docs/KNOWN_C_BEHAVIORS.md).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/wrann.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: app/wrann.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2010 George B. Moody; revised 2018 by Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private fun wrannHelp(pname: ByteArray) {
    eprintf("usage: %s -r RECORD -a ANNOTATOR <TEXT-FILE\n", pname)
    eprintf("TEXT-FILE should be in the format produced by `rdann'.\n")
}

/** The wrann tool. */
fun Wfdb.wrannMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val argc = argv.size
    val pname = progName(argv[0])
    var record: ByteArray? = null
    var ainame: ByteArray? = null
    val sub = CInt(0)
    val ch = CInt(0)
    val nm = CInt(0)
    val tm = CLong(0)
    val annot = Annotation()
    // The mnemonic buffer (static in C: it keeps its contents when a line
    // has no mnemonic).
    val mnem = CBytes(ByteArray(0))

    // Interpret command-line options.
    var i = 1
    while (i < argc) {
        val a = argv[i]
        if (a.at(0) == '-'.code) {
            when (a.at(1).toChar()) {
                'a' -> { // annotator follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: annotator must follow -a\n", pname)
                        exit(1)
                    }
                    ainame = argv[i]
                }
                'h' -> { // print usage summary and quit
                    wrannHelp(pname)
                    exit(0)
                }
                'r' -> { // input record name follows
                    i++
                    if (i >= argc) {
                        eprintf("%s: input record name must follow -r\n", pname)
                        exit(1)
                    }
                    record = argv[i]
                }
                else -> {
                    eprintf("%s: unrecognized option %s\n", pname, a)
                    exit(1)
                }
            }
        } else {
            eprintf("%s: unrecognized argument %s\n", pname, a)
            exit(1)
        }
        i++
    }
    if (record == null || ainame == null) {
        wrannHelp(pname)
        exit(1)
    }

    setafreq(sampfreq(record))
    val ai = arrayOf(Anninfo(ainame, WFDB_WRITE))
    if (annopen(record, ai, 1) < 0) exit(2) // open annotation file

    // Sizes of C's line and aux string buffers.
    val linelen = 400
    val auxbuflen = 256
    val input = WfdbFile.stdin()
    val buf = ByteVec(linelen)
    while (input.fgets(buf, linelen)) {
        val line = cstr(buf.toByteArray())
        val n = line.size
        // Skip the time column (at least 9 characters, as "0:00.000" with
        // its leading space, or a "[...]" time of day).
        var p = 9
        if (line.at(0) == '['.code) {
            while (p < n && line[p] != ']'.code.toByte()) p++
        }
        while (p < n && line[p] != ' '.code.toByte()) p++
        val rest = if (p < n) line.copyOfRange(p + 1, n) else ByteArray(0)
        sscanf(rest, "%lld%s%d%d%d", tm, mnem, sub, ch, nm)
        annot.anntyp = strann(mnem.v)
        if (line.at(0) == '['.code) {
            annot.time = -strtim(line)
            if (annot.time < 0) continue
        } else {
            annot.time = tm.v
        }
        annot.subtyp = sub.v
        annot.chan = ch.v
        annot.num = nm.v
        // If mnem does not contain a recognizable mnemonic, write a NOTE
        // annotation and put mnem at the beginning of the aux field.
        val astr: ByteArray
        if (annot.anntyp == NOTQRS) {
            annot.anntyp = NOTE
            astr = mnem.v.copyOf()
        } else {
            mnem.v = ByteArray(0)
            astr = ByteArray(0)
        }
        val tab = rest.indexOf('\t'.code.toByte())
        val haveAp = tab >= 0
        var ap = ByteArray(0)
        if (haveAp) { // auxinfo at end of line
            ap = rest.copyOfRange(tab, rest.size)
            var cut: Long = if (astr.size + ap.size + 2 > auxbuflen) {
                auxbuflen.toLong() - astr.size - 3
            } else {
                -1 // discard trailing newline
            }
            if (cut < 0) cut += ap.size
            if (cut < 0) cut = 0
            if (cut < ap.size) ap = ap.copyOf(cut.toInt())
        }
        // Create an aux string if needed.
        if (astr.isNotEmpty() || haveAp) {
            val tail = if (ap.size > 1) ap.copyOfRange(1, ap.size) else ByteArray(0)
            val s = ByteVec(astr.size + tail.size + 2)
            if (astr.isNotEmpty() && haveAp) {
                s.addAll(astr)
                s.add(' '.code)
                s.addAll(tail)
            } else if (astr.isNotEmpty()) {
                s.addAll(astr)
            } else {
                s.addAll(tail)
            }
            val aux = ByteVec(s.size + 1)
            aux.add(s.size and 0xff)
            aux.addAll(s.bytes, 0, s.size)
            annot.aux = aux.toByteArray()
        } else {
            annot.aux = null
        }
        putann(0, annot)
    }
    wfdbquit()
    exit(0)
}
