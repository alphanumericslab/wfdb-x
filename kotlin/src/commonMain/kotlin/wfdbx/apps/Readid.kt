// readid: read an AHA-format ID block, write record name and file lengths
// (port of convert/readid.c, through rust/src/bin/readid.rs).
//
// The C program reads the record ID into a 9-byte buffer, which overflows
// for longer IDs; this port prints the whole ID, as the C program does (see
// docs/KNOWN_C_BEHAVIORS.md).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of convert/readid.c from the WFDB Software
// Package 10.7.0, by George B. Moody. The translation follows the logic and
// behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: convert/readid.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2005 George B. Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

/** Reads a 16-bit integer in PDP-11 format (as g16 in readid.c: EOF gives 0xff bytes). */
private fun readidG16(fp: WfdbFile): Int {
    val l = fp.getc()
    val h = fp.getc()
    return ((h shl 8) and 0xff00) or (l and 0xff)
}

/** Size of an AHA ID block, and of the logical blocks counted in it. */
private const val READID_BLOCK_SIZE = 512

/** The readid tool. */
fun Wfdb.readidMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    if (argv.size < 3) {
        eprintf("usage: %s data-block-size annot-block-size\n", argv[0])
        exit(1)
    }
    val dasize = maxOf(atoi(argv[1]), 1)
    val ansize = maxOf(atoi(argv[2]), 1)
    val stdin = WfdbFile.stdin()
    val buf = ByteArray(READID_BLOCK_SIZE)
    // Bytes 1-24: record ID, number of annotations, ..., last sample time.
    stdin.fread(buf, 1, 24)
    // sscanf(buf, "%s", name)
    val s = cstr(buf)
    var k = 0
    while (k < s.size && isspace(s.at(k))) k++
    var e = k
    while (e < s.size && !isspace(s.at(e))) e++
    val name = s.copyOfRange(k, e)
    // Bytes 25-26: number of blocks of sample data.
    val block = READID_BLOCK_SIZE.toLong()
    val dcount = (readidG16(stdin).toLong() * block + dasize.toLong() - 1) / dasize.toLong()
    // Bytes 27-40: unused, first and last annotation times.
    stdin.fread(ByteArray(14), 1, 14)
    // Bytes 41-42: number of blocks of annotations.
    val acount = (readidG16(stdin).toLong() * block + ansize.toLong() - 1) / ansize.toLong()
    stdin.close()
    printf("%s %ld %ld\n", name, dcount, acount)
    exit(0)
}
