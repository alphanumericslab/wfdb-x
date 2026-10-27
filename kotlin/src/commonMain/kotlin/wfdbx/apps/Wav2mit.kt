// wav2mit: convert a .wav format file to WFDB format (port of
// convert/wav2mit.c, through rust/src/bin/wav2mit.rs).
//
// Most .wav files are already written in a WFDB-compatible format. This
// program simply creates a .hea (WFDB header) file that describes the .wav
// file; other WFDB applications can then read the .wav file directly. To
// perform the reverse conversion, use mit2wav.
//
// Where the C program has undefined behavior (without -r, the record name
// it generates contains one uninitialized byte; a format chunk with no
// signals divides by zero), this port uses the input file name without .wav
// as the record name, and 0 as the number of samples (see
// docs/KNOWN_C_BEHAVIORS.md).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of convert/wav2mit.c from the WFDB Software
// Package 10.7.0, by George B. Moody. The translation follows the logic and
// behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: no built-in gain or units: the new options -G
// GAIN (required) and -U UNITS (required unless the gain is 0) give them (the
// original wrote 12.5 adu/mV for 8-bit and 6400 adu/mV for 16-bit files, in
// millivolts); --legacy, as the first argument, restores the original
// behavior. Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md
// gives the reasons.
//
// Original C program: convert/wav2mit.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2003-2004 George B. Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private const val WAV_CHUNK_HEADER_LEN = 8L
private const val WAV_FMT_CHUNK_LEN = 16L
private const val WAVE_FORMAT_PCM = 1
private const val WAV_HEADER_LEN = 44L

/** A 16-bit little-endian integer (EOF at the end of the file). */
private fun wavIn16(f: WfdbFile): Int {
    val a = f.getc()
    if (a == EOF) return EOF
    val b = f.getc()
    if (b == EOF) return EOF
    return ((a and 0xff) or ((b shl 8) and 0xff00)).toShort().toInt()
}

/** A 32-bit little-endian integer (EOF at the end of the file). */
private fun wavIn32(f: WfdbFile): Long {
    var r = 0L
    for (k in 0 until 4) {
        val c = f.getc()
        if (c == EOF) return EOF.toLong()
        r = r or ((c and 0xff).toLong() shl (8 * k))
    }
    return r
}

private val WAV2MIT_HELP = arrayOf(
    "usage: %s -i FILE.wav -r RECORD [ OPTIONS ... ]\n",
    "where FILE.wav is the name of the wav-format input signal file,",
    "and OPTIONS may include:",
    " -G GAIN    gain in adu per physical unit (required; 0: uncalibrated)",
    " -h         print this usage summary",
    " -r RECORD  create RECORD.hea (default: FILE.hea)",
    " -U UNITS   physical units (required unless the gain is 0)",
)

/** wfdb-x: the help lines added by WFDB-x (left out in legacy mode). */
private val WAV2MIT_WFDBX_LINES = setOf(WAV2MIT_HELP[3], WAV2MIT_HELP[6])

private fun Wfdb.wav2mitHelp(pname: ByteArray) {
    val legacy = wfdbx_get_legacy() != 0
    eprintf(WAV2MIT_HELP[0], pname)
    for (k in 1 until WAV2MIT_HELP.size) {
        if (!(legacy && WAV2MIT_HELP[k] in WAV2MIT_WFDBX_LINES)) eprintf("%s\n", WAV2MIT_HELP[k])
    }
}

private fun wavCheckTag(f: WfdbFile, tag: String): Boolean {
    val buf = ByteArray(4)
    return f.fread(buf, 1, 4) == 4 && beq(buf, tag)
}

