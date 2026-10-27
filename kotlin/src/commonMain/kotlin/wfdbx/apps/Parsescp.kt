// parsescp: parse an SCP-ECG file (read from the standard input) (port of
// convert/parsescp.c, through rust/src/bin/parsescp.rs).
//
// parsescp converts SCP-ECG files produced by SpaceLabs/Burdick ECG carts
// into more easily usable formats:
//
//   RECORD.des (text): description (age, sex, recording bandwidth,
//     measurements, diagnoses)
//   RECORD.ecg (binary): reconstructed ECGs
//   RECORD.key (text): patient's name and ID (medical record number)
//   RECORD.txt (text): reconstructed ECGs (with -v)
//   RECORD.dat, RECORD.hea: WFDB-format record (with -w)
//
// With -a, an anonymized copy of the input is written to the standard
// output instead.
//
// The input is held in one byte buffer and the C program's pointers into it
// are represented by offsets. Behaviors of the C program that are undefined
// (on defective inputs) are resolved as in the other wfdb-x implementations
// (see docs/KNOWN_C_BEHAVIORS.md): bytes beyond the end of the input are
// read as 0; signal arrays have at least 5000 samples and samples beyond
// the end of a lead are 0; missing subtraction zones are ignored and
// samples outside the arrays are skipped; strings copied into fixed-size
// buffers are truncated; a missing date or time of acquisition is left
// empty, and an invalid month is printed as ???. Samples are written in
// little-endian byte order, as the C program does on x86.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Kotlin translation of convert/parsescp.c from the WFDB Software
// Package 10.7.0, by George B. Moody and Edna S. Moody. The translation
// follows the logic and behavior of the original program, but it is new code,
// not the original C code.
//
// Changes from the original: the record is written with the sampling frequency
// given in the SCP file, and is not written if the file gives none (the
// original always wrote 500 Hz); signals and reference beats that could not be
// allocated, and samples beyond the end of a signal shorter than lead 0, are
// read as absent or as zeros (undefined behavior in the original); --legacy,
// as the first argument, restores the original behavior. Each change is marked
// "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/parsescp.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2000-2014 George B. Moody and Edna S. Moody; revised
//   2016-2020 by Benjamin Moody.
// Kotlin translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx.apps

import wfdbx.*
import wfdbx.cstd.*

private const val SCP_VERSION_STRING = "#ECG/1.0"
private const val SCP_INVALID_SAMPLE: Short = -32768

/** Requests for more elements than this are treated as allocation failures. */
private const val SCP_MAXALLOC: Long = 1L shl 28

/** Signal arrays have at least this many elements. */
private const val SCP_MINSIGLEN: Long = 5000

private const val SCP_CRCLEN = 2L
private const val SCP_RECHDRLEN = 6
private const val SCP_SECHDRLEN = 16L
private const val SCP_SEC_ID = 2L
private const val SCP_SEC_LEN = 4L
private const val SCP_SEC_VERSION = 8L
private const val SCP_SEC_PROTOCOL = 9L
private const val SCP_SECMINLEN = 8L
private const val SCP_SCPECG_POS = 10L
private const val SCP_SECPTRLEN = 10L
private const val SCP_TAGHDRLEN = 3L
private const val SCP_TAG_END = 255
private const val SCP_AXIS_UNDEF = 999
private const val SCP_HT_DEFAULT_ONLY = 19999
private const val SCP_MAXAGE = 90

/** Unsigned comparison of 64-bit values (a < b). */
private fun ult(a: Long, b: Long): Boolean = (a xor Long.MIN_VALUE) < (b xor Long.MIN_VALUE)

/** C conversion of double to short (via a 32-bit int). */
private fun d2s(x: Double): Short = d2i(x).toShort()

/** calloc(n, sizeof(short)) for a signal (n unsigned); null if allocation fails. */
private fun newsig(n: Long): ShortArray? {
    if (ult(SCP_MAXALLOC, n)) return null
    return ShortArray(maxOf(n, SCP_MINSIGLEN).toInt())
}

/** Reference beat subtraction zone. */
private class Subzone(var ztype: Int, val t0: Long, val t1: Long, val t2: Long)

private const val M_LEADID = 0
private const val M_VLEN = 1
private const val NMEAS = 33

private val SCP_MONTH = arrayOf(
    "January", "February", "March", "April", "May", "June", "July",
    "August", "September", "October", "November", "December",
)

private val SCP_LEADNAME = arrayOf(
    "<Unspecified lead>", "I", "II", "V1", "V2",
    "V3", "V4", "V5", "V6", "V7",
    "V2R", "V3R", "V4R", "V5R", "V6R",
    "V7R", "X", "Y", "Z", "CC5",
    "CM5", "Left Arm", "Right Arm", "Left Leg", "I (Frank)",
    "E", "C", "A", "M", "F",
    "H", "I-cal", "II-cal", "V1-cal", "V2-cal",
    "V3-cal", "V4-cal", "V5-cal", "V6-cal", "V7-cal",
    "V2R-cal", "V3R-cal", "V4R-cal", "V5R-cal", "V6R-cal",
    "V7R-cal", "X-cal", "Y-cal", "Z-cal", "CC5-cal",
    "CM5-cal", "Left Arm-cal", "Right Arm-cal", "Left Leg-cal", "I-cal (Frank)",
    "E-cal", "C-cal", "A-cal", "M-cal", "F-cal",
    "H-cal", "III", "aVR", "aVL", "aVF",
    "-aVR", "V8", "V9", "V8R", "V9R",
    "D (Nehb - Dorsal)", "A (Nehb - Anterior)", "J (Nehb - Inferior",
    "Defibrillator lead: anterior-lateral", "External pacing lead: anterior-posterior",
    "A1 (Auxiliary unipolar lead 1)", "A2 (Auxiliary unipolar lead 2)",
    "A3 (Auxiliary unipolar lead 3)", "A4 (Auxiliary unipolar lead 4)", "V8-cal",
    "V9-cal", "V8R-cal", "V9R-cal", "D-cal (Nehb - Dorsal)", "A-cal (Nehb - Anterior)",
    "J-cal (Nehb - Inferior)",
)

private val SCP_MEASROWS: Array<Pair<String, Int>> = arrayOf(
    "\nP duration    ms" to 2,
    "\nPR interval   ms" to 3,
    "\nQRS duration  ms" to 4,
    "\nQT interval   ms" to 5,
    "\nQ duration    ms" to 6,
    "\nR duration    ms" to 7,
    "\nS duration    ms" to 8,
    "\nR' duration   ms" to 9,
    "\nS' duration   ms" to 10,
    "\nQ amplitude   uV" to 11,
    "\nR amplitude   uV" to 12,
    "\nS amplitude   uV" to 13,
    "\nJ amplitude   uV" to 16,
    "\nP+ amplitude  uV" to 17,
    "\nP- amplitude  uV" to 18,
    "\nT+ amplitude  uV" to 19,
    "\nT- amplitude  uV" to 20,
    "\nST slope    uV/s" to 21,
    "\nP morphology  --" to 22,
    "\nT morphology  --" to 23,
    "\nIsoelec (I)   ms" to 24,
    "\nIsoelec (K)   ms" to 25,
    "\nIntrins defl  ms" to 26,
    "\nQuality       --" to 27,
    "\nST (J+20ms)   uV" to 28,
    "\nST (J+60ms)   uV" to 29,
    "\nST (J+80ms)   uV" to 30,
    "\nST (J+RRm/16) uV" to 31,
    "\nST (J+RRm/8)  uV" to 32,
)

/** The default (SCP standard) Huffman table: pattern, suffix bits, base value. */
private val SCP_HTDEFAULT: Array<IntArray> = arrayOf(
    intArrayOf(0, 0, 0),
    intArrayOf(4, 0, 1),
    intArrayOf(5, 0, -1),
    intArrayOf(0xc, 0, 2),
    intArrayOf(0xd, 0, -2),
    intArrayOf(0x1c, 0, 3),
    intArrayOf(0x1d, 0, -3),
    intArrayOf(0x3c, 0, 4),
    intArrayOf(0x3d, 0, -4),
    intArrayOf(0x7c, 0, 5),
    intArrayOf(0x7d, 0, -5),
    intArrayOf(0xfc, 0, 6),
    intArrayOf(0xfd, 0, -6),
    intArrayOf(0x1fc, 0, 7),
    intArrayOf(0x1fd, 0, -7),
    intArrayOf(0x3fc, 0, 8),
    intArrayOf(0x3fd, 0, -8),
    intArrayOf(0x3fe, 8, 0),
    intArrayOf(0x3ff, 16, 0),
)

private fun isprintC(c: Int): Boolean = c in 32..126

private fun prval(out: ByteVec, v: Int) {
    when (v) {
        29999 -> out.addString("  n/comp")
        29998 -> out.addString("     rej")
        19999 -> out.addString("  absent")
        else -> sprintfInto(out, "%8d", arrayOf(v))
    }
}

/** Writes n samples of s, beginning at sample i0, as little-endian 16-bit integers. */
private fun writeSamples(f: WfdbFile, s: ShortArray, i0: Int, n: Int) {
    val end = minOf(i0 + n, s.size)
    if (i0 >= end) return
    val buf = ByteArray(2 * (end - i0))
    var k = 0
    for (j in i0 until end) {
        val v = s[j].toInt()
        buf[k++] = v.toByte()
        buf[k++] = (v shr 8).toByte()
    }
    f.write(buf)
}

private fun wsum3(a: Double, wa: Double, bv: Double, wb: Double, c: Double, wc: Double): Double {
    val x = a * wa
    val y = bv * wb
    val z = c * wc
    val r = x + y
    return r + z
}

private fun wsum4(a: Double, wa: Double, bv: Double, wb: Double, c: Double, wc: Double, d: Double, wd: Double): Double {
    val r = wsum3(a, wa, bv, wb, c, wc)
    val z = d * wd
    return r + z
}

private fun out(v: ByteVec) = Stdout.write(v.bytes, 0, v.size)

