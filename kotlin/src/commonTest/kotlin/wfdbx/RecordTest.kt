// Tests of the high-level signal functions (readRecord, readHeader,
// writeRecord, the settings): ports of the high-level parts of
// python/tests/test_signals.py and rust/tests/signals.rs. The tests use a
// copy of tests/data (DataDir) as input and output directory.
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

import wfdbx.cstd.getenv
import wfdbx.cstd.latin1
import wfdbx.cstd.setenv
import wfdbx.cstd.unsetenv
import kotlin.math.abs
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RecordTest {
    private fun withData(name: String, f: (DataDir, Wfdb) -> Unit) {
        val d = DataDir(name)
        val w = d.wfdb()
        try {
            f(d, w)
        } finally {
            w.wfdbquit()
            d.remove()
        }
    }

    private fun str(b: ByteArray?): String? = b?.latin1()

    private fun fails(msg: String, f: () -> Unit) {
        val e = assertFailsWith<WfdbException> { f() }
        assertEquals(msg, e.message)
    }

    private fun failsContaining(part: String, f: () -> Unit) {
        val e = assertFailsWith<WfdbException> { f() }
        assertTrue(e.message!!.contains(part), "${e.message} does not contain $part")
    }

    /** The values of each frame of [x] (n frames of [nsig] values) as rows. */
    private fun rows(x: IntArray, nsig: Int): List<List<Int>> = x.asList().chunked(nsig)

    private fun near(a: Double, b: Double) = abs(a - b) < 1e-9

    /** Legacy mode reads from the WFDB path, not from the input directory: the WFDB path of [w] is set to [d]. */
    private fun legacyPath(w: Wfdb, d: DataDir) {
        val saved = getenv("WFDB")
        w.wfdbx_set_legacy(1)
        w.setwfdb(d.dir)
        w.wfdbx_set_legacy(0)
        if (saved == null) unsetenv("WFDB") else setenv("WFDB", saved)
    }

    // Ranges of random samples, and ADC resolutions, for each format
    private val ranges = mapOf(
        8 to 1000, 16 to 32767, 61 to 32767, 80 to 127, 160 to 32767, 212 to 2047, 310 to 511, 311 to 511,
        24 to 8388607, 32 to 2147483647, 508 to 127, 516 to 32767, 524 to 8388607,
    )
    private val res = mapOf(
        8 to 12, 16 to 16, 61 to 16, 80 to 8, 160 to 16, 212 to 12, 310 to 10, 311 to 10, 24 to 24, 32 to 32,
        508 to 8, 516 to 16, 524 to 24,
    )

    @Test
    fun roundtripEveryFormat() = withData("roundtrip") { _, w ->
        for (fmt in ranges.keys.sorted()) {
            for (nsig in 1..3) {
                val rng = Random(fmt * 10 + nsig)
                val hi = ranges.getValue(fmt)
                val n = if (fmt >= 500) 5003 else 1001
                val x = IntArray(n * nsig)
                if (fmt == 8) {
                    for (s in 0 until nsig) {
                        var v = 0
                        for (i in 0 until n) {
                            v += rng.nextInt(-60, 61)
                            x[i * nsig + s] = v
                        }
                    }
                } else {
                    for (i in x.indices) x[i] = rng.nextLong(-hi + 1L, hi + 1L).toInt()
                }
                w.writeRecord("rt", x, nsig, 250.0, fmt = fmt, gains = doubleArrayOf(200.0), adcres = intArrayOf(res.getValue(fmt)), units = listOf("mV"))
                val r = w.readRecord("rt")
                var y = r.samples
                if ((fmt == 310 || fmt == 311) && (n * nsig) % 3 == 2) {
                    // A final group of two samples is written in 4 bytes, so the
                    // file appears to contain an extra (zero) sample, as with C.
                    assertEquals(List(nsig) { 0 }, y.copyOfRange(y.size - nsig, y.size).toList())
                    y = y.copyOf(y.size - nsig)
                }
                assertContentEquals(x, y, "format $fmt, $nsig signals")
                assertEquals(250.0, r.fs)
                assertEquals(n, r.samples.size / nsig - (if ((fmt == 310 || fmt == 311) && (n * nsig) % 3 == 2) 1 else 0))
                // random access with the per-sample interface
                w.isigopen("rt", null, nsig)
                for (t in listOf(n - 1, 0, n / 2, 3, n - 2)) {
                    assertEquals((0 until nsig).map { x[t * nsig + it] }, (0 until nsig).map { w.sample(it, t.toLong()) })
                }
                w.wfdbquit()
            }
        }
    }

    @Test
    fun bulkEqualsGetvec() = withData("bulkgetvec") { _, w ->
        for (rec in listOf("fmt212", "fmt310", "fmt311", "fmt8", "twog", "100s")) {
            val n = w.isigopen(rec, null, 0)
            w.isigopen(rec, Array(n) { Siginfo() }, n)
            val v = IntArray(n)
            val ref = ArrayList<Int>()
            while (w.getvec(v) >= 0) for (x in v) ref.add(x)
            w.wfdbquit()
            w.wfdbquiet()
            val r = w.readRecord(rec)
            w.wfdbverbose()
            assertEquals(ref, r.samples.toList(), rec)
        }
    }

    @Test
    fun physicalUnitsAndRecordFields() = withData("physical") { _, w ->
        val r = w.readRecord("100s", to = TimeSpec(3), physical = true)
        val p = r.physical!!
        assertEquals(6, p.size)
        for (i in 0 until 3) {
            assertTrue(near(-0.145, p[2 * i]) && near(-0.065, p[2 * i + 1]))
            assertTrue(near(-0.145, r.physicalAt(i, 0)))
        }
        assertContentEquals(doubleArrayOf(p[1], p[3], p[5]), r.physicalSignal(1))
        assertEquals(listOf("MLII", "V5"), r.names)
        assertEquals(listOf<String?>(null, null), r.units)
        assertEquals(listOf(200.0, 200.0), r.gains)
        assertEquals(listOf(1024, 1024), r.baselines)
        assertEquals(360.0, r.fs)
        assertEquals(2, r.nsig)
        assertEquals(3, r.nsamples)
        assertContentEquals(intArrayOf(0, 1), r.signalNumbers)
        assertContentEquals(intArrayOf(995, 995, 995), r.signal(0))
        assertEquals(995, r.at(2, 0))
        assertTrue(r.checksumOk)
        assertEquals(0L, r.sampfrom)
        // without physical: no physical array
        assertNull(w.readRecord("100s", to = TimeSpec(3)).physical)
        // channels by name and number, in the order given
        val c = w.readRecord("100s", channels = listOf("V5", "0"), from = TimeSpec("0:10"), to = TimeSpec("0:20"))
        assertEquals(3600, c.nsamples)
        assertEquals(3600L, c.sampfrom)
        assertContentEquals(intArrayOf(1, 0), c.signalNumbers)
        assertEquals(listOf("V5", "MLII"), c.names)
        val full = w.readRecord("100s", from = TimeSpec(3600), to = TimeSpec(7200))
        assertEquals(full.signal(1).toList(), c.signal(0).toList())
        assertEquals(full.signal(0).toList(), c.signal(1).toList())
        fails("record 100s has no signal V9") { w.readRecord("100s", channels = listOf("V9")) }
        fails("record 100s has no signal 2") { w.readRecord("100s", channels = listOf("2")) }
        // "e", and times of day
        assertEquals(21600, w.readRecord("100s", to = TimeSpec("e")).nsamples)
        // the info strings
        assertEquals(w.readHeader("100s").comments, w.readRecord("100s", to = TimeSpec(1)).comments)
    }

    @Test
    fun multifrequencyAndVariableLayout() = withData("mfreq") { _, w ->
        val lo = w.readRecord("mfreq", to = TimeSpec(10))
        val hi = w.readRecord("mfreq", to = TimeSpec(20), highres = true)
        assertEquals(Pair(10, 3), Pair(lo.nsamples, lo.nsig))
        assertEquals(Pair(20, 3), Pair(hi.nsamples, hi.nsig))
        assertEquals(400.0, hi.fs)
        assertEquals(100.0, lo.fs)
        w.wfdbquiet()
        val r = w.readRecord("vlay", from = TimeSpec(1498), to = TimeSpec(1502))
        w.wfdbverbose()
        assertEquals(List(3) { WFDB_INVALID_SAMPLE }, rows(r.samples, r.nsig)[2])
    }

    @Test
    fun headerWriting() = withData("hw") { d, w ->
        w.writeRecord(
            "hw", IntArray(20), 2, 125.5, fmt = 16, gains = doubleArrayOf(100.0, 0.0), adcres = intArrayOf(16),
            units = listOf("mV", "uV"), names = listOf("lead I", "pressure"), baseTime = "12:00:00 01/02/2003",
            comments = listOf("c1"),
        )
        val text = d.read("hw.hea")!!.latin1()
        assertTrue(text.startsWith("hw 2 125.5 10 12:00:00 01/02/2003\r\n"), text)
        assertTrue("hw.dat 16 100/mV 16 0 0 0 0 lead I\r\n" in text, text)
        assertTrue(text.endsWith("#c1\r\n"), text)
    }

    // wfdb-x: no default sampling frequency, gain, ADC resolution or units
    // (see docs/DIVERGENCES.md)

    @Test
    fun writeRecordRequiresGainsAndFrequency() = withData("nodefw") { _, w ->
        val x = IntArray(20)
        fails("writeRecord: gains must be specified") { w.writeRecord("nd", x, 2, 250.0, adcres = intArrayOf(16), units = listOf("mV")) }
        fails("writeRecord: gains must be specified") {
            w.writeRecord("nd", x, 2, 250.0, gains = doubleArrayOf(200.0, 100.0, 1.0).copyOf(0), adcres = intArrayOf(16), units = listOf("mV"))
        }
        for (fs in listOf(0.0, -1.0, Double.NaN)) {
            fails("writeRecord: the sampling frequency must be > 0") {
                w.writeRecord("nd", x, 2, fs, gains = doubleArrayOf(200.0), adcres = intArrayOf(16), units = listOf("mV"))
            }
        }
        fails("writeRecord: signal 1 is uncalibrated") {
            w.writeRecord("nd", DoubleArray(20), 2, 250.0, gains = doubleArrayOf(200.0, 0.0), adcres = intArrayOf(16), units = listOf("mV"))
        }
        fails("writeRecord: no signals") { w.writeRecord("nd", x, 0, 250.0) }
        fails("writeRecord: the number of samples is not a multiple of the frame size") {
            w.writeRecord("nd", IntArray(5), 2, 250.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(16), units = listOf("mV"))
        }
        // a gain of 0 (uncalibrated) is allowed for samples in ADC units,
        // and such a signal needs no units
        w.writeRecord("nd", x, 2, 250.0, gains = doubleArrayOf(200.0, 0.0), adcres = intArrayOf(16), units = listOf("mV", null))
        val r = w.readRecord("nd")
        assertEquals(listOf(200.0, 0.0), r.gains)
        assertEquals(listOf("mV", null), r.units)
    }

    @Test
    fun writeRecordFrameChecks() = withData("spfchk") { d, w ->
        // Each signal has at least one sample per frame, checked before
        // anything else (in both modes); nothing is written otherwise.
        val x = IntArray(8) { it }
        val msg = "writeRecord: sampsPerFrame must hold integers >= 1"
        for (spf in listOf(intArrayOf(0, 2), intArrayOf(2, 0), intArrayOf(-1, 3), intArrayOf(0))) {
            for (legacy in listOf(false, true)) {
                fails(msg) {
                    w.writeRecord("bad", x, spf.size, 250.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(16), units = listOf("mV"), sampsPerFrame = spf, legacy = legacy)
                }
                fails(msg) { w.writeRecord("bad", DoubleArray(8), spf.size, 0.0, sampsPerFrame = spf, dir = d.path("nosuch"), legacy = legacy) }
                assertFalse(fileExists(d.path("bad.hea")))
                assertFalse(fileExists(d.path("bad.dat")))
            }
        }
        for (spf in listOf(intArrayOf(3), intArrayOf(1, 2))) {
            fails("writeRecord: the number of samples is not a multiple of the frame size") {
                w.writeRecord("bad", x, spf.size, 250.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(16), units = listOf("mV"), sampsPerFrame = spf)
            }
            assertFalse(fileExists(d.path("bad.hea")))
        }
        w.writeRecord("good", x, 1, 250.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(16), units = listOf("mV"), sampsPerFrame = intArrayOf(2))
        assertEquals(4, w.readRecord("good").nsamples)
        assertContentEquals(x, w.readRecord("good", highres = true).samples)
        w.writeRecord("good", x, 2, 250.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(16), units = listOf("mV"), sampsPerFrame = intArrayOf(1, 1))
        assertContentEquals(x, w.readRecord("good").samples)
    }

    @Test
    fun writeRecordRequiresResolutionAndUnits() = withData("nodefr") { _, w ->
        val x = IntArray(20)
        for (r in listOf(null, intArrayOf(16, 0), intArrayOf(0), intArrayOf(16, 12, 0).copyOf(0))) {
            fails("writeRecord: ADC resolution(s) must be specified") {
                w.writeRecord("nd", x, 2, 250.0, gains = doubleArrayOf(200.0), adcres = r, units = listOf("mV"))
            }
        }
        for (u in listOf(null, listOf("mV", null), listOf("mV", ""), listOf(""))) {
            fails("writeRecord: units must be specified") {
                w.writeRecord("nd", x, 2, 250.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = u)
            }
        }
        w.writeRecord("nd", x, 2, 250.0, fmt = 212, gains = doubleArrayOf(200.0, 100.0), adcres = intArrayOf(11, 12), units = listOf("mV", "uV"))
        val r = w.readRecord("nd")
        assertEquals(listOf(11, 12), r.siginfo.map { it.adcres })
        assertEquals(listOf("mV", "uV"), r.units)
    }

    @Test
    fun readRecordUnspecifiedResolutionAndUnits() = withData("nr") { d, w ->
        legacyPath(w, d)
        writeFile(d.path("nr.hea"), "nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n")
        val r = w.readRecord("nr", to = TimeSpec(10))
        assertEquals(listOf(0, 0), r.siginfo.map { it.adcres })
        assertEquals(listOf<String?>(null, null), r.units)
        // readHeader: the same; legacy mode: the original defaults
        assertEquals(listOf(0, 0), w.readHeader("nr").siginfo.map { it.adcres })
        assertEquals(listOf(12, 12), w.readHeader("nr", legacy = true).siginfo.map { it.adcres })
    }

    private fun writeNofreq(d: DataDir) = writeFile(
        d.path("nf.hea"),
        "nf 2\n100s.dat 212 200 11 1024 995 21537 0 MLII\n100s.dat 212 0 11 1024 1011 -3962 0 V5\n",
    )

    @Test
    fun readRecordWithoutFrequency() = withData("nf") { d, w ->
        writeNofreq(d)
        val r = w.readRecord("nf", from = TimeSpec("s1"), to = TimeSpec("s4"))
        assertEquals(0.0, r.fs)
        assertNull(r.baseTime)
        assertEquals(w.readRecord("100s", from = TimeSpec(1), to = TimeSpec(4)).samples.toList(), r.samples.toList())
        assertEquals(0, w.readRecord("nf", to = TimeSpec("e")).samples.size)
        for ((f, t) in listOf(TimeSpec("0:1") to null, TimeSpec(0) to TimeSpec("1:0"), TimeSpec("[10:00:00]") to null, TimeSpec("f3") to null)) {
            fails("sampling frequency of record nf is not specified") { w.readRecord("nf", from = f, to = t) }
        }
        // uncalibrated signals
        val p = w.readRecord("nf", channels = listOf("0"), to = TimeSpec(3), physical = true)
        assertTrue(p.physical!!.all { near(-0.145, it) })
        fails("signal 1 of record nf is uncalibrated") { w.readRecord("nf", to = TimeSpec(3), physical = true) }
        val a = w.readRecord("nf", to = TimeSpec(3))
        assertEquals(listOf(200.0, 0.0), a.gains)
        fails("signal 1 of record nf is uncalibrated") { a.physicalSignal(1) }
    }

    // wfdb-x: legacy mode (the original package's defaults, on request)

    @Test
    fun writeRecordLegacy() = withData("lgw") { d, w ->
        legacyPath(w, d)
        val x = IntArray(20) { it }
        w.writeRecord("lg", x, 2, 250.0, fmt = 212, legacy = true)
        assertFalse(w.wfdbxGetLegacy())
        var r = w.readRecord("lg")
        assertEquals(listOf(200.0, 200.0), r.gains)
        assertEquals(listOf<String?>(null, null), r.units)
        assertEquals(listOf(12, 12), r.siginfo.map { it.adcres })
        assertContentEquals(x, r.samples)
        // physical units, gain 0: the default gain
        w.writeRecord("lg", doubleArrayOf(1.0, -0.5), 1, 360.0, gains = doubleArrayOf(0.0), legacy = true)
        r = w.readRecord("lg")
        assertEquals(listOf(200, -100), r.samples.toList())
        assertEquals(listOf(16), r.siginfo.map { it.adcres })
        // without legacy, the same calls fail
        fails("writeRecord: gains must be specified") { w.writeRecord("lg", x, 2, 250.0, fmt = 212) }
    }

    @Test
    fun readRecordLegacy() = withData("lgr") { d, w ->
        legacyPath(w, d)
        writeNofreq(d)
        var r = w.readRecord("nf", to = TimeSpec("0:0.012"), physical = true, legacy = true)
        assertFalse(w.wfdbxGetLegacy())
        assertEquals(250.0, r.fs)
        assertEquals(3, r.nsamples)
        assertTrue(r.legacy)
        // signal 1 is uncalibrated: gain 200
        val adc = w.readRecord("nf", to = TimeSpec(3))
        for (i in 0 until 3) {
            assertTrue(near(-0.145, r.physical!![2 * i]))
            assertTrue(near((adc.at(i, 1) - 1024) / 200.0, r.physical!![2 * i + 1]))
            assertTrue(near((adc.at(i, 1) - 1024) / 200.0, r.physicalAt(i, 1)))
        }
        assertEquals(listOf(200.0, 0.0), r.gains)
        // the uncalibrated record null (its samples are all invalid: NaN)
        r = w.readRecord("null", to = TimeSpec(4), physical = true, legacy = true)
        assertEquals(listOf(0.0, 0.0), r.gains)
        assertTrue(r.physical!!.all { it.isNaN() })
        // the previous setting is restored, also on errors
        assertFailsWith<WfdbException> { w.readRecord("nf", channels = listOf("9"), legacy = true) }
        assertFalse(w.wfdbxGetLegacy())
        w.wfdbxSetLegacy(true)
        w.readRecord("nf", to = TimeSpec(1), legacy = true)
        assertTrue(w.wfdbxGetLegacy())
        // (the library's legacy mode applies to a call without legacy = true)
        assertTrue(w.readRecord("nf", to = TimeSpec(1)).legacy)
        w.wfdbxSetLegacy(false)
        failsContaining("uncalibrated") { w.readRecord("null", to = TimeSpec(4), physical = true) }
    }

    // -----------------------------------------------------------------------
    // The bulk writer of writeRecord (putframes): byte for byte as putvec

    private fun writeBoth(d: DataDir, w: Wfdb, x: IntArray, nsig: Int, fmt: Int, spf: IntArray? = null): Pair<List<ByteArray>, List<ByteArray>> {
        val out = ArrayList<List<ByteArray>>()
        for (bulk in listOf(true, false)) {
            val dir = d.path(if (bulk) "fast" else "slow")
            if (!fileExists("$dir/.keep")) writeFile("$dir/.keep", "")
            bulkPutOff = !bulk
            try {
                w.writeRecord(
                    "r", x, nsig, 360.0, fmt = fmt, gains = doubleArrayOf(200.0), adcres = intArrayOf(res.getValue(fmt)),
                    units = listOf("mV"), sampsPerFrame = spf, dir = dir,
                )
            } finally {
                bulkPutOff = false
            }
            out.add(listOf(readFile("$dir/r.dat")!!, readFile("$dir/r.hea")!!))
        }
        return Pair(out[0], out[1])
    }

    private fun assertSameFiles(p: Pair<List<ByteArray>, List<ByteArray>>, what: String) {
        assertContentEquals(p.second[0], p.first[0], "$what: signal file")
        assertContentEquals(p.second[1], p.first[1], "$what: header")
    }

    @Test
    fun bulkWriteIdentical() = withData("bulkwrite") { d, w ->
        val mins = mapOf(
            8 to Int.MIN_VALUE, 16 to -32768, 61 to -32768, 160 to -32768, 80 to -128, 212 to -2048, 310 to -512,
            311 to -512, 24 to -(1 shl 23), 32 to Int.MIN_VALUE,
        )
        for (fmt in listOf(8, 16, 24, 32, 61, 80, 160, 212, 310, 311)) {
            for (nsig in 1..3) {
                for (n in listOf(1, 2, 3, 7, 1000)) {
                    val rng = Random(fmt + 7 * nsig + n)
                    val lo = mins.getValue(fmt)
                    val hi = -(lo + 1)
                    val x = IntArray(n * nsig)
                    if (fmt == 8) {
                        for (s in 0 until nsig) {
                            var v = rng.nextInt(-1000, 1000)
                            for (i in 0 until n) {
                                x[i * nsig + s] = v
                                v += rng.nextInt(-128, 128)
                            }
                        }
                    } else {
                        for (i in x.indices) x[i] = rng.nextLong(lo.toLong(), hi.toLong() + 1).toInt()
                        for (i in x.indices step 5) x[i] = lo // (edge values; lo is the invalid value)
                        for (i in 1 until x.size step 7) x[i] = hi
                        for (i in 2 until x.size step 11) x[i] = WFDB_INVALID_SAMPLE
                    }
                    assertSameFiles(writeBoth(d, w, x, nsig, fmt), "format $fmt, $nsig signals, $n frames")
                }
            }
            // samples outside the range of the format (or, for format 8, too
            // large differences)
            val y = intArrayOf(0, 1, 40000, -5, 3, 2, -70000, 9, Int.MAX_VALUE, Int.MIN_VALUE + 1)
            assertSameFiles(writeBoth(d, w, y, 2, fmt), "format $fmt, out of range")
        }
        // multi-frequency records: signal 0 (2 samples per frame), then signal 1
        for (fmt in listOf(16, 212, 310, 8, 24)) {
            val rng = Random(fmt)
            val x = IntArray(101 * 3) { rng.nextInt(-500, 501) }
            assertSameFiles(writeBoth(d, w, x, 2, fmt, intArrayOf(2, 1)), "format $fmt, spf 2 1")
            val z = IntArray(33 * 6) { rng.nextInt(-500, 501) }
            assertSameFiles(writeBoth(d, w, z, 3, fmt, intArrayOf(1, 3, 2)), "format $fmt, spf 1 3 2")
        }
        // FLAC (putvec for each frame): the record reads back
        val x = IntArray(3000) { (it * 37) % 2000 - 1000 }
        w.writeRecord("fl", x, 3, 250.0, fmt = 516, gains = doubleArrayOf(200.0), adcres = intArrayOf(16), units = listOf("mV"))
        assertContentEquals(x, w.readRecord("fl").samples)
    }

    @Test
    fun physicalWriting() = withData("physw") { _, w ->
        // round(x * gain) + baseline, halves away from zero; NaN: invalid
        val x = doubleArrayOf(0.0, 0.0025, -0.0025, 1.0, Double.NaN, -1.0, 0.0124, -0.0126)
        w.writeRecord("pw", x, 2, 100.0, gains = doubleArrayOf(200.0, 1000.0), baselines = intArrayOf(10, -5), adcres = intArrayOf(16), units = listOf("mV"))
        val r = w.readRecord("pw", physical = true)
        assertEquals(listOf(10, -2, 9, 995, WFDB_INVALID_SAMPLE, -1005, 12, -18), r.samples.toList())
        assertTrue(r.physical!![4].isNaN())
        assertTrue(near(1.0, r.physical!![3]))
        // samples per frame: the gain of each column
        w.writeRecord("pm", doubleArrayOf(1.0, 2.0, 3.0), 2, 100.0, gains = doubleArrayOf(10.0, 100.0), adcres = intArrayOf(16), units = listOf("mV"), sampsPerFrame = intArrayOf(2, 1))
        assertEquals(listOf(15, 300), w.readRecord("pm").samples.toList())
        assertEquals(listOf(10, 20, 300), w.readRecord("pm", highres = true).samples.toList().let { listOf(it[0], it[2], it[1]) })
    }

    // -----------------------------------------------------------------------
    // writeRecord(dir = ...) (WFDB-x)

    @Test
    fun writeRecordDir() = withData("wrdir") { d, w ->
        val x = IntArray(20) { it }
        writeFile(d.path("out/.keep"), "")
        val prev = w.wfdbxSetOutputDir(d.path("elsewhere"))
        w.writeRecord("rec", x, 2, 360.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("mV"), dir = d.path("out"))
        assertEquals(d.path("elsewhere"), w.wfdbxGetOutputDir()) // restored
        w.wfdbxSetOutputDir(prev)
        assertEquals(listOf(".keep", "rec.dat", "rec.hea"), listFiles(d.path("out")))
        assertFalse(fileExists(d.path("rec.hea")))
        val hea = readFile(d.path("out/rec.hea"))!!.latin1().lines()
        assertEquals("rec 2 360 10", hea[0])
        assertTrue(hea[1].startsWith("rec.dat 16 "))
        assertContentEquals(x, w.readRecord("rec", inputDir = d.path("out")).samples)
        assertContentEquals(x, w.readRecord("out/rec").samples)
        assertEquals(d.dir, w.wfdbxGetOutputDir())
        fails("directory ${d.path("nosuch")} does not exist") {
            w.writeRecord("rec", x, 2, 360.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("mV"), dir = d.path("nosuch"))
        }
        fails("record name must not contain a directory when dir is given") {
            w.writeRecord("sub/rec", x, 2, 360.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(12), units = listOf("mV"), dir = d.path("out"))
        }
        // the dir checks come first; the setting is restored after an error
        fails("record name must not contain a directory when dir is given") { w.writeRecord("sub/rec", x, 2, 0.0, dir = d.path("out")) }
        fails("directory ${d.path("nosuch")} does not exist") { w.writeRecord("rec", x, 2, 0.0, dir = d.path("nosuch")) }
        fails("writeRecord: gains must be specified") { w.writeRecord("rec", x, 2, 360.0, dir = d.path("out")) }
        assertEquals(d.dir, w.wfdbxGetOutputDir())
        // the same in legacy mode
        w.writeRecord("leg", x, 2, 360.0, dir = d.path("out"), legacy = true)
        assertTrue(readFile(d.path("out/leg.hea"))!!.latin1().startsWith("leg 2 360 10"))
    }

    @Test
    fun recordNames() = withData("names") { d, w ->
        w.wfdbquiet()
        val x = IntArray(10) { it }
        for (name in listOf("my.data/rec", d.path("a.b/c.d/rec"))) {
            w.writeRecord(name, x, 1, 100.0, gains = doubleArrayOf(100.0), adcres = intArrayOf(16), units = listOf("mV"))
            val path = if (name.startsWith("/")) name else d.path(name)
            assertTrue(readFile("$path.hea")!!.latin1().startsWith("rec 1 100 10\r\nrec.dat 16 "), name)
            assertContentEquals(x, w.readRecord(name).samples, name)
        }
        // the last component must be a valid record name
        failsContaining("rec.1") { w.writeRecord("rec.1", x, 1, 100.0, gains = doubleArrayOf(100.0), adcres = intArrayOf(16), units = listOf("mV")) }
        assertEquals("init: illegal character 46 in record name\n", str(w.wfdberror()))
        // a name whose last part has a dot is a file name: 100s.hea is the
        // header of 100s
        assertEquals(w.readRecord("100s", to = TimeSpec(5)), w.readRecord("100s.hea", to = TimeSpec(5)).copy(name = "100s"))
        // legacy mode: the whole name is checked, and names are written as given
        assertFailsWith<WfdbException> {
            w.writeRecord("my.data/rec2", x, 1, 100.0, gains = doubleArrayOf(100.0), adcres = intArrayOf(16), units = listOf("mV"), legacy = true)
        }
        assertEquals("init: illegal character 46 in record name\n", str(w.wfdberror()))
        writeFile(d.path("out/.keep"), "")
        w.writeRecord("out/rec", x, 1, 100.0, legacy = true)
        assertTrue(readFile(d.path("out/rec.hea"))!!.latin1().startsWith("out/rec 1 100 10\r\n"))
        // absolute names are read as given (not from the input directory)
        val abs = d.path("100s")
        w.wfdbxSetInputDir(d.path("nonexistent"))
        assertEquals(7200, w.readRecord(abs, to = TimeSpec(3600)).samples.size)
        assertEquals(75, w.readAnnotations(abs, "atr").size)
        assertFailsWith<WfdbException> { w.readRecord("100s") }
    }

    // -----------------------------------------------------------------------
    // Read errors and checksums

    private fun writeTruncated(w: Wfdb, d: DataDir): IntArray {
        val x = intArrayOf(1, 2, 3, 4, 5, 6, 7, 8)
        for (name in listOf("tr", "ok")) w.writeRecord(name, x, 2, 100.0, gains = doubleArrayOf(100.0), adcres = intArrayOf(16), units = listOf("mV"))
        writeFile(d.path("tr.dat"), d.read("tr.dat")!!.copyOf(8)) // 2 frames of 2 format-16 samples
        return x
    }

    @Test
    fun readRecordTruncatedSignalFile() = withData("trunc") { d, w ->
        legacyPath(w, d)
        w.wfdbquiet()
        for (legacy in listOf(false, true)) {
            val x = writeTruncated(w, d)
            // unexpected EOF (getvec status -3) is an error, not the end of data
            for (phys in listOf(false, true)) {
                fails("can't read signal data of record tr (getvec status -3)") { w.readRecord("tr", physical = phys, legacy = legacy) }
                // the library is left usable: a good record reads normally
                assertContentEquals(x, w.readRecord("ok", legacy = legacy).samples)
            }
            // reading only what the file holds is not an error
            assertContentEquals(x.copyOf(4), w.readRecord("tr", to = TimeSpec(2), legacy = legacy).samples)
            // sub-intervals, and `to` past the end of a record whose header gives its length
            assertContentEquals(x.copyOfRange(2, 6), w.readRecord("ok", from = TimeSpec(1), to = TimeSpec(3), legacy = legacy).samples)
            assertContentEquals(x, w.readRecord("ok", to = TimeSpec(10), legacy = legacy).samples)
            fails("can't seek to sample 10 of record ok") { w.readRecord("ok", from = TimeSpec(10), legacy = legacy) }
            // the low-level API is unchanged: getvec returns -3
            w.isigopen("tr", null, 2)
            val v = IntArray(2)
            assertEquals(listOf(2, 2, -3), List(3) { w.getvec(v) })
            w.wfdbquit()
        }
        fails("can't read record nosuch") { w.readRecord("nosuch") }
        fails("can't read header for record nosuch") { w.readHeader("nosuch") }
    }

    private val cksumMsg = "checksum error in record ck: the signal data do not match the checksums in its header"

    @Test
    fun readRecordChecksumWarning() = withData("cksum") { d, w ->
        legacyPath(w, d)
        for (legacy in listOf(false, true)) {
            val x = intArrayOf(1, 2, 3, 4, 5, 6, 7, 8)
            w.writeRecord("ck", x, 2, 100.0, gains = doubleArrayOf(100.0), adcres = intArrayOf(16), units = listOf("mV"))
            val data = d.read("ck.dat")!!
            data[4] = 9 // sample (1, 0): 3 -> 9
            writeFile(d.path("ck.dat"), data)
            val y = x.copyOf()
            y[2] = 9
            w.writeRecord("good", y, 2, 100.0, gains = doubleArrayOf(100.0), adcres = intArrayOf(16), units = listOf("mV"))
            val good = w.readRecord("good", legacy = legacy)
            assertTrue(good.checksumOk)
            for (phys in listOf(false, true)) {
                val got = ArrayList<String>()
                val r = w.readRecord("ck", physical = phys, legacy = legacy, onWarning = { got.add(it) })
                assertEquals(listOf(cksumMsg), got)
                assertContentEquals(y, r.samples) // (every frame, the last one included)
                assertFalse(r.checksumOk)
                if (phys) assertTrue(near(0.09, r.physical!![2]))
            }
            // the default: "wfdb-x: " + the message, as a library message
            // (printed unless wfdbquiet was called)
            w.wfdbquiet()
            w.readRecord("ck", legacy = legacy)
            assertEquals("wfdb-x: $cksumMsg\n", str(w.wfdberror()))
            w.wfdbverbose()
            // checksumWarning = false: no warning; checksumOk false either way
            val none = ArrayList<String>()
            val r = w.readRecord("ck", checksumWarning = false, legacy = legacy, onWarning = { none.add(it) })
            assertTrue(none.isEmpty())
            assertContentEquals(good.samples, r.samples)
            assertFalse(r.checksumOk)
            // not read to the end: no checksum is verified
            val r3 = w.readRecord("ck", to = TimeSpec(3), legacy = legacy, onWarning = { none.add(it) })
            assertTrue(r3.checksumOk && none.isEmpty())
            assertContentEquals(y.copyOf(6), r3.samples)
            assertContentEquals(y.copyOfRange(2, 8), w.readRecord("ck", from = TimeSpec(1), to = TimeSpec("e"), checksumWarning = false, legacy = legacy).samples)
            // the low-level API is unchanged: getvec returns -4 for the last frame
            w.wfdbquiet()
            w.isigopen("ck", null, 2)
            val v = IntArray(2)
            assertEquals(listOf(2, 2, 2, -4), List(4) { w.getvec(v) })
            assertEquals(listOf(7, 8), v.toList())
            assertEquals("getvec: checksum error in signal 0\n", str(w.wfdberror()))
            w.wfdbquit()
            w.wfdbverbose()
        }
    }

    /** A format 16 record of [nframes] frames with samples per frame [spf], samples 1, 2, 3, ...; with [bad] (frame, signal), that sample is 99 in the file only. */
    private fun writeMf(w: Wfdb, d: DataDir, name: String, spf: IntArray, nframes: Int, bad: Pair<Int, Int>?): IntArray {
        val width = spf.sum()
        val x = IntArray(nframes * width) { it + 1 }
        w.writeRecord(name, x, spf.size, 100.0, sampsPerFrame = spf, gains = doubleArrayOf(100.0), adcres = intArrayOf(16), units = listOf("mV"))
        if (bad == null) return x
        val k = bad.first * width + spf.copyOf(bad.second).sum()
        val data = d.read("$name.dat")!!
        data[2 * k] = 99
        data[2 * k + 1] = 0
        writeFile(d.path("$name.dat"), data)
        val y = x.copyOf()
        y[k] = 99
        return y
    }

    @Test
    fun readRecordHighresChecksumError() = withData("hrck") { d, w ->
        val nframes = 4
        for (spf in listOf(intArrayOf(2), intArrayOf(3), intArrayOf(1, 2), intArrayOf(2, 3))) {
            for (where in listOf("first", "last")) {
                val bad = Pair(if (where == "first") 0 else nframes - 1, spf.size - 1)
                val x = writeMf(w, d, "mf", spf, nframes, bad)
                w.writeRecord("good", x, spf.size, 100.0, sampsPerFrame = spf, gains = doubleArrayOf(100.0), adcres = intArrayOf(16), units = listOf("mV"))
                val n = nframes * spf.max()
                val all = (0 until spf.size).map { it.toString() }
                for (chans in listOf(null, listOf((spf.size - 1).toString()), all.reversed())) {
                    val good = w.readRecord("good", channels = chans, highres = true)
                    assertTrue(good.checksumOk)
                    assertEquals(n, good.nsamples)
                    val warnings = ArrayList<String>()
                    val r = w.readRecord("mf", channels = chans, highres = true, onWarning = { warnings.add(it) })
                    assertFalse(r.checksumOk)
                    assertContentEquals(good.samples, r.samples)
                    assertEquals(listOf(cksumMsg.replace(" ck:", " mf:")), warnings)
                    val p = w.readRecord("mf", channels = chans, highres = true, physical = true, checksumWarning = false)
                    assertEquals(good.samples.map { it / 100.0 }, p.physical!!.toList())
                    val lo = w.readRecord("good", channels = chans)
                    val rl = w.readRecord("mf", channels = chans, checksumWarning = false)
                    assertFalse(rl.checksumOk)
                    assertEquals(nframes, rl.nsamples)
                    assertContentEquals(lo.samples, rl.samples)
                }
                // a read ending before the last frame verifies no checksum
                val good = w.readRecord("good", highres = true)
                for (to in listOf(n - spf.max(), n - spf.max() / 2 - 1, n - 1)) {
                    val r = w.readRecord("mf", highres = true, to = TimeSpec(to), checksumWarning = false)
                    assertContentEquals(good.samples.copyOf(to * good.nsig), r.samples)
                    if (to <= n - spf.max()) assertTrue(r.checksumOk)
                }
                val from = n - spf.max() - 1
                val r = w.readRecord("mf", highres = true, from = TimeSpec(from), checksumWarning = false)
                assertContentEquals(good.samples.copyOfRange(from * good.nsig, good.samples.size), r.samples)
            }
        }
        // the example of the specification: spf 2, the first sample is 99
        w.writeRecord("mf", IntArray(8) { it + 1 }, 1, 100.0, sampsPerFrame = intArrayOf(2), gains = doubleArrayOf(100.0), adcres = intArrayOf(16), units = listOf("mV"))
        val data = d.read("mf.dat")!!
        data[0] = 99
        writeFile(d.path("mf.dat"), data)
        val r = w.readRecord("mf", highres = true, checksumWarning = false)
        assertEquals(listOf(99, 2, 3, 4, 5, 6, 7, 8), r.samples.toList())
        assertFalse(r.checksumOk)
    }

    // -----------------------------------------------------------------------
    // readHeader, base time and date

    private fun setRecordLine(d: DataDir, name: String, line: String) {
        val text = d.read("$name.hea")!!.latin1()
        writeFile(d.path("$name.hea"), line + "\n" + text.substring(text.indexOf('\n') + 1))
    }

    @Test
    fun readHeaderFields() = withData("hdr") { d, w ->
        legacyPath(w, d)
        for (legacy in listOf(false, true)) {
            w.writeRecord("bt", IntArray(20) { it }, 2, 250.0, gains = doubleArrayOf(200.0), adcres = intArrayOf(16), units = listOf("mV"), comments = listOf("first", "second"))
            for ((line, ms, date, text) in listOf(
                listOf("bt 2 250/1000(7) 10 14:00:03.500 21/06/2024", 50403500L, BaseDate(2024, 6, 21), "[14:00:03 21/06/2024]"),
                listOf("bt 2 250/1000(7) 10 14:00:03", 50403000L, null, "[14:00:03]"),
                listOf("bt 2 250/1000(7) 10", null, null, null),
            )) {
                setRecordLine(d, "bt", line as String)
                val h = w.readHeader("bt", legacy = legacy)
                assertEquals(listOf<Any>("bt", 250.0, 1000.0, 7.0, 10L, 2), listOf(h.name, h.fs, h.counterFreq, h.baseCounter, h.nsamples, h.nsig))
                assertEquals(listOf("record bt, signal 0", "record bt, signal 1"), h.siginfo.map { str(it.desc) })
                assertEquals(200.0, h.siginfo[0].gain)
                assertEquals(1, h.siginfo[1].initval)
                assertEquals(listOf(text, ms, date), listOf(h.baseTime, h.baseTimeMs, h.baseDate))
                assertEquals(listOf("first", "second"), h.comments)
                val r = w.readRecord("bt", legacy = legacy)
                assertEquals(listOf(text, ms, date), listOf(r.baseTime, r.baseTimeMs, r.baseDate))
                assertEquals(h.comments, r.comments)
            }
            // no frequency, no length: fs 0 (legacy: 250) and nsamples 0
            setRecordLine(d, "bt", "bt 2")
            val h = w.readHeader("bt", legacy = legacy)
            assertEquals(if (legacy) listOf(250.0, 250.0, 0L) else listOf(0.0, 0.0, 0L), listOf(h.fs, h.counterFreq, h.nsamples))
            assertEquals(listOf(null, null, null), listOf(h.baseTime, h.baseTimeMs, h.baseDate))
            w.wfdbquiet()
            fails("can't read header for record nx") { w.readHeader("nx", legacy = legacy) }
            w.wfdbverbose()
        }
        // no signals
        writeFile(d.path("ns.hea"), "ns 0 100 1000 08:00:00 01/02/2003\n#note\n")
        val h = w.readHeader("ns")
        assertEquals(listOf<Any>(0, 100.0, 1000L), listOf(h.nsig, h.fs, h.nsamples))
        assertTrue(h.siginfo.isEmpty())
        assertEquals(28800000L, h.baseTimeMs)
        assertEquals(BaseDate(2003, 2, 1), h.baseDate)
        assertEquals(listOf("note"), h.comments)
        w.wfdbquiet()
        fails("can't read record ns") { w.readRecord("ns") }
    }

    @Test
    fun namesWithoutSpaces() = withData("namesp") { d, w ->
        // Descriptions that end (or begin) with white space in the header are
        // given without it by the high-level readers, and found by that name;
        // the C-style functions keep it, as in C.
        writeFile(
            d.path("sp.hea"),
            "sp 3 250 4\nfmt16.dat 16 200/mV 16 0 0 0 0 III \nfmt16.dat 16 200/mV 16 0 0 0 0 ABP\t \n" +
                "fmt16.dat 16 200/mV 16 0 0 0 0 PLETH\n",
        )
        legacyPath(w, d)
        w.wfdbquiet()
        val want = listOf("III", "ABP", "PLETH")
        for (legacy in listOf(false, true)) {
            val r = w.readRecord("sp", legacy = legacy, checksumWarning = false)
            assertEquals(want, r.names)
            assertEquals(want, r.siginfo.map { str(it.desc) })
            assertEquals(want, w.readHeader("sp", legacy = legacy).siginfo.map { str(it.desc) })
            val r2 = w.readRecord("sp", channels = listOf("ABP", "III ", "2"), legacy = legacy, checksumWarning = false)
            assertEquals(listOf("ABP", "III", "PLETH"), r2.names)
            assertEquals(r.nsamples, r2.nsamples)
            for (i in 0 until r.nsamples) {
                assertEquals(listOf(r.at(i, 1), r.at(i, 0), r.at(i, 2)), listOf(r2.at(i, 0), r2.at(i, 1), r2.at(i, 2)))
            }
        }
        val si = Array(3) { Siginfo() }
        assertEquals(3, w.isigopen("sp", si, 3))
        assertEquals(listOf("III ", "ABP\t ", "PLETH"), si.map { str(it.desc) })
        w.wfdbquit()
    }

    @Test
    fun readRecordBulkEqualsPerFrame() = withData("bulkread") { d, w ->
        w.wfdbquiet()
        for (fmt in listOf(8, 80, 16, 61, 160, 24, 32, 212, 310, 311)) {
            val rng = Random(fmt)
            for (nsig in 1..4) {
                val n = rng.nextInt(5000, 30000)
                val hi = if (fmt == 8) 30000 else ranges.getValue(fmt)
                val x = IntArray(n * nsig)
                if (fmt == 8) {
                    for (s in 0 until nsig) {
                        var v = 0
                        for (i in 0 until n) {
                            v += rng.nextInt(-60, 61)
                            x[i * nsig + s] = v
                        }
                    }
                } else {
                    for (i in x.indices) x[i] = if (rng.nextDouble() < 0.01) WFDB_INVALID_SAMPLE else rng.nextLong(-hi + 1L, hi + 1L).toInt()
                    for (i in 0 until 3) x[i * nsig] = WFDB_INVALID_SAMPLE
                }
                w.writeRecord("r", x, nsig, 250.0, fmt = fmt, gains = doubleArrayOf(200.0), adcres = intArrayOf(res.getValue(fmt)), units = listOf("mV"))
                fun both(f: () -> Record): Pair<Record, Record> {
                    val a = f()
                    val prev = w.wfdbx_bulk_read(false)
                    try {
                        return Pair(a, f())
                    } finally {
                        w.wfdbx_bulk_read(prev)
                    }
                }
                for (call in listOf<() -> Record>(
                    { w.readRecord("r") },
                    { w.readRecord("r", pad = true) },
                    { w.readRecord("r", physical = true) },
                    { w.readRecord("r", from = TimeSpec(1234)) },
                    { w.readRecord("r", from = TimeSpec(7), to = TimeSpec(n - 9)) },
                    { w.readRecord("r", to = TimeSpec(n + 50)) },
                    { w.readRecord("r", channels = listOf("${nsig - 1}", "0", "0")) },
                )) {
                    val (a, b) = both(call)
                    assertEquals(b, a, "format $fmt, $nsig signals")
                }
                var y = w.readRecord("r").samples
                if ((fmt == 310 || fmt == 311) && (n * nsig) % 3 == 2) y = y.copyOf(y.size - nsig)
                assertContentEquals(x, y)
                // a wrong checksum is seen on both paths
                val data = d.read("r.dat")!!
                data[0] = (data[0].toInt() xor 0x10).toByte()
                writeFile(d.path("r.dat"), data)
                val (a, b) = both { w.readRecord("r", checksumWarning = false) }
                assertEquals(b, a)
                assertFalse(a.checksumOk)
                // truncated files: the same error (or checksum error) on both paths
                for (cut in listOf(data.size / 2 + 1, data.size - 1)) {
                    writeFile(d.path("r.dat"), data.copyOf(cut))
                    val out = ArrayList<String>()
                    for (bulk in listOf(true, false)) {
                        val prev = w.wfdbx_bulk_read(bulk)
                        out.add(
                            try {
                                val r = w.readRecord("r", checksumWarning = false)
                                "${r.samples.toList()} ${r.checksumOk}"
                            } catch (e: WfdbException) {
                                e.message!!
                            },
                        )
                        w.wfdbx_bulk_read(prev)
                    }
                    assertEquals(out[0], out[1])
                    if (cut == data.size / 2 + 1) assertTrue("getvec status -3" in out[0], out[0])
                }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Settings and the default instance

    @Test
    fun settingsAndDefaultInstance() = withData("settings") { d, w ->
        val prevIn = w.wfdbxSetInputDir("/x/in")
        assertEquals(d.dir, prevIn)
        assertEquals("/x/in", w.wfdbxGetInputDir())
        assertEquals("/x/in", w.wfdbxSetInputDir(null))
        assertNull(w.wfdbxGetInputDir())
        w.wfdbxSetInputDir(d.dir)
        assertEquals(d.dir, w.wfdbxSetOutputDir(d.path("o")))
        assertEquals(d.path("o"), w.wfdbxGetOutputDir())
        w.wfdbxSetOutputDir(d.dir)
        val net = w.wfdbxSetNetwork(true)
        assertTrue(w.wfdbxGetNetwork())
        w.wfdbxSetNetwork(net)
        assertFalse(w.wfdbxSetLegacy(true))
        assertTrue(w.wfdbxSetLegacy(false))
        // the input options apply to one call
        assertEquals(2, w.readHeader("100s", inputDir = d.dir).nsig)
        w.wfdbxSetInputDir(d.path("nowhere"))
        w.wfdbquiet()
        assertEquals(2, w.readHeader("100s", inputDir = d.dir).nsig)
        assertEquals(d.path("nowhere"), w.wfdbxGetInputDir())
        assertFailsWith<WfdbException> { w.readHeader("100s") }
        assertFailsWith<WfdbException> { w.readRecord("nosuch", inputDir = d.dir, network = true) }
        assertEquals(d.path("nowhere"), w.wfdbxGetInputDir())
        assertFalse(w.wfdbxGetNetwork())
    }
}
