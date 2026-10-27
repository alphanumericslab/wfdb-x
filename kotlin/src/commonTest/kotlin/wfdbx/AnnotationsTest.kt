// Tests of the high-level annotation functions (readAnnotations,
// writeAnnotations) and of the bulk MIT-format encoder of writeAnnotations:
// ports of the high-level parts of python/tests/test_annotations.py and
// rust/tests/annotations.rs.
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
import kotlin.random.Random
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AnnotationsTest {
    private fun withData(name: String, f: (DataDir, Wfdb) -> Unit) {
        val d = DataDir(name)
        val w = d.wfdb()
        val saved = getenv("WFDBANNSORT")
        unsetenv("WFDBANNSORT")
        try {
            f(d, w)
        } finally {
            w.wfdbquit()
            if (saved == null) unsetenv("WFDBANNSORT") else setenv("WFDBANNSORT", saved)
            d.remove()
        }
    }

    private fun fails(msg: String, f: () -> Unit) {
        val e = assertFailsWith<WfdbException> { f() }
        assertEquals(msg, e.message)
    }

    private fun legacyPath(w: Wfdb, d: DataDir) {
        val saved = getenv("WFDB")
        w.wfdbx_set_legacy(1)
        w.setwfdb(d.dir)
        w.wfdbx_set_legacy(0)
        if (saved == null) unsetenv("WFDB") else setenv("WFDB", saved)
    }

    @Test
    fun read() = withData("annread") { _, w ->
        val a = w.readAnnotations("100s", "atr")
        assertEquals(75, a.size)
        assertEquals(listOf("+", "N", "N"), a.symbols.take(3))
        assertEquals("(N", a.aux[0])
        assertNull(a.aux[1])
        assertEquals(listOf(18L, 77L, 370L), a.samples.take(3))
        assertEquals(360.0, a.fs)
        assertEquals("100s", a.record)
        assertEquals("atr", a.annotator)
        // from and to
        val b = w.readAnnotations("100s", "atr", from = TimeSpec("0:10"), to = TimeSpec("0:30"))
        assertEquals(a.samples.filter { it in 3600 until 10800 }, b.samples.toList())
        val pvc = w.readAnnotations("100s", "atr", to = TimeSpec(10000))
        assertEquals(a.samples.filter { it < 10000 }.size, pvc.size)
        fails("can't read annotator nosuch for record 100s") {
            w.wfdbquiet()
            w.readAnnotations("100s", "nosuch")
        }
    }

    @Test
    fun roundtrip() = withData("annrt") { _, w ->
        val samples = longArrayOf(0, 5, 5, 5, 300, 70000, 70001, 5000000000, 5000000000)
        val codes = intArrayOf(NOTE, NORMAL, NORMAL, NORMAL, PVC, ARFCT, RHYTHM, NORMAL, NOISE)
        val chans = intArrayOf(0, 0, 1, 1, 0, 3, 0, 0, 2)
        val nums = intArrayOf(0, 0, 0, 2, 0, -1, 0, 0, 1)
        val sub = intArrayOf(0, 0, 0, 0, 3, 0, 0, 0, -1)
        val aux = listOf("start", null, null, null, null, null, "(AFIB", null, "x".repeat(200))
        w.writeAnnotations("100s", "rt", samples, codes = codes, chans = chans, nums = nums, subtypes = sub, aux = aux)
        w.wfdbquiet()
        val a = w.readAnnotations("100s", "rt")
        w.wfdbverbose()
        // (the NOTE at time 0 is consumed as a modification label by annopen)
        assertEquals(samples.drop(1), a.samples.toList())
        assertEquals(codes.drop(1), a.codes.toList())
        assertEquals(chans.drop(1), a.chans.toList())
        assertEquals(nums.drop(1), a.nums.toList())
        assertEquals(sub.drop(1), a.subtypes.toList())
        assertEquals(aux.drop(1), a.aux)
        assertEquals(listOf("N", "N", "N", "V", "|", "+", "N", "~"), a.symbols)
        // symbols (an unknown mnemonic is code 0, NOTQRS), and the
        // Annotations overload
        w.writeAnnotations("100s", "sy", longArrayOf(10, 20, 30), symbols = listOf("N", "??", "V"), aux = listOf(null, null, "é"))
        val s = w.readAnnotations("100s", "sy")
        assertEquals(listOf(10L, 20L, 30L), s.samples.toList())
        assertEquals(listOf(NORMAL, NOTQRS, PVC), s.codes.toList())
        assertEquals(listOf("N", " ", "V"), s.symbols)
        assertEquals(listOf(null, null, "é"), s.aux)
        w.writeAnnotations("100s", "cp", s)
        assertEquals(s.copy(annotator = "cp"), w.readAnnotations("100s", "cp"))
        // aux texts longer than 255 bytes are cut
        w.writeAnnotations("100s", "lg", longArrayOf(1), codes = intArrayOf(1), aux = listOf("y".repeat(300)))
        assertEquals("y".repeat(255), w.readAnnotations("100s", "lg").aux[0])
        // the fs argument is written to the file
        w.writeAnnotations("nohdr", "fq", longArrayOf(1, 2), codes = intArrayOf(1, 1), fs = 1000.0)
        assertEquals(1000.0, w.readAnnotations("nohdr", "fq").fs)
        assertEquals(0.0, w.getafreq())
        // arguments
        fails("symbols or codes must be given") { w.writeAnnotations("100s", "x", longArrayOf(1)) }
        fails("writeAnnotations: codes must have one value per annotation") { w.writeAnnotations("100s", "x", longArrayOf(1), codes = intArrayOf(1, 2)) }
        fails("writeAnnotations: aux must have one value per annotation") { w.writeAnnotations("100s", "x", longArrayOf(1), codes = intArrayOf(1), aux = listOf()) }
        w.wfdbquiet()
        fails("can't create annotator x for record http://127.0.0.1:1/r") { w.writeAnnotations("http://127.0.0.1:1/r", "x", longArrayOf(1), codes = intArrayOf(1)) }
        // an empty file
        w.writeAnnotations("100s", "em", LongArray(0), codes = IntArray(0))
        assertEquals(0, w.readAnnotations("100s", "em").size)
    }

    @Test
    fun readWithoutFrequency() = withData("annnofs") { d, w ->
        writeFile(d.path("nohea.atr"), d.read("100s.atr")!!) // a record without a header
        w.wfdbquiet()
        val a = w.readAnnotations("nohea", "atr")
        assertEquals(0.0, a.fs)
        assertEquals(75, a.size)
        assertEquals(a.samples.filter { it < 1000 }, w.readAnnotations("nohea", "atr", to = TimeSpec("s1000")).samples.toList())
        fails("sampling frequency of record nohea is not specified") { w.readAnnotations("nohea", "atr", to = TimeSpec("0:10")) }
        val b = w.readAnnotations("nohea", "atr", to = TimeSpec("0:10"), fs = 360.0)
        assertEquals(360.0, b.fs)
        assertEquals(a.samples.filter { it < 3600 }, b.samples.toList())
        // the frequency of the header takes precedence over fs
        assertEquals(360.0, w.readAnnotations("100s", "atr", fs = 100.0).fs)
        for (fs in listOf(0.0, -1.0, Double.NaN)) fails("readAnnotations: fs must be > 0") { w.readAnnotations("nohea", "atr", fs = fs) }
        // legacy mode: 250 Hz
        legacyPath(w, d)
        val l = w.readAnnotations("nohea", "atr", to = TimeSpec("0:10"), legacy = true)
        assertEquals(250.0, l.fs)
        assertEquals(false, w.wfdbxGetLegacy())
        assertEquals(a.samples.filter { it < 2500 }, l.samples.toList())
    }

    // -----------------------------------------------------------------------
    // Sorting

    @Test
    fun writeAnnotationsSorts() = withData("annsort") { d, w ->
        w.wfdbquiet()
        // the same file as putann for each annotation, sorted when closed
        val t = longArrayOf(100, 50, 100, 100, 100, 75, 75, 10, 200, 150, 150, 20, 0, 5, 5000)
        val c = intArrayOf(NORMAL, PVC, APC, NORMAL, PVC, NOTQRS, NORMAL, NOTQRS, RHYTHM, NOISE, NOISE, NORMAL, NORMAL, NORMAL, NORMAL)
        val ch = intArrayOf(0, 0, 1, 0, 0, 2, 2, 0, 0, 3, 3, 0, 0, 1, 0)
        val nm = intArrayOf(0, 0, 0, 1, 0, 0, 0, 0, 0, -1, 0, 0, 0, 0, 0)
        val aux = listOf(null, "(VT", null, "num 1", "replaces N", null, "odd", null, "(AFIB", null, null, "x".repeat(101), null, null, null)
        w.writeAnnotations("100s", "hl", t, codes = c, chans = ch, nums = nm, aux = aux)
        assertEquals(0, w.annopen("100s", arrayOf(Anninfo("ll", WFDB_WRITE)), 1))
        for (k in t.indices) {
            w.putann(0, Annotation(t[k], c[k], 0, ch[k], nm[k], aux[k]?.let { byteArrayOf(it.length.toByte()) + it.latin1() }))
        }
        w.wfdbquit()
        assertContentEquals(d.read("100s.ll"), d.read("100s.hl"))
        val a = w.readAnnotations("100s", "hl")
        assertEquals(a.samples.sorted(), a.samples.toList())
    }

    @Test
    fun writeAnnotationsSortOption() = withData("annsortopt") { d, w ->
        legacyPath(w, d)
        val t = longArrayOf(300, 100, 200)
        val s = listOf("N", "V", "N")
        w.wfdbquiet()
        for (legacy in listOf(false, true)) {
            // sort = false: the file stays in the given order (WFDBANNSORT unset)
            unsetenv("WFDBANNSORT")
            w.writeAnnotations("rec", "uns", t, symbols = s, sort = false, legacy = legacy)
            assertEquals(t.toList(), w.readAnnotations("rec", "uns", fs = 360.0).samples.toList())
            // sort = true: sorted although WFDBANNSORT is 0, which is unchanged
            setenv("WFDBANNSORT", "0")
            w.writeAnnotations("rec", "srt", t, symbols = s, sort = true, legacy = legacy)
            assertEquals("0", getenv("WFDBANNSORT")!!.latin1())
            assertEquals(listOf(100L, 200L, 300L), w.readAnnotations("rec", "srt", fs = 360.0).samples.toList())
            // unset: WFDBANNSORT decides (0: not sorted; 1: sorted)
            w.writeAnnotations("rec", "env0", t, symbols = s, legacy = legacy)
            assertEquals(t.toList(), w.readAnnotations("rec", "env0", fs = 360.0).samples.toList())
            setenv("WFDBANNSORT", "1")
            w.writeAnnotations("rec", "env1", t, symbols = s, legacy = legacy)
            assertEquals(listOf(100L, 200L, 300L), w.readAnnotations("rec", "env1", fs = 360.0).samples.toList())
            w.writeAnnotations("rec", "uns1", t, symbols = s, sort = false, legacy = legacy)
            assertEquals(t.toList(), w.readAnnotations("rec", "uns1", fs = 360.0).samples.toList())
            // the option applies to that call only
            assertNull(w.ann.sortOverride)
        }
        // sort = false: the caller chose the order, so the library does not
        // advise running sortann; WFDBANNSORT=0 (and the C-style API) still does
        for (env in listOf(null, "0", "1")) {
            if (env == null) unsetenv("WFDBANNSORT") else setenv("WFDBANNSORT", env)
            for (legacy in listOf(false, true)) {
                w.wfdb_error("sentinel\n")
                w.writeAnnotations("rec", "uns", t, symbols = s, sort = false, legacy = legacy)
                assertEquals("sentinel\n", w.wfdberror().latin1())
            }
        }
        setenv("WFDBANNSORT", "0")
        w.writeAnnotations("rec", "env0", t, symbols = s)
        assertEquals("to rearrange annotations in the correct order.\n", w.wfdberror().latin1())
    }

    @Test
    fun legacySortInOutputDir() = withData("annlegsort") { d, w ->
        // legacy mode: the sortann program runs in the output directory
        // (where the file is), with --legacy; the result is that of the
        // modern sort
        w.wfdbquiet()
        writeFile(d.path("out/.keep"), "")
        val t = longArrayOf(300, 100, 200, 100, 50)
        val s = listOf("N", "V", "N", "A", "N")
        w.writeAnnotations("rec", "leg", t, symbols = s, dir = d.path("out"), legacy = true)
        w.writeAnnotations("rec", "mod", t, symbols = s, dir = d.path("out"))
        assertEquals(listOf(".keep", "rec.leg", "rec.mod"), listFiles(d.path("out")))
        assertContentEquals(readFile(d.path("out/rec.mod")), readFile(d.path("out/rec.leg")))
        val a = w.readAnnotations("out/rec", "leg", fs = 360.0)
        assertEquals(listOf(50L, 100L, 200L, 300L), a.samples.toList())
        assertEquals("A", a.symbols[1])
    }

    @Test
    fun writeAnnotationsDir() = withData("anndir") { d, w ->
        writeFile(d.path("out/.keep"), "")
        w.wfdbquiet()
        w.writeAnnotations("rec", "atr", longArrayOf(30, 10, 20), symbols = listOf("N", "V", "N"), dir = d.path("out"))
        w.wfdbverbose()
        assertEquals(listOf(".keep", "rec.atr"), listFiles(d.path("out")))
        assertEquals(d.dir, w.wfdbxGetOutputDir())
        val a = w.readAnnotations("out/rec", "atr") // sorted in place
        assertEquals(listOf(10L, 20L, 30L), a.samples.toList())
        assertEquals("V", a.symbols[0])
        fails("directory ${d.path("nosuch")} does not exist") { w.writeAnnotations("rec", "atr", longArrayOf(1), symbols = listOf("N"), dir = d.path("nosuch")) }
        fails("record name must not contain a directory when dir is given") { w.writeAnnotations("x/rec", "atr", longArrayOf(1), symbols = listOf("N"), dir = d.path("out")) }
        // the dir checks come first
        fails("record name must not contain a directory when dir is given") { w.writeAnnotations("x/rec", "atr", longArrayOf(1), dir = d.path("out")) }
        fails("directory ${d.path("nosuch")} does not exist") { w.writeAnnotations("rec", "atr", longArrayOf(1), dir = d.path("nosuch")) }
        fails("symbols or codes must be given") { w.writeAnnotations("rec", "atr", longArrayOf(1), dir = d.path("out")) }
    }

    // -----------------------------------------------------------------------
    // The bulk MIT-format encoder of writeAnnotations (putanns) writes the
    // same bytes as putann for each annotation

    private class Anns(
        val times: LongArray, val codes: IntArray, val subtypes: IntArray, val chans: IntArray,
        val nums: IntArray, val aux: List<String?>,
    )

    private fun randomAnnotations(rng: Random, n: Int): Anns {
        val times = LongArray(n)
        var t = 0L
        for (k in 0 until n) {
            t += if (rng.nextDouble() < 0.05) rng.nextLong(-(1L shl 33), 1L shl 33) else rng.nextLong(-50, 1500)
            times[k] = if (rng.nextDouble() < 0.02) 0 else t
        }
        val codes = IntArray(n) { if (rng.nextDouble() < 0.05) 0 else rng.nextInt(0, 50) }
        val subtypes = IntArray(n) { if (rng.nextDouble() < 0.2) rng.nextInt(-128, 128) else 0 }
        val chans = IntArray(n) { if (rng.nextDouble() < 0.2) rng.nextInt(0, 256) else 0 }
        val nums = IntArray(n) { if (rng.nextDouble() < 0.2) rng.nextInt(-128, 128) else 0 }
        val aux = List(n) {
            if (rng.nextDouble() < 0.6) {
                null
            } else {
                val len = listOf(0, 1, 2, 3, 254, 255, rng.nextInt(0, 256))[rng.nextInt(7)]
                String(CharArray(len) { rng.nextInt(32, 256).toChar() })
            }
        }
        return Anns(times, codes, subtypes, chans, nums, aux)
    }

    private fun auxBytes(x: String?): ByteArray? {
        if (x == null) return null
        val b = x.latin1().let { it.copyOf(minOf(it.size, 255)) }
        return byteArrayOf(b.size.toByte()) + b
    }

    /** Writes [a] to rec.NAME with putann for each annotation, or with putanns. */
    private fun writeLowLevel(w: Wfdb, d: DataDir, name: String, a: Anns, bulk: Boolean, freq: Double? = null, auxb: Array<ByteArray?>? = null): ByteArray {
        if (freq != null) w.setafreq(freq)
        assertEquals(0, w.annopen("rec", arrayOf(Anninfo(name, WFDB_WRITE)), 1))
        val ab = auxb ?: Array(a.times.size) { auxBytes(a.aux[it]) }
        if (bulk) {
            w.putanns(0, a.times.size, a.times, a.codes, a.subtypes, a.chans, a.nums, ab)
        } else {
            for (k in a.times.indices) w.putann(0, Annotation(a.times[k], a.codes[k], a.subtypes[k], a.chans[k], a.nums[k], ab[k]))
        }
        w.wfdbquit()
        w.setafreq(0.0)
        return d.read("rec.$name")!!
    }

    @Test
    fun bulkAnnotationEncoder() = withData("annbulk") { d, w ->
        setenv("WFDBANNSORT", "0") // (keep the order written)
        w.wfdbquiet()
        val rng = Random(6)
        for (trial in 0 until 60) {
            val n = listOf(0, 1, 2, 5, 50, 500)[rng.nextInt(6)]
            val a = randomAnnotations(rng, n)
            val freq = if (trial % 3 == 0) 1000.0 else null
            assertContentEquals(writeLowLevel(w, d, "ref", a, false, freq), writeLowLevel(w, d, "blk", a, true, freq), "trial $trial")
        }
        // a time that putann rejects (overflow) is skipped in both
        val ov = Anns(longArrayOf(5, WFDB_TIME_MAX, 7, 3), IntArray(4) { 1 }, IntArray(4), IntArray(4), IntArray(4), listOf(null, null, "a", null))
        assertContentEquals(writeLowLevel(w, d, "ref", ov, false), writeLowLevel(w, d, "blk", ov, true))
        // writeAnnotations == putann
        val a = randomAnnotations(rng, 2000)
        w.writeAnnotations("rec", "hl", a.times, codes = a.codes, subtypes = a.subtypes, chans = a.chans, nums = a.nums, aux = a.aux, sort = false)
        assertContentEquals(writeLowLevel(w, d, "ref", a, false), d.read("rec.hl"))
        // (without subtypes, chans, nums and aux: zeros)
        w.writeAnnotations("rec", "hl", a.times, codes = a.codes, sort = false)
        val z = Anns(a.times, a.codes, IntArray(2000), IntArray(2000), IntArray(2000), List(2000) { null })
        assertContentEquals(writeLowLevel(w, d, "ref", z, false), d.read("rec.hl"))
    }

    @Test
    fun bulkAnnotationEncoderLarge() = withData("annbulk2") { d, w ->
        setenv("WFDBANNSORT", "0")
        w.wfdbquiet()
        val rng = Random(1234)
        val n = 100000
        val a0 = randomAnnotations(rng, n)
        val times = a0.times.copyOf()
        for (k in 0 until n) {
            val r = rng.nextDouble()
            if (r < 0.001) times[k] = rng.nextLong(-(1L shl 36), 1L shl 36)
            else if (r < 0.0015) times[k] = WFDB_TIME_MAX
            else if (r < 0.002) times[k] = WFDB_TIME_MIN
        }
        val aux = a0.aux.toMutableList()
        repeat(300) { aux[rng.nextInt(n)] = "y".repeat(rng.nextInt(256, 600)) }
        val a = Anns(times, a0.codes, a0.subtypes, a0.chans, a0.nums, aux)
        val ref = writeLowLevel(w, d, "ref", a, false, 360.0)
        w.writeAnnotations("rec", "hl", times, codes = a.codes, subtypes = a.subtypes, chans = a.chans, nums = a.nums, aux = aux, fs = 360.0, sort = false)
        assertContentEquals(ref, d.read("rec.hl"))
        assertContentEquals(ref, writeLowLevel(w, d, "blk", a, true, 360.0))
        // aux as given to putann: a length byte that differs from the
        // length of the text (the text is cut, or padded with zeros)
        val auxb = Array(n) { auxBytes(aux[it]) }
        repeat(500) {
            val k = rng.nextInt(n)
            val b = auxb[k] ?: byteArrayOf(0)
            auxb[k] = byteArrayOf(rng.nextInt(0, 256).toByte()) + b.copyOfRange(1, b.size)
        }
        assertContentEquals(writeLowLevel(w, d, "b2", a, false, auxb = auxb), writeLowLevel(w, d, "b3", a, true, auxb = auxb))
        // two calls: the previous annotation is carried over
        assertEquals(0, w.annopen("rec", arrayOf(Anninfo("b4", WFDB_WRITE)), 1))
        w.putanns(0, 2, longArrayOf(5, 9), intArrayOf(1, 1), intArrayOf(0, 0), intArrayOf(258, 2), intArrayOf(0, 0), arrayOf(null, null))
        w.putanns(0, 2, longArrayOf(9, 20), intArrayOf(1, 0), intArrayOf(3, 0), intArrayOf(2, 2), intArrayOf(-1, 0), arrayOf(auxBytes("ab"), null))
        w.wfdbquit()
        val two = Anns(longArrayOf(5, 9, 9, 20), intArrayOf(1, 1, 1, 0), intArrayOf(0, 0, 3, 0), intArrayOf(258, 2, 2, 2), intArrayOf(0, 0, -1, 0), listOf(null, null, "ab", null))
        assertContentEquals(writeLowLevel(w, d, "ref", two, false), d.read("rec.b4"))
    }

    @Test
    fun bulkAnnotationEncoderAha() = withData("annaha") { d, w ->
        // (an AHA-format output annotator: putanns uses putann)
        val out = ArrayList<ByteArray>()
        val aux = arrayOf(null, auxBytes("(VT"), null)
        for (bulk in listOf(false, true)) {
            assertEquals(0, w.annopen("rec", arrayOf(Anninfo("aha", WFDB_AHA_WRITE)), 1))
            val t = longArrayOf(10, 20, 30)
            val c = intArrayOf(1, 5, 1)
            if (bulk) {
                w.putanns(0, 3, t, c, IntArray(3), IntArray(3), IntArray(3), aux)
            } else {
                for (k in 0 until 3) w.putann(0, Annotation(t[k], c[k], 0, 0, 0, aux[k]))
            }
            w.wfdbquit()
            out.add(d.read("rec.aha")!!)
        }
        assertContentEquals(out[0], out[1])
        assertTrue(out[0].isNotEmpty())
    }

    // -----------------------------------------------------------------------
    // A truncated annotation file is an error of readAnnotations (getann
    // status other than 0 and -1)

    /** The annotations (time, code, aux) getann returns, and its final status (null if the file cannot be opened). */
    private fun getannAll(w: Wfdb, record: String, annotator: String): Pair<List<Triple<Long, Int, String?>>, Int>? {
        w.wfdbquit()
        val out = ArrayList<Triple<Long, Int, String?>>()
        if (w.annopen(record, arrayOf(Anninfo(annotator, WFDB_READ)), 1) < 0) {
            w.wfdbquit()
            return null
        }
        val a = Annotation()
        var stat: Int
        while (true) {
            stat = w.getann(0, a)
            if (stat != 0) break
            val x = a.aux
            out.add(Triple(a.time, a.anntyp, x?.let { it.copyOfRange(1, minOf(1 + (it[0].toInt() and 0xff), it.size)).latin1().substringBefore('\u0000') }))
        }
        w.wfdbquit()
        return Pair(out, stat)
    }

    private fun triples(a: Annotations) = (0 until a.size).map { Triple(a.samples[it], a.codes[it], a.aux[it]) }

    @Test
    fun readTruncatedAnnotationFile() = withData("anntrunc") { d, w ->
        legacyPath(w, d)
        w.wfdbquiet()
        w.writeRecord("ann", IntArray(5000) { 1 }, 1, 100.0, gains = doubleArrayOf(100.0), adcres = intArrayOf(16), units = listOf("mV"))
        // (an aux string, and a SKIP before the annotation at 4000)
        w.writeAnnotations("ann", "atr", longArrayOf(10, 20, 4000, 4010), codes = intArrayOf(1, RHYTHM, 5, 1), aux = listOf(null, "(AFIB", null, null))
        val data = d.read("ann.atr")!!
        val full = w.readAnnotations("ann", "atr")
        assertEquals(listOf(10L, 20L, 4000L, 4010L), full.samples.toList())
        assertEquals(listOf(null, "(AFIB", null, null), full.aux)
        val (expect, stat0) = getannAll(w, "ann", "atr")!!
        assertEquals(-1, stat0)
        assertEquals(expect, triples(full))
        var errors = 0
        for (cut in data.indices) {
            writeFile(d.path("ann.atr"), data.copyOf(cut))
            val got = getannAll(w, "ann", "atr")
            if (got == null) { // (not opened: an empty file)
                fails("can't read annotator atr for record ann") { w.readAnnotations("ann", "atr") }
                continue
            }
            val (anns, stat) = got
            if (stat == -1) {
                assertEquals(anns, triples(w.readAnnotations("ann", "atr")))
                continue
            }
            errors++
            val msg = "can't read annotation file atr of record ann (getann status $stat)"
            fails(msg) { w.readAnnotations("ann", "atr") }
            // stopped by `to` before the truncation: no error
            if (anns.isNotEmpty()) {
                val t = anns.last().first
                assertEquals(anns.map { it.first }.filter { it < t }, w.readAnnotations("ann", "atr", to = TimeSpec(t)).samples.toList())
            }
            // legacy mode too
            fails(msg) { w.readAnnotations("ann", "atr", legacy = true) }
        }
        assertTrue(errors > 0)
        // the example of the specification: without the EOF word
        w.writeAnnotations("ann", "atr", longArrayOf(10, 20, 30), codes = intArrayOf(1, 5, 1))
        val ex = d.read("ann.atr")!!
        writeFile(d.path("ann.atr"), ex.copyOf(ex.size - 2))
        fails("can't read annotation file atr of record ann (getann status -3)") { w.readAnnotations("ann", "atr") }
        assertEquals("getann: unexpected EOF in annotator atr\n", w.wfdberror().latin1())
        assertEquals(listOf(10L), w.readAnnotations("ann", "atr", to = TimeSpec(20)).samples.toList())
        // the annotator was closed: the C-style API starts fresh
        assertEquals(0, w.annopen("ann", arrayOf(Anninfo("atr", WFDB_READ)), 1))
        val a = Annotation()
        assertEquals(listOf(0, 0, -3), List(3) { w.getann(0, a) })
        w.wfdbquit()
    }
}
