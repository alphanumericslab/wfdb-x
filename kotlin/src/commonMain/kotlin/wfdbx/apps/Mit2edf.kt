// mit2edf: convert MIT format header and signal files to EDF (European
// Data Format) file (port of convert/mit2edf.c, through
// rust/src/bin/mit2edf.rs).
//
// As in the C program, the current date and time are used as the start of a
// record that has none. Where the C program has undefined behavior, this
// port uses: 0 for time and date fields that cannot be parsed; the first 50
// characters of a long record name for the default output file name; and it
// does not write header fields past the end of the header, divide by zero,
// or name a month outside 1-12 (DEC is used).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of convert/mit2edf.c from the WFDB Software
// Package 10.7.0, by George B. Moody. The translation follows the logic and
// behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: no built-in sampling frequency, gain or ADC
// resolution: the record must give the sampling frequency, and the gain and
// ADC resolution of every signal (the original assumed 250 Hz and 200 adu/mV,
// and guessed the resolution from the storage format); unspecified units are
// written as "nd" (the original wrote "mV"); --legacy, as the first argument,
// restores the original behavior. Each change is marked "wfdb-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/mit2edf.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2002-2014 George B. Moody; revised 2020 by Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private const val EDFMAXBLOCK = 61440L
private const val EDFHDRBLOCK = 256L
private const val EDFSAMPLEBYTES = 2L

private val MIT2EDF_MONTHS = arrayOf("JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC")

private val MIT2EDF_HELP = arrayOf(
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -h          print this usage summary",
    " -o EDFILE   write the specified European Data Format file (default:",
    "              RECORD.edf)",
    " -p          write the output as an EDF+ file",
    " -v          select verbose mode",
    "This program reads MIT-format signal and header files and writes an EDF",
    "file containing the same data.",
)

private fun mit2edfHelp(pname: ByteArray) {
    eprintf(MIT2EDF_HELP[0], pname)
    for (k in 1 until MIT2EDF_HELP.size) eprintf("%s\n", MIT2EDF_HELP[k])
}

/** The EDF header being built, with the current position. */
private class EdfHeader(n: Int) {
    val h = ByteArray(n) { ' '.code.toByte() }
    var pos = 0

    /** strncpy(header + pos, s, len), within the header. */
    fun put(s0: ByteArray, len: Int) {
        val s = cstr(s0)
        for (m in 0 until len) {
            if (pos + m >= h.size) break
            h[pos + m] = if (m < s.size) s[m] else 0
        }
    }

    fun put(s: String, len: Int) = put(s.latin1(), len)

    fun puts(s: ByteArray) = put(s, cstrlen(s))

    fun puts(s: String) = puts(s.latin1())
}

private fun guessAdcres(fmt: Int): Int = when (fmt) {
    524, 24 -> 24
    32 -> 32
    508, 80 -> 8
    212 -> 12
    310, 311 -> 10
    516, 16, 61, 160 -> 16
    else -> if (fmt >= 100 && fmt % 100 > 0 && fmt % 100 <= 32) fmt % 100 else 16
}

