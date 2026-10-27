// ahaecg2mit: convert *.ecg or *.txt files from an AHA Database DVD to
// WFDB-compatible format (port of convert/ahaecg2mit.c, through
// rust/src/bin/ahaecg2mit.rs).
//
// Behaviors of the C program that are undefined are resolved as in the
// other WFDB-x implementations (see docs/KNOWN_C_BEHAVIORS.md): the 16-byte
// line buffer of readtxtdata keeps the bytes of earlier lines of the same
// input file and is not NUL-terminated (bytes beyond it are treated as
// NUL), and the record name is made of the (up to 4) characters that
// precede the extension. The line buffer, the samples and the annotation
// are reset for each input file; with -s, a record name of fewer than 2
// characters is left unchanged.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of convert/ahaecg2mit.c from the WFDB Software
// Package 10.7.0, by George B. Moody. The translation follows the logic and
// behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: no built-in signal parameters: the new options -F
// FREQ, -G GAIN, -R BITS and -U UNITS give the sampling frequency, gain, ADC
// resolution and units, and are required (-U unless the gain is 0; the
// original assumed those of the AHA database: 250 Hz, 400 adu/mV, 12 bits and
// millivolts); the options precede the input files, in any order; the
// short-format part of a long-format file (skipped by -s) is located from -F;
// --legacy, as the first argument, restores the original behavior. Each change
// is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/ahaecg2mit.c, WFDB Software Package 10.7.0.
//   By George B. Moody (2008); revised 2017 by Benjamin Moody. The C source
//   has no copyright or license notice.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

/** The signal parameters (-F, -G, -R, -U). */
private class AhaParams(var freq: Double, var gain: Double, var adcres: Int, var units: ByteArray?)

private const val AHA_FMT_ECG = 1
private const val AHA_FMT_TXT = 2
private const val AHA_ECG_FRAMELEN = 5
private const val AHA_TXTBUFLEN = 16
private const val AHA_SKIP_MINUTES = 145L

/** The state of the C program (its static variables). */
private class AhaState(val format: Int, val ifile: WfdbFile) {
    val a = Annotation()
    val v = IntArray(2)
    val txtbuf = ByteArray(AHA_TXTBUFLEN)

    fun readbindata(): Int {
        val data = ByteArray(AHA_ECG_FRAMELEN)
        if (ifile.fread(data, 1, AHA_ECG_FRAMELEN) != AHA_ECG_FRAMELEN) return 0
        v[0] = (data[0].toInt() and 0xff) or ((data[1].toInt() and 0xff) shl 8)
        v[1] = (data[2].toInt() and 0xff) or ((data[3].toInt() and 0xff) shl 8)
        if (data[4] == '.'.code.toByte()) return 1
        a.anntyp = ammap(data[4].toInt())
        a.subtyp = if (data[4] == 'U'.code.toByte()) -1 else 0
        return 2
    }

    fun readtxtdata(): Int {
        var c = 0 // char is signed in the reference C implementation
        for (k in txtbuf.indices) {
            c = ifile.getc().toByte().toInt()
            if (c == '\r'.code || c == EOF || c == '\n'.code) break
            txtbuf[k] = c.toByte()
        }
        if (c == EOF) return 0
        val s = cstr(txtbuf)
        val v0 = CLong()
        val v1 = CLong()
        val cc = CChar(c and 0xff)
        val n = sscanf(s, "%lld,%lld,\"%c", v0, v1, cc)
        if (n >= 1) v[0] = v0.v.toInt()
        if (n >= 2) v[1] = v1.v.toInt()
        if (n >= 3) c = cc.v.toByte().toInt()
        if (n < 3) {
            eprintf("Error: improperly formatted input!\n")
            eprintf(" n = %d, buf = |%s|, v[0] = %d, v[1] = %d, c = |%c|\n", n, s, v[0], v[1], c)
            return 0
        }
        if (c == '"'.code) return 1
        a.anntyp = ammap(c)
        a.subtyp = if (c == 'U'.code) -1 else 0
        return 2
    }
}

private fun Wfdb.ahaProcess(st: AhaState, record: ByteArray, par: AhaParams) {
    var t = -1L
    setsampfreq(par.freq)
    val s0 = Siginfo(
        fname = bcat(record, ".dat".latin1()), desc = "ECG0".latin1(), units = par.units,
        gain = par.gain, fmt = 212, adcres = par.adcres
    )
    val s1 = s0.copy()
    s1.desc = "ECG1".latin1()
    val si = arrayOf(s0, s1)
    val ai = arrayOf(Anninfo("atr", WFDB_WRITE))
    if (osigfopen(si, 2) != 2 || annopen(record, ai, 1) < 0) {
        wfdbquit()
        return
    }
    if (st.format == AHA_FMT_ECG) {
        while (true) {
            val stat = st.readbindata()
            if (stat == 0) break
            putvec(st.v)
            if (stat > 1) {
                st.a.time = t
                putann(0, st.a)
            }
            t++
        }
    } else {
        while (true) {
            val stat = st.readtxtdata()
            if (stat == 0) break
            t++
            putvec(st.v)
            if (stat > 1) {
                st.a.time = t
                putann(0, st.a)
            }
        }
    }
    newheader(record)
    wfdbquit()
    eprintf("wrote %s.atr, %s.dat, and %s.hea\n", record, record, record)
}

