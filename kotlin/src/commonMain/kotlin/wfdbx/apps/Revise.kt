// revise: convert obsolete-format header files into new ones (port of
// convert/revise.c, through rust/src/bin/revise.rs).
//
// Like the C program (which includes <wfdb/wfdblib.h>), this port opens the
// old header with the library's internal wfdb_open. As in C, an old-style
// header that describes exactly 32 signals is rejected (see
// docs/KNOWN_C_BEHAVIORS.md).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of convert/revise.c from the WFDB Software
// Package 10.7.0, by George B. Moody. The translation follows the logic and
// behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: no built-in ADC resolution: a missing resolution
// stays unspecified (the original assumed 12 bits); --legacy, as the first
// argument, restores the original behavior. Each change is marked "wfdb-x:" in
// the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/revise.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1999 George B. Moody; revised 2018 by Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private const val REVISE_SEP = " \t\n"

/** Size of C's line buffer. */
private const val REVISE_LINEBUFLEN = 256

private fun Wfdb.reviseIncorrect(record: ByteArray): Int {
    wfdb_error(cformat("init: incorrect format in record %s header\n", record))
    return -2
}

/** Reads the next line (C `fgets(linebuf, 256, iheader)`) as a C string, or null at the end. */
private fun reviseNextLine(iheader: WfdbFile, linebuf: ByteVec): ByteArray? =
    if (iheader.fgets(linebuf, REVISE_LINEBUFLEN)) cstr(linebuf.toByteArray()) else null