/** The mit2edf tool. */
fun Wfdb.mit2edfMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val legacy = wfdbx_get_legacy() != 0
    val argc = argv.size
    val pname = argv[0]
    var ofname0: ByteArray? = null
    var record0: ByteArray? = null
    var edfplusflag = false
    var vflag = false
    var blocksPerMinute = 0L
    var blocksPerHour = 0L

    var i = 1
    while (i < argc) {
        if (argv[i].at(0) == '-'.code) {
            when (argv[i].at(1).toChar()) {
                'h' -> {
                    mit2edfHelp(pname)
                    exit(0)
                }
                'o' -> {
                    i++
                    if (i < argc) ofname0 = cstr(argv[i])
                    else {
                        eprintf("%s: output file name must follow -o\n", pname)
                        exit(1)
                    }
                }
                'p' -> edfplusflag = true
                'r' -> {
                    i++
                    if (i < argc) record0 = cstr(argv[i])
                    else {
                        eprintf("%s: record name must follow -r\n", pname)
                        exit(1)
                    }
                }
                'v' -> vflag = true
                else -> {}
            }
        }
        i++
    }

    if (record0 == null) {
        mit2edfHelp(pname)
        exit(1)
    }
    var record: ByteArray = record0

    val ofname: ByteArray = if (ofname0 == null) {
        val q = record.lastIndexOf('/'.code.toByte()) + 1
        val tail = record.copyOfRange(q, record.size)
        bcat(tail.copyOf(minOf(tail.size, WFDB_MAXRNL)), ".edf".latin1())
    } else {
        if (edfplusflag) {
            val len = ofname0.size
            val p = ofname0.copyOfRange(maxOf(len - 4, 0), len)
            if (!beq(p, ".edf") && !beq(p, ".EDF")) {
                eprintf("%s: '%s' is not a valid EDF+ file name\n", pname, ofname0)
                eprintf(" EDF+ file names must end with '.edf' or '.EDF')\n")
                exit(1)
            }
        }
        ofname0
    }

    var nsig = isigopen(record, null, 0)
    if (nsig <= 0) exit(2)
    val si = Array(nsig) { Siginfo() }
    nsig = isigopen(record, si, nsig)
    if (nsig <= 0) exit(3)

    // wfdb-x: the sampling frequency, the gains and the ADC resolutions must be
    // specified (the C program assumed 250 Hz, 200 adu/mV and a resolution based
    // on the format, as legacy mode does).
    if (!legacy && sampfreq(null as ByteArray?) <= 0.0) {
        eprintf("%s: sampling frequency of record %s is not specified\n", pname, record)
        exit(3)
    }
    if (!legacy) {
        for (k in 0 until nsig) {
            val s = si[k]
            if (s.gain == 0.0) {
                eprintf("%s: signal %d of record %s is uncalibrated\n", pname, k, record)
                exit(3)
            }
            if (s.adcres < 1) {
                eprintf("%s: ADC resolution of signal %d of record %s is not specified\n", pname, k, record)
                exit(3)
            }
        }
    }
    val ns = nsig

    val ofile = WfdbFile.fopen(ofname, "wb")
    if (ofile == null) {
        eprintf("%s: can't create %s\n", pname, ofname)
        exit(4)
    }

    var ts = timstr(0)
    var startDateRecorded = true
    if (ts.at(0) != '['.code) {
        setbasetime(null as ByteArray?)
        ts = timstr(0)
        startDateRecorded = false
    }
    val hour = CInt(); val minute = CInt(); val second = CInt()
    val day = CInt(); val month = CInt(); val year = CInt()
    val nconv = sscanf(ts, "[%d:%d:%d %d/%d/%d", hour, minute, second, day, month, year)
    if (nconv != 6) {
        startDateRecorded = false
        day.v = 1
        month.v = 1
        year.v = 1985
    }

    var samplesPerFrame = 0
    for (s in si) samplesPerFrame += s.spf
    val framesPerSecond = strtim("1:0").toDouble() / 60.0
    var framesPerBlock = d2l(10.0 * framesPerSecond + 0.5)
    var bytesPerBlock = (EDFSAMPLEBYTES * samplesPerFrame.toLong()) * framesPerBlock
    while (bytesPerBlock > EDFMAXBLOCK) {
        framesPerBlock /= 10
        bytesPerBlock = (samplesPerFrame.toLong() * EDFSAMPLEBYTES) * framesPerBlock
    }
    var secondsPerBlock = framesPerBlock.toDouble() / framesPerSecond
    if (framesPerBlock < 1 && bytesPerBlock < EDFMAXBLOCK / 60) {
        framesPerBlock = strtim("1:0")
        bytesPerBlock = (EDFSAMPLEBYTES * samplesPerFrame.toLong()) * framesPerBlock
        secondsPerBlock = 60.0
    }

    if (bytesPerBlock > EDFMAXBLOCK) {
        eprintf("%s: can't convert record %s to EDF\n", pname, record)
        eprintf(" EDF blocks cannot be larger than %d bytes, but each input frame requires\n", EDFMAXBLOCK.toInt())
        eprintf(
            " %d bytes.  Use 'snip' to select a subset of the input signals, or use\n 'xform' to reduce the sampling frequency.\n",
            samplesPerFrame * EDFSAMPLEBYTES.toInt()
        )
        ofile.close()
        exit(5)
    }

    val nblocks: Long = (if (framesPerBlock != 0L) cdiv(strtim("e"), framesPerBlock) else 0L) + 1

    val dmax = IntArray(ns)
    val dmin = IntArray(ns)
    val pmax = DoubleArray(ns)
    val pmin = DoubleArray(ns)
    val hlen = (ns + 1) * EDFHDRBLOCK.toInt()
    val hd = EdfHeader(hlen)
    val v = IntArray(maxOf(samplesPerFrame, 0))
    val block = ByteArray(maxOf(bytesPerBlock, 0L).toInt())
    val blockp = LongArray(ns)

    if (vflag) {
        printf("Converting record %s to %s (%s mode)\n", record, ofname, if (edfplusflag) "EDF+" else "EDF")
    }

    for (k in 0 until ns) {
        val s = si[k]
        // wfdb-x: legacy mode: the resolution of the C program, based on the format
        if (legacy && s.adcres < 1) s.adcres = guessAdcres(s.fmt)
        val half = 1 shl ((s.adcres - 1) and 31)
        dmax[k] = s.adczero + half - 1
        dmin[k] = s.adczero - half
        pmax[k] = aduphys(k, dmax[k])
        pmin[k] = aduphys(k, dmin[k])
    }

    hd.put("0", 1)
    hd.pos += 8

    if (record.size > 80) record = record.copyOf(79)
    hd.puts(record)
    hd.pos += 80

    val buf = if (startDateRecorded) {
        val m = if (month.v in 1..12) month.v - 1 else 11
        cformat("Startdate %02d-%s-%d", day.v, MIT2EDF_MONTHS[m], year.v)
    } else {
        if (edfplusflag) eprintf("WARNING (%s): EDF+ requires start date (not specified)\n", pname)
        "Startdate not recorded".latin1()
    }
    hd.puts(buf)
    hd.pos += 80

    hd.put(cformat("%02d.%02d.%02d", day.v, month.v, year.v % 100), 8)
    hd.pos += 8
    hd.put(cformat("%02d.%02d.%02d", hour.v, minute.v, second.v), 8)
    hd.pos += 8

    hd.puts(cformat("%ld", (nsig.toLong() + 1) * EDFHDRBLOCK))
    hd.pos += 8

    if (edfplusflag) hd.put("EDF+C", 5)
    hd.pos += 44

    hd.puts(cformat("%ld", nblocks))
    hd.pos += 8

    var dbuf = cformat("%g", secondsPerBlock)
    if (dbuf.size > 8) dbuf = dbuf.copyOf(8)
    hd.puts(dbuf)
    hd.pos += 8

    hd.puts(cformat("%d", nsig))
    hd.pos += 4

    for (s in si) {
        var d = s.desc ?: ByteArray(0)
        if (d.size > 16) d = d.copyOf(16)
        s.desc = d
        hd.puts(d)
        hd.pos += 16
    }
    for (k in 0 until ns) {
        hd.puts("transducer type not recorded")
        hd.pos += 80
    }
    for (s in si) {
        // wfdb-x: unspecified units are written as "nd" (C, legacy mode: mV)
        var u = s.units ?: (if (legacy) "mV" else "nd").latin1()
        if (u.size > 8) u = u.copyOf(8)
        s.units = u
        hd.puts(u)
        hd.pos += 8
    }
    for (x in pmin) { hd.puts(cformat("%g", x)); hd.pos += 8 }
    for (x in pmax) { hd.puts(cformat("%g", x)); hd.pos += 8 }
    for (x in dmin) { hd.puts(cformat("%d", x)); hd.pos += 8 }
    for (x in dmax) { hd.puts(cformat("%d", x)); hd.pos += 8 }
    for (k in 0 until ns) {
        hd.puts("prefiltering not recorded")
        hd.pos += 80
    }
    for (s in si) {
        hd.puts(cformat("%ld", framesPerBlock * s.spf.toLong()))
        hd.pos += 8
    }

    val header = hd.h
    ofile.write(header)

    for ((k, b) in header.withIndex()) {
        val c = b.toInt()
        if (c < 32 || c > 126) {
            eprintf("WARNING (%s): output contains an invalid character, %d, at byte %d\n", pname, c, k)
        }
    }

    if (vflag) {
        printf(" Header block size: %d bytes\n", (nsig + 1) * EDFHDRBLOCK.toInt())
        printf(
            " Data block size: %g second%s (%ld frame%s or %ld bytes)\n",
            secondsPerBlock, if (secondsPerBlock == 1.0) "" else "s",
            framesPerBlock, if (framesPerBlock == 1L) "" else "s", bytesPerBlock
        )
        val es = timstr(strtim("e"))
        var k = 0
        while (k < es.size && es[k] == ' '.code.toByte()) k++
        printf(
            " Recording length: %s (%ld data blocks, %ld frames, %ld bytes)\n",
            es.copyOfRange(k, es.size), nblocks, nblocks * framesPerBlock, nblocks * bytesPerBlock
        )
        printf(
            " Total length of file to be written: %ld bytes\n",
            (nsig.toLong() + 1) * EDFHDRBLOCK + nblocks * bytesPerBlock
        )
        blocksPerMinute = d2l(60.0 / secondsPerBlock)
        blocksPerHour = blocksPerMinute * 60
    }

    var n = 1L
    while (n <= nblocks) {
        if (ns > 0) blockp[0] = 0
        for (j in 1 until ns) {
            blockp[j] = blockp[j - 1] + (EDFSAMPLEBYTES * framesPerBlock) * si[j - 1].spf.toLong()
        }
        var fr = 0L
        while (fr < framesPerBlock) {
            fr++
            if (nsig != getframe(v)) v.fill(WFDB_INVALID_SAMPLE)
            var vp = 0
            for (j in 0 until ns) {
                repeat(si[j].spf) {
                    val x = v[vp]
                    vp++
                    val b = blockp[j]
                    if (b >= 0 && b < block.size) block[b.toInt()] = (x and 0xff).toByte()
                    if (b + 1 >= 0 && b + 1 < block.size) block[(b + 1).toInt()] = ((x shr 8) and 0xff).toByte()
                    blockp[j] += EDFSAMPLEBYTES
                }
            }
        }
        ofile.write(block)
        if (vflag) {
            if (blocksPerMinute != 0L && cmod(n, blocksPerMinute) == 0L) {
                printf(".")
                Stdout.flush()
            }
            if (blocksPerHour != 0L && cmod(n, blocksPerHour) == 0L) printf("\n")
        }
        n++
    }
    ofile.close()
    printf("\n")

    if (edfplusflag) {
        eprintf(
            "\nWARNING (%s): EDF+ requires the subject's gender, birthdate, and name, as\n well as additional information about the recording that is not usually\n available.  This information is not saved in the output file even if\n available.  EDF+ also requires the use of standard names for signals and\n for physical units;  these requirements are not enforced by this program.\n To make the output file fully EDF+ compliant, its header must be edited\n manually.\n",
            pname
        )
        if (!si.any { beq(it.desc, "EDF-Annotations") }) {
            eprintf("\nWARNING:  The output file does not include EDF annotations, which are\n required for EDF+.\n")
        }
    }

    wfdbquit()
    exit(0)
}