/** The ahaecg2mit tool. */
fun Wfdb.ahaecg2mitMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    var sflag = false

    if (argc < 2 || beq(cstr(argv[1]), "-h")) {
        if (legacy) {
            eprintf("usage: %s [-s] RECORD.XXX [RECORD.XXX]...\n", argv[0])
        } else {
            eprintf("usage: %s [-s] -F FREQ -G GAIN -R BITS -U UNITS RECORD.XXX [RECORD.XXX]...\n", argv[0])
        }
        eprintf(
            " where RECORD.XXX is the name of the AHA DVD input file to be converted\n ('RECORD' is one of the 4-digit AHA DB record names, and 'XXX' may be either\n 'ecg' or 'txt', depending on the version of the AHA DVD.)\n Output files are RECORD.hea (text), RECORD.atr (binary), RECORD.dat (binary).\n Two or more input files may be converted in a single run.\n Use -s to make short-format (35-minute) records from long-format (2.5 hour)\n input files.  When using -s, the second digit in the output record name is\n incremented by 2.\n"
        )
        if (!legacy) {
            eprintf(
                " -F, -G, -R and -U give the sampling frequency (Hz), gain (adu per physical\n unit), ADC resolution (bits) and units of the signals; for the AHA DVD\n files, use -F 250 -G 400 -R 12 -U mV.\n"
            )
        }
        exit(1)
    }
    val pname = argv[0]
    var par = AhaParams(0.0, 0.0, 0, null)
    var gset = false
    var i = 1
    // wfdb-x: the signal parameters are given by -F, -G, -R and -U (required);
    // in legacy mode, those that the C program set (the AHA database: 250 Hz,
    // 400 adu/mV, 12 bits, millivolts).
    if (legacy) {
        if (beq(cstr(argv[1]), "-s")) {
            sflag = true
            i = 2
        }
        par = AhaParams(250.0, 400.0, 12, "mV".latin1())
        gset = true
    }
    while (!legacy && i < argc) {
        val a = cstr(argv[i])
        if (!(a.size == 2 && a[0] == '-'.code.toByte() && "sFGRU".indexOf(a[1].toInt().toChar()) >= 0)) break
        when (a[1].toInt().toChar()) {
            's' -> sflag = true
            'F' -> {
                i++
                val d = CDouble(par.freq)
                val ok = i < argc && sscanf(argv[i], "%lf", d) == 1
                par.freq = d.v
                if (!ok || par.freq <= 0.0) {
                    eprintf("%s: sampling frequency (> 0) must follow -F\n", pname)
                    exit(1)
                }
            }
            'G' -> {
                i++
                val d = CDouble(par.gain)
                val ok = i < argc && sscanf(argv[i], "%lf", d) == 1
                par.gain = d.v
                if (!ok || par.gain < 0.0) {
                    eprintf("%s: gain (>= 0) must follow -G\n", pname)
                    exit(1)
                }
                gset = true
            }
            'R' -> {
                i++
                val d = CInt(par.adcres)
                val ok = i < argc && sscanf(argv[i], "%d", d) == 1
                par.adcres = d.v
                if (!ok || par.adcres !in 1..32) {
                    eprintf("%s: ADC resolution (1-32 bits) must follow -R\n", pname)
                    exit(1)
                }
            }
            else -> {
                i++
                if (i >= argc) {
                    eprintf("%s: units must follow -U\n", pname)
                    exit(1)
                }
                par.units = cstr(argv[i])
            }
        }
        i++
    }
    if (par.freq <= 0.0) {
        eprintf("%s: the sampling frequency must be specified (-F)\n", pname)
        exit(1)
    }
    if (!gset) {
        eprintf("%s: the gain must be specified (-G)\n", pname)
        exit(1)
    }
    if (par.adcres < 1) {
        eprintf("%s: the ADC resolution must be specified (-R)\n", pname)
        exit(1)
    }
    if (par.gain != 0.0 && par.units == null) {
        eprintf("%s: the units must be specified (-U)\n", pname)
        exit(1)
    }
    while (i < argc) {
        val arg = cstr(argv[i])
        val len = arg.size
        val p = maxOf(len - 4, 0)
        val ext = arg.copyOfRange(p, len)
        val format = if (len >= 4 && (beq(ext, ".ecg") || beq(ext, ".ECG"))) AHA_FMT_ECG
        else if (len >= 4 && (beq(ext, ".txt") || beq(ext, ".TXT"))) AHA_FMT_TXT
        else {
            eprintf("%s: ignoring '%s'\n", argv[0], arg)
            i++
            continue
        }
        val ifile = WfdbFile.fopen(arg, "rb")
        if (ifile == null) {
            eprintf("%s: can't open '%s'\n", argv[0], argv[1])
            i++
            continue
        }
        argv[i] = argv[i].copyOf(p)
        val record = if (p >= 4) arg.copyOfRange(p - 4, p) else arg.copyOf(p)
        val st = AhaState(format, ifile)
        if (sflag) {
            val nskip = d2l((AHA_SKIP_MINUTES * 60).toDouble() * par.freq)
            if (format == AHA_FMT_ECG) {
                ifile.seek(nskip * AHA_ECG_FRAMELEN, SEEK_SET)
            } else {
                var k = 0L
                while (k < nskip) {
                    st.readtxtdata()
                    k++
                }
            }
            if (record.size > 1) record[1] = (record[1] + 2).toByte()
        }
        ahaProcess(st, record, par)
        ifile.close()
        i++
    }
    exit(0)
}
