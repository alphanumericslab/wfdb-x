// Tests of the fast paths of the high-level functions and of rdsamp against
// the reference paths they replace: readAnnotations (getannAll) against
// getann called for each annotation, readRecord (its reading into one
// array, and the conversion to physical units) against getvec called for
// each vector, meansamp against the halving loop, and rdsamp's number
// formatting against printf.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It tests WFDB-x; it has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

import wfdbx.apps.RdOut
import wfdbx.cstd.cformat
import wfdbx.cstd.getenv
import wfdbx.cstd.latin1
import wfdbx.cstd.setenv
import wfdbx.cstd.unsetenv
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class FastPathTest {
    // -----------------------------------------------------------------------
    // readAnnotations == getann for each annotation

    /** One annotation, every field (the aux string as text, the mnemonic from annstr). */
    private data class Ann(val t: Long, val code: Int, val sym: String, val sub: Int, val chan: Int, val num: Int, val aux: String?)

    /** What readAnnotations returns, by getann (null if the annotator cannot be opened), and getann's last status. */
    private fun refAnnotations(w: Wfdb, rec: String, an: String, from: Long?, to: Long?): Pair<List<Ann>, Int>? {
        w.wfdbquit()
        w.sampfreq(rec)
        if (w.annopen(rec, arrayOf(Anninfo(an, WFDB_READ)), 1) < 0) {
            w.wfdbquit()
            return null
        }
        if (from != null && from != 0L && w.iannsettime(from) < 0) {
            w.wfdbquit()
            return Pair(emptyList(), SEEK_FAILED)
        }
        val out = ArrayList<Ann>()
        val a = Annotation()
        var stat: Int
        while (true) {
            stat = w.getann(0, a)
            if (stat != 0 || (to != null && a.time >= to)) break
            val x = a.aux
            val text = if (x == null || x.isEmpty()) {
                null
            } else {
                x.copyOfRange(1, minOf(1 + (x[0].toInt() and 0xff), x.size)).latin1().substringBefore('\u0000')
            }
            out.add(Ann(a.time, a.anntyp, w.annstr(a.anntyp).latin1(), a.subtyp, a.chan, a.num, text))
        }
        w.wfdbquit()
        return Pair(out, stat)
    }

    private val SEEK_FAILED = -1000

    private fun anns(a: Annotations) = (0 until a.size).map {
        Ann(a.samples[it], a.codes[it], a.symbols[it], a.subtypes[it], a.chans[it], a.nums[it], a.aux[it])
    }

    /** readAnnotations gives what getann gives (or fails as it should), with and without from and to. */
    private fun sameAnnotations(w: Wfdb, rec: String, an: String, rng: Random) {
        val all = refAnnotations(w, rec, an, null, null) ?: return
        val times = all.first.map { it.t }.filter { it >= 0 }
        val ranges = mutableListOf<Pair<Long?, Long?>>(Pair(null, null))
        if (times.isNotEmpty()) {
            ranges.add(Pair(null, times[rng.nextInt(times.size)]))
            ranges.add(Pair(times[rng.nextInt(times.size)].coerceAtLeast(1), null))
            ranges.add(Pair(times.min() + 1, times.max()))
        }
        for ((from, to) in ranges) {
            val (expect, stat) = refAnnotations(w, rec, an, from, to)!!
            val got = try {
                anns(w.readAnnotations(rec, an, from = from?.let { TimeSpec(it) }, to = to?.let { TimeSpec(it) }))
            } catch (e: WfdbException) {
                e.message
            }
            if (stat == 0 || stat == -1) {
                assertEquals<Any?>(expect, got, "$rec.$an from $from to $to")
            } else if (stat == SEEK_FAILED) {
                assertEquals<Any?>("can't seek in annotator $an", got, "$rec.$an")
            } else {
                assertEquals<Any?>("can't read annotation file $an of record $rec (getann status $stat)", got, "$rec.$an")
            }
        }
    }

    /** Random annotations (every field; long gaps, out of order, aux strings of every length) written with putann. */
    private fun writeRandom(w: Wfdb, rng: Random, an: String, n: Int, freq: Double?) {
        if (freq != null) w.setafreq(freq)
        assertEquals(0, w.annopen("rec", arrayOf(Anninfo(an, WFDB_WRITE)), 1))
        var t = 0L
        for (k in 0 until n) {
            t += when (rng.nextInt(40)) {
                0 -> rng.nextLong(-(1L shl 33), 1L shl 33)
                1 -> rng.nextLong(-3000, 0)
                2 -> 0
                else -> rng.nextLong(1, 1500)
            }
            t = t.coerceIn(0, 1L shl 40)
            val code = if (rng.nextInt(30) == 0) rng.nextInt(-128, 128) else rng.nextInt(1, 50)
            val aux = if (rng.nextInt(3) == 0) {
                val len = listOf(0, 1, 2, 3, 254, 255, rng.nextInt(0, 256))[rng.nextInt(7)]
                val b = ByteArray(len + 1) { if (it == 0) len.toByte() else rng.nextInt(1, 256).toByte() }
                if (len > 3 && rng.nextInt(4) == 0) b[1 + rng.nextInt(len)] = 0 // (a null inside)
                b
            } else {
                null
            }
            val sub = if (rng.nextInt(5) == 0) rng.nextInt(-128, 128) else 0
            val chan = if (rng.nextInt(5) == 0) rng.nextInt(0, 256) else 0
            val num = if (rng.nextInt(5) == 0) rng.nextInt(-128, 128) else 0
            w.putann(0, Annotation(t, code, sub, chan, num, aux))
        }
        w.wfdbquit()
        w.setafreq(0.0)
    }

    @Test
    fun readAnnotationsEqualsGetann() {
        val d = DataDir("fpann")
        val w = d.wfdb()
        val saved = getenv("WFDBANNSORT")
        setenv("WFDBANNSORT", "0") // (keep the order written)
        try {
            w.wfdbquiet()
            val rng = Random(20261028)
            w.writeRecord("rec", IntArray(100) { it }, 1, 250.0, gains = doubleArrayOf(100.0), adcres = intArrayOf(12), units = listOf("mV"))
            var withAux = 0
            for (trial in 0 until 40) {
                val n = listOf(0, 1, 2, 7, 300, 3000)[trial % 6]
                // (a time resolution of its own, and modified mnemonics:
                // labels at the start, which annopen reads and pushes back
                // the annotation after them)
                val freq = if (trial % 4 == 1) 1000.0 else null
                val wm = if (trial % 5 == 2) d.wfdb() else w
                if (wm !== w) {
                    wm.wfdbquiet()
                    wm.setannstr(30, "QQ")
                    wm.setanndesc(31, "a description")
                }
                writeRandom(wm, rng, "r$trial", n, freq)
                sameAnnotations(w, "rec", "r$trial", rng)
                val back = w.readAnnotations("rec", "r$trial")
                assertTrue(back.size > 0 || n == 0, "trial $trial")
                withAux += back.aux.count { it != null && it.isNotEmpty() }
                // truncated
                val data = d.read("rec.r$trial")!!
                for (k in 0 until 4) {
                    if (data.isEmpty()) break
                    writeFile(d.path("rec.t$trial"), data.copyOf(rng.nextInt(data.size)))
                    sameAnnotations(w, "rec", "t$trial", rng)
                }
            }
            assertTrue(withAux > 3000)
            // the annotation files of tests/data (MIT and AHA formats)
            for (f in listFiles(d.dir).sorted()) {
                val dot = f.indexOf('.')
                if (dot <= 0) continue
                val ext = f.substring(dot + 1)
                if (ext in listOf("hea", "dat", "txt", "edf", "ecg", "scp", "wav", "mat") || '.' in ext) continue
                sameAnnotations(w, f.substring(0, dot), ext, rng)
            }
            assertEquals(75, w.readAnnotations("100s", "atr").size)
        } finally {
            w.wfdbquit()
            if (saved == null) unsetenv("WFDBANNSORT") else setenv("WFDBANNSORT", saved)
            d.remove()
        }
    }

    // -----------------------------------------------------------------------
    // readRecord == getvec for each vector

    /** What readRecord returns, by getvec: the samples, and whether there was a checksum error; or the error message. */
    private fun refRecord(w: Wfdb, rec: String, highres: Boolean, pad: Boolean, from: Long, to: Long?): Any {
        w.wfdbquit()
        val nsig = w.isigopen(rec, null, 0)
        assertTrue(nsig > 0)
        assertEquals(nsig, w.isigopen(rec, Array(nsig) { Siginfo() }, nsig))
        w.setgvmode((if (highres) WFDB_HIGHRES else WFDB_LOWRES) or (if (pad) WFDB_GVPAD else 0))
        if (w.isigsettime(from) < 0) {
            w.wfdbquit()
            return "can't seek to sample $from of record $rec"
        }
        val out = ArrayList<Int>()
        val v = IntArray(nsig)
        var bad = false
        var k = 0L
        while (to == null || k < to - from) {
            val stat = w.getvec(v)
            if (stat == -1) break
            if (stat < -1 && stat != -4) {
                w.wfdbquit()
                return "can't read signal data of record $rec (getvec status $stat)"
            }
            if (stat == -4) bad = true
            for (x in v) out.add(x)
            k++
        }
        w.wfdbquit()
        return Pair(out, bad)
    }

    private fun sameRecord(w: Wfdb, rec: String, highres: Boolean, pad: Boolean, from: Long, to: Long?) {
        val expect = refRecord(w, rec, highres, pad, from, to)
        val got: Any = try {
            val r = w.readRecord(
                rec, from = TimeSpec(from), to = to?.let { TimeSpec(it) }, highres = highres, pad = pad,
                checksumWarning = false,
            )
            Pair(r.samples.toList(), !r.checksumOk)
        } catch (e: WfdbException) {
            e.message!!
        }
        assertEquals(expect, got, "$rec highres $highres pad $pad from $from to $to")
    }

    /** Sets the number of samples in the header of [rec] (null: none). */
    private fun setLength(d: DataDir, rec: String, n: Long?) {
        val h = d.read("$rec.hea")!!.latin1()
        val lines = h.split("\n").toMutableList()
        val f = lines[0].split(" ").toMutableList()
        while (f.size > 3) f.removeAt(f.size - 1)
        if (n != null) f.add(n.toString())
        lines[0] = f.joinToString(" ")
        writeFile(d.path("$rec.hea"), lines.joinToString("\n"))
    }

    @Test
    fun readRecordEqualsGetvec() {
        // Records whose headers give fewer samples than the signal files hold
        // (the array is full, and grows), as many, more (the files end
        // early), or no number: readRecord reads what getvec reads.
        val d = DataDir("fprec")
        val w = d.wfdb()
        try {
            w.wfdbquiet()
            val rng = Random(7)
            val cases = listOf(Pair(212, intArrayOf(1, 1)), Pair(16, intArrayOf(1, 1, 1)), Pair(8, intArrayOf(1)),
                Pair(311, intArrayOf(4, 1, 1, 1)), Pair(24, intArrayOf(2, 3)))
            for ((fmt, spf) in cases) {
                val nsig = spf.size
                val n = rng.nextInt(70000, 140000)
                val cols = spf.sum()
                val lim = if (fmt == 8) 100 else if (fmt == 311) 500 else 2000
                val x = IntArray(n * cols) { if (rng.nextInt(100) == 0) WFDB_INVALID_SAMPLE else rng.nextInt(-lim, lim) }
                if (fmt == 8) {
                    // (a triangle wave: no slew too fast for the format)
                    for (i in x.indices) {
                        val t = i / cols % 400
                        x[i] = if (t < 200) t - 100 else 300 - t
                    }
                }
                w.writeRecord("p", x, nsig, 250.0, fmt = fmt, gains = DoubleArray(nsig) { 200.0 + it }, adcres = intArrayOf(12),
                    units = listOf("mV"), sampsPerFrame = spf)
                val lengths = listOf<Long?>(n.toLong(), n / 2L, n - 1L, 1, 0, n + 1000L, null)
                for (len in lengths) {
                    setLength(d, "p", len)
                    for (hr in listOf(false, true)) {
                        sameRecord(w, "p", hr, false, 0, null)
                        sameRecord(w, "p", hr, true, 7, null)
                        sameRecord(w, "p", hr, false, 3, n + 50L)
                    }
                }
            }
        } finally {
            w.wfdbquit()
            d.remove()
        }
    }

    @Test
    fun physicalUnits() {
        // (v - baseline) / gain for each value (NaN for invalid samples),
        // with channels selected, of every record of tests/data
        val d = DataDir("fpphys")
        val w = d.wfdb()
        try {
            w.wfdbquiet()
            val rng = Random(3)
            val x = IntArray(30000 * 3) { if (rng.nextInt(50) == 0) WFDB_INVALID_SAMPLE else rng.nextInt(-2000, 2000) }
            x[0] = WFDB_INVALID_SAMPLE
            x[x.size - 1] = WFDB_INVALID_SAMPLE
            w.writeRecord("ph", x, 3, 360.0, fmt = 212, gains = doubleArrayOf(200.0, 1.7, 1e-3), baselines = intArrayOf(5, -1000, 0),
                adcres = intArrayOf(12), units = listOf("mV"), names = listOf("a", "b", "c"))
            val recs = listOf("ph") + listFiles(d.dir).filter { it.endsWith(".hea") }.map { it.removeSuffix(".hea") }
                .filter { it != "8" && it != "16" }.sorted()
            var checked = 0
            for (rec in recs) {
                for (ch in listOf<List<String>?>(null, listOf("2", "0", "2"), listOf("0"))) {
                    val r = try {
                        w.readRecord(rec, channels = ch, physical = true, checksumWarning = false)
                    } catch (e: WfdbException) {
                        continue
                    }
                    val p = r.physical!!
                    assertEquals(r.samples.size, p.size)
                    for (i in p.indices) {
                        val c = i % r.nsig
                        val v = r.samples[i]
                        val e = if (v == WFDB_INVALID_SAMPLE) Double.NaN else (v.toDouble() - r.baselines[c]) / r.gains[c]
                        assertEquals(e.toRawBits(), p[i].toRawBits(), "$rec $ch $i")
                    }
                    checked++
                }
            }
            assertTrue(checked > 20)
        } finally {
            w.wfdbquit()
            d.remove()
        }
    }

    // -----------------------------------------------------------------------
    // meansamp

    /** meansamp as the C library computes it (halving a power of 2 step by step). */
    private fun refMeansamp(s: IntArray, off: Int, n: Int): Int {
        var sum = (n / 2).toLong()
        for (i in 0 until maxOf(n, 0)) {
            val x = s[off + i]
            if (x == WFDB_INVALID_SAMPLE) return WFDB_INVALID_SAMPLE
            sum += x
        }
        val neg = if (sum < 0) 1L else 0L
        if (n and (n - 1) != 0) return ((sum + neg) / n - neg).toInt()
        var m = n
        while (true) {
            m /= 2
            if (m == 0) break
            sum = (sum - (if (sum < 0) 1 else 0)) / 2
        }
        return sum.toInt()
    }

    @Test
    fun meansampEqualsReference() {
        val rng = Random(11)
        val s = IntArray(64)
        for (trial in 0 until 200000) {
            val n = rng.nextInt(1, 33)
            val big = trial % 3 == 0
            for (i in 0 until n) {
                s[i] = when {
                    rng.nextInt(200) == 0 -> WFDB_INVALID_SAMPLE
                    big -> rng.nextInt(Int.MIN_VALUE + 1, Int.MAX_VALUE)
                    else -> rng.nextInt(-40, 40)
                }
            }
            assertEquals(refMeansamp(s, 0, n), meansamp(s, 0, n), "${s.copyOf(n).toList()}")
        }
        assertEquals(refMeansamp(s, 0, 0), meansamp(s, 0, 0))
    }

    // -----------------------------------------------------------------------
    // rdsamp's numbers == printf

    @Test
    fun rdsampSamplesEqualPrintf() {
        val rng = Random(17)
        val v = IntArray(4000) {
            when (it % 5) {
                0 -> rng.nextInt(-3000, 3000)
                1 -> rng.nextInt()
                2 -> listOf(0, -1, 9, 10, -10, 99, -100, 999999999, 1000000000, Int.MAX_VALUE, Int.MIN_VALUE, -32768)[rng.nextInt(12)]
                else -> rng.nextInt(-10, 10)
            }
        }
        for (width in intArrayOf(0, 3, 7, 12)) {
            for (lead in intArrayOf('\t'.code, ','.code)) {
                val out = RdOut()
                val expect = StringBuilder()
                var off = 0
                while (off + 6 <= v.size) {
                    val sig = intArrayOf(0, 2, 5, 1, 1).copyOf(rng.nextInt(0, 6))
                    out.samples(lead, v, off, sig, width)
                    for (s in sig) {
                        expect.append(lead.toChar())
                        expect.append(cformat("%${width}d", v[off + s]).latin1())
                    }
                    expect.append('\n')
                    off += 6
                }
                assertEquals(expect.toString(), out.buf.toString(), "width $width")
            }
        }
    }

    @Test
    fun rdsampSampleNumbersEqualPrintf() {
        // successive numbers (carries at 9, 99, ...), jumps, negative numbers
        val rng = Random(13)
        val values = ArrayList<Long>()
        var v = 0L
        for (k in 0 until 200000) {
            v = when (rng.nextInt(1000)) {
                0 -> rng.nextLong(-100, 100)
                1 -> rng.nextLong(0, Long.MAX_VALUE)
                2 -> listOf(9L, 99L, 999L, 99999999L, 999999999999L, Long.MAX_VALUE - 2, -2L)[rng.nextInt(7)]
                3 -> v
                else -> v + 1
            }
            values.add(v)
        }
        for (width in intArrayOf(0, 15)) {
            val out = RdOut()
            val expect = StringBuilder()
            for (x in values) {
                out.sampleNumber(x, width)
                expect.append(cformat("%${width}ld", x).latin1())
            }
            assertEquals(expect.toString(), out.buf.toString(), "width $width")
        }
    }
}
