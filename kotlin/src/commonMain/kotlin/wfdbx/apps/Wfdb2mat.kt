// wfdb2mat: convert (all or part of) a WFDB signal file to Matlab .mat
// format (port of convert/wfdb2mat.c, through rust/src/bin/wfdb2mat.rs).
//
// If the input record name is REC, the output files are RECm.mat (a version
// 5 MAT-file containing a single matrix named 'val' of raw samples, one
// column per sample) and RECm.hea. See the C source for details.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of convert/wfdb2mat.c from the WFDB Software
// Package 10.7.0, by George B. Moody. The translation follows the logic and
// behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: no built-in sampling frequency, gain or units:
// the record must give the sampling frequency (the original assumed 250 Hz),
// uncalibrated signals stay uncalibrated in the output header (the original
// wrote 200 adu/mV), and unspecified units are written as "nd" (the original
// wrote "mV"); --legacy, as the first argument, restores the original
// behavior. Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md
// gives the reasons.
//
// Original C program: convert/wfdb2mat.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2009-2013 George B. Moody; revised 2014-2021 by
//   Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private const val MAT8 = 2
private const val MAT16 = 3
private const val MAT32 = 5

private val WFDB2MAT_HELP = arrayOf(
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -l INTERVAL truncate output after the specified time interval (hh:mm:ss)",
    " -s SIGNAL   [SIGNAL ...]  convert only the specified signal(s)",
    " -S SIGNAL   search for a valid sample of the specified SIGNAL at or after",
    "\t\tthe time specified with -f, and begin converting then",
    " -t TIME     stop at specified time",
    "Outputs are written to the current directory as RECORD.mat and RECORDm.hea.",
)

private fun wfdb2matHelp(pname: ByteArray) {
    eprintf(WFDB2MAT_HELP[0], pname)
    for (k in 1 until WFDB2MAT_HELP.size) eprintf("%s\n", WFDB2MAT_HELP[k])
}

/** Stores the low 32 bits of x (little-endian) at p[at until at + 4]. */
private fun matPut32(p: ByteArray, at: Int, x: Long) {
    for (k in 0 until 4) p[at + k] = (x shr (8 * k)).toByte()
}