private fun cut(s: ByteArray, n: Int): ByteArray = if (s.size > n) s.copyOf(n) else s

private const val VT_TEXT = 0
private const val VT_DATE = 1
private const val VT_TIME = 2
private const val VT_B1 = 3
private const val VT_B2 = 4
private const val VT_B2B1 = 5
private const val VT_BN = 6
private const val VT_MIXED = 7

/** The state of the program (the global and static variables of C). */
private class Scp(val wf: Wfdb, val pname: ByteArray) {
    var bflag = 0
    var fflag = 0
    var tflag = 0
    var vflag = 0
    var xflag = 0
    var shift = 0
    var data = ByteArray(0)
    var nleads = -1
    var nqrs = -1
    var nsamp = ArrayList<Long>() // unsigned
    var rblen = 0L
    var rblenms = 0L
    var fcM = 0
    var gref = 0.0
    var gres = 0.0
    var sfreq = -1.0
    var recdate = ByteArray(0)
    var rectime = ByteArray(0)
    var recname = ByteArray(0)
    var patientName = ByteArray(0)
    var referringDr = ByteArray(0)
    var comments = ByteArray(0)
    var patientId = ByteArray(0)
    var age = -1
    var sex = -1
    var rrint = -1
    var pon = -1
    var pend = -1
    var qrson = -1
    var qrsend = -1
    var tend = -1
    var paxis = SCP_AXIS_UNDEF
    var qrsaxis = SCP_AXIS_UNDEF
    var taxis = SCP_AXIS_UNDEF
    var blfilt = -1
    var lpfilt = -1
    var filterBit = -1
    var tdevid = -1
    var tinst = -1
    var tdept = -1
    var dept = -1L
    var inst = -1L
    var stmnts = -1
    val report = LongArray(1200) { -1L }
    var lflag = 0
    var wflag = 0
    var zflag = 0
    var aflag = 0
    val skip = IntArray(12)
    var nout = 0L // unsigned
    var subz = ArrayList<Subzone?>()
    var ecg = ArrayList<ShortArray?>()
    var haveEcg = false
    var refbeat = ArrayList<ShortArray?>()
    var leadI = -1
    var leadII = -1
    var leadIII = -1
    var avr = -1
    var avf = -1
    var avl = -1
    var v1 = -1
    var v2 = -1
    var v3 = -1
    var v4 = -1
    var v5 = -1
    var v6 = -1
    var ecgmeas = ArrayList<ShortArray>()
    var nsecleads = 0
    // static variables of getbits() and Huffdecode()
    var wb = 0
    var hdx = 0
    var hx = 0
    var hxx = 0
    var hxxx = 0
    var hxout = 0
    var zbuf = ShortArray(5000)

    // ---- access to the input buffer ----

    fun b(off: Long): Int = if (off >= 0 && off < data.size) data[off.toInt()].toInt() and 0xff else 0

    fun get16(off: Long): Int = b(off) or (b(off + 1) shl 8)

    fun put16(v: Int, off: Long) {
        if (off >= 0 && off < data.size) data[off.toInt()] = v.toByte()
        val o1 = off + 1
        if (o1 >= 0 && o1 < data.size) data[o1.toInt()] = (v shr 8).toByte()
    }

    /** A 32-bit value, sign-extended (as C's *p << 24 is a signed int); unsigned 64-bit in Rust. */
    fun get32(off: Long): Long = (b(off) or (b(off + 1) shl 8) or (b(off + 2) shl 16) or (b(off + 3) shl 24)).toLong()

    fun cstrAt(off: Long): ByteArray {
        if (off < 0 || off >= data.size) return ByteArray(0)
        val o = off.toInt()
        var e = o
        while (e < data.size && data[e].toInt() != 0) e++
        return data.copyOfRange(o, e)
    }

    fun getcrc(off0: Long, length0: Long): Int {
        var off = off0
        var length = length0
        var crchigh = 0xff
        var crclow = 0xff
        while (length > 0) {
            length--
            var a = (b(off) xor crchigh) and 0xff
            off++
            crchigh = a
            a = a ushr 4
            a = a xor crchigh
            crchigh = crclow
            crclow = a
            var bb = (a and 0xf) shl 4
            a = a ushr 4
            a = (a or bb) and 0xff
            bb = a
            a = ((a shl 1) or (a ushr 7)) and 0xff
            a = a and 0x1f
            crchigh = crchigh xor a
            a = bb and 0xf0
            crchigh = crchigh xor a
            bb = ((bb shl 1) or (bb ushr 7)) and 0xff
            bb = bb and 0xe0
            crclow = crclow xor bb
        }
        return ((crchigh and 0xff) shl 8) or (crclow and 0xff)
    }

    fun crcok(off: Long, length: Long, crcref: Int, description: ByteArray): Int {
        val crc = getcrc(off, length)
        if (crc == crcref) {
            if (vflag != 0) printf("%s: correct (%d)\n", description, crc)
            return 1
        }
        if (vflag != 0) printf("%s: error (calculated: %d, expected: %d)\n", description, crc, crcref)
        if (fflag != 0) return 0
        exit(1)
    }

    fun sigp(k: Long): ShortArray? = if (k < 0 || k >= ecg.size) null else ecg[k.toInt()]

    fun srcsig(k: Long): ShortArray = sigp(k)?.copyOf() ?: ShortArray(maxOf(nout, SCP_MINSIGLEN).toInt())

    fun nsampk(k: Long): Long = if (k < 0 || k >= nsamp.size) 0L else nsamp[k.toInt()]

    fun sigr(k: Long): ShortArray = sigp(k) ?: ShortArray(SCP_MINSIGLEN.toInt())

    fun sampleAt(k: Long, i: Long): Int {
        val s = sigp(k) ?: return 0
        return if (ult(i, s.size.toLong())) s[i.toInt()].toInt() else 0
    }

    fun order(): LongArray = longArrayOf(
        leadI.toLong(), leadII.toLong(), leadIII.toLong(), avr.toLong(), avf.toLong(), avl.toLong(),
        v1.toLong(), v2.toLong(), v3.toLong(), v4.toLong(), v5.toLong(), v6.toLong(),
    )

    // ---- output ----

    fun lowpass() {
        for (i in 0 until maxOf(nleads, 0).toLong()) {
            val inp = sigp(i) ?: continue
            val n = nsampk(i)
            val outs = newsig(n)
            if (outs == null) {
                eprintf("Insufficient memory for filtering\n")
                break
            }
            val nin = inp.size.toLong()
            val nout2 = outs.size.toLong()
            fun xs(k: Long): Int = if (ult(k, nin)) inp[k.toInt()].toInt() else 0
            fun x(k: Long): Double = xs(k).toDouble()
            fun put(k: Long, v: Short) {
                if (ult(k, nout2)) outs[k.toInt()] = v
            }
            put(0, d2s(wsum3(x(0), 0.67, x(1), 0.22, x(2), 0.11)))
            put(1, d2s(wsum4(x(0), 0.33, x(1), 0.34, x(2), 0.22, x(3), 0.11)))
            val nm2 = n - 2
            val jend = if (ult(nm2, nout2)) nm2 else nout2
            var j = 2L
            while (ult(j, jend)) {
                put(
                    j, d2s(
                        wsum3(
                            x(j), 0.34, (xs(j - 1) + xs(j + 1)).toDouble(), 0.22,
                            (xs(j - 2) + xs(j + 2)).toDouble(), 0.11
                        )
                    )
                )
                j++
            }
            put(j, d2s(wsum4(x(j - 2), 0.11, x(j - 1), 0.22, x(j), 0.34, x(j + 1), 0.33)))
            j++
            put(j, d2s(wsum3(x(j - 2), 0.11, x(j - 1), 0.22, x(j), 0.67)))
            ecg[i.toInt()] = outs
        }
    }

    fun precgmeas(): ByteVec {
        val o = ByteVec()
        o.addString("Parameter  Units")
        for (m in ecgmeas) {
            val id = m[M_LEADID].toInt()
            if (id in 1..85) sprintfInto(o, "%8s", arrayOf(SCP_LEADNAME[id]))
            else sprintfInto(o, "  <%4d>", arrayOf(id))
        }
        for ((label, field) in SCP_MEASROWS) {
            o.addString(label)
            for (m in ecgmeas) prval(o, m[field].toInt())
        }
        o.add('\n'.code)
        return o
    }

    fun writeWfdbRecord(): Int {
        val filename = bcat(recname, ".dat".latin1())
        val wleadname = arrayOf("I", "II", "III", "aVR", "aVF", "aVL", "V1", "V2", "V3", "V4", "V5", "V6")
        val v = IntArray(12)
        val ord = order()
        val legacy = wf.wfdbx_get_legacy() != 0
        // wfdb-x: the record is written at the sampling frequency of the SCP file,
        // and not written if the file gives none (the C program always wrote 500 Hz,
        // as legacy mode does).
        if (!legacy) {
            if (sfreq <= 0.0) {
                eprintf("%s: sampling frequency not specified; record %s not written\n", pname, recname)
                return 0
            }
            wf.setsampfreq(sfreq)
        }
        if (wf.newheader(recname) < 0) return 0
        if (legacy) wf.setsampfreq(500.0)

        val s = Array(12) {
            Siginfo(
                fname = filename.copyOf(), desc = wleadname[it].latin1(), units = "mV".latin1(),
                fmt = 16, gain = 200.0, adcres = 16
            )
        }
        if (wf.osigfopen(s, 12) < 12) return 0
        wf.setbasetime(bcat(recdate, " ".latin1(), rectime, "\n".latin1()))

        var i = 0L
        while (ult(i, nout)) {
            for (k in 0 until 12) v[k] = sampleAt(ord[k], i)
            if (wf.putvec(v) < 0) break
            i++
        }
        wf.newheader(recname)
        val info = cformat(
            "<age>: %d <sex>: %c", if (age < SCP_MAXAGE) age else SCP_MAXAGE,
            when (sex) {
                1 -> 'M'.code
                2 -> 'F'.code
                else -> '?'.code
            }
        )
        wf.putinfo(info)
        wf.wfdbquit()
        return 1
    }

