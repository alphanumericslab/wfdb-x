// makeid: make an AHA-format ID block for a database record (port of
// convert/makeid.c, through rust/src/bin/makeid.rs).
//
// Where the C program uses uninitialized variables (the time of the last
// annotation if there is only one, or of the first if there is none), this
// port uses 0 (see docs/KNOWN_C_BEHAVIORS.md).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of convert/makeid.c from the WFDB Software
// Package 10.7.0, by George B. Moody. The translation follows the logic and
// behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: convert/makeid.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2003 George B. Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.Annotation
import wfdbx.cstd.*

// Size of an AHA ID block, and of the record ID at its start.
private const val MAKEID_IDBLOCK_SIZE = 512
private const val MAKEID_RECID_LEN = 8

// Size of the (unused) end of the ID block, after byte 48.
private const val MAKEID_NOTICE_LEN = MAKEID_IDBLOCK_SIZE - 48

/** Writes a 16-bit integer in PDP-11 format. */
private fun makeidP16(x: Int) {
    Stdout.write(byteArrayOf(x.toByte(), (x shr 8).toByte()))
}

/** Writes a 32-bit integer in PDP-11 format. */
private fun makeidP32(x: Long) {
    makeidP16((x shr 16).toInt())
    makeidP16(x.toInt())
}

/** The makeid tool. */
fun Wfdb.makeidMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val nulls = ByteArray(MAKEID_NOTICE_LEN)
    if (argv.size < 3) {
        eprintf("usage: %s annotator record\n", argv[0])
        exit(1)
    }
    val rec = cstr(argv[2])
    val len = rec.size
    if (len > MAKEID_RECID_LEN) {
        eprintf("record name must be 8 characters or less\n")
        exit(1)
    }
    val afarray = arrayOf(Anninfo(cstr(argv[1]), WFDB_READ))
    val dfarray = Array(2) { Siginfo() }
    if (wfdbinit(rec, afarray, 1, dfarray, 2) < 1) exit(2)
    val nsamp = dfarray[0].nsamp
    val annot = Annotation()
    getann(0, annot)
    val first = annot.time
    var last = 0L
    var nann = 1
    while (getann(0, annot) >= 0) {
        last = annot.time
        nann++
    }
    wfdbquit()

    // Bytes 1-8: record ID (null-padded)
    Stdout.write(rec)
    if (len < MAKEID_RECID_LEN) Stdout.write(nulls, 0, MAKEID_RECID_LEN - len)
    eprintf("%s\n", rec)

    // Bytes 9-10: number of annotations
    makeidP16(nann)
    eprintf("%d annotations\n", nann)

    // Bytes 11-16: unused
    Stdout.write(nulls, 0, 6)

    // Bytes 17-20: time of first sample in the annotated segment of the
    // record, relative to the beginning of the record
    makeidP32(0)
    eprintf("Annotated segment begins at sample 0\n")

    // Bytes 21-24: time of last sample in the annotated segment of the
    // record, relative to the beginning of the record
    makeidP32(nsamp)
    eprintf("Annotated segment ends at sample %ld\n", nsamp)

    // Bytes 25-26: number of 512-byte logical blocks of sample data
    // (nsamp * 2 bytes per sample * 2 channels / 512, rounded upward)
    var blocks = ((nsamp + 127) shr 7).toInt()
    makeidP16(blocks)
    eprintf("%d blocks of sample data\n", blocks)

    // Bytes 27-32: unused
    Stdout.write(nulls, 0, 6)

    // Bytes 33-36: TOC of first annotation, relative to the beginning of
    // the annotated segment
    makeidP32(first)
    eprintf("First annotation is at sample %ld\n", first)

    // Bytes 37-40: TOC of last annotation, relative to the beginning of the
    // annotated segment
    makeidP32(last)
    eprintf("Last annotation is at sample %ld\n", last)

    // Bytes 41-42: number of 512-byte logical blocks of annotations
    // (nann * 16 bytes per annotation / 512, rounded upward)
    blocks = (nann + 31) shr 5
    makeidP16(blocks)
    eprintf("%d blocks of annotations\n", blocks)

    // Bytes 43-48: unused
    Stdout.write(nulls, 0, 6)

    // Bytes 49-512: may contain information such as a copyright notice
    Stdout.write(nulls)
    exit(0)
}
