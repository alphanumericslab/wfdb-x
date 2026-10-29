// wfdbdesc: describe signal specifications (port of app/wfdbdesc.c,
// through rust/src/bin/wfdbdesc.rs). This program is an expanded version
// of Example 5 in the WFDB Programmer's Guide.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of app/wfdbdesc.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency, gain, ADC
// resolution or units: an unspecified sampling frequency or ADC resolution is
// shown as "not specified" (lengths are then given in sample intervals only),
// a gain of 0 as "uncalibrated" (the original: "uncalibrated; assume 200"),
// and unspecified units as "adu/nd" (the original assumed 250 Hz, 12 bits and
// millivolts); --legacy, as the first argument, restores the original
// behavior. Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md
// gives the reasons.
//
// Original C program: app/wfdbdesc.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1989-2012 George B. Moody; revised 2018-2020 by
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

/** `%s` of a string that may be NULL. */
private fun nstr(s: ByteArray?): ByteArray? = s?.let { cstr(it) }

/** The size of a regular file (C: stat, fopen, fseek to the end, ftell), or null. */
private fun regularFileSize(name: ByteArray): Long? {
    if (Platform.isDirectory(name)) return null
    val f = WfdbFile.fopen(name, "rb") ?: return null
    if (f.seek(0, SEEK_END) != 0) {
        f.close()
        return null
    }
    val n = f.tell()
    f.close()
    return n
}