    fun writeOutput(): Int {
        if (recname.isEmpty()) recname = "ecg".latin1()
        val rn = recname
        val dname = bcat(rn, ".des".latin1())
        val ename = bcat(rn, ".ecg".latin1())
        val kname = bcat(rn, ".key".latin1())
        val tname = bcat(rn, ".txt".latin1())
        val dfile = WfdbFile.fopen(dname, "wb")
        if (dfile == null) {
            eprintf("%s: can't create '%s'\n", pname, dname)
            return 0
        }
        val efile = WfdbFile.fopen(ename, "wb")
        if (efile == null) {
            dfile.close()
            eprintf("%s: can't create '%s'\n", pname, ename)
            return 0
        }
        val kfile = WfdbFile.fopen(kname, "wb")
        if (kfile == null) {
            dfile.close()
            efile.close()
            eprintf("%s: can't create '%s'\n", pname, kname)
            return 0
        }
        var tfile: WfdbFile? = null
        if (vflag != 0) {
            tfile = WfdbFile.fopen(tname, "wb")
            if (tfile == null) {
                dfile.close()
                efile.close()
                kfile.close()
                eprintf("%s: can't create '%s'\n", pname, tname)
                return 0
            }
        }

        dfile.printf("%s description\n", SCP_VERSION_STRING)
        dfile.printf("Record: %s (%s %s)\n", rn, recdate, rectime)
        dfile.printf("Age: %d\n", age)
        dfile.printf("Sex: ")
        when (sex) {
            1 -> dfile.printf("M\n")
            2 -> dfile.printf("F\n")
            0 -> dfile.printf("not known\n")
            9 -> dfile.printf("unspecified\n")
            else -> dfile.printf("<error>\n")
        }
        dfile.printf("Referring Dr: %s\n", referringDr)
        dfile.printf("Comments: %s\n", comments)
        if (tdevid == 0) dfile.printf("Cart ID: <missing>\n") else dfile.printf("Cart ID: %d\n", tdevid)
        val sdept = if (dept < 0) "<missing>".latin1() else cstrAt(dept)
        dfile.printf("Department: %s\n", sdept)
        if (tdept == 0) dfile.printf("Department #: <missing>\n") else dfile.printf("Department #: %s\n", sdept)
        val sinst = if (inst < 0) "<missing>".latin1() else cstrAt(inst)
        dfile.printf("Institution: %s\n", sinst)
        if (tinst == 0) dfile.printf("Institution #: <missing>\n") else dfile.printf("Institution #: %d\n", tinst)

        for (i in 0 until maxOf(stmnts, 0)) {
            val r = report[i]
            val s = if (r < 0) "(null)".latin1() else cstrAt(r)
            dfile.printf("Report %d: %s\n", i, s)
        }

        dfile.printf("Bandwidth: %g-%d Hz\n", blfilt.toDouble() * 0.0001, lpfilt)
        dfile.printf("Filtering:")
        if (filterBit and 1 != 0) dfile.printf(" 60 Hz notch")
        if (filterBit and 2 != 0) dfile.printf(" 50 Hz notch")
        if (filterBit and 4 != 0) dfile.printf(" Artifact filter")
        if (filterBit and 8 != 0) dfile.printf(" Baseline filter")
        if (filterBit and 0xf0 != 0) dfile.printf(" <undefined>")
        if (filterBit == 0) dfile.printf(" <not specified>")
        dfile.printf("\n\n")

        dfile.printf("RR interval: %d\n", rrint)
        dfile.printf("P onset: %d\n", pon)
        dfile.printf("P end: %d\n", pend)
        dfile.printf("QRS onset: %d\n", qrson)
        dfile.printf("QRS end: %d\n", qrsend)
        dfile.printf("T end: %d\n", tend)
        dfile.printf("P axis: %d\n", paxis)
        dfile.printf("QRS axis: %d\n", qrsaxis)
        dfile.printf("T axis: %d\n", taxis)

        val m = precgmeas()
        dfile.write(m.bytes, 0, m.size)
        dfile.close()

        kfile.printf("%s key\n", SCP_VERSION_STRING)
        kfile.printf("Record: %s (%s %s)\n", rn, recdate, rectime)
        kfile.printf("Name: %s\n", patientName)
        kfile.printf("MRN: %s\n", patientId)
        kfile.close()

        if (zflag != 0) {
            for (s in 0 until maxOf(nleads, 0).toLong()) {
                val ns = nsampk(s)
                val buf = zbuf
                val sig = sigp(s) ?: continue
                val imax = if (ult(5000, ns)) 5000 else ns.toInt()
                for (i in 0 until imax) buf[i] = if (i < sig.size) sig[i] else 0
                buf.sort(0, imax)
                val med = buf[imax / 2].toInt()
                val k = ns - 1
                if (k != 0L && ult(k, sig.size.toLong()) && sig[k.toInt()].toInt() == 0) {
                    sig[k.toInt()] = sig[k.toInt() - 1]
                }
                var ii = 0L
                while (ult(ii, nout) && ii < sig.size) {
                    val v = (sig[ii.toInt()].toInt() - med).toShort()
                    sig[ii.toInt()] = v
                    if (v < -2000 || v > 2000) sig[ii.toInt()] = SCP_INVALID_SAMPLE
                    ii++
                }
            }
        }

        if (wflag != 0) writeWfdbRecord()

        val ord = order()

        if (tfile != null) {
            if (vflag > 1) {
                tfile.printf("samp#      I     II    III    aVR    aVF    aVL     V1     V2     V3     V4     V5     V6")
            }
            val line = ByteVec(128)
            var i = 0L
            while (ult(i, nout)) {
                line.clear()
                sprintfInto(line, "%5d", arrayOf(i.toInt()))
                for (o in ord) sprintfInto(line, "%7d", arrayOf(sampleAt(o, i)))
                line.add('\n'.code)
                tfile.write(line.bytes, 0, line.size)
                i++
            }
            tfile.close()
        }

        val prolog = ByteVec(512)
        prolog.addString(SCP_VERSION_STRING)
        prolog.addString(" signals\nRecord: ")
        prolog.addAll(rn)
        prolog.addString(" (")
        prolog.addAll(recdate)
        prolog.add(' '.code)
        prolog.addAll(rectime)
        prolog.addString(")\n")
        if (lflag != 0) {
            prolog.addString("Low-pass filtered\n")
            lowpass()
        }
        val pb = prolog.toByteArray().copyOf(512)
        efile.write(pb)
        val rows = arrayOf(
            intArrayOf(leadI, avr, v1, v4),
            intArrayOf(leadII, avl, v2, v5),
            intArrayOf(leadIII, avf, v3, v6),
        )
        for (row in rows) {
            for ((k, l) in row.withIndex()) writeSamples(efile, sigr(l.toLong()), 1250 * k, 1250)
        }
        writeSamples(efile, sigr(leadII.toLong()), 0, 5000)
        efile.close()
        return 1
    }

    // ---- sections ----

    fun hexdump(p: Long, len: Long) {
        printf("Hex dump of data area:\n\n")
        var i = 0L
        while (i < len) {
            if (i % 16 == 0L) printf("\n%4d:  ", i.toInt())
            printf(" %2x", b(p + i))
            i++
        }
        printf("\n\n")
    }

    fun section0(p0: Long, len0: Long): Int {
        var p = p0
        var len = len0
        val id = "SCPECG"
        var matched = true
        for (k in id.indices) {
            if (b(p + SCP_SCPECG_POS + k) != id[k].code) {
                matched = false
                break
            }
        }
        if (!matched && vflag != 0) printf(" Warning: SCPECG identifier is missing in header\n")
        p += SCP_SECHDRLEN
        len -= SCP_SECHDRLEN
        if (len < SCP_SECPTRLEN) {
            if (vflag != 0) printf(" Error: section 0 contains no data\n")
            return 0
        }
        while (len > 0) {
            val secId = get16(p)
            val secLen = get32(p + 2)
            val secIndex = get32(p + 6)
            if (vflag != 0) {
                printf("  Section %2d:%6lld bytes beginning at byte %6lld\n", secId, secLen, secIndex)
            }
            len -= SCP_SECPTRLEN
            p += SCP_SECPTRLEN
        }
        if (len < 0) {
            if (vflag != 0) printf(" Error: section 0 overlaps the next section\n")
            return 0
        }
        return 1
    }

    fun censor(p0: Long, len0: Int, c: Int) {
        var p = p0
        var len = len0
        while (true) {
            len = (len - 1) and 0xffff
            if (len == 0) break
            if (p >= 0 && p < data.size) data[p.toInt()] = c.toByte()
            p++
        }
        if (p >= 0 && p < data.size) data[p.toInt()] = 0
    }