/** The wfdb2mat tool. */
fun Wfdb.wfdb2matMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    var record0: ByteArray? = null
    var search: ByteArray? = null
    val prologlen = 192
    val prolog = ByteArray(prologlen)
    val mastertype = 14
    val sub1type = 6
    val sub2type = 5
    val sub3type = 1
    val fieldversion = 256
    val sub1class = 6
    var highres = false
    var isiglist = 0
    var nosig = 0
    var stat = 0
    var from = 0L
    var maxl = 0L
    var to = 0L

    var i = 1
    while (i < argc) {
        if (argv[i].at(0) == '-'.code) {
            when (argv[i].at(1).toChar()) {
                'f' -> {
                    i++
                    if (i >= argc) {
                        eprintf("%s: time must follow -f\n", pname)
                        exit(1)
                    }
                    from = i.toLong()
                }
                'h' -> {
                    wfdb2matHelp(pname)
                    exit(0)
                }
                'H' -> highres = true
                'l' -> {
                    i++
                    if (i >= argc) {
                        eprintf("%s: max output length must follow -l\n", pname)
                        exit(1)
                    }
                    maxl = i.toLong()
                }
                'r' -> {
                    i++
                    if (i >= argc) {
                        eprintf("%s: record name must follow -r\n", pname)
                        exit(1)
                    }
                    record0 = cstr(argv[i])
                }
                's' -> {
                    isiglist = i + 1
                    while (i + 1 < argc && argv[i + 1].at(0) != '-'.code) {
                        i++
                        nosig++
                    }
                    if (nosig == 0) {
                        eprintf("%s: signal list must follow -s\n", pname)
                        exit(1)
                    }
                }
                'S' -> {
                    i++
                    if (i >= argc) {
                        eprintf("%s: signal name or number must follow -S\n", pname)
                        exit(1)
                    }
                    search = cstr(argv[i])
                }
                't' -> {
                    i++
                    if (i >= argc) {
                        eprintf("%s: time must follow -t\n", pname)
                        exit(1)
                    }
                    to = i.toLong()
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
    if (record0 == null) {
        wfdb2matHelp(pname)
        exit(1)
    }
    val record: ByteArray = record0
    var nisig = isigopen(record, null, 0)
    if (nisig <= 0) exit(2)
    val si = Array(nisig) { Siginfo() }
    val vi = IntArray(nisig)
    nisig = isigopen(record, si, nisig)
    if (nisig <= 0) exit(2)
    // WFDB-x: no default gain (the C program assumed 200 adu/mV for
    // uncalibrated signals, as legacy mode does).
    if (legacy) {
        for (k in 0 until minOf(nisig, si.size)) if (si[k].gain == 0.0) si[k].gain = WFDB_DEFGAIN
    }
    if (highres) setgvmode(WFDB_HIGHRES)
    val freq = sampfreq(null as ByteArray?)
    // WFDB-x: no default sampling frequency (except in legacy mode).
    if (freq <= 0.0 && !legacy) {
        eprintf("%s: sampling frequency of record %s is not specified\n", pname, record)
        exit(2)
    }
    if (from > 0) {
        from = strtim(argv[from.toInt()])
        if (from < 0) from = -from
    }
    if (isigsettime(from) < 0) exit(2)
    if (to > 0) {
        to = strtim(argv[to.toInt()])
        if (to < 0) to = -to
    }
    val sig: IntArray
    if (nosig != 0) {
        sig = IntArray(nosig)
        for (k in 0 until nosig) {
            val s = findsig(argv[isiglist + k])
            if (s < 0) {
                eprintf("%s: can't read signal '%s'\n", pname, argv[isiglist + k])
                exit(2)
            }
            sig[k] = s
        }
    } else {
        nosig = nisig
        sig = IntArray(nosig) { it }
    }
    val so = Array(nosig) { Siginfo() }
    val vo = IntArray(nosig)

    val srch = search
    if (srch != null) {
        val s = findsig(srch)
        var ok = false
        if (s >= 0) {
            from = tnextvec(s, from)
            ok = from >= 0
        }
        if (!ok) {
            eprintf("%s: can't read signal '%s'\n", pname, srch)
            exit(2)
        }
    }

    if (maxl > 0) {
        maxl = strtim(argv[maxl.toInt()])
        if (maxl < 0) maxl = -maxl
    }
    if (maxl != 0L && (to == 0L || to > from + maxl)) to = from + maxl

    var t = strtim("e")
    if (t == 0L) {
        wfdbquiet()
        var lower = 0L
        var upper = WFDB_TIME_MAX
        t = 16L * 1024
        while (lower < upper) {
            if (isigsettime(t) >= 0 && getvec(vi) > 0) lower = t + 1
            else upper = t
            if (upper == WFDB_TIME_MAX && t < WFDB_TIME_MAX / 2) t *= 2
            else t = lower + (upper - lower) / 2
        }
        wfdbverbose()
        if (isigsettime(from) < 0) exit(2)
    }
    if (to == 0L || to > t) to = t

    if (to <= from) {
        wfdbquit()
        eprintf("%s: no output\n", pname)
        eprintf(" Use the -f and -t options to specify time limits\n(or type '%s -h' for help)\n", pname)
        exit(1)
    }

    val orec = ByteVec()
    run {
        val r = record
        var sfname = 0
        var q = r.size - 1
        if (q >= 0 && r[q] == '/'.code.toByte()) sfname = 1
        while (true) {
            q--
            if (q <= 0) break
            if (r[q] == '/'.code.toByte()) {
                q++
                break
            }
        }
        if (q < 0) q = 0
        orec.addAll(r, q, r.size - q - sfname)
    }
    for (k in 0 until orec.size) if (orec.bytes[k] == '.'.code.toByte()) orec.bytes[k] = '_'.code.toByte()
    orec.add('m'.code)
    val orecName = orec.toByteArray()
    val matname = bcat(orecName, ".mat".latin1())

    var nbytesperelement = 1
    for (sg in sig) {
        val s = si[sg]
        if (s.adcres > 0) {
            if (s.adcres > 16) nbytesperelement = 4
            else if (s.adcres > 8 && nbytesperelement < 2) nbytesperelement = 2
        } else {
            if (s.fmt == 24 || s.fmt == 32) nbytesperelement = 4
            else if (s.fmt != 80 && nbytesperelement < 2) nbytesperelement = 2
        }
    }
    val sub4type: Int
    val wfdbtype: Int
    when (nbytesperelement) {
        1 -> { sub4type = MAT8; wfdbtype = 80 }
        2 -> { sub4type = MAT16; wfdbtype = 16 }
        else -> { sub4type = MAT32; wfdbtype = 32 }
    }

    for (k in 0 until nosig) {
        val s = si[sig[k]]
        val o = s.copy()
        so[k] = o
        o.fname = matname.copyOf()
        o.group = 0
        o.spf = 1
        o.fmt = wfdbtype
        o.adczero = 0
        o.baseline = o.baseline - s.adczero
        val u = o.units
        // WFDB-x: unspecified units are written as "nd" (C, legacy mode: mV)
        if (u == null) o.units = (if (legacy) "mV" else "nd").latin1()
        else if (u.isEmpty()) o.units = "nd".latin1()
    }

    val maxLength = (1L shl 31) / nbytesperelement / nosig
    if (to - from > maxLength) {
        eprintf("%s: cannot write mat file - data size exceeds 2GB limit\n", pname)
        exit(1)
    }

    val nbytesofdata = (nbytesperelement * nosig).toLong() * (to - from)
    val lremain = nbytesofdata % 8
    val nbytesmaster = if (lremain == 0L) nbytesofdata + 56 else {
        for (o in so) o.bsize = 8
        nbytesofdata + 64 - lremain
    }

    if (osigfopen(so, nosig) != nosig) {
        wfdbquit()
        exit(1)
    }

    "MATLAB 5.0".latin1().copyInto(prolog, 0)
    prolog[124] = (fieldversion and 0xff).toByte()
    prolog[125] = ((fieldversion shr 8) and 0xff).toByte()
    prolog[126] = 'I'.code.toByte()
    prolog[127] = 'M'.code.toByte()
    prolog[128] = (mastertype and 0xff).toByte()
    matPut32(prolog, 132, nbytesmaster)
    prolog[136] = (sub1type and 0xff).toByte()
    prolog[140] = 8
    prolog[144] = (sub1class and 0xff).toByte()
    prolog[152] = (sub2type and 0xff).toByte()
    prolog[156] = 8
    matPut32(prolog, 160, nosig.toLong())
    matPut32(prolog, 164, to - from)
    prolog[168] = (sub3type and 0xff).toByte()
    prolog[172] = 3
    "val".latin1().copyInto(prolog, 176)
    prolog[184] = (sub4type and 0xff).toByte()
    matPut32(prolog, 188, nbytesofdata)
    wfdbputprolog(prolog, prologlen.toLong(), 0)

    t = from
    while (t < to && stat >= 0) {
        stat = getvec(vi)
        for (k in 0 until nosig) vo[k] = vi[sig[k]] - si[sig[k]].adczero
        if (putvec(vo) != nosig) break
        t++
    }

    if (t != to) {
        eprintf("%s (warning): final %lld columns are invalid\n", pname, to - t)
        vo.fill(WFDB_INVALID_SAMPLE)
        while (t < to) {
            t++
            putvec(vo)
        }
    }

    setsampfreq(freq)
    val ps = mstimstr(-from)
    if (ps.at(0) == '['.code) setbasetime(ps.copyOfRange(1, ps.size))
    newheader(orecName)

    while (true) {
        val info = getinfo(null as ByteArray?) ?: break
        putinfo(info)
    }

    putinfo(bcat("Creator: ".latin1(), pname))
    val p = ByteVec()
    p.addString("Source: record ")
    p.addAll(record)
    val qs = mstimstr(0)
    var k0 = 0
    while (k0 < qs.size && qs[k0] == ' '.code.toByte()) k0++
    val q = qs.copyOfRange(k0, qs.size)
    if (from != 0L || q.at(0) == '['.code) {
        p.addString("  Start: ")
        p.addAll(q)
    }
    val pb = p.toByteArray()
    putinfo(pb)

    val offset = if (wfdbtype == 80) 128 else 0

    val ns = nosig
    val s1 = if (ns == 1) "" else "s"
    val s2 = if (to == from + 1) "" else "s"
    printf("%s\n", pb)
    printf("val has %d row%s (signal%s) and %lld column%s (sample%s/signal)\n", ns, s1, s1, to - from, s2, s2)
    printf("Duration: %s\n", timstr(to - from))
    printf("Sampling frequency: %.12g Hz  Sampling interval: %.10g sec\n", freq, 1.0 / freq)
    printf("Row\tSignal\tGain\tBase\tUnits\n")
    for ((k, o) in so.withIndex()) {
        printf(
            "%d\t%s\t%.12g\t%d\t%s\n", k + 1, o.desc ?: "(null)".latin1(), o.gain,
            o.baseline + offset, o.units ?: ByteArray(0)
        )
    }
    printf("\nTo convert from raw units to the physical units shown\nabove, call the 'rdmat.m' function from the wfdb-matlab\ntoolbox: https://physionet.org/physiotools/matlab/wfdb-app-matlab/\n")
    wfdbquit()
    exit(0)
}
