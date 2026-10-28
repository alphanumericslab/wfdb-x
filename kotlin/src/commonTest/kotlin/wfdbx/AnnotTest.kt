// Tests of the annotation functions and the annotation code tables (ports
// of the annotation parts of rust/tests/annotations.rs, which port
// cpp/tests/test_api.cpp and cpp/tests/test_api_c.cpp; the expected values
// were produced by the original C library).
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

import wfdbx.cstd.cstr
import wfdbx.cstd.getenv
import wfdbx.cstd.latin1
import wfdbx.cstd.setenv
import wfdbx.cstd.unsetenv
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class AnnotTest {
    private fun str(b: ByteArray?) = b?.latin1()

    /** getann: status, time, anntyp, subtyp, chan, num. */
    private fun ann(w: Wfdb, n: Int): List<Long> {
        val a = Annotation()
        val stat = w.getann(n, a)
        return listOf(stat.toLong(), a.time, a.anntyp.toLong(), a.subtyp.toLong(), a.chan.toLong(), a.num.toLong())
    }

    private fun ai(name: String, stat: Int) = arrayOf(Anninfo(name, stat))

    /** Runs [f] with WFDBANNSORT unset (restored afterwards). */
    private fun withSortEnv(f: () -> Unit) {
        val saved = getenv("WFDBANNSORT")
        unsetenv("WFDBANNSORT")
        try {
            f()
        } finally {
            if (saved == null) unsetenv("WFDBANNSORT") else setenv("WFDBANNSORT", saved)
        }
    }

    @Test
    fun annopenErrors() {
        val d = DataDir("errors")
        val w = d.wfdb()
        w.wfdbquiet()
        assertEquals(-3, w.annopen("nosuch", ai("atr", WFDB_READ), 1))
        assertEquals("annopen: can't read annotator atr for record nosuch\n", str(w.wfdberror()))
        d.remove()
    }

    @Test
    fun annotationsRead() {
        val d = DataDir("read")
        val w = d.wfdb()
        assertEquals(0, w.annopen("100s", ai("atr", WFDB_READ), 1))
        val a = Annotation()
        val v = ArrayList<Annotation>()
        while (w.getann(0, a) == 0) v.add(a.copy())
        assertEquals(75, v.size)
        assertEquals("+", str(w.annstr(v[0].anntyp)))
        assertEquals("N", str(w.annstr(v[1].anntyp)))
        // (the aux string of the file includes its terminating null)
        assertEquals("(N", cstr(v[0].aux!!.copyOfRange(1, v[0].aux!!.size)).latin1())
        w.wfdbquit()
        d.remove()
    }

    /** The C API, as in the C program that produced the expected output and files (MIT and AHA output, reading back, iannsettime, wrong formats, errors). */
    @Test
    fun apiLikeC() = withSortEnv {
        val d = DataDir("apic")
        val w = d.wfdb()
        w.wfdbquiet()
        val out = StringBuilder()
        val times = longArrayOf(0, 5, 5, 5, 300, 70000, 70001, 5000000000, 5000000000, 4000000000, 10, 3000000000)
        val codes = intArrayOf(NOTE, NORMAL, NORMAL, NORMAL, PVC, ARFCT, RHYTHM, NORMAL, NOISE, NORMAL, 0, VFON)
        val chans = intArrayOf(0, 0, 1, 1, 0, 3, 0, 0, 2, 200, 0, 5)
        val nums = intArrayOf(0, 0, 0, 2, 0, -1, 0, 0, 1, 0, 3, -128)
        val subs = intArrayOf(0, 0, 0, 0, 3, 0, 0, 0, -1, 0, 0, 7)

        setenv("WFDBANNSORT", "0")
        val aiw = arrayOf(Anninfo("mit", WFDB_WRITE), Anninfo("aha", WFDB_AHA_WRITE))
        assertEquals(0, w.annopen("x", aiw, 2))
        for (i in 0 until 12) {
            val a = Annotation(times[i], codes[i], subs[i], chans[i], nums[i])
            a.aux = when (i) {
                0 -> aux("start")
                6 -> aux("(AFIB")
                8 -> aux("x".repeat(200))
                11 -> aux("ab")
                else -> null
            }
            val s1 = w.putann(1, a)
            val s0 = w.putann(0, a)
            out.append("put $s0 $s1\n")
        }
        w.wfdbquit()

        fun pr(n: Int) {
            val a = Annotation()
            var s: Int
            while (true) {
                s = w.getann(n, a)
                if (s != 0) break
                out.append("${a.time} ${a.anntyp} ${a.subtyp} ${a.chan} ${a.num}")
                val x = a.aux
                if (x != null) {
                    val len = x[0].toInt() and 0xff
                    out.append(" aux[$len]=${hex(x.copyOfRange(1, len + 1))}")
                }
                out.append("\n")
            }
            out.append("end $s\n")
        }

        val air = arrayOf(Anninfo("mit", WFDB_READ), Anninfo("aha", WFDB_AHA_READ))
        out.append("open ${w.annopen("x", air, 2)}\n")
        pr(0)
        pr(1)
        val a = Annotation()
        out.append("settime ${w.iannsettime(300)}\n")
        w.getann(0, a)
        out.append("${a.time} ${a.anntyp}\n")
        w.getann(1, a)
        out.append("${a.time} ${a.anntyp}\n")
        out.append("settime ${w.iannsettime(-70000)}\n")
        w.getann(0, a)
        out.append("${a.time} ${a.anntyp}\n")
        out.append("settime ${w.iannsettime(6000000000)}\n")
        out.append("settime ${w.iannsettime(0)}\n")
        w.getann(0, a)
        out.append("${a.time} ${a.anntyp}\n")
        w.wfdbquit()

        // read with the wrong stat
        val air2 = arrayOf(Anninfo("mit", WFDB_AHA_READ), Anninfo("aha", WFDB_READ))
        out.append("open ${w.annopen("x", air2, 2)}\n")
        w.getann(0, a)
        out.append("${a.time} ${a.anntyp}\n")
        w.getann(1, a)
        out.append("${a.time} ${a.anntyp}\n")
        w.wfdbquit()
        val bad = ai("bad name", WFDB_WRITE)
        out.append("open ${w.annopen("x", bad, 1)}\n")
        bad[0].stat = 9
        out.append("open ${w.annopen("x", bad, 1)}\n")
        out.append(str(w.wfdberror()))
        val p = w.putann(0, a)
        val g = w.getann(0, a)
        out.append("getann $g putann $p\n")

        val expect = ("put 0 0\nput 0 0\nput 0 0\nput 0 0\nput 0 0\nput 0 0\nput 0 0\n" +
            "put 0 0\nput 0 0\nput 0 0\nput 0 0\nput 0 0\nopen 0\n5 1 0 0 0\n5 1 0 1 0\n" +
            "5 1 0 1 2\n300 5 3 0 0\n70000 16 0 3 -1\n70001 28 0 0 0 aux[5]=2841464942\n" +
            "5000000000 1 0 0 0\n5000000000 14 -1 2 1 aux[200]=XXX\n4000000000 1 0 200 0\n" +
            "10 0 0 0 3\n3000000000 32 7 5 -128 aux[2]=6162\nend -1\n5 1 0 1 0\n5 1 0 1 0\n" +
            "5 1 0 1 0\n300 5 3 5 0\n70000 22 0 16 0\n70001 22 0 28 0 aux[6]=284146494200\n" +
            "705032704 1 0 1 0\n705032704 14 -1 14 0 aux[6]=787878787878\n" +
            "-294967296 1 0 1 0\n10 22 0 0 0\n-1294967296 32 7 32 0 aux[6]=616200000000\n" +
            "end -1\nsettime 0\n300 5\n300 5\nsettime 0\n70000 16\nsettime -1\nsettime 0\n" +
            "0 22\nopen 0\n5 1\n5 1\nopen -4\nopen -5\n" +
            "annopen: illegal stat 9 for annotator bad name, record x\ngetann -2 putann -2\n")
            .replace("XXX", "78".repeat(200))
        assertEquals(expect, out.toString())

        val expectMit = "005805fc7374617274000504000401f8000402f0271503f400f800f000ec01004410004003f8" +
            "fff3017000f800f005fc28414649420000ecff7fffff00ecff7fffff00ec042a91e000040038" +
            "fff702f801f0c8fc" + "78".repeat(200) + "00ec65c400360004c8f800f000ec0080010000ec949108d8010000f803" +
            "f000ecff7fffff00ecd032f75d008007f405f880f302fc61620000"
        assertEquals(expectMit, hex(d.read("x.mit")!!))
        val aha = d.read("x.aha")!!
        assertEquals(1024, aha.size)
        val expectAha = "004f0000000001000016737461727400004e000005000200000100000000000000" +
            "4e0000050003000001000000000000004e0000050004000001000000000000005600002c010500" +
            "0305000000000000004f0100701106000010000000000000004f010071110700001c2841464942" +
            "00004e052a00f2080000010000000000000055052a00f20900ff0e787878787878004e6bee0028" +
            "0a000001000000000000004f00000a000b000000000000000000005bd0b2005e0c000720616200" +
            "000000"
        val n = expectAha.length / 2
        assertEquals(expectAha, hex(aha.copyOf(n)))
        assertTrue(aha.copyOfRange(n, aha.size).all { it == 0xff.toByte() })
        d.remove()
    }

    @Test
    fun inputAnnotators() {
        val d = DataDir("input")
        val w = d.wfdb()
        assertEquals(0.0, w.getafreq())
        assertEquals(360.0, w.sampfreq("100s"))
        val ais = arrayOf(Anninfo("atr", WFDB_READ), Anninfo("ooo", WFDB_READ))
        assertEquals(0, w.annopen("100s", ais, 2))
        assertEquals(360.0, w.getiafreq(0))
        assertEquals(360.0, w.getiafreq(1))
        assertEquals(-2.0, w.getiafreq(2))
        assertEquals(0.0, w.getiaorigfreq(0))
        assertEquals(360.0, w.getiaorigfreq(1))
        assertEquals(-2.0, w.getiaorigfreq(2))
        assertEquals(listOf(0L, 18, 28, 0, 0, 0), ann(w, 0))
        assertEquals(listOf(0L, 77, 1, 0, 0, 0), ann(w, 0))
        w.setiafreq(0, 1000.0)
        assertEquals(1000.0, w.getiafreq(0))
        assertEquals(0.0, w.getiaorigfreq(0))
        val a = Annotation()
        assertEquals(0, w.getann(0, a))
        assertTrue(a.time == 1028L && a.anntyp == 1)
        w.wfdbquiet()
        assertEquals(0, w.ungetann(0, a))
        assertEquals(-1, w.ungetann(0, a)) // the pushback buffer is full
        assertEquals(-2, w.ungetann(5, a))
        w.wfdbverbose()
        assertEquals(listOf(0L, 1028, 1, 0, 0, 0), ann(w, 0))
        assertEquals(listOf(0L, 1839, 1, 0, 0, 0), ann(w, 0))
        a.time = 5
        a.anntyp = PVC
        assertEquals(0, w.ungetann(0, a))
        assertEquals(listOf(0L, 5, 5, 0, 0, 0), ann(w, 0))
        w.setiafreq(0, 0.0)
        assertEquals(360.0, w.getiafreq(0))
        assertEquals(listOf(0L, 946, 1, 0, 0, 0), ann(w, 0))
        w.iannclose(0) // annotator 1 (ooo) becomes annotator 0
        assertEquals(360.0, w.getiafreq(0))
        assertEquals(-2.0, w.getiafreq(1))
        assertEquals(listOf(0L, 18, 1, 0, 0, 0), ann(w, 0))
        w.wfdbquiet()
        assertEquals(-2L, ann(w, 1)[0])
        w.iannclose(0)
        assertEquals(-2L, ann(w, 0)[0])
        w.iannclose(3)
        w.wfdbquit()
        d.remove()
    }

    @Test
    fun annotationTimeResolution() {
        val d = DataDir("tres")
        val w = d.wfdb()
        w.setafreq(1000.0)
        assertEquals(1000.0, w.getafreq())
        val a1 = ai("hf", WFDB_WRITE)
        w.annopen("100s", a1, 1)
        val a = Annotation(time = 1000, anntyp = NORMAL)
        w.putann(0, a)
        a.time = 2500
        w.putann(0, a)
        w.wfdbquit()
        assertEquals(1000.0, w.getafreq())
        w.setafreq(0.0)
        a1[0].stat = WFDB_READ
        w.annopen("100s", a1, 1)
        assertEquals(1000.0, w.getiafreq(0))
        assertEquals(1000.0, w.getiaorigfreq(0))
        assertEquals(listOf(0L, 1000, 1, 0, 0, 0), ann(w, 0))
        w.setiafreq(0, 360.0)
        assertEquals(360.0, w.getiafreq(0))
        assertEquals(listOf(0L, 900, 1, 0, 0, 0), ann(w, 0))
        w.wfdbquit()
        d.remove()
    }

    @Test
    fun outputAnnotationsFlush() {
        val d = DataDir("flush")
        val w = d.wfdb()
        assertEquals(0, w.annopen("out", ai("tst", WFDB_WRITE), 1))
        val a = Annotation(time = 3, anntyp = NORMAL)
        w.putann(0, a)
        a.time = 4
        a.anntyp = PVC
        w.putann(0, a)
        w.wfdbflush()
        assertEquals(4, d.read("out.tst")!!.size)
        w.wfdbquit()
        assertContentEquals(unhex("0304 0114 0000"), d.read("out.tst"))
        d.remove()
    }

    @Test
    fun ecgstrFunctions() {
        val w = Wfdb()
        assertEquals("N", str(w.ecgstr(1)))
        assertEquals(" ", str(w.ecgstr(0)))
        assertEquals("[15]", str(w.ecgstr(15)))
        assertEquals("\"", str(w.ecgstr(22)))
        assertEquals("[50]", str(w.ecgstr(50)))
        assertEquals("[-1]", str(w.ecgstr(-1)))
        assertEquals(5, w.strecg("V"))
        assertEquals(0, w.strecg("xx"))
        assertEquals(0, w.strecg(""))
        assertEquals(15, w.strecg("[15]"))
        assertEquals(0, w.setecgstr(5, "PVC"))
        assertEquals("PVC", str(w.ecgstr(5)))
        assertEquals("V", str(w.annstr(5)))
        assertEquals(5, w.strecg("PVC"))
        assertEquals(0, w.strecg("V"))
        w.wfdbquiet()
        assertEquals(-1, w.setecgstr(50, "x"))
        assertEquals(-1, w.setecgstr(-1, "x"))
        w.wfdbverbose()
        assertEquals(0, w.setecgstr(0, "Z"))
        assertEquals("Z", str(w.ecgstr(0)))
    }

    @Test
    fun annstrAnndesc() {
        val d = DataDir("annstr")
        val w = d.wfdb()
        assertEquals(0, w.setannstr(5, "pvc"))
        assertEquals("pvc", str(w.annstr(5)))
        assertEquals("V", str(w.ecgstr(5)))
        assertEquals(5, w.strann("pvc"))
        assertEquals(0, w.strann("V"))
        assertEquals(0, w.setannstr(-6, "fus"))
        assertEquals("fus", str(w.annstr(6)))
        w.wfdbquiet()
        assertEquals(-1, w.setannstr(60, "x"))
        assertEquals(-1, w.setannstr(-60, "x"))
        assertEquals("setannstr: illegal annotation code 60\n", str(w.wfdberror()))
        w.wfdbverbose()
        assertEquals(0, w.setannstr(0, "zero"))
        assertEquals("zero", str(w.annstr(0)))
        assertEquals("[60]", str(w.annstr(60)))
        assertEquals(0, w.setannstr(42, "new"))
        assertEquals(42, w.strann("new"))
        assertEquals("Normal beat", str(w.anndesc(1)))
        assertNull(w.anndesc(15))
        assertEquals("illegal annotation code", str(w.anndesc(60)))
        assertEquals("illegal annotation code", str(w.anndesc(-1)))
        assertEquals(0, w.setanndesc(15, "my description"))
        assertEquals("my description", str(w.anndesc(15)))
        assertEquals(0, w.setanndesc(-43, "negative"))
        assertEquals("negative", str(w.anndesc(43)))
        w.wfdbquiet()
        assertEquals(-1, w.setanndesc(50, "x"))
        w.wfdbverbose()

        // Modified mnemonics (but not those set with a negative code) are
        // written into output annotation files ...
        val a1 = ai("mod", WFDB_WRITE)
        w.annopen("100s", a1, 1)
        w.putann(0, Annotation(time = 10, anntyp = PVC))
        w.wfdbquit()
        val expect = unhex("0058 1efc") + "## annotation type definitions".latin1() +
            unhex("0058 27fc") + "5 pvc Premature ventricular contraction".latin1() +
            unhex("00 0058 16fc") + "15 [15] my description".latin1() +
            unhex("0058 07fc") + "42 new ".latin1() +
            unhex("00 0058 15fc") + "## end of definitions".latin1() +
            unhex("00 00ec ffff ffff 0100 0a14 0000")
        assertEquals(hex(expect), hex(d.read("100s.mod")!!))
        w.setannstr(5, "V")
        w.setannstr(-6, "F")
        w.setannstr(0, " ")
        w.setannstr(-42, "[42]")
        w.setanndesc(-15, "")
        w.setanndesc(-43, "")
        // ... and reading the file defines them again.
        a1[0].stat = WFDB_READ
        w.annopen("100s", a1, 1)
        assertEquals(listOf(0L, 10, 5, 0, 0, 0), ann(w, 0))
        assertEquals("pvc", str(w.annstr(5)))
        assertEquals("my description", str(w.anndesc(15)))
        assertEquals("", str(w.anndesc(42)))
        w.wfdbquit()
        d.remove()
    }

    @Test
    fun mnemonicsDefaultInstance() {
        assertEquals("N", str(annstr(NORMAL)))
        assertEquals(PVC, strann("V"))
        assertEquals("Premature ventricular contraction", str(anndesc(PVC)))
        assertEquals("[99]", str(ecgstr(99)))
        assertTrue(isqrs(NORMAL) != 0 && isqrs(NOTE) == 0)
        assertTrue(map1(APC) == NORMAL && map2(APC) == SVPB)
    }

    @Test
    fun roundingToTime() {
        assertEquals(3L, roundToTime(2.5))
        assertEquals(2L, roundToTime(2.49))
        assertEquals(-2L, roundToTime(-2.5))
        assertEquals(-3L, roundToTime(-2.51))
        assertEquals(WFDB_TIME_MIN, roundToTime(Double.NaN))
        assertEquals(WFDB_TIME_MAX, roundToTime(1e300))
    }

    /** isann, isqrs, map1, map2, annpos, mamap(code, 0) and mamap(code, -1) of the codes -1 to 50 (from the C library). */
    private val maps = arrayOf(
        intArrayOf(-1, 0, 0, 0, 0, 0, 79, 79), intArrayOf(0, 0, 0, 0, 0, 0, 79, 79),
        intArrayOf(1, 1, 1, 1, 1, 1, 78, 78), intArrayOf(2, 1, 1, 1, 1, 1, 78, 78),
        intArrayOf(3, 1, 1, 1, 1, 1, 78, 78), intArrayOf(4, 1, 1, 1, 9, 1, 78, 78),
        intArrayOf(5, 1, 1, 5, 5, 1, 86, 86), intArrayOf(6, 1, 1, 6, 6, 1, 70, 70),
        intArrayOf(7, 1, 1, 1, 9, 1, 78, 78), intArrayOf(8, 1, 1, 1, 9, 1, 78, 78),
        intArrayOf(9, 1, 1, 1, 9, 1, 78, 78), intArrayOf(10, 1, 1, 5, 5, 1, 69, 69),
        intArrayOf(11, 1, 1, 1, 1, 1, 78, 78), intArrayOf(12, 1, 1, 1, 1, 1, 80, 80),
        intArrayOf(13, 1, 1, 1, 1, 1, 81, 81), intArrayOf(14, 1, 0, 0, 0, 2, 79, 85),
        intArrayOf(15, 1, 0, 0, 0, 0, 79, 79), intArrayOf(16, 1, 0, 0, 0, 2, 79, 79),
        intArrayOf(17, 1, 0, 0, 0, 0, 79, 79), intArrayOf(18, 1, 0, 0, 0, 2, 79, 79),
        intArrayOf(19, 1, 0, 0, 0, 2, 79, 79), intArrayOf(20, 1, 0, 0, 0, 2, 79, 79),
        intArrayOf(21, 1, 0, 0, 0, 2, 79, 79), intArrayOf(22, 1, 0, 0, 0, 2, 79, 79),
        intArrayOf(23, 1, 0, 0, 0, 2, 79, 79), intArrayOf(24, 1, 0, 0, 0, 2, 79, 79),
        intArrayOf(25, 1, 1, 1, 1, 1, 78, 78), intArrayOf(26, 1, 0, 0, 0, 2, 79, 79),
        intArrayOf(27, 1, 0, 0, 0, 2, 79, 79), intArrayOf(28, 1, 0, 0, 0, 3, 79, 79),
        intArrayOf(29, 1, 0, 0, 0, 2, 79, 79), intArrayOf(30, 1, 1, 30, 30, 1, 81, 81),
        intArrayOf(31, 1, 1, 5, 5, 1, 79, 79), intArrayOf(32, 1, 0, 0, 0, 1, 91, 91),
        intArrayOf(33, 1, 0, 0, 0, 1, 93, 93), intArrayOf(34, 1, 1, 1, 1, 1, 78, 78),
        intArrayOf(35, 1, 1, 1, 1, 1, 78, 78), intArrayOf(36, 1, 0, 0, 0, 2, 79, 79),
        intArrayOf(37, 1, 0, 0, 0, 2, 79, 79), intArrayOf(38, 1, 1, 1, 1, 1, 78, 78),
        intArrayOf(39, 1, 0, 0, 0, 2, 79, 79), intArrayOf(40, 1, 0, 0, 0, 2, 79, 79),
        intArrayOf(41, 1, 1, 5, 5, 1, 82, 82), intArrayOf(42, 1, 0, 0, 0, 0, 79, 79),
        intArrayOf(43, 1, 0, 0, 0, 0, 79, 79), intArrayOf(44, 1, 0, 0, 0, 0, 79, 79),
        intArrayOf(45, 1, 0, 0, 0, 0, 79, 79), intArrayOf(46, 1, 0, 0, 0, 0, 79, 79),
        intArrayOf(47, 1, 0, 0, 0, 0, 79, 79), intArrayOf(48, 1, 0, 0, 0, 0, 79, 79),
        intArrayOf(49, 1, 0, 0, 0, 0, 79, 79), intArrayOf(50, 0, 0, 0, 0, 0, 79, 79),
    )

    @Test
    fun codeMaps() {
        val w = Wfdb()
        for (r in maps) {
            val c = r[0]
            assertEquals(r.toList(), listOf(c, isann(c), isqrs(c), map1(c), map2(c), annpos(c), mamap(c, 0), mamap(c, -1)), "code $c")
            assertEquals(r.toList(), listOf(c, wfdb_isann(c), wfdb_isqrs(c), wfdb_map1(c), wfdb_map2(c), wfdb_annpos(c), wfdb_mamap(c, 0), wfdb_mamap(c, -1)), "code $c")
            assertEquals(r.toList(), listOf(c, wfdb_isann(c), w.wfdb_isqrs(c), w.wfdb_map1(c), w.wfdb_map2(c), w.wfdb_annpos(c), wfdb_mamap(c, 0), wfdb_mamap(c, -1)), "code $c")
        }
        // ammap of 'C'..'_' (C: printf("ammap:") ...)
        val am = ('C'.code..'_'.code).map { wfdb_ammap(it) }
        assertEquals(listOf(0, 0, 10, 6, 0, 0, 0, 0, 0, 0, 0, 1, 22, 12, 13, 41, 0, 0, 14, 5, 0, 0, 0, 0, 32, 0, 33, 0, 0), am)
        assertEquals(NORMAL, ammap('N'.code))
    }

    @Test
    fun codeMapSetters() {
        // on the default instance (the top-level functions)
        try {
            assertEquals(0, wfdb_setisqrs(1, 0))
            assertEquals(0, isqrs(1))
            assertEquals(0, wfdb_setisqrs(60, 1))
            assertEquals(44, wfdb_setisqrs(2, 300)) // (stored in a char)
            assertEquals(44, isqrs(2))
            assertEquals(5, wfdb_setmap1(14, PVC))
            assertEquals(5, map1(14))
            assertEquals(0, wfdb_setmap1(0, PVC))
            assertEquals(9, wfdb_setmap2(14, SVPB))
            assertEquals(9, map2(14))
            assertEquals(0, wfdb_setmap2(-3, PVC))
            assertEquals(6, wfdb_setannpos(14, 6))
            assertEquals(6, annpos(14))
            assertEquals(0, wfdb_setannpos(50, 2))
            // the aliases without the wfdb_ prefix
            assertEquals(1, setisqrs(1, 1))
            assertEquals(1, setmap1(14, NORMAL))
            assertEquals(1, setmap2(14, NORMAL))
            assertEquals(44, setannpos(14, 300))
            assertEquals(44, annpos(14))
        } finally {
            wfdb_setisqrs(1, 1)
            wfdb_setisqrs(2, 1)
            wfdb_setmap1(14, NOTQRS)
            wfdb_setmap2(14, NOTQRS)
            wfdb_setannpos(14, 2)
        }
        assertEquals(listOf(1, 1, 0, 0, 2), listOf(isqrs(1), isqrs(2), map1(14), map2(14), annpos(14)))
        // on an instance (which does not affect the default instance)
        val w = Wfdb()
        assertEquals(44, w.wfdb_setisqrs(2, 300))
        assertEquals(44, w.wfdb_isqrs(2))
        assertEquals(5, w.wfdb_setmap1(14, PVC))
        assertEquals(9, w.wfdb_setmap2(14, SVPB))
        assertEquals(6, w.wfdb_setannpos(14, 6))
        assertEquals(listOf(5, 9), listOf(w.wfdb_map1(14), w.wfdb_map2(14)))
        assertEquals(listOf(1, 0, 0, 2), listOf(isqrs(2), map1(14), map2(14), annpos(14)))
    }

    @Test
    fun annotationFields() {
        val a = Annotation(anntyp = 200, subtyp = -129, chan = 300, num = 128)
        assertEquals(listOf(-56, 127, 44, -128), listOf(a.anntyp, a.subtyp, a.chan, a.num))
        a.chan = -1
        assertEquals(255, a.chan)
    }

    // -----------------------------------------------------------------------
    // WFDB-x: in-process sorting of out-of-order output annotation files

    private class Tr(val time: Long, val anntyp: Int, val num: Int, val chan: Int, val aux: String?)

    /** The annotations written by [writeTricky]. */
    private val tricky = listOf(
        Tr(10, NORMAL, 0, 0, null),
        Tr(5, PVC, 0, 0, "first"),
        Tr(5, NORMAL, 1, 0, null),
        Tr(5, APC, 0, 2, "odd"),
        Tr(5, PVC, 0, 0, "second"), // replaces (5, 0, 0)
        Tr(3, NOTQRS, 0, 0, null), // dropped by the sort
        Tr(-4, NORMAL, 0, 0, null), // negative: dropped
        Tr(20, NORMAL, 0, 1, "hello world"),
        Tr(15, 42, 0, 0, null),
        Tr(5, NORMAL, 1, 0, "dup"), // replaces (5, 1, 0)
        Tr(7, NOTE, -3, 0, "note"),
        Tr(2, NORMAL, 0, 0, null),
        Tr(12, NORMAL, 0, 0, null),
        Tr(12, NORMAL, 0, 0, null),
        Tr(1, PVC, 2, 1, null),
    )

    /**
     * Writes REC.srt with annotations out of order: ties in time with
     * different num and chan, duplicates (time, num, chan), a NOTQRS
     * annotation, aux strings, a negative time, a modified mnemonic and a
     * time resolution. The input annotator atr of 100s is open at the same
     * time (as input annotator 0), and is read on after the output file is
     * closed. Returns the times read from atr.
     */
    private fun writeTricky(w: Wfdb, rec: String): List<Long> {
        w.setafreq(1000.5)
        w.setannstr(42, "new")
        assertEquals(0, w.annopen("100s", ai("atr", WFDB_READ), 1))
        val times = ArrayList<Long>()
        val a = Annotation()
        repeat(10) {
            assertEquals(0, w.getann(0, a))
            times.add(a.time)
        }
        assertEquals(0, w.annopen("+$rec", ai("srt", WFDB_WRITE), 1))
        for (t in tricky) {
            val x = Annotation(time = t.time, anntyp = t.anntyp, num = t.num, chan = t.chan)
            x.aux = t.aux?.let { aux(it) }
            assertEquals(0, w.putann(0, x))
        }
        w.oannclose(0)
        while (w.getann(0, a) == 0) times.add(a.time)
        w.wfdbquit()
        w.setafreq(0.0)
        return times
    }

    /** Writes two annotations out of order to REC.srt, closes the file (with annopen) and returns the status of closing. */
    private fun writeTwo(w: Wfdb, rec: String): Int {
        assertEquals(0, w.annopen(rec, ai("srt", WFDB_WRITE), 1))
        for (t in longArrayOf(5, 3)) w.putann(0, Annotation(time = t, anntyp = NORMAL))
        w.wfdbflush()
        return w.annopen(null as String?, arrayOf(), 0)
    }

    @Test
    fun sortInProcess() = withSortEnv {
        val d = DataDir("sort")
        val w = d.wfdb()
        w.wfdbquiet()

        // The atr times of 100s, as read without an output annotator.
        val expected = ArrayList<Long>()
        assertEquals(0, w.annopen("100s", ai("atr", WFDB_READ), 1))
        val a = Annotation()
        while (w.getann(0, a) == 0) expected.add(a.time)
        w.wfdbquit()

        // WFDBANNSORT=0: the file is left as written.
        setenv("WFDBANNSORT", "0")
        assertEquals(-6, writeTwo(w, "two"))
        assertEquals("050400ecfffffeff00040000", hex(d.read("two.srt")!!))
        assertEquals(expected, writeTricky(w, "unsorted"))
        assertEquals("to rearrange annotations in the correct order.\n", str(w.wfdberror()))
        unsetenv("WFDBANNSORT")

        // Sorted in this process, without disturbing the open input annotator.
        val w2 = d.wfdb() // (w has a modified mnemonic)
        w2.wfdbquiet()
        assertEquals(-6, writeTwo(w2, "two")) // as in C, also when sorted
        assertEquals("done!\n", str(w2.wfdberror()))
        assertEquals("030402040000", hex(d.read("two.srt")!!))
        assertEquals(expected, writeTricky(w, "modern"))
        assertEquals("done!\n", str(w.wfdberror()))
        val modern = d.read("modern.srt")!!
        assertEquals(SORTED_TRICKY_HEX, hex(modern))

        // Legacy mode: the sortann program is run (java -cp <class path>
        // wfdbx.cli.MainKt sortann), and sorts the file as sorting in this
        // process does.
        w.wfdbx_set_legacy(1)
        val savedWfdb = getenv("WFDB")
        w.setwfdb(d.dir) // (the WFDB path; exported to WFDB, as in C)
        writeTricky(w, "legacy")
        if (savedWfdb == null) unsetenv("WFDB") else setenv("WFDB", savedWfdb)
        assertEquals("done!\n", str(w.wfdberror()))
        assertContentEquals(modern, d.read("legacy.srt"))
        w.wfdbx_set_legacy(0)

        // The sorted file: in order, without the NOTQRS and negative-time
        // annotations, with the replacements, the time resolution and the
        // definition of code 42 (read with a fresh library state).
        val w3 = d.wfdb()
        assertEquals(0, w3.annopen("modern", ai("srt", WFDB_READ), 1))
        assertEquals(1000.5, w3.getiaorigfreq(0))
        val got = ArrayList<String>()
        while (w3.getann(0, a) == 0) {
            val x = a.aux?.let { cstr(it.copyOfRange(1, it.size)).latin1() }
            got.add("${a.time} ${a.anntyp} ${a.num} ${a.chan} $x")
        }
        w3.wfdbquit()
        assertEquals(
            listOf(
                "1 $PVC 2 1 null", "2 $NORMAL 0 0 null", "5 $PVC 0 0 second", "5 $APC 0 2 odd",
                "5 $NORMAL 1 0 dup", "7 $NOTE -3 0 note", "10 $NORMAL 0 0 null", "12 $NORMAL 0 0 null",
                "15 42 0 0 null", "20 $NORMAL 0 1 hello world",
            ),
            got,
        )
        assertEquals("new", str(w3.annstr(42)))
        d.remove()
    }

    /** A sort that fails (here: the file cannot be read back, its directory having been removed) leaves the annotations to be rearranged. */
    @Test
    fun sortErrors() = withSortEnv {
        val d = DataDir("sorterr")
        val w = d.wfdb()
        w.wfdbquiet()
        assertEquals(0, w.annopen("gone/rec", ai("srt", WFDB_WRITE), 1))
        for (t in longArrayOf(5, 3)) w.putann(0, Annotation(time = t, anntyp = NORMAL))
        w.wfdbflush()
        removeTree(d.path("gone"))
        assertEquals(-6, w.annopen(null as String?, arrayOf(), 0))
        assertEquals("to rearrange annotations in the correct order.\n", str(w.wfdberror()))
        d.remove()
    }

    /** WFDB-x: the list no longer loses an out-of-order annotation at time 0 (num and chan 0) and those inserted after it; the original insertion (legacy) does. */
    @Test
    fun annListTime0() {
        fun list(legacy: Boolean, anns: List<Pair<Long, Int>>): List<Pair<Long, Int>> {
            val l = AnnList(legacy)
            for ((time, chan) in anns) l.insert(Annotation(time = time, chan = chan, anntyp = NORMAL))
            assertFalse(l.inOrder())
            return l.toList().map { Pair(it.time, it.chan) }
        }
        val x = listOf(5L to 0, 0L to 0, 3L to 0)
        assertEquals(listOf(0L to 0, 3L to 0, 5L to 0), list(false, x))
        assertEquals(listOf(5L to 0), list(true, x))
        // several channels; a later (0, 0, 0) replaces a real (0, 0, 0) entry
        val y = listOf(5L to 0, 0L to 1, 0L to 0, 2L to 0, 0L to 0, 0L to 2)
        assertEquals(listOf(0L to 0, 0L to 1, 0L to 2, 2L to 0, 5L to 0), list(false, y))
        // (original: the (0, 0) entries replace the head; (0, 1) and what follows it remain reachable)
        assertEquals(listOf(0L to 1, 0L to 2, 2L to 0, 5L to 0), list(true, y))
        // (0, 0, chan > 0) was never lost
        val z = listOf(5L to 0, 0L to 1, 3L to 0)
        assertEquals(list(true, z), list(false, z))
        assertEquals(0, AnnList().toList().size)
    }

    /** WFDB-x: the library sort keeps time-0 annotations. */
    @Test
    fun sortTime0() = withSortEnv {
        val d = DataDir("sort0")
        val w = d.wfdb()
        w.wfdbquiet()
        fun write(rec: String) {
            assertEquals(0, w.annopen(rec, ai("srt", WFDB_WRITE), 1))
            for ((t, x) in listOf(5L to null, 0L to "+ (N", 3L to null)) {
                val a = Annotation(time = t, anntyp = NORMAL)
                a.aux = x?.let { aux(it) }
                w.putann(0, a)
            }
            w.wfdbquit()
        }
        write("modern")
        assertEquals("done!\n", str(w.wfdberror()))
        setenv("WFDBANNSORT", "0")
        write("child") // (unsorted: the input of the sortann tool below)
        unsetenv("WFDBANNSORT")
        assertEquals(0, w.annopen("modern", ai("srt", WFDB_READ), 1))
        val v = ArrayList<Long>()
        val a = Annotation()
        while (w.getann(0, a) == 0) v.add(a.time)
        w.wfdbquit()
        assertEquals(listOf(0L, 3, 5), v)
        // the file of the sortann tool (rust/target/release/sortann) for the same input
        assertEquals("000404fc2b20284e030402040000", hex(d.read("modern.srt")!!))
        d.remove()
    }

    @Test
    fun calibration() {
        val d = DataDir("cal")
        val w = d.wfdb()
        fun cal(desc: String?, units: String?): String {
            val c = Calinfo()
            val stat = w.getcal(desc, units, c)
            if (stat != 0) return "$stat"
            return "${c.low} ${c.high} ${c.scale} ${c.caltype} ${str(c.sigtype)} ${str(c.units)}"
        }
        assertEquals(0, w.calopen("wfdbcal"))
        assertEquals("0.0 1.0 1.0 4 ECG mV", cal("ECG lead II", "mV"))
        assertEquals("0.0 1.0 1000.0 4 ECG uV", cal("ECG", "uV"))
        assertEquals("0.0 0.0 100.0 3 ABP mmHg", cal("ABP", "mmHg"))
        assertEquals("0.0 100.0 100.0 3 BP mmHg", cal("BP", null))
        assertEquals("0.0 1.0 1.0 4 ECG mV", cal(null, null))
        assertEquals("-1", cal("nosuch", "x"))
        val test = Calinfo(-1.5, 2.5, 3.0, "TEST".latin1(), "xu".latin1(), WFDB_DC_COUPLED or WFDB_CAL_SINE)
        val ac = Calinfo(0.0, 0.0, 7.0, "AC".latin1(), "yu".latin1(), WFDB_AC_COUPLED or WFDB_CAL_UNDEF)
        assertEquals(0, w.putcal(test))
        assertEquals(0, w.putcal(ac))
        assertEquals("-1.5 2.5 3.0 5 TEST xu", cal("TEST signal", "xu"))
        w.flushcal()
        assertEquals("-1", cal("ECG", "mV"))
        w.putcal(test)
        w.putcal(ac)
        w.putcal(Calinfo(1.0, 2.0, 0.25, "SQ".latin1(), "zu".latin1(), WFDB_DC_COUPLED or WFDB_CAL_SQUARE))
        w.putcal(Calinfo(1.0, 2.0, 0.25, "SAW".latin1(), "zu".latin1(), WFDB_AC_COUPLED or WFDB_CAL_SAWTOOTH))
        w.wfdbquiet()
        assertEquals(-1, w.newcal("my.cal")) // illegal name
        w.wfdbverbose()
        assertEquals(0, w.newcal("mycal"))
        assertEquals(
            "TEST\t-1.5 2.5 sine 3 xu\r\nAC\t- - undefined 7 yu\r\nSQ\t1 2 square 0.25 zu\r\nSAW\t- 2 sawtooth 0.25 zu\r\n",
            d.read("mycal")!!.latin1(),
        )
        assertEquals(0, w.calopen("mycal"))
        assertEquals("0.0 0.0 7.0 0 AC yu", cal("AC", "yu"))
        assertEquals("-1", cal("ECG", "mV"))
        assertEquals(0, w.calopen("+wfdbcal"))
        assertEquals("0.0 1.0 1.0 4 ECG mV", cal("ECG", "mV"))
        assertEquals("0.0 2.0 0.25 6 SAW zu", cal("SAW", null))
        w.wfdbquiet()
        assertEquals(-2, w.calopen("nosuch.cal"))
        assertEquals("calopen: can't read calibration file nosuch.cal\n", str(w.wfdberror()))
        w.wfdbverbose()
        // calopen(NULL): $WFDBCAL, or wfdbcal
        assertEquals(0, w.calopen(null as ByteArray?))
        assertEquals("0.0 1.0 1.0 4 ECG mV", cal("ECG", "mV"))
        w.flushcal()
        d.remove()
    }

    @Test
    fun wfdbinitQuit() {
        val d = DataDir("init")
        val w = d.wfdb()
        w.wfdbquiet()
        // annopen fails first: its status is returned
        assertEquals(-3, w.wfdbinit("nosuch".latin1(), ai("atr", WFDB_READ), 1, null, 0))
        w.wfdbquit()
        // otherwise, that of isigopen
        val si = Array(2) { Siginfo() }
        assertEquals(2, w.wfdbinit("100s".latin1(), ai("atr", WFDB_READ), 1, si, 2))
        assertEquals("MLII", str(si[0].desc))
        val a = Annotation()
        assertEquals(0, w.getann(0, a))
        val v = IntArray(2)
        assertEquals(2, w.getvec(v))
        assertEquals(listOf(995, 1011), v.toList())
        w.wfdbquit()
        assertEquals(0.0, w.sampfreq(null))
        assertEquals(-2, w.getann(0, a))
        assertEquals(0, w.isigsettime(5)) // (no signals open)
        w.wfdbverbose()
        d.remove()
    }

    companion object {
        /**
         * The file sorted by writeTricky, byte for byte: the output of the
         * sortann tool (rust/target/release/sortann -r. child -a srt, which
         * gives the same file as the C program) for the unsorted file.
         */
        const val SORTED_TRICKY_HEX = "00581afc23232074696d65207265736f6c7574696f6e3a20313030302e3500581efc232320616e6e6f746174696f6e2074" +
            "79706520646566696e6974696f6e73005807fc3432206e65772000005815fc232320656e64206f6620646566696e6974696f6e730000ecffffffff01" +
            "00011401f802f0010400f800f0031406fc7365636f6e64002002f803fc6f646400000400f801f003fc647570000258fdf304fc6e6f7465030400f002" +
            "0403a8050401f80bfc68656c6c6f20776f726c64000000"
    }
}