    fun section1(p0: Long, len0: Long): Int {
        var p = p0
        var len = len0
        var tpatid = -1L
        var trefdr = -1L
        var tcomments = -1L
        var tdate = -1L
        var ttime = -1L
        var pyob = -1L
        var firstname = -1L
        var lastname = -1L
        val pSave = p
        val lenSave = len
        val v = vflag != 0
        val a = aflag != 0

        p += SCP_SECHDRLEN
        len -= SCP_SECHDRLEN
        if (len < SCP_TAGHDRLEN) {
            if (v) printf(" Error: section 1 contains no data\n")
            return 0
        }

        fun say(s: String) {
            if (v) printf(s)
        }

        while (len > 2) {
            val tag = b(p)
            if (tag == SCP_TAG_END) break
            var vlen = get16(p + 1)
            if (vlen.toLong() > len) {
                if (v) printf(" Error: tagged field overlaps next section\n")
                return 0
            }
            val vtype: Int
            val d = p + SCP_TAGHDRLEN
            when (tag) {
                0 -> {
                    say("\n  Last name\n"); vtype = VT_TEXT
                    lastname = d
                    if (a) censor(lastname, vlen, 'x'.code)
                }
                1 -> {
                    say("\n  First name\n"); vtype = VT_TEXT
                    firstname = d
                    if (a) censor(firstname, vlen, 'x'.code)
                }
                2 -> {
                    say("\n  Patient ID number\n"); vtype = VT_TEXT
                    tpatid = d
                    if (a) censor(tpatid, vlen, '0'.code)
                }
                3 -> {
                    say("\n  Second last name\n"); vtype = VT_TEXT
                    if (a) censor(d, vlen, 'x'.code)
                }
                4 -> {
                    say("\n  Age\n"); vtype = VT_B2B1
                    age = get16(d)
                    if (a && age > SCP_MAXAGE) put16(SCP_MAXAGE, d)
                }
                5 -> {
                    say("\n  Date of birth\n"); vtype = VT_DATE
                    if (a) {
                        pyob = d
                        put16(257, d + 2)
                    }
                }
                6 -> { say("\n  Height\n"); vtype = VT_B2B1 }
                7 -> { say("\n  Weight\n"); vtype = VT_B2B1 }
                8 -> {
                    say("\n  Sex\n"); vtype = VT_B1
                    sex = b(d)
                }
                9 -> { say("\n  Race\n"); vtype = VT_B1 }
                10 -> { say("\n  Drug\n"); vtype = VT_MIXED }
                11 -> { say("\n  Systolic blood pressure\n"); vtype = VT_B2 }
                12 -> { say("\n  Diastolic blood pressure\n"); vtype = VT_B2 }
                13 -> { say("\n  Diagnosis or referral indication\n"); vtype = VT_TEXT }
                14 -> {
                    say("\n  ID of the acquiring device\n")
                    tdevid = get16(d + 4)
                    tinst = get16(d)
                    tdept = get16(d + 2)
                    if (v) {
                        printf("   Institution number: %d\n", get16(d))
                        printf("   Department number: %d\n", get16(d + 2))
                        printf("   Device ID: %d\n", get16(d + 4))
                        val c = b(d + 6)
                        printf(
                            "   Device type: %d (%s)\n", c,
                            when (c) {
                                0 -> "cart"
                                1 -> "system or host"
                                else -> "<error>"
                            }
                        )
                        printf("   Manufacturer code: %d\n", b(d + 7))
                        printf("   Text model description: [%d]", b(d + 8))
                        printf("   SCP-ECG protocol revision number: %g\n", b(d + 14).toDouble() / 10.0)
                        printf("   SCP-ECG protocol compatibility level: %d\n", b(d + 15))
                        printf("   Language support code: %d\n", b(d + 16))
                        printf("   Device capabilities: %d\n", b(d + 17))
                        val c2 = b(d + 18)
                        printf("   AC mains frequency environment: %d ", c2)
                        when (c2) {
                            0 -> printf("(unspecified)\n")
                            1 -> printf("(50 Hz)\n")
                            2 -> printf("(60 Hz)\n")
                            else -> printf("<error>")
                        }
                        val labels = arrayOf(
                            "Analyzing program revision number",
                            "Serial number of acquisition device",
                            "Acquisition device system software ID",
                            "Acquisition device SCP implementation ID",
                            "Manufacturer of acquisition device",
                        )
                        var q = d + 36
                        for (label in labels) {
                            val s = cstrAt(q)
                            printf("   %s: [%s]\n", label, s)
                            q += s.size + 1
                        }
                    }
                    vtype = VT_MIXED
                }
                15 -> { say("\n  ID of the analyzing device\n"); vtype = VT_MIXED }
                16 -> {
                    say("\n  Acquiring institution\n"); vtype = VT_TEXT
                    inst = d
                    if (a) censor(d, vlen, 'x'.code)
                }
                17 -> {
                    say("\n  Analyzing institution\n"); vtype = VT_TEXT
                    if (a) censor(d, vlen, 'x'.code)
                }
                18 -> {
                    say("\n  Acquiring department\n"); vtype = VT_TEXT
                    if (a) censor(d, vlen, 'x'.code)
                    dept = d
                }
                19 -> {
                    say("\n  Analyzing department\n"); vtype = VT_TEXT
                    if (a) censor(d, vlen, 'x'.code)
                }
                20 -> {
                    say("\n  Referring physician\n"); vtype = VT_TEXT
                    if (a) censor(d, vlen, 'x'.code)
                    trefdr = d
                }
                21 -> {
                    say("\n  Latest confirming physician\n"); vtype = VT_TEXT
                    if (a) censor(d, vlen, 'x'.code)
                }
                22 -> {
                    say("\n  Technician\n"); vtype = VT_TEXT
                    if (a) censor(d, vlen, 'x'.code)
                }
                23 -> {
                    say("\n  Room\n"); vtype = VT_TEXT
                    if (a) censor(d, vlen, 'x'.code)
                }
                24 -> { say("\n  Stat code (urgency)\n"); vtype = VT_B1 }
                25 -> {
                    say("\n  Date of acquisition\n")
                    tdate = d
                    if (a) put16(257, d + 2)
                    vtype = VT_DATE
                }
                26 -> {
                    say("\n  Time of acquisition\n")
                    ttime = d
                    vtype = VT_TIME
                }
                27 -> {
                    say("\n  Baseline filter\n"); vtype = VT_B2
                    blfilt = get16(d)
                }
                28 -> {
                    say("\n  Low-pass filter\n"); vtype = VT_B2
                    lpfilt = get16(d)
                }
                29 -> {
                    say("\n  Filter bit map\n"); vtype = VT_B1
                    filterBit = b(d)
                }
                30 -> {
                    say("\n  Free text field (comments)\n")
                    tcomments = d
                    vtype = VT_TEXT
                }
                31 -> { say("\n  Sequence number\n"); vtype = VT_TEXT }
                32 -> { say("\n  Medical history codes\n"); vtype = VT_BN }
                33 -> { say("\n  Electrode configuration code\n"); vtype = VT_B2 }
                34 -> { say("\n  Time zone\n"); vtype = VT_MIXED }
                35 -> { say("\n  Free text medical history\n"); vtype = VT_TEXT }
                else -> { say("\n  <Undefined tag>\n"); vtype = VT_MIXED }
            }
            if (v) printf("   Tag%3d (%2d bytes): ", tag, vlen)
            p += SCP_TAGHDRLEN
            len -= vlen.toLong() + SCP_TAGHDRLEN
            if (vlen == 0) {
                say("<not defined>\n")
                continue
            }
            when (vtype) {
                VT_TEXT -> {
                    if (v) printf("[%*s]", vlen - 1, cstrAt(p))
                    p += vlen
                }
                VT_DATE -> {
                    if (vlen != 4) {
                        if (v) printf("  Error: incorrect date format (%d bytes)\n", vlen)
                    } else if (v) {
                        printf("%4d/%02d/%02d", get16(p), b(p + 2), b(p + SCP_TAGHDRLEN))
                    }
                    p += vlen
                }
                VT_TIME -> {
                    if (vlen != 3) {
                        if (v) printf("  Error: incorrect time format (%d bytes)\n", vlen)
                    } else if (v) {
                        printf("%02d:%02d:%02d", b(p), b(p + 1), b(p + 2))
                    }
                    p += vlen
                }
                VT_B1 -> {
                    if (vlen != 1) {
                        if (v) printf("  Error: incorrect format (%d bytes instead of 1)\n", vlen)
                    } else if (v) {
                        printf("%d", b(p))
                    }
                    p += vlen
                }
                VT_B2 -> {
                    if (vlen != 2) {
                        if (v) printf("  Error: incorrect format (%d bytes instead of 2)\n", vlen)
                    } else if (v) {
                        printf("%d", get16(p))
                    }
                    p += vlen
                }
                VT_B2B1 -> {
                    if (vlen != 3) {
                        if (v) printf("  Error: incorrect format (%d bytes instead of 3)\n", vlen)
                    } else if (v) {
                        printf("%d (code %d)", get16(p), b(p + 2))
                    }
                    p += vlen
                }
                VT_BN -> {
                    while (vlen > 0) {
                        vlen--
                        if (v) printf("%d, ", b(p))
                        p++
                    }
                }
                else -> {
                    if (v) {
                        val o = ByteVec()
                        while (vlen > 0) {
                            vlen--
                            val c = b(p)
                            if (isprintC(c)) o.add(c) else sprintfInto(o, "\\%03o", arrayOf(c))
                            p++
                        }
                        o.add('\n'.code)
                        out(o)
                    } else {
                        p += vlen
                    }
                }
            }
        }

        if (tdate >= 0) {
            val mon = b(tdate + 2).toByte().toInt() - 1
            recdate = cformat(
                "%d %s %d", b(tdate + 3).toByte().toInt(),
                if (mon in 0..11) SCP_MONTH[mon] else "???", get16(tdate)
            )
        }
        if (ttime >= 0) {
            rectime = cformat(
                "%02d:%02d:%02d", b(ttime).toByte().toInt(), b(ttime + 1).toByte().toInt(),
                b(ttime + 2).toByte().toInt()
            )
        }
        val slast = if (lastname < 0) "<last name missing>".latin1() else cstrAt(lastname)
        val sfirst = if (firstname < 0) "<first name missing>".latin1() else cstrAt(firstname)
        if (slast.size + sfirst.size < 100 - 3) {
            patientName = bcat(slast, ", ".latin1(), sfirst)
        } else {
            eprintf("Patient name (%s, %s) is too long\n", slast, sfirst)
            patientName = "Name not available -- too long".latin1()
        }
        patientId = cut(if (tpatid < 0) "<patient ID missing>".latin1() else cstrAt(tpatid), 30)
        referringDr = cut(if (trefdr < 0) "<referring physician missing>".latin1() else cstrAt(trefdr), 100)
        comments = cut(if (tcomments < 0) "<comments missing>".latin1() else cstrAt(tcomments), 200)

        if (b(p) != SCP_TAG_END && v) printf(" Error: header terminator (tag 255) is missing\n")
        if ((tdevid == -1 || tinst == -1 || tdept == -1) && v) printf(" Error: device ID number (tag 14) is missing\n")
        if (tdate < 0 && v) printf(" Error: date of acquisition (tag 25) is missing\n")
        if (ttime < 0 && v) printf(" Error: time of acquisition (tag 26) is missing\n")

        if (a && pyob >= 0) {
            val crc = getcrc(pSave + SCP_CRCLEN, lenSave - SCP_CRCLEN)
            put16(crc, pSave)
        }

        if (b(p) != SCP_TAG_END || tdevid == -1 || tdate < 0 || ttime < 0) return 0
        return 1
    }