/** Reads an old-style header (the header file is left open, as in C, until the caller closes it). */
private fun Wfdb.readoldheader(record: ByteArray, siarray: Array<Siginfo>, iheader: WfdbFile): Int {
    val linebuf = ByteVec(REVISE_LINEBUFLEN)
    var nsamples = 0L

    // Get the first token (the record name) from the first non-empty,
    // non-comment line.
    var p: ByteArray
    var rest: ByteArray?
    while (true) {
        val line = reviseNextLine(iheader, linebuf)
        if (line == null) {
            wfdb_error(cformat("init: can't find record name in record %s header\n", record))
            return -2
        }
        val tk = Strtok(line)
        val q = tk.next(REVISE_SEP)
        if (q != null && q.at(0) != '#'.code) {
            p = q
            rest = tk.next(REVISE_SEP)
            break
        }
    }
    if (!iheader.isStd() && !beq(p, record)) {
        wfdb_error(cformat("init: record name in record %s header is incorrect\n", record))
        return -2
    }

    // Identify which type of header file is being read by trying to get
    // another token from the line which contains the record name.
    // (Old-style headers have only one token on the first line, but
    // new-style headers have two or more.)
    if (rest != null) {
        eprintf("The header for record %s appears not to be an old-style header.\n", record)
        return -2
    }

    // The file appears to be an old-style header file.

    // Determine the number of signal groups.
    var line = reviseNextLine(iheader, linebuf) ?: return reviseIncorrect(record)
    p = Strtok(line).next(REVISE_SEP) ?: return reviseIncorrect(record)
    val ng = atoi(p).toLong() and 0xffffffffL // (unsigned in C)

    // Now get information for each signal group.
    var s = 0
    var g = 0L
    while (g < ng) {
        // Set the group number for the first signal in the group.
        siarray[s].group = g.toInt()

        // Get the signal file name.
        line = reviseNextLine(iheader, linebuf) ?: return reviseIncorrect(record)
        p = Strtok(line).next(REVISE_SEP) ?: return reviseIncorrect(record)
        siarray[s].fname = p

        // Determine the gain.
        line = reviseNextLine(iheader, linebuf) ?: return reviseIncorrect(record)
        p = Strtok(line).next(REVISE_SEP) ?: return reviseIncorrect(record)
        siarray[s].gain = atof(p)

        // Determine the sampling frequency.
        line = reviseNextLine(iheader, linebuf) ?: return reviseIncorrect(record)
        p = Strtok(line).next(REVISE_SEP) ?: return reviseIncorrect(record)
        val f = atof(p)
        if (f <= 0.0) return reviseIncorrect(record)
        setsampfreq(f)

        // Determine the format, block size, and number of signals in this
        // group. In old-style headers these three quantities are encoded
        // into two fields.
        line = reviseNextLine(iheader, linebuf) ?: return reviseIncorrect(record)
        var tk = Strtok(line)
        p = tk.next(REVISE_SEP) ?: return reviseIncorrect(record)
        val i = atoi(p)
        var mpx = tk.next(REVISE_SEP)?.let { atoi(it) } ?: 1
        if (mpx == 0) mpx = 1
        if (i != 8 && i != 16) {
            siarray[s].bsize = i
            if (mpx < 0) {
                mpx = -mpx
                siarray[s].fmt = 8
            } else {
                siarray[s].fmt = 16
            }
        } else {
            siarray[s].fmt = i
            siarray[s].bsize = 0
        }

        // Determine the ADC resolution.
        // wfdb-x: unspecified (0) if missing; C (and legacy mode) assumed
        // WFDB_DEFRES
        val dflt = if (wfdbx_get_legacy() != 0) WFDB_DEFRES else 0
        siarray[s].adcres = tk.next(REVISE_SEP)?.let { atoi(it) } ?: dflt

        // Determine the ADC zero.
        siarray[s].adczero = tk.next(REVISE_SEP)?.let { atoi(it) } ?: 0

        // Determine the initial value.
        line = reviseNextLine(iheader, linebuf) ?: return reviseIncorrect(record)
        tk = Strtok(line)
        p = tk.next(REVISE_SEP) ?: return reviseIncorrect(record)
        siarray[s].initval = atoi(p)

        // Determine the number of samples.
        val ns = tk.next(REVISE_SEP)?.let { atol(it) } ?: 0L
        if (ns < 0) return reviseIncorrect(record)
        if (nsamples == 0L) {
            nsamples = ns
        } else if (ns > 0 && ns != nsamples) {
            wfdb_error("warning (init):\n")
            wfdb_error(cformat(" record %s durations are inconsistent\n", record))
            // nsamples must match the shortest record duration.
            if (nsamples > ns) nsamples = ns
        }

        // Determine the checksum.
        val ck = tk.next(REVISE_SEP)
        if (ck != null) {
            siarray[s].cksum = atoi(ck)
            siarray[s].nsamp = ns
        } else {
            siarray[s].cksum = 0
            siarray[s].nsamp = 0
        }

        // If this signal group contains more than one signal, make
        // additional copies of the siginfo structure for the other signals.
        while (true) {
            s++
            if (s >= WFDB_MAXSIG) break
            mpx--
            if (mpx <= 0) break
            siarray[s] = siarray[s - 1].copy()
        }

        if (s == WFDB_MAXSIG && (mpx > 0 || g < ((ng - 1) and 0xffffffffL))) {
            wfdb_error(cformat("init: too many signals in record %s\n", record))
            return -2
        }
        g++
    }

    // Now generate signal descriptions for each signal.
    for (k in 0 until s) siarray[k].desc = cformat("record %s, signal %d", record, k)

    return s // return number of available signals
}

/** The revise tool. */
fun Wfdb.reviseMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    if (argv.size < 2) {
        eprintf("usage: %s record\n", argv[0])
        eprintf(" This program converts obsolete-format header files into new ones.\n")
        exit(1)
    }
    var record = cstr(argv[1])
    if (record.startsWith("header.")) record = record.copyOfRange(7, record.size)
    val si = Array(WFDB_MAXSIG) { Siginfo() }

    // Try to open the header file.
    val iheader = wfdb_open("header".latin1(), record, WFDB_READ)
    val nsig = if (iheader == null) {
        wfdb_error(cformat("init: can't open header for record %s\n", record))
        -1
    } else {
        val n = readoldheader(record, si, iheader)
        iheader.close()
        n
    }
    if (nsig < 0) exit(2)
    setheader(record, si, nsig)
    exit(0)
}
