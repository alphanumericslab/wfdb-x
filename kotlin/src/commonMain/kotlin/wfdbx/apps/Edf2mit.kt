// edf2mit: convert EDF (European Data Format) file to MIT format header
// and signal files (port of convert/edf2mit.c, through
// rust/src/bin/edf2mit.rs).
//
// As in the C program, the header fields are read into one reusable 81-byte
// buffer, so a 16-character signal label is followed by a space and by the
// bytes that remain in the buffer from earlier fields (see
// docs/KNOWN_C_BEHAVIORS.md). Where the C program has undefined behavior,
// this port uses: 0 for header fields that cannot be parsed and are left
// uninitialized in C; the characters of the input file name only for the
// default record name; 0 for samples beyond the end of a data record; 0
// frames per record if a signal has 0 samples per frame; and INT_MIN for
// out-of-range conversions of doubles to int (as on x86).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of convert/edf2mit.c from the WFDB Software
// Package 10.7.0, by George B. Moody. The translation follows the logic and
// behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: convert/edf2mit.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1996-2004 George B. Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private val EDF2MIT_HELP = arrayOf(
    "usage: %s [OPTIONS ...]\n",
    "where OPTIONS may include:",
    " -b          input is in big-endian byte order (default: little-endian)",
    " -h          print this usage summary",
    " -i EDFILE   read the specified European Data Format file",
    " -r RECORD   create the specified RECORD (default: input file name without",
    "              suffix)",
    " -s SIGNAL [SIGNAL ...]  copy only the specified signal(s) (use signal",
    "              numbers, beginning with zero;  default: copy all signals)",
    " -v          print debugging output",
    "This program reads an EDF file and creates MIT-format signal and header",
    "files containing the same data.",
)

private fun edf2mitHelp(pname: ByteArray) {
    eprintf(EDF2MIT_HELP[0], pname)
    for (k in 1 until EDF2MIT_HELP.size) eprintf("%s\n", EDF2MIT_HELP[k])
}

/** Euclid's algorithm with a 0.1% relative tolerance (non-integral arguments). */
private fun edfGcd(x0: Double, y0: Double): Double {
    var x = x0
    var y = y0
    val tol = if (x > y) 0.001 * y else 0.001 * x
    while (true) {
        if (x > y && x - y > tol) x -= y
        else if (y > x && y - x > tol) y -= x
        else return x
    }
}

private const val EDF_MAXFIELD = 80

/** The reusable header field buffer of the C program. */
private class EdfField {
    val buf = ByteArray(EDF_MAXFIELD + 1)

    /** Reads a field of n bytes, marks its end with a space, and replaces trailing spaces (from buf[t]) with NULs. */
    fun read(ifile: WfdbFile, n: Int, t: Int): Int {
        ifile.read(buf, 0, n)
        buf[n] = ' '.code.toByte()
        var jj = t
        while (jj >= 0 && buf[jj] == ' '.code.toByte()) {
            buf[jj] = 0
            jj--
        }
        return jj
    }

    fun s(): ByteArray = cstr(buf)
}