/** The wav2mit tool. */
fun Wfdb.wav2mitMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    var ifname0: ByteArray? = null
    var record0: ByteArray? = null
    var uunits: ByteArray? = null
    var ggain = 0.0
    var gset = false

    var i = 1
    while (i < argc) {
        if (argv[i].at(0) == '-'.code) {
            val c = argv[i].at(1).toChar()
            if (c == 'G' && !legacy) {
                i++
                val g = CDouble(ggain)
                if (i >= argc || sscanf(argv[i], "%lf", g) != 1 || g.v < 0.0) {
                    eprintf("%s: gain (>= 0) must follow -G\n", pname)
                    exit(1)
                }
                ggain = g.v
                gset = true
            } else if (c == 'h') {
                wav2mitHelp(pname)
                exit(1)
            } else if (c == 'i') {
                i++
                if (i >= argc) {
                    eprintf("%s: name of wav-format input file must follow -i\n", pname)
                    exit(1)
                }
                val f = cstr(argv[i])
                if (f.size <= 4 || !f.endsWith(".wav")) {
                    eprintf("%s: name of input file must end in '.wav'\n", pname)
                    exit(1)
                }
                ifname0 = f
            } else if (c == 'r') {
                i++
                if (i >= argc) {
                    eprintf("%s: record name must follow -r\n", pname)
                    exit(1)
                }
                record0 = cstr(argv[i])
            } else if (c == 'U' && !legacy) {
                i++
                if (i >= argc) {
                    eprintf("%s: units must follow -U\n", pname)
                    exit(1)
                }
                uunits = cstr(argv[i])
            } else {
                eprintf("%s: unrecognized option %s\n", pname, argv[i])
                exit(1)
            }
        } else {
            eprintf("%s: unrecognized argument %s\n", pname, argv[i])
            exit(1)
        }
        i++
    }

    if (ifname0 == null) {
        wav2mitHelp(pname)
        exit(1)
    }
    val ifname: ByteArray = ifname0
    // wfdb-x: the gain (-G), and the units (-U) of a calibrated signal, must be
    // specified (the C program set a gain of 12.5 or 6400 adu/mV, by sample
    // size, and no units, i.e., millivolts, as legacy mode does).
    if (!gset && !legacy) {
        eprintf("%s: the gain must be specified (-G)\n", pname)
        exit(1)
    }
    if (ggain != 0.0 && uunits == null && !legacy) {
        eprintf("%s: the units must be specified (-U)\n", pname)
        exit(1)
    }

    val record = record0 ?: ifname.copyOf(ifname.size - 4)

    val ifile = WfdbFile.fopen(ifname, "rb")
    if (ifile == null) {
        eprintf("%s: can't open %s\n", pname, ifname)
        exit(2)
    }

    ifile.seek(0, SEEK_END)
    val flen = ifile.tell()
    ifile.seek(0, SEEK_SET)

    if (!wavCheckTag(ifile, "RIFF")) {
        eprintf("%s: %s is not a .wav-format file\n", pname, ifname)
        exit(3)
    }
    val hlen = wavIn32(ifile) + WAV_CHUNK_HEADER_LEN
    if (hlen != flen) {
        eprintf("%s: header chunk of %s has incorrect length (%ld, should be %ld)\n", pname, ifname, hlen, flen)
        exit(3)
    }
    if (!wavCheckTag(ifile, "WAVE")) {
        eprintf("%s: %s is not a .wav-format file\n", pname, ifname)
        exit(3)
    }

    if (!wavCheckTag(ifile, "fmt ")) {
        eprintf("%s: format chunk missing or corrupt in %s\n", pname, ifname)
        exit(3)
    }
    val flenChunk = wavIn32(ifile)
    val tag = wavIn16(ifile)
    if (flenChunk != WAV_FMT_CHUNK_LEN || tag != WAVE_FORMAT_PCM) {
        eprintf("%s: unsupported format %d in %s\n", pname, tag, ifname)
        exit(3)
    }
    val nsig = wavIn16(ifile)
    val sps = wavIn32(ifile).toDouble()
    wavIn32(ifile)
    val framelen = wavIn16(ifile)
    val bitspersample = wavIn16(ifile)
    val wres: Int
    if (bitspersample <= 8) {
        if (legacy) ggain = 12.5
        wres = 8
    } else if (bitspersample <= 16) {
        if (legacy) ggain = 6400.0
        wres = 16
    } else {
        eprintf("%s: unsupported resolution (%d bits/sample) in %s\n", pname, bitspersample, ifname)
        exit(3)
    }
    if (framelen != nsig * wres / 8) {
        eprintf("%s: format chunk of %s has incorrect frame length\n", pname, ifname)
        exit(3)
    }

    if (!wavCheckTag(ifile, "data")) {
        eprintf("%s: data chunk missing or corrupt in %s\n", pname, ifname)
        exit(3)
    }
    val dlen = wavIn32(ifile)
    val wnsamp = if (framelen != 0) cdiv(dlen, framelen.toLong()) else 0L

    if (nsig < 0) {
        eprintf("%s: insufficient memory\n", pname)
        exit(2)
    }
    val s = Array(nsig) { Siginfo() }
    for ((k, si) in s.withIndex()) {
        si.fname = ifname.copyOf()
        si.desc = null
        si.units = uunits?.copyOf()
        si.gain = ggain
        si.initval = 0
        si.group = 0
        si.fmt = if (wres == 16) 16 else 80
        si.spf = 1
        si.bsize = 0
        si.adcres = wres
        si.adczero = if (wres == 16) 0 else 128
        si.baseline = si.adczero
        si.nsamp = wnsamp
        si.cksum = 0
        wfdbsetstart(k, WAV_HEADER_LEN)
    }
    setsampfreq(sps)

    if (setheader(record, s, nsig) != 0) {
        ifile.close()
        exit(4)
    }

    wfdbquit()
    ifile.close()
    exit(0)
}