    fun section2(p0: Long, len0: Long): Int {
        val p = p0 + SCP_SECHDRLEN
        val len = len0 - SCP_SECHDRLEN
        if (len < 2) {
            if (vflag != 0) printf("  Error: section 2 contains no data\n")
            return 0
        }
        val ntables = get16(p)
        if (ntables == SCP_HT_DEFAULT_ONLY) {
            if (vflag != 0) printf("  Using standard Huffman table only\n")
        } else {
            if (vflag != 0) printf("  Number of Huffman tables defined: %d\n", get16(p))
            if (vflag != 0) printf("  Number of code structures in table 1: %d\n", get16(p + 2))
        }
        return 1
    }

    fun section3(p0: Long, len0: Long): Int {
        var p = p0
        var len = len0
        var i = 0
        var nsmax = 0
        val v = vflag != 0

        p += SCP_SECHDRLEN
        len -= SCP_SECHDRLEN
        if (len < 2) {
            if (v) printf("  Error: section3 contains no data\n")
            return 0
        }

        nleads = b(p)
        p++
        if (v) printf("  Number of leads: %d\n", nleads)
        len--

        nsamp = ArrayList<Long>()
        repeat(nleads + 4) { nsamp.add(0L) }

        if (v) printf("  Flag byte: %xH\n", b(p))
        len--
        if (b(p) and 1 != 0) {
            if (v) printf("   Reference beat subtraction used for compression\n")
        } else if (v) {
            printf("   Reference beat subtraction not used for compression\n")
        }
        if (b(p) and 4 != 0) {
            if (v) printf("   All leads recorded simultaneously\n")
        } else if (v) {
            printf("   %d leads recorded simultaneously\n", (b(p) shr 3) and 0xf)
        }
        p++

        while (len > 8) {
            val j = b(p + 8)
            if (j < SCP_LEADNAME.size) {
                if (v) printf("  %s", SCP_LEADNAME[j])
                val idx = i.toShort().toInt()
                when (j) {
                    1 -> leadI = idx
                    2 -> leadII = idx
                    61 -> leadIII = idx
                    62 -> avr = idx
                    64 -> avf = idx
                    63 -> avl = idx
                    3 -> v1 = idx
                    4 -> v2 = idx
                    5 -> v3 = idx
                    6 -> v4 = idx
                    7 -> v5 = idx
                    8 -> v6 = idx
                    else -> {}
                }
            } else if (j < 100) {
                if (v) printf("  <Reserved lead>")
            } else if (v) {
                printf("  <Manufacturer-defined lead>")
            }
            if (v) printf(": ID %d, samples %llu to %llu\n", j, get32(p).toULong(), get32(p + 4).toULong())
            val ns = get32(p + 4) - get32(p) + 1
            if (i < nsamp.size) nsamp[i] = ns else nsamp.add(ns)
            i++
            p += 9
            len -= 9
        }

        ecg = ArrayList()
        repeat(nleads + 5) { ecg.add(null) }
        haveEcg = true

        for (k in 0 until nleads + 4) {
            if (k >= nleads) {
                nsamp[k] = nsmax.toLong()
            } else if (ult(nsmax.toLong(), nsamp[k])) {
                nsmax = nsamp[k].toInt()
            }
            if (nsamp[k] == 0L) nsamp[k] = 1
            val s = newsig(nsamp[k])
            if (s == null) {
                if (v) printf("  Error: too many (%d) leads\n", nleads)
                return 0
            }
            ecg[k] = s
        }

        if (len < 0) return 0
        return 1
    }

    fun section4(p0: Long, len0: Long): Int {
        var p = p0
        var len = len0
        var stat = 1
        val v = vflag != 0

        p += SCP_SECHDRLEN
        len -= SCP_SECHDRLEN
        if (len < 6) {
            if (v) printf("  Error: section 4 contains no data\n")
            return 0
        }
        rblenms = get16(p).toLong()
        fcM = get16(p + 2)
        nqrs = get16(p + 4)
        if (v) {
            printf("  Length of reference beat type 0 data: %lld msec\n", rblenms)
            printf("  Sample # of fiducial relative to start of ref beat type 0: %d\n", fcM)
            printf("  Number of QRS complexes in the entire record: %d\n", nqrs)
        }
        if (nqrs < 1) return 0

        p += 6
        len -= 6
        subz = ArrayList()
        repeat(nqrs) { subz.add(null) }

        if (len >= nqrs.toLong() * 14) {
            if (v) printf("  Reference beat subtraction zones:\n")
            var i = 0
            while (i < nqrs && len >= 14) {
                val z = Subzone(get16(p).toShort().toInt(), get32(p + 2), get32(p + 6), get32(p + 10))
                if (z.ztype == 0 && z.t2 == 0L) z.ztype = 9
                subz[i] = z
                if (v) {
                    printf(
                        "   %2d  Type: %2d  start: %7lld  fiducial: %7lld  end: %7lld\n",
                        i + 1, z.ztype, z.t0, z.t1, z.t2
                    )
                    if (z.ztype != 0 && (z.t0 != 0L || z.t2 != 0L)) {
                        printf("  Error: start and end should be zero for beats of non-zero types\n")
                    }
                }
                p += 14
                len -= 14
                i++
            }
        } else {
            if (v) printf("  Error: reference beat subtraction zones are missing\n")
            stat = 0
        }
        if (len >= nqrs.toLong() * 8) {
            if (v) printf("  QRS locations:\n")
            for (i in 0 until nqrs) {
                if (v) printf("   %2d  start: %7llu  end: %7llu\n", i + 1, get32(p).toULong(), get32(p + 4).toULong())
                p += 8
            }
        } else {
            if (v) printf("  Error: QRS locations are missing\n")
            stat = 0
        }
        return stat
    }

    fun section5(p0: Long, len0: Long): Int {
        val p = p0 + SCP_SECHDRLEN
        val len = len0 - SCP_SECHDRLEN
        if (len <= 0) {
            if (vflag != 0) printf(" Error: section 5 contains no data\n")
            return 0
        }
        val d = get16(p + 2)
        var x = rblenms.toDouble() * 1000.0
        if (d != 0) x /= d.toDouble()
        else x = if (x == 0.0) Double.NaN else Double.POSITIVE_INFINITY
        rblen = d2l(x)

        refbeat = ArrayList()
        repeat(maxOf(nleads + 1, 0)) { refbeat.add(null) }
        for (i in 0 until maxOf(nleads, 0)) {
            if (rblen < 0 || rblen > SCP_MAXALLOC) {
                eprintf("  Error: too many (%d) leads\n", nleads)
                return 0
            }
            refbeat[i] = ShortArray(rblen.toInt())
        }
        return huffdecode(p, len, 5)
    }

    /** The value decoded by the last getbits call. */
    private var gbx = 0

    /**
     * Reads bits from the input, beginning ibits bits from the MSB of the
     * byte at p, until a Huffman-encoded value is recognized (stored into
     * gbx; x0 if none is). Returns the number of bits read.
     */
    fun getbits(x0: Int, p: Long, ibits0: Long): Long {
        var ibits = ibits0
        var bitbuffer = 0
        var nbits = 0
        gbx = x0
        while (true) {
            bitbuffer = (bitbuffer shl 1) and 0xffff
            if ((ibits and 7) == 0L) wb = b(p + (ibits ushr 3))
            if (wb and 0x80 != 0) bitbuffer = bitbuffer or 1
            wb = (wb shl 1) and 0xff
            ibits++
            nbits++
            for (e in SCP_HTDEFAULT) {
                if (bitbuffer == e[0]) {
                    var j = e[1]
                    if (j == 0) {
                        gbx = e[2]
                    } else {
                        if ((ibits and 7) == 0L) wb = b(p + (ibits ushr 3))
                        var v: Int
                        if (wb and 0x80 != 0) {
                            v = 1
                            repeat(maxOf(16 - j, 0)) {
                                v = ((v shl 1) or 1).toShort().toInt()
                            }
                        } else {
                            v = 0
                        }
                        wb = (wb shl 1) and 0xff
                        ibits++
                        nbits++
                        j--
                        while (j > 0) {
                            v = (v shl 1).toShort().toInt()
                            if ((ibits and 7) == 0L) wb = b(p + (ibits ushr 3))
                            if (wb and 0x80 != 0) v = (v or 1).toShort().toInt()
                            wb = (wb shl 1) and 0xff
                            j--
                            ibits++
                            nbits++
                        }
                        gbx = v
                    }
                    return nbits.toLong()
                }
            }
            if (nbits >= 64 - 1) break
        }
        if (vflag != 0) printf("Huffman encoding error\n")
        return 1000000
    }

    fun section6(p0: Long, len0: Long): Int {
        val p = p0 + SCP_SECHDRLEN
        val len = len0 - SCP_SECHDRLEN
        if (len <= 6) {
            if (vflag != 0) printf(" Error: section 6 contains no data\n")
            return 0
        }
        return huffdecode(p, len, 6)
    }

