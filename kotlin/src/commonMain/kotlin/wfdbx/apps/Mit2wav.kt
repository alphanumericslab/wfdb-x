// mit2wav: convert WFDB format signal files to .wav format (port of
// convert/mit2wav.c, through rust/src/bin/mit2wav.rs).
//
// The output file has exactly three chunks (a header chunk, a format chunk,
// and a data chunk). The C program writes the header and format chunks to a
// temporary file, and prepends it to the signal file written by putvec
// using the mv, cat, and rm commands; this port prepends them directly,
// with the same result. Where the C program has undefined behavior (signals
// with more than 16 bits of ADC resolution, for which it shifts by a
// negative amount), this port shifts samples to the right and uses a gain
// multiplier of 0.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of convert/mit2wav.c from the WFDB Software
// Package 10.7.0, by George B. Moody. The translation follows the logic and
// behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: no built-in sampling frequency: the record must
// give it (the original assumed 250 Hz); --legacy, as the first argument,
// restores the original behavior. Each change is marked "WFDB-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/mit2wav.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2003-2010 George B. Moody; revised 2018 by Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private const val M2W_CHUNK_HEADER_LEN = 8L
private const val M2W_FMT_CHUNK_LEN = 16L
private const val M2W_FORMAT_PCM = 1
private const val M2W_HEADER_LEN = 44L
private const val M2W_BITS = 16

private fun m2wOut16(b: ByteVec, x: Int) {
    b.add(x and 0xff)
    b.add((x shr 8) and 0xff)
}

private fun m2wOut32(b: ByteVec, x: Long) {
    for (k in 0 until 4) b.add(((x shr (8 * k)) and 0xff).toInt())
}

private val MIT2WAV_HELP = arrayOf(
    "usage: %s -o FILE.wav -r RECORD [ OPTIONS ... ]\n",
    "where FILE.wav is the name of the wav-format output signal file,",
    "RECORD is the record name, and OPTIONS may include:",
    " -h         print this usage summary",
    " -n NEWREC  create a header file for the output signal file, so it",
    "             may be read as record NEWREC",
)

private fun mit2wavHelp(pname: ByteArray) {
    eprintf(MIT2WAV_HELP[0], pname)
    for (k in 1 until MIT2WAV_HELP.size) eprintf("%s\n", MIT2WAV_HELP[k])
}

/** The mit2wav tool. */
fun Wfdb.mit2wavMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    var nrec: ByteArray? = null
    var ofname0: ByteArray? = null
    var record0: ByteArray? = null
    var bitspersample = 0

    var i = 1
    while (i < argc) {
        if (argv[i].at(0) == '-'.code) {
            when (argv[i].at(1).toChar()) {
                'h' -> {
                    mit2wavHelp(pname)
                    exit(1)
                }
                'n' -> {
                    i++
                    if (i >= argc) {
                        eprintf("%s: new record name must follow -n\n", pname)
                        exit(1)
                    }
                    nrec = cstr(argv[i])
                }
                'o' -> {
                    i++
                    if (i >= argc) {
                        eprintf("%s: name of wav-format output file must follow -o\n", pname)
                        exit(1)
                    }
                    val o = cstr(argv[i])
                    if (o.size <= 4 || !o.endsWith(".wav")) {
                        eprintf("%s: name of output file must end in '.wav'\n", pname)
                        exit(1)
                    }
                    ofname0 = o
                }
                'r' -> {
                    i++
                    if (i >= argc) {
                        eprintf("%s: record name must follow -r\n", pname)
                        exit(1)
                    }
                    record0 = cstr(argv[i])
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

    if (ofname0 == null || record0 == null) {
        mit2wavHelp(pname)
        exit(1)
    }
    val ofname: ByteArray = ofname0
    val record: ByteArray = record0
    if (nrec != null && beq(nrec, record)) {
        eprintf("%s: names of input and output records must not be identical\n", pname)
        exit(1)
    }

    var nsig = isigopen(record, null, 0)
    if (nsig <= 0) exit(2)
    val s = Array(nsig) { Siginfo() }
    nsig = isigopen(record, s, nsig)
    if (nsig <= 0) exit(3)
    // WFDB-x: no default sampling frequency (the C program assumed 250 Hz, as
    // legacy mode does).
    if (!legacy && sampfreq(null as ByteArray?) <= 0.0) {
        eprintf("%s: sampling frequency of record %s is not specified\n", pname, record)
        exit(3)
    }
    val n = nsig
    val offset = IntArray(n)
    val shift = IntArray(n)
    val x = IntArray(n)
    val y = IntArray(n)

    if (nrec != null && newheader(nrec) < 0) exit(3)

    for (k in 0 until n) {
        val si = s[k]
        if (si.adcres > bitspersample) bitspersample = si.adcres
        offset[k] = si.adczero
        si.adczero = 0
        shift[k] = M2W_BITS - si.adcres
        si.adcres = M2W_BITS
        val mag = if (shift[k] >= 0) 1 shl shift[k] else 0
        si.gain *= mag.toDouble()
        si.baseline = si.baseline - offset[k]
        si.baseline = si.baseline * mag
        si.fname = ofname.copyOf()
        si.group = 0
        si.fmt = 16
        si.spf = 1
    }

    val nsamp = strtim("e")
    val sps = strtim("1").toDouble()
    val framelen = nsig * (M2W_BITS / 8)

    if (osigfopen(s, nsig) < nsig) exit(4)

    for (k in 0 until nsig) wfdbsetstart(k, M2W_HEADER_LEN)

    val hdr = ByteVec()
    hdr.addString("RIFF")
    m2wOut32(hdr, nsamp * framelen.toLong() + (M2W_HEADER_LEN - M2W_CHUNK_HEADER_LEN))
    hdr.addString("WAVEfmt ")
    m2wOut32(hdr, M2W_FMT_CHUNK_LEN)
    m2wOut16(hdr, M2W_FORMAT_PCM)
    m2wOut16(hdr, nsig)
    m2wOut32(hdr, d2l(sps))
    m2wOut32(hdr, d2l(sps * framelen.toDouble()))
    m2wOut16(hdr, framelen)
    m2wOut16(hdr, bitspersample)
    hdr.addString("data")
    m2wOut32(hdr, nsamp * framelen.toLong())

    while (getvec(x) == nsig) {
        for (k in 0 until n) {
            val d = x[k] - offset[k]
            y[k] = if (shift[k] >= 0) d shl shift[k] else d shr (-shift[k])
        }
        if (putvec(y) != nsig) break
    }

    setsampfreq(sampfreq(null as ByteArray?))
    if (nrec != null) newheader(nrec)

    wfdbquit()

    var data = ByteArray(0)
    val fin = WfdbFile.fopen(ofname, "rb")
    if (fin != null) {
        data = fin.readToEnd()
        fin.close()
    }
    val fout = WfdbFile.fopen(ofname, "wb")
    if (fout != null) {
        fout.write(hdr.bytes, 0, hdr.size)
        fout.write(data)
        fout.close()
    }

    exit(0)
}