/** The wfdbdesc tool. */
fun Wfdb.wfdbdescMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = progName(argv[0])
    var msrec = false

    if (argc < 2) {
        eprintf("usage: %s RECORD [-readable]\n", pname)
        exit(1)
    }
    // Discover the number of signals defined in the header.
    var nsig = isigopen(argv[1], null, 0)
    // (The C library's isigopen() removes a trailing ".hea" from its
    // argument in place, which changes the record name printed below.)
    val rec = wfdb_striphea(argv[1])
    if (nsig < 0) exit(2)

    // Allocate storage for nsig signal information structures.
    val s = Array(maxOf(nsig, 0)) { Siginfo() }

    // If the `-readable' option is given, report only on signals which can
    // be opened. Otherwise, report on all signals named in the header file,
    // without attempting to open them.
    if (nsig > 0 && argc > 2 && "-readable".latin1().startsWith(cstr(argv[2]))) {
        nsig = isigopen(rec, s, nsig)
    } else if (nsig > 0) {
        nsig = isigopen(rec, s, -nsig)
    }
    printf("Record %s", rec)
    setgvmode(WFDB_LOWRES)
    var t = strtim("e")
    if (nsig > 0 && (s[0].fmt == 0 || s[0].nsamp != 0L) && s[0].nsamp != t) {
        msrec = true
        printf(" (a %s-layout multi-segment record)\n", if (s[0].nsamp == 0L) "variable" else "fixed")
        if (s[0].nsamp != 0L) {
            printf("----------------------------------------------\n")
            printf("The following data apply to the entire record:\n")
            printf("----------------------------------------------")
        }
    }
    var info = getinfo(rec)
    if (info != null) {
        printf("\nNotes\n=====\n")
        while (info != null) {
            printf("%s\n", info)
            info = getinfo(null as ByteArray?)
        }
        printf("=====\n")
    }
    // WFDB-x: if the sampling frequency is not specified, times are not
    // shown (the C program assumed 250 Hz). In legacy mode, the output is
    // that of the C program.
    val freq = sampfreq(null)
    // As in C, these tests are not complements when freq is NaN.
    val timed = freq > 0.0 || legacy
    val untimed = freq <= 0.0 && !legacy
    val p = if (timed) mstimstr(0) else ByteArray(0)
    printf("\nStarting time: %s\n", if (p.at(0) == '['.code) p else "not specified")
    printf("Length: ")
    if (untimed && (nsig < 1 || t > 0)) {
        printf("%lld sample intervals\n", t)
    } else if (nsig < 1 || t > 0) {
        val ts = if (t > 0) mstimstr(t) else "0".latin1()
        printf("%s (%lld sample intervals)\n", ts, t)
    } else {
        val fname = s[0].fname
        val size = if (fname != null && s[0].fmt != 0) regularFileSize(fname) else null
        if (size != null) {
            var framesize = 0L
            val nbytes = size - wfdbgetstart(0)
            for (k in 0 until nsig) {
                if (s[k].group != 0) break
                framesize += s[k].spf.toLong()
            }
            // Frames in the file, from the bytes per sample of the format
            // (212 packs 2 samples in 3 bytes, 310 and 311 pack 3 in 4).
            t = when (s[0].fmt) {
                8, 80 -> nbytes / framesize
                16, 61, 160 -> nbytes / (2 * framesize)
                24 -> nbytes / (3 * framesize)
                32 -> nbytes / (4 * framesize)
                212 -> (2 * nbytes) / (3 * framesize)
                310, 311 -> (3 * nbytes) / (4 * framesize)
                else -> -1
            }
            if (t >= 0 && untimed) {
                printf("%lld sample intervals [from signal file size]\n", t)
            } else if (t >= 0) {
                printf("%s (%lld sample intervals) [from signal file size]\n", mstimstr(t), t)
            } else {
                printf("not specified\n")
            }
        } else {
            printf("not specified\n")
        }
    }
    if (timed) printf("Sampling frequency: %.12g Hz\n", freq)
    else printf("Sampling frequency: not specified\n")
    printf("%d signal%s\n", nsig, if (nsig == 1) "" else "s")
    if (nsig < 1) exit(2)
    if (msrec && s[0].nsamp != 0L) {
        printf("----------------------------------------------\n")
        printf("The following data apply to the first segment:\n")
        printf("----------------------------------------------\n")
        if (timed) {
            printf("Segment length: %s (%ld sample intervals)\n", mstimstr(s[0].nsamp), s[0].nsamp)
        } else {
            printf("Segment length: %ld sample intervals\n", s[0].nsamp)
        }
    }
    for (i in 0 until nsig) {
        val x = s[i]
        printf("Group %d, Signal %d:\n", x.group, i)
        printf(" File: %s\n", if (x.fmt != 0) nstr(x.fname) else "[none]".latin1())
        printf(" Description: %s\n", nstr(x.desc))
        printf(" Gain: ")
        if (legacy) {
            // WFDB-x: as in the C program (legacy mode)
            if (x.gain == 0.0) printf("uncalibrated; assume %g", WFDB_DEFGAIN)
            else printf("%.12g", x.gain)
            printf(" adu/%s\n", x.units?.let { cstr(it) } ?: "mV".latin1())
        } else if (x.gain == 0.0) {
            // WFDB-x: no default gain (C: "uncalibrated; assume 200")
            printf("uncalibrated\n")
        } else {
            // WFDB-x: unspecified units are shown as "nd" (C: mV)
            printf("%.12g adu/%s\n", x.gain, x.units?.let { cstr(it) } ?: "nd".latin1())
        }
        printf(" Initial value: %d\n", x.initval)
        if (x.fmt != 0) printf(" Storage format: %d", x.fmt)
        if (x.spf > 1) printf(" (%d samples per frame)", x.spf)
        if (x.fmt != 0 || x.spf > 1) printf("\n")
        printf(" I/O: ")
        if (x.bsize == 0) printf("can be unbuffered\n")
        else printf("%d-byte blocks\n", x.bsize)
        if (x.adcres > 0 || legacy) {
            printf(" ADC resolution: %d bits\n", x.adcres)
        } else {
            // WFDB-x: no default resolution
            printf(" ADC resolution: not specified\n")
        }
        printf(" ADC zero: %d\n", x.adczero)
        printf(" Baseline: %d\n", x.baseline)
        if (x.nsamp > 0) printf(" Checksum: %d\n", x.cksum)
    }
    exit(0)
}