    fun huffdecode(p0: Long, len0: Long, section: Int): Int {
        var p = p0
        var len = len0
        val v = vflag != 0
        var tleadlen = 0L
        val g = get16(p).toDouble()

        if (section == 5) gref = g / 5000.0 else gres = g / 5000.0
        if (v) printf("  Amplitude value multiplier: %g nanovolts per unit\n", g)
        val sampint = get16(p + 2)
        if (v) printf("  Sample time interval: %d microseconds\n", sampint)
        if (sampint > 0) {
            if (sfreq > 0.0 && sfreq != 1.0e6 / sampint.toDouble()) {
                printf("Warning: section 5 and 6 sample intervals don't match")
            }
            sfreq = 1.0e6 / sampint.toDouble()
        } else if (wf.wfdbx_get_legacy() != 0) {
            // wfdb-x: no assumed sampling frequency (C, legacy mode: 500 Hz)
            printf("Error: sampling frequency not specified;  assuming 500 Hz\n")
            sfreq = 500.0
        } else {
            printf("Error: sampling frequency not specified\n")
        }
        if (v) printf("  Encoding type: %d ", b(p + 3))
        val enctype = when (b(p + 3)) {
            0 -> { if (v) printf("(amplitudes)\n"); 0 }
            1 -> { if (v) printf("(first differences)\n"); 1 }
            2 -> { if (v) printf("(second differences)\n"); 2 }
            else -> { if (v) printf("<undefined, assuming second differences>\n"); 2 }
        }
        if (section == 6) {
            if (v) printf("  Compression type: %d ", b(p + 4))
            when (b(p + 4)) {
                0 -> if (v) printf("(non-bimodal)\n")
                1 -> if (v) printf("(bimodal)\n")
                else -> if (v) printf("<undefined, assuming bimodal>\n")
            }
        }
        p += 6
        len -= 6

        if (nleads < 0) {
            if (v) printf("  Error: number of leads undefined -- section 3 missing or out of order\n")
            return 0
        }
        if (nleads == 0) {
            if (v) printf("  Error: no leads recorded\n")
            return 0
        }
        val nl = nleads
        val leadlen = LongArray(nl)
        for (i in 0 until nl) {
            leadlen[i] = get16(p).toLong()
            tleadlen += leadlen[i]
            if (v) printf("  Lead %d:%5llu bytes\n", i, leadlen[i].toULong())
            p += 2
            len -= 2
        }

        val ulen = len
        if (ult(ulen, tleadlen)) {
            if (v) {
                val d = tleadlen - ulen
                printf(
                    "  Error: %llu data byte%s missing from section %d\n", d.toULong(),
                    if (d == 1L) "" else "s", section
                )
            }
            return 0
        } else if (ult((tleadlen + 1) and 1L.inv(), ulen)) {
            if (v) {
                val d = ulen - tleadlen
                printf("  Warning: %llu extra byte%s in section %d\n", d.toULong(), if (d == 1L) "" else "s", section)
            }
        }

        for (i in 0 until nl) {
            if (v) {
                printf("  Lead %d data\n", i)
                for (j in 0 until 10) printf(" %02x", b(p + j))
                printf("\n")
            }
            hxxx = 0
            hxx = 0
            val explen: Int
            val gain: Double
            if (section == 6) {
                explen = nsamp[i].toInt()
                gain = gres
            } else {
                explen = rblen.toInt()
                gain = gref
            }
            val tbits = leadlen[i] * 8
            var ibits = 0L
            var j = 0
            while (j < explen && ult(ibits, tbits)) {
                ibits += getbits(hx, p, ibits)
                val x = gbx
                hx = x
                if (j == 0) {
                    hxx = x
                    hxxx = x
                } else if (j == 1) {
                    hdx = (x - hxxx).toShort().toInt()
                    hxxx = x
                    hxx = (hxx + x).toShort().toInt()
                } else {
                    hdx = (hdx + x).toShort().toInt()
                    hxxx = (hxxx + hdx).toShort().toInt()
                    hxx = (hxx + x).toShort().toInt()
                }
                hxout = when (enctype) {
                    0 -> x
                    1 -> hxx
                    else -> hxxx
                }
                val value = d2s(hxout.toDouble() * gain)
                val dest = if (section == 6) ecg.getOrNull(i) else refbeat.getOrNull(i)
                if (dest != null && j < dest.size) dest[j] = value
                if (vflag > 1) printf("   %5d %5d %5d %5d\n", j, x, hxx, hxxx)
                j++
            }
            if (j < explen && v) {
                val d = leadlen[i] - j.toLong()
                printf("   Error: %lld sample%s missing in lead %d\n", d, if (d == 1L) "" else "s", i)
            }
            if (ult(ibits, tbits) && v) {
                val d = tbits - ibits
                printf("   Warning: %lld extra bit%s in lead %d\n", d, if (d == 1L) "" else "s", i)
            }
            p += leadlen[i]
            if (v) printf("\n")
        }
        return 1
    }

    fun section7(p0: Long, len0: Long): Int {
        val v = vflag != 0
        val p = p0 + SCP_SECHDRLEN
        val len = len0 - SCP_SECHDRLEN
        if (len <= 0) {
            if (v) printf(" Error: section 7 contains no data\n")
            return 0
        }
        if (xflag != 0 && v) hexdump(p, len)
        if (len < 20) {
            if (v) printf(" Error: section 7 is too short (len = %lld)\n", len)
            return 0
        }
        rrint = get16(p + 2)
        var q = p + 6
        pon = get16(q)
        pend = get16(q + 2)
        qrson = get16(q + 4)
        qrsend = get16(q + 6)
        tend = get16(q + 8)
        paxis = get16(q + 10).toShort().toInt()
        qrsaxis = get16(q + 12).toShort().toInt()
        taxis = get16(q + 14).toShort().toInt()

        val nmb = b(p)
        val nps = b(p + 1)
        var sec7qrsOffset = (6 + 16 * nmb + 10 * nps).toShort().toInt()
        if (sec7qrsOffset.toLong() > len) sec7qrsOffset = len.toInt().toShort().toInt()
        if (sec7qrsOffset.toLong() > len) {
            if (v) printf(" Error: section 7 is too short (nmb = %d, nps = %d)\n", nmb, nps)
            return 0
        }
        val sec7qrs = get16(p + sec7qrsOffset) and 0xff

        if (v) {
            printf(" QRS complexes measured: %d\n", sec7qrs)
            printf(" Measurement blocks: %d\n", nmb)
            if (nmb == sec7qrs + 1) {
                printf("  (First measurement block contains measurements for reference beat type 0;\n   Others contain measurements for each individual beat)\n")
            } else {
                printf("  (Measurements for each reference beat type)\n")
            }
            printf("  Number of measurement blocks: %d\n", nmb)
            printf("  Number of pacemaker spikes: %d\n", nps)
            printf("  Mean RR interval: %d ms\n", rrint)
            printf("  Mean PP interval: %d ms\n", get16(p + 4))
            q = p + 6
            for (i in 0 until nmb) {
                printf("   Block %d\n", i)
                printf("    P onset:   %d ms\n", get16(q))
                printf("    P end:     %d ms\n", get16(q + 2))
                printf("    QRS onset: %d ms\n", get16(q + 4))
                printf("    QRS  end:  %d ms\n", get16(q + 6))
                printf("    T end:     %d ms\n", get16(q + 8))
                var n = get16(q + 10).toShort().toInt()
                if (n == SCP_AXIS_UNDEF) printf("    P axis:    undefined\n") else printf("    P axis:    %d degrees\n", n)
                n = get16(q + 12).toShort().toInt()
                if (n == SCP_AXIS_UNDEF) printf("    QRS axis:  undefined\n") else printf("    QRS axis:  %d degrees\n", n)
                n = get16(q + 14).toShort().toInt()
                if (n == SCP_AXIS_UNDEF) printf("    T axis:    undefined\n") else printf("    T axis:    %d degrees\n", n)
                q += 16
            }
            if (nps > 0) printf(" Pacemaker spike measurement data\n")
            var r = q + nps.toLong() * 4
            for (i in 0 until nps) {
                printf("Spike %d: %u ms, %d microvolts ", i, get16(q), get16(q + 2))
                when (val c = b(r)) {
                    0 -> printf("(unknown spike type, ")
                    1 -> printf("(triggers neither P nor QRS, ")
                    2 -> printf("(triggers a QRS, ")
                    3 -> printf("(triggers a P, ")
                    else -> printf("(spike type %d, ", c)
                }
                when (val c = b(r + 1)) {
                    0 -> printf("source unknown, ")
                    1 -> printf("internal, ")
                    2 -> printf("external, ")
                    else -> printf("source type %d, ", c)
                }
                var n = get16(r + 2).toShort().toInt()
                if (n == 0) printf(" not linked to a QRS, ") else printf(" linked to QRS #%d, ", n)
                n = get16(r + 4).toShort().toInt()
                if (n == 0) printf("width unknown)\n") else printf("%d microseconds\n)", n)
                q += 4
                r += 6
            }

            printf(" <!> sec7qrs = <%d>\n", sec7qrs)
            if (sec7qrs > 0) printf(" QRS type information (%d beats)\n", get16(r))
            q = r + 2
            for (i in 0 until sec7qrs) {
                printf("  QRS %d: reference beat type %d\n", i, b(q))
                q++
            }

            printf("%lld bytes remaining in section 7\n", len - (q - p))
            val o = ByteVec()
            while (q < p + len) {
                sprintfInto(o, " %5d [%3d]", arrayOf(get16(q), b(q)))
                q++
            }
            o.add('\n'.code)
            out(o)
        }
        return 1
    }