/** The edf2mit tool. */
fun Wfdb.edf2mitMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val argc = argv.size
    val pname = argv[0]
    var record = ByteArray(0)
    var ifile: WfdbFile? = null
    var bigEndian = false
    var vflag = false
    var siglist = ArrayList<Int>()

    var i = 1
    while (i < argc) {
        if (argv[i].at(0) == '-'.code) {
            when (argv[i].at(1).toChar()) {
                'b' -> bigEndian = true
                'h' -> {
                    edf2mitHelp(pname)
                    exit(0)
                }
                'i' -> {
                    i++
                    if (i < argc) {
                        if (beq(cstr(argv[i]), "-")) {
                            ifile = WfdbFile.stdin()
                        } else {
                            val f = WfdbFile.fopen(argv[i], "rb")
                            if (f == null) {
                                eprintf("%s: can't read %s\n", pname, argv[i])
                                exit(1)
                            }
                            ifile = f
                            if (record.isEmpty()) {
                                val r = ByteVec()
                                for (c in cstr(argv[i]).take(WFDB_MAXRNL)) {
                                    val ci = c.toInt() and 0xff
                                    if (isalnum(ci)) r.add(ci)
                                    else if (ci == '.'.code) break
                                    else r.add('_'.code)
                                }
                                record = r.toByteArray()
                            }
                        }
                    }
                }
                'r' -> {
                    i++
                    if (i < argc) {
                        val r = cstr(argv[i])
                        record = r.copyOf(minOf(r.size, WFDB_MAXRNL))
                    } else {
                        eprintf("%s: record name must follow -r\n", pname)
                        exit(1)
                    }
                }
                's' -> {
                    var j = 0
                    while (true) {
                        i++
                        if (!(i < argc && argv[i].at(0) != '-'.code)) break
                        j++
                    }
                    if (j == 0) {
                        eprintf("%s: signal list must follow -s\n", pname)
                        exit(1)
                    }
                    i -= j
                    while (i < argc && argv[i].at(0) != '-'.code) {
                        siglist.add(atoi(argv[i]))
                        i++
                    }
                    i--
                }
                'v' -> vflag = true
                else -> {}
            }
        }
        i++
    }
    var nosig = siglist.size

    if (ifile == null) {
        edf2mitHelp(pname)
        exit(1)
    }

    if (record.isEmpty() || newheader(record) < 0) {
        eprintf("\n")
        edf2mitHelp(pname)
        eprintf("\nRun %s again, specifying a valid name for the output record,\n", argv[0])
        eprintf("using the -r option as described above.\n\n")
        eprintf("  Valid record names may include letters, digits, and underscores only.\n")
        exit(1)
    }

    val f = EdfField()
    ifile.read(f.buf, 0, 8)
    if (!f.buf.copyOf(8).contentEquals("0       ".latin1())) {
        eprintf("%s: input does not appear to be EDF -- no conversion attempted.\n", pname)
        exit(2)
    }
    f.buf[8] = ' '.code.toByte()
    run {
        var j = 8
        while (j >= 0 && f.buf[j] == ' '.code.toByte()) {
            f.buf[j] = 0
            j--
        }
    }
    if (vflag) printf("EDF version number: '%s'\n", f.s())

    f.read(ifile, 80, 80)
    if (vflag) printf("Patient ID: '%s'\n", f.s())
    f.read(ifile, 80, 80)
    if (vflag) printf("Recording ID: '%s'\n", f.s())

    f.read(ifile, 8, 8)
    if (vflag) printf("Recording date: '%s'\n", f.s())
    val day = CInt(); val month = CInt(); val year = CInt()
    sscanf(f.s(), "%d%*c%d%*c%d", day, month, year)
    if (year.v < 1970) year.v += 1900
    if (year.v < 1970) year.v += 100

    f.read(ifile, 8, 8)
    if (vflag) printf("Recording time: '%s'\n", f.s())
    val hour = CInt(); val minute = CInt(); val second = CInt()
    sscanf(f.s(), "%d%*c%d%*c%d", hour, minute, second)

    f.read(ifile, 8, 8)
    if (vflag) printf("Number of bytes in header record: '%s'\n", f.s())

    val jr = f.read(ifile, 44, 44)
    if (jr > 0 && vflag) printf("Free space: '%s'\n", f.s())

    f.read(ifile, 8, 8)
    if (vflag) printf("Number of data records: '%s'\n", f.s())

    f.read(ifile, 8, 8)
    if (vflag) printf("Duration of each data record in seconds: '%s'\n", f.s())
    val sprv = CDouble()
    sscanf(f.s(), "%lf", sprv)
    var spr = sprv.v
    if (spr <= 0.0) spr = 1.0

    f.read(ifile, 4, 4)
    if (vflag) printf("Number of signals: '%s'\n", f.s())
    val nsigv = CInt()
    sscanf(f.s(), "%d", nsigv)
    val nsig = nsigv.v

    if (nsig < 1) exit(1)
    val ns = nsig

    val si = Array(ns) { Siginfo() }
    val spb = IntArray(ns)
    val sigdmax = LongArray(ns)
    val sigdmin = LongArray(ns)
    val sigpmax = DoubleArray(ns)
    val sigpmin = DoubleArray(ns)
    val sampfreqs = DoubleArray(ns)

    if (nosig == 0) {
        siglist = ArrayList((0 until nsig).toList())
        nosig = ns
    } else {
        for (s in siglist) {
            if (s < 0 || s >= nsig) {
                eprintf("%s: invalid signal number, %d, in signal list\n", pname, s)
                exit(1)
            }
        }
    }
    val sl = siglist.toIntArray()
    val so = Array(nosig) { Siginfo() }

    for (k in 0 until ns) {
        f.read(ifile, 16, 15)
        if (vflag) printf("Signal %d label: '%s'\n", k, f.s())
        si[k].desc = f.s()
    }
    for (k in 0 until ns) {
        val j = f.read(ifile, 80, 80)
        if (vflag && j > 0) printf("Signal %d transducer type: '%s'\n", k, f.s())
    }
    for (k in 0 until ns) {
        f.read(ifile, 8, 8)
        if (vflag) printf("Signal %d physical dimension: '%s'\n", k, f.s())
        si[k].units = f.s()
    }
    for (k in 0 until ns) {
        f.read(ifile, 8, 8)
        if (vflag) printf("Signal %d physical minimum: '%s'\n", k, f.s())
        val v = CDouble(sigpmin[k]); sscanf(f.s(), "%lf", v); sigpmin[k] = v.v
    }
    for (k in 0 until ns) {
        f.read(ifile, 8, 8)
        if (vflag) printf("Signal %d physical maximum: '%s'\n", k, f.s())
        val v = CDouble(sigpmax[k]); sscanf(f.s(), "%lf", v); sigpmax[k] = v.v
    }
    for (k in 0 until ns) {
        f.read(ifile, 8, 8)
        if (vflag) printf("Signal %d digital minimum: '%s'\n", k, f.s())
        val v = CLong(sigdmin[k]); sscanf(f.s(), "%ld", v); sigdmin[k] = v.v
    }
    for (k in 0 until ns) {
        f.read(ifile, 8, 8)
        if (vflag) printf("Signal %d digital maximum: '%s'\n", k, f.s())
        val v = CLong(sigdmax[k]); sscanf(f.s(), "%ld", v); sigdmax[k] = v.v
    }

    for (k in 0 until ns) {
        if (sigpmax[k] == sigpmin[k]) {
            eprintf("gain for signal %d is undefined\n", k)
            continue
        }
        val s = si[k]
        s.adczero = ((sigdmax[k] + 1 + sigdmin[k]) / 2).toInt()
        var adcrange = sigdmax[k] - sigdmin[k]
        s.gain = adcrange.toDouble() / (sigpmax[k] - sigpmin[k])
        var j = 0
        while (adcrange > 1) {
            adcrange /= 2
            j++
        }
        s.adcres = j
        s.baseline = d2i(sigdmax[k].toDouble() - sigpmax[k] * s.gain + 1.0)
    }

    for (k in 0 until ns) {
        val j = f.read(ifile, 80, 80)
        if (vflag && j > 0) printf("Signal %d filtering information: '%s'\n", k, f.s())
    }
    for (k in 0 until ns) {
        f.read(ifile, 8, 8)
        if (vflag) printf("Signal %d number of samples per record: '%s'\n", k, f.s())
        val d = CDouble(sampfreqs[k]); sscanf(f.s(), "%lf", d); sampfreqs[k] = d.v
        val n = CInt(spb[k]); sscanf(f.s(), "%d", n); spb[k] = n.v
        sampfreqs[k] /= spr
    }
    for (k in 0 until ns) {
        val j = f.read(ifile, 32, 32)
        if (vflag && j > 0) printf("Signal %d free space: '%s'\n", k, f.s())
    }

    var sps = sampfreqs[sl[0]]
    for (k in 1 until sl.size) {
        val s = sl[k]
        if (sampfreqs[s] != sps) sps = edfGcd(sps, sampfreqs[s])
    }
    setsampfreq(sps)

    var bt = cformat("%02d:%02d:%02d %02d/%02d/%04d", hour.v, minute.v, second.v, day.v, month.v, year.v)
    if (bt.size > EDF_MAXFIELD) bt = bt.copyOf(EDF_MAXFIELD)
    setbasetime(bt)

    val fname = bcat(record, ".dat".latin1())
    var tspf = 0
    for ((k, s) in sl.withIndex()) {
        si[s].fname = fname.copyOf()
        si[s].fmt = 16
        si[s].spf = d2i(sampfreqs[s] / sps + 0.5)
        tspf += si[s].spf
        so[k] = si[s].copy()
    }

    val fpb = if (si[sl[0]].spf != 0) {
        val a = spb[sl[0]]; val b = si[sl[0]].spf
        if (b == -1) -a else a / b
    } else 0

    if (vflag) printf("\nOUTPUT:\nBase sampling frequency: %g Hz\n", sps)
    if (vflag) {
        for ((k, s) in sl.withIndex()) {
            val j = si[s].spf
            printf(" Signal %d samples per second: %g (%d sample%s per frame)\n", k, sampfreqs[s], j, if (j > 1) "s" else "")
        }
    }

    val vin = Array(ns) { ByteArray(if (spb[it] > 0) spb[it] * 2 else 0) }
    val vi = IntArray(nosig)
    var room = 0
    for (s in so) room += maxOf(s.spf, 0)
    val vout = IntArray(maxOf(room, maxOf(tspf, 0)))
    osigfopen(so, nosig)
    while (true) {
        var j = 0
        for (k in 0 until ns) {
            j = if (spb[k] > 0) ifile.fread(vin[k], 2, spb[k]) else 0
        }
        if (j == 0) break
        vi.fill(0)
        repeat(fpb) {
            var vo = 0
            for (jj in 0 until nosig) {
                val v = vin[sl[jj]]
                repeat(so[jj].spf) {
                    val p = vi[jj]
                    val b0 = if (p < v.size) v[p].toInt() else 0
                    val b1 = if (p + 1 < v.size) v[p + 1].toInt() else 0
                    vi[jj] += 2
                    val h: Int; val l: Int
                    if (bigEndian) { h = b0; l = b1 } else { h = b1; l = b0 }
                    vout[vo] = ((h shl 8) or (l and 0xff)).toShort().toInt()
                    vo++
                }
            }
            putvec(vout)
        }
    }
    ifile.close()

    newheader(record)
    wfdbquit()
    exit(0)
}