    fun section8(p0: Long, len0: Long): Int {
        val v = vflag != 0
        var p = p0 + SCP_SECHDRLEN
        var len = len0 - SCP_SECHDRLEN
        if (len <= 0) {
            if (v) printf(" Error: section 8 contains no data\n")
            return 0
        }
        if (v) {
            printf(" Status: %d ", b(p))
            when (b(p)) {
                0 -> printf("(original report, not confirmed)\n")
                1 -> printf("(confirmed report)\n")
                2 -> printf("(overread report, but not confirmed)\n")
                else -> printf("<undefined>\n")
            }
            printf(" Date: %4d/%02d/%02d\n", get16(p + 1), b(p + 3), b(p + 4))
            printf(" Time: %02d:%02d:%02d\n", b(p + 5), b(p + 6), b(p + 7))
        }
        val n = b(p + 8)
        stmnts = n
        if (v) printf(" Number of statements: %d\n", n)
        p += 9
        len -= 9

        var i = 0
        while (i < n && len > 2) {
            report[i] = p + 3
            val slen = get16(p + 1)
            if (v) {
                printf("  Statement %2d: (%d bytes)\n", b(p), slen)
                printf("   [%*s]\n", slen, cstrAt(p + 3))
            }
            p += slen.toLong() + 3
            len -= slen.toLong() + 3
            i++
        }
        if (i < n) {
            if (v) printf("  Error: data missing in section 8\n")
            return 0
        }
        return 1
    }

    fun section9(p0: Long, len0: Long): Int {
        var p = p0 + SCP_SECHDRLEN
        var len = len0 - SCP_SECHDRLEN
        if (len <= 0) {
            if (vflag != 0) printf(" Error: section 9 contains no data\n")
            return 0
        }
        if (vflag != 0) {
            val o = ByteVec()
            o.addString("  Data:\n   ")
            while (len > 0) {
                len--
                val c = b(p)
                if (isprintC(c)) o.add(c) else sprintfInto(o, "\\%03o", arrayOf(c))
                p++
            }
            o.add('\n'.code)
            out(o)
        }
        return 1
    }

    fun section10(p0: Long, len0: Long): Int {
        var p = p0 + SCP_SECHDRLEN
        val len = len0 - SCP_SECHDRLEN
        if (len <= 0) {
            if (vflag != 0) printf(" Error: section 10 contains no data\n")
            return 0
        }
        nsecleads = get16(p)
        val em = ArrayList<ShortArray>(nsecleads)
        p += 4
        repeat(nsecleads) {
            val m = ShortArray(NMEAS)
            for (k in 0 until NMEAS) m[k] = get16(p + 2 * k).toShort()
            p += m[M_VLEN].toLong() + 4
            em.add(m)
        }
        ecgmeas = em
        if (vflag != 0) {
            printf(" Results for %d leads\n", nsecleads)
            out(precgmeas())
        }
        return 1
    }

    fun section11(len0: Long): Int {
        val len = len0 - SCP_SECHDRLEN
        if (len <= 0) {
            if (vflag != 0) printf(" Error: section 11 contains no data\n")
            return 0
        }
        return 1
    }
}

private fun parsescpHelp(pname: ByteArray) {
    eprintf("usage: %s -o RECORD [OPTIONS ...] <SCPFILE\n", pname)
    eprintf(
        "  where RECORD is the name (<= 11 alphanumeric characters) of this case,\n  SCPFILE is the name of a file containing ECG data in SCP-ECG format, and\n  OPTIONS may include:\n   -a    anonymize and copy stdin to stdout (suppresses other output).\n   -f    force parsing of a file with CRC errors.\n   -h    print brief help\n   -l    low-pass filter (smooth) the output waveforms.\n   -v    option to print a (very) detailed analysis of SCPFILE.\n   -w    produce a WFDB-format record\n   -z    zero-mean the input\n\n  Additional options for debugging only:\n   -b    show baseline (residuals);  suppress templates\n   -s N  shift templates by N samples before adding\n   -S N  skip parsing of section N\n   -t    show templates; suppress baseline\n   -x    show hex dumps (implies -v)\n"
    )
}

private val SCP_CONTENTS = arrayOf(
    " Pointers to data areas in the record\n",
    " Header information - Patient data/ECG acquisition data\n",
    " Huffman tables used in encoding of ECG data\n",
    " ECG lead definition\n",
    " QRS locations\n",
    " Encoded reference beat data\n",
    " Residual signal after reference beat subtraction (if reference beats\n  are stored);  otherwise, encoded rhythm data\n",
    " Global measurements\n",
    " Textual diagnosis from the interpretive device\n",
    " Manufacturer specific diagnostic and overreading data\n",
    " Lead measurement results\n",
    " Universal statement codes resulting from the interpretation\n",
)

/** The parsescp tool. */
fun Wfdb.parsescpMain(argv0: Array<ByteArray>): Int {
    val argv = toolArgv(argv0)
    val argc = argv.size
    val pname = progName(argv[0])
    val s = Scp(this, pname)

    var i = 1
    while (i < argc) {
        val a = cstr(argv[i])
        if (a.at(0) == '-'.code) {
            when (a.at(1).toChar()) {
                'a' -> {
                    s.aflag = 1; s.xflag = 0; s.vflag = 0
                }
                'b' -> {
                    s.bflag = 1; s.tflag = 0
                }
                'f' -> s.fflag = 1
                'h' -> {
                    parsescpHelp(pname)
                    exit(1)
                }
                'l' -> s.lflag = 1
                'o' -> {
                    i++
                    if (i < argc && cstrlen(argv[i]) <= 11) {
                        s.recname = cstr(argv[i])
                    } else {
                        eprintf("%s: a record name of 11 or fewer alphanumericcharacters must\n follow -o\n", pname)
                        exit(1)
                    }
                }
                's' -> {
                    i++
                    if (i < argc) {
                        s.shift = strtol(argv[i], 10).value.toInt()
                    } else {
                        eprintf("%s: number of samples to shift templates must follow -s\n", pname)
                        exit(1)
                    }
                }
                'S' -> {
                    i++
                    if (i < argc) {
                        if (argv[i].at(0) == '-'.code) {
                            s.skip.fill(1)
                        } else {
                            val index = strtol(argv[i], 10).value.toInt()
                            if (index in 0..11) s.skip[index] = 1 - s.skip[index]
                        }
                    } else {
                        eprintf("%s: number of section to skip, or '-', must follow -S\n", pname)
                        exit(1)
                    }
                }
                't' -> {
                    s.tflag = 1; s.bflag = 0
                }
                'v' -> {
                    s.vflag++; s.aflag = 0
                }
                'w' -> s.wflag++
                'x' -> {
                    s.xflag = 1; s.vflag = 1; s.aflag = 0
                }
                'z' -> s.zflag++
                else -> {
                    eprintf("%s: unrecognized option '%s'\n", pname, a)
                    parsescpHelp(pname)
                    exit(1)
                }
            }
        } else {
            eprintf("%s: unrecognized argument '%s'\n", pname, a)
            parsescpHelp(pname)
            exit(1)
        }
        i++
    }

    val input = WfdbFile.stdin()
    val header = ByteArray(SCP_RECHDRLEN)
    var bytesread = input.fread(header, 1, SCP_RECHDRLEN).toLong()
    if (bytesread != SCP_RECHDRLEN.toLong()) {
        eprintf("%s: input too short (only %llu bytes)\n", pname, bytesread.toULong())
        exit(1)
    }
    s.data = header
    var crc = s.get16(0)
    val length = s.get32(SCP_CRCLEN)
    if (s.vflag != 0) printf("CRC = %d, expected length = %lld bytes\n", crc, length)
    if (length < 0) {
        eprintf("%s: insufficient memory (%lld bytes needed)\n", pname, length)
        exit(2)
    }
    val all = ByteVec(maxOf(minOf(length, 1L shl 24), 16L).toInt())
    all.addAll(header)
    val buf = ByteArray(65536)
    while (bytesread < length) {
        val want = minOf(length - bytesread, buf.size.toLong()).toInt()
        val n = input.read(buf, 0, want)
        if (n == 0) break
        all.addAll(buf, 0, n)
        bytesread += n
    }
    s.data = all.toByteArray()
    if (bytesread < length) {
        val d = length - bytesread
        eprintf("%s: input too short (%llu byte%s missing)\n", pname, d.toULong(), if (d == 1L) "" else "s")
        exit(3)
    }
    input.close()
    if (s.vflag != 0) printf("Record length: %lld bytes\n", length)
    s.crcok(SCP_CRCLEN, length - SCP_CRCLEN, crc, "Top-level CRC".latin1())

    var p = SCP_RECHDRLEN.toLong()
    while (p < length) {
        crc = s.get16(p)
        val secId = s.get16(p + SCP_SEC_ID)
        var secLen = s.get32(p + SCP_SEC_LEN)
        val v = s.vflag != 0
        if (v) printf("\nSection %d length: %lld bytes\n", secId, secLen)
        if (ult(secLen, SCP_SECMINLEN)) {
            if (v) {
                printf(
                    " Warning: section length too short (must be at least 8 bytes)\n  Remaining data (%llu bytes) following short section will not be read\n",
                    (length - (p + SCP_SECMINLEN)).toULong()
                )
            }
            secLen = SCP_SECMINLEN
        }
        if (ult(length - p, secLen)) {
            if (v) printf(" Warning: section length exceeds amount of remaining data\n  This section will not be parsed\n")
            break
        }
        val desc = cformat(" Section %d CRC", secId)
        s.crcok(p + SCP_CRCLEN, secLen - SCP_CRCLEN, crc, desc)
        if (v) {
            printf(" Section version number: %d\n", s.b(p + SCP_SEC_VERSION))
            printf(" Protocol version number: %d\n", s.b(p + SCP_SEC_PROTOCOL))
            printf(" Contents: ")
        }
        val sl = secLen
        if (secId < SCP_CONTENTS.size) {
            if (v) printf("%s", SCP_CONTENTS[secId])
            if (s.skip[secId] != 0) {
                printf("  [skipped]\n")
            } else {
                when (secId) {
                    0 -> s.section0(p, sl)
                    1 -> s.section1(p, sl)
                    2 -> s.section2(p, sl)
                    3 -> s.section3(p, sl)
                    4 -> s.section4(p, sl)
                    5 -> s.section5(p, sl)
                    6 -> s.section6(p, sl)
                    7 -> s.section7(p, sl)
                    8 -> s.section8(p, sl)
                    9 -> s.section9(p, sl)
                    10 -> s.section10(p, sl)
                    else -> s.section11(sl)
                }
            }
        } else if (v) {
            printf(" Manufacturer-defined (non-standard) section %d\n", secId)
        }
        p += sl
    }

    // Low-pass filter the residuals.
    for (li in 0 until maxOf(s.nleads, 0)) {
        val n = s.nsampk(li.toLong())
        val inp = s.ecg.getOrNull(li) ?: continue
        val outs = newsig(n)
        if (outs == null) {
            eprintf("Insufficient memory for filtering\n")
            break
        }
        if (s.tflag == 0) {
            outs[0] = inp[0]
            var jj = 1L
            while (ult(jj + 1, n)) {
                val j = jj.toInt()
                val vv = inp[j - 1].toInt() + inp[j].toInt() + inp[j + 1].toInt()
                outs[j] = if (vv > 0) ((vv + 2) / 3).toShort() else if (vv < 0) ((vv - 2) / 3).toShort() else 0
                jj++
            }
            outs[jj.toInt()] = inp[jj.toInt()]
            for (k in 0 until maxOf(s.nqrs, 0)) {
                val z = s.subz.getOrNull(k) ?: continue
                if (z.ztype == 0) {
                    val j0 = maxOf(z.t0 - 1, 0L)
                    val j1 = minOf(z.t2 + 2, outs.size.toLong())
                    var jx = j0
                    while (jx < j1) {
                        outs[jx.toInt()] = inp[jx.toInt()]
                        jx++
                    }
                }
            }
        }
        s.ecg[li] = outs
    }

    // Add the reference beats back into the residuals to obtain the raw ECG.
    if (s.bflag == 0) {
        for (k in 0 until maxOf(s.nqrs, 0)) {
            val z = s.subz.getOrNull(k) ?: continue
            if (z.ztype != 0) continue
            for (li in 0 until maxOf(s.nleads, 0)) {
                val m = (s.fcM.toLong() - z.t1 + z.t0 - 1).toInt()
                if (z.t2 - z.t0 + 1 > s.rblen || m < 0) {
                    eprintf("error: subtraction zone is larger than template\n")
                    exit(1)
                }
                val shift = s.shift.toLong()
                val rf = s.refbeat.getOrNull(li) ?: continue
                val sig = s.ecg.getOrNull(li) ?: continue
                var jlo = z.t0 - 1 + shift
                val jhi = z.t2 - 1 + shift
                var mm = m.toLong()
                if (jlo < 0) {
                    mm += -jlo
                    jlo = 0
                }
                var jx = jlo
                while (jx <= jhi) {
                    if (!ult(jx, sig.size.toLong()) || !ult(mm, rf.size.toLong())) break
                    sig[jx.toInt()] = (sig[jx.toInt()] + rf[mm.toInt()]).toShort()
                    jx++
                    mm++
                }
            }
        }
    }

    var n0 = 0L
    if (s.haveEcg) {
        n0 = s.nsamp.firstOrNull() ?: 0L
        n0 = if (!ult(SCP_MAXALLOC, n0)) n0 else 0L
        s.nout = n0
        for (k in s.ecg.indices) {
            var sg = s.ecg[k] ?: newsig(0)!!
            if (sg.size.toLong() < n0) sg = sg.copyOf(n0.toInt())
            s.ecg[k] = sg
        }
    }
    val vflag = s.vflag != 0
    val n0i = n0.toInt()

    if (s.leadIII < 0) {
        if (s.leadI >= 0 && s.leadII >= 0) {
            if (vflag) printf(" Calculating lead III\n")
            s.leadIII = s.nleads.toShort().toInt()
            s.nleads++
            val li = s.leadI.toLong(); val lii = s.leadII.toLong(); val liii = s.leadIII.toLong()
            s.nsamp[liii.toInt()] = if (ult(s.nsampk(lii), s.nsampk(li))) s.nsampk(lii) else s.nsampk(li)
            val l1 = s.srcsig(li)
            val l2 = s.srcsig(lii)
            val ns = s.nsamp[liii.toInt()]
            val l3 = s.sigp(liii)
            if (l3 != null) {
                var ne = ns
                for (len in longArrayOf(l1.size.toLong(), l2.size.toLong(), l3.size.toLong())) if (ult(len, ne)) ne = len
                for (jx in 0 until ne.toInt()) l3[jx] = (l2[jx] - l1[jx]).toShort()
            }
        } else if (s.leadI < 0) {
            if (s.leadII < 0) eprintf("Leads I, II, and III are missing\n")
            else eprintf("Leads I and III are missing\n")
        } else {
            eprintf("Leads II and III are missing\n")
        }
    } else if (s.leadII < 0) {
        if (s.leadI >= 0) {
            if (vflag) printf(" Calculating lead II\n")
            s.leadII = s.nleads.toShort().toInt()
            s.nleads++
            val li = s.leadI.toLong(); val lii = s.leadII.toLong(); val liii = s.leadIII.toLong()
            s.nsamp[lii.toInt()] = if (ult(s.nsampk(liii), s.nsampk(li))) s.nsampk(liii) else s.nsampk(li)
            val l1 = s.srcsig(li)
            val l3 = s.srcsig(liii)
            val l2 = s.sigp(lii)
            if (l2 != null) for (jx in 0 until n0i) l2[jx] = (l1[jx] + l3[jx]).toShort()
        } else {
            eprintf("Leads I and II are missing\n")
        }
    } else if (s.leadI < 0) {
        if (vflag) printf(" Calculating lead I\n")
        s.leadI = s.nleads.toShort().toInt()
        s.nleads++
        val li = s.leadI.toLong(); val lii = s.leadII.toLong(); val liii = s.leadIII.toLong()
        s.nsamp[li.toInt()] = if (ult(s.nsampk(liii), s.nsampk(lii))) s.nsampk(liii) else s.nsampk(lii)
        val l2 = s.srcsig(lii)
        val l3 = s.srcsig(liii)
        val l1 = s.sigp(li)
        if (l1 != null) for (jx in 0 until n0i) l1[jx] = (l2[jx] - l3[jx]).toShort()
    }

    if (s.avr < 0) {
        if (s.leadI >= 0 && s.leadII >= 0) {
            if (vflag) printf(" Calculating lead aVR\n")
            s.avr = s.nleads.toShort().toInt()
            s.nleads++
            val li = s.leadI.toLong(); val lii = s.leadII.toLong(); val k = s.avr.toLong()
            s.nsamp[k.toInt()] = if (ult(s.nsampk(lii), s.nsampk(li))) s.nsampk(lii) else s.nsampk(li)
            val l1 = s.srcsig(li)
            val l2 = s.srcsig(lii)
            val o = s.sigp(k)
            if (o != null) for (jx in 0 until n0i) o[jx] = (-((l1[jx] + l2[jx]) / 2)).toShort()
        } else {
            eprintf("Lead aVR cannot be derived\n")
        }
    }

    if (s.avl < 0) {
        if (s.leadII >= 0 && s.leadIII >= 0) {
            if (vflag) printf(" Calculating lead aVL\n")
            s.avl = s.nleads.toShort().toInt()
            s.nleads++
            val lii = s.leadII.toLong(); val liii = s.leadIII.toLong(); val k = s.avl.toLong()
            s.nsamp[k.toInt()] = if (ult(s.nsampk(liii), s.nsampk(lii))) s.nsampk(liii) else s.nsampk(lii)
            val l2 = s.srcsig(lii)
            val l3 = s.srcsig(liii)
            val o = s.sigp(k)
            if (o != null) for (jx in 0 until n0i) o[jx] = (l2[jx] / 2 - l3[jx]).toShort()
        } else {
            eprintf("Lead aVL cannot be derived\n")
        }
    }

    if (s.avf < 0) {
        if (s.leadI >= 0 && s.leadII >= 0) {
            if (vflag) printf(" Calculating lead aVF\n")
            s.avf = s.nleads.toShort().toInt()
            s.nleads++
            val li = s.leadI.toLong(); val liii = s.leadIII.toLong(); val k = s.avf.toLong()
            s.nsamp[k.toInt()] = if (ult(s.nsampk(liii), s.nsampk(li))) s.nsampk(liii) else s.nsampk(li)
            val l1 = s.srcsig(li)
            val l3 = s.srcsig(liii)
            val o = s.sigp(k)
            if (o != null) for (jx in 0 until n0i) o[jx] = (l1[jx] / 2 + l3[jx]).toShort()
        } else {
            eprintf("Lead aVF cannot be derived\n")
        }
    }

    if (s.v1 < 0) eprintf("Lead V1 is missing\n")
    if (s.v2 < 0) eprintf("Lead V2 is missing\n")
    if (s.v3 < 0) eprintf("Lead V3 is missing\n")
    if (s.v4 < 0) eprintf("Lead V4 is missing\n")
    if (s.v5 < 0) eprintf("Lead V5 is missing\n")
    if (s.v6 < 0) eprintf("Lead V6 is missing\n")

    if (s.nleads > 0 && s.order().any { it < 0 }) {
        val nl = s.nleads
        if (s.ecg[nl] == null) s.ecg[nl] = newsig(0)
        val l = nl.toShort().toInt()
        if (s.leadI < 0) s.leadI = l
        if (s.leadII < 0) s.leadII = l
        if (s.leadIII < 0) s.leadIII = l
        if (s.avr < 0) s.avr = l
        if (s.avf < 0) s.avf = l
        if (s.avl < 0) s.avl = l
        if (s.v1 < 0) s.v1 = l
        if (s.v2 < 0) s.v2 = l
        if (s.v3 < 0) s.v3 = l
        if (s.v4 < 0) s.v4 = l
        if (s.v5 < 0) s.v5 = l
        if (s.v6 < 0) s.v6 = l
    }

    if (s.aflag != 0) {
        val c = s.getcrc(SCP_CRCLEN, bytesread - SCP_CRCLEN)
        s.put16(c, 0)
        Stdout.write(s.data, 0, bytesread.toInt())
    } else if (s.nleads > 0) {
        s.writeOutput()
    }

    exit(0)
}
