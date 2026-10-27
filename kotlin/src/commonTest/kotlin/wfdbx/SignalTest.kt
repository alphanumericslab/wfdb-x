// Tests of the signal functions (Signal.kt, SignalTime.kt): ports of the
// C-style parts of rust/tests/signals.rs (the counterparts of the signal
// parts of cpp/tests/test_api.cpp and cpp/tests/test_api_c.cpp; expected
// values produced by the C library, see tests/reference/api_expect.c). The
// parts of the Rust tests that use the high-level API (read_record,
// write_record, ...) are written here with the C-style functions
// (osigfopen/putvec/newheader, isigopen/getvecs); the high-level API
// itself is tested in phase 4.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It tests wfdb-x; it has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

package wfdbx

import wfdbx.cstd.GlibcRand
import wfdbx.cstd.latin1
import wfdbx.cstd.startsWith
import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class SignalTest {
    private fun str(b: ByteArray?) = b?.latin1()

    /** Runs [f] with a fresh copy of tests/data and a library instance reading and writing there. */
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

    /** Open all signals of a record (as isigopen(record, NULL, 8) in C). */
    private fun isig(w: Wfdb, record: String): Int = w.isigopen(record, null, 8)

    /** getvec: the status followed by n samples. */
    private fun vec(w: Wfdb, n: Int): List<Int> {
        val v = IntArray(n + 8)
        val stat = w.getvec(v)
        return listOf(stat) + v.copyOf(n).toList()
    }

    /** getframe: the status followed by n samples. */
    private fun frame(w: Wfdb, n: Int): List<Int> {
        val v = IntArray(n + 8)
        val stat = w.getframe(v)
        return listOf(stat) + v.copyOf(n).toList()
    }

    private fun segs(w: Wfdb): List<String> {
        val s = ArrayList<Seginfo>()
        val n = w.getseginfo(s)
        return (0 until maxOf(n, 0)).map { "${s[it].recname.latin1()} ${s[it].nsamp} ${s[it].samp0}" }
    }

    /** All the samples of a record, read with getvec until it fails (and its last status). */
    private fun readAll(w: Wfdb, rec: String): Pair<List<Int>, Int> {
        val n = w.isigopen(rec, null, 0)
        assertTrue(n > 0, rec)
        assertEquals(n, w.isigopen(rec, Array(n) { Siginfo() }, n))
        val v = IntArray(n)
        val r = ArrayList<Int>()
        var stat: Int
        while (true) {
            stat = w.getvec(v)
            if (stat < 0) break
            for (x in v) r.add(x)
        }
        w.wfdbquit()
        return Pair(r, stat)
    }

    /** All the samples of a record, read with getvecs (in pieces of [chunk] vectors). */
    private fun readAllBulk(w: Wfdb, rec: String, chunk: Int = 100000): List<Int> {
        val n = w.isigopen(rec, null, 0)
        assertEquals(n, w.isigopen(rec, Array(n) { Siginfo() }, n))
        val buf = IntArray(chunk * n)
        val r = ArrayList<Int>()
        while (true) {
            val k = w.getvecs(buf, chunk.toLong())
            for (i in 0 until maxOf(k, 0L).toInt() * n) r.add(buf[i])
            if (k < chunk) break
        }
        w.wfdbquit()
        return r
    }

    /** Signal specifications of a record written with osigfopen. */
    private fun spec(fname: String, nsig: Int, fmt: Int, gain: Double = 200.0, adcres: Int = 16, units: String? = "mV"): Array<Siginfo> =
        Array(nsig) {
            Siginfo(
                fname = fname.latin1(), desc = "s$it".latin1(), units = units?.latin1(), gain = gain, group = 0,
                fmt = fmt, adcres = adcres,
            )
        }

    /** Writes a record with the C-style functions (as write_record does). */
    private fun writeRec(w: Wfdb, rec: String, x: IntArray, nsig: Int, fs: Double, fmt: Int = 16, si: Array<Siginfo>? = null) {
        val s = si ?: spec("$rec.dat", nsig, fmt)
        assertEquals(nsig, w.osigfopen(s, nsig), str(w.wfdberror()))
        w.setsampfreq(fs)
        val v = IntArray(nsig)
        for (i in 0 until x.size / nsig) {
            x.copyInto(v, 0, i * nsig, (i + 1) * nsig)
            assertTrue(w.putvec(v) >= 0)
        }
        assertEquals(0, w.newheader(rec))
        w.wfdbquit()
    }

    // -----------------------------------------------------------------------
    // Time and date conversion

    @Test
    fun intervalStrings() = withData("intervals") { _, w ->
        assertEquals(2, w.isigopen("100s", null, 0))
        assertEquals(21600L, w.strtim("1:0"))
        assertEquals("    1:00", str(w.timstr(21600)))
        assertEquals("    0:03.428", str(w.mstimstr(1234)))
        assertEquals(7L, w.strtim("s7"))
        assertEquals(21600L, w.strtim("e"))
    }

    @Test
    fun absoluteTimes() = withData("abstimes") { _, w ->
        w.isigopen("fmt16", null, 0)
        assertEquals("[12:34:56 31/12/1999]", str(w.timstr(0)))
        assertEquals(-803L, w.strtim("[12:35:00]"))
        assertEquals("[12:35:06.789 31/12/1999]", str(w.mstimstr(-2500)))
    }

    @Test
    fun dates() {
        val w = Wfdb()
        for (s in listOf("01/01/2000", "29/02/2000", "15/10/1582", "31/12/1999")) {
            val d = w.strdat(s)
            assertEquals(" $s", str(w.datstr(d)))
        }
        val d = w.strdat("29/02/1900")
        assertEquals(" 01/03/1900", str(w.datstr(d)))
        assertEquals(0L, w.strdat("bogus"))
    }

    @Test
    fun counterAndBaseTime() = withData("counter") { _, w ->
        isig(w, "100s")
        assertEquals(360.0, w.getcfreq())
        assertEquals(0.0, w.getbasecount())
        w.setcfreq(1000.0)
        w.setbasecount(500.5)
        assertEquals(1000.0, w.getcfreq())
        assertEquals(500.5, w.getbasecount())
        assertEquals(360L, w.strtim("c1500.5"))
        assertEquals(0L, w.strtim("c500.5"))
        w.setcfreq(0.0)
        assertEquals(360.0, w.getcfreq())
        assertEquals(0, w.setbasetime("10:20:30 15/6/2001"))
        assertEquals("[10:20:30 15/06/2001]", str(w.timstr(0)))
        assertEquals("    0:01", str(w.timstr(360)))
        assertEquals("[10:20:31 15/06/2001]", str(w.timstr(-360)))
        assertEquals("[10:20:32.778 15/06/2001]", str(w.mstimstr(-1000)))
        assertEquals(0, w.setbasetime("8:00"))
        assertEquals("[00:08:00]", str(w.timstr(0)))
        assertEquals("[00:08:02]", str(w.timstr(-720)))
        w.wfdbquiet()
        assertEquals(-1, w.setbasetime("garbage"))
        w.wfdbverbose()
        w.setcfreq(500.0)
        w.wfdbquit()
        assertEquals(500.0, w.getcfreq())
    }

    @Test
    fun currentBaseTime() {
        // setbasetime(NULL): the current local time (a valid date and time)
        val w = Wfdb()
        assertEquals(0, w.setbasetime(null as ByteArray?))
        w.setsampfreq(1.0)
        val s = str(w.timstr(0))!!
        assertTrue(Regex("""\[\d\d:\d\d:\d\d \d\d/\d\d/\d{4}]""").matches(s), s)
    }

    // -----------------------------------------------------------------------
    // The C-style API (expected values from the C library)

    @Test
    fun errors() = withData("errors") { _, w ->
        w.wfdbquiet()
        assertEquals(-1, isig(w, "nosuch"))
        assertEquals("init: can't open header for record nosuch\n", str(w.wfdberror()))
    }

    @Test
    fun bufferSizes() = withData("bufsizes") { _, w ->
        w.wfdbquiet()
        assertEquals(8192, w.setibsize(0))
        assertEquals(1000, w.setibsize(1000))
        assertEquals(-2, w.setibsize(-1))
        assertEquals(8192, w.setobsize(0))
        assertEquals(2000, w.setobsize(2000))
        assertEquals(-2, w.setobsize(-5))
        isig(w, "100s")
        assertEquals(-1, w.setibsize(512))
    }

    @Test
    fun getvecModesAndFrequencies() = withData("gvmodes") { _, w ->
        assertEquals(0, w.getgvmode())
        assertEquals(2, isig(w, "100s"))
        assertEquals(360.0, w.getifreq())
        assertEquals(1, w.getspf())
        w.wfdbquit()
        isig(w, "fmt16")
        assertEquals(listOf(3, -7, 32, -33), vec(w, 3))
        assertEquals(listOf(3, 4, 53, -47), vec(w, 3))
        assertEquals(listOf(3, -20, 24, -27), vec(w, 3))
        assertEquals(0, w.setifreq(100.0))
        assertEquals(100.0, w.getifreq())
        assertEquals(0, w.isigsettime(0))
        assertEquals(listOf(3, -7, 32, -33), vec(w, 3))
        assertEquals(listOf(3, -21, 23, -35), vec(w, 3))
        assertEquals(listOf(3, 7, -14, -44), vec(w, 3))
        assertEquals(0, w.setifreq(1000.0))
        assertEquals(1000.0, w.getifreq())
        assertEquals(0, w.isigsettime(2))
        assertEquals(listOf(3, -7, 32, -33), vec(w, 3))
        repeat(4) { assertEquals(listOf(3, 4, 53, -47), vec(w, 3)) }
        w.wfdbquiet()
        assertEquals(-1, w.setifreq(-1.0))
        w.wfdbverbose()
        assertEquals(250.0, w.getifreq())
        w.wfdbquit()
        isig(w, "100s")
        w.setgvmode(WFDB_HIGHRES)
        assertEquals(1, w.getgvmode())
        w.setgvmode(WFDB_GVPAD or WFDB_LOWRES)
        assertEquals(2, w.getgvmode())
        w.setgvmode(WFDB_HIGHRES or WFDB_GVPAD or 4)
        assertEquals(3, w.getgvmode())
        w.setgvmode(0)
    }

    @Test
    fun amplitudeConversion() = withData("amplitude") { _, w ->
        w.wfdbquiet()
        isig(w, "100s") // gain 200, baseline 1024
        assertEquals(1000, w.adumuv(0, 200))
        assertEquals(-185, w.adumuv(0, -37))
        assertEquals(5, w.adumuv(1, 1))
        assertEquals(-5, w.adumuv(0, -1))
        assertEquals(WFDB_INVALID_SAMPLE, w.adumuv(7, 100)) // wfdb-x: invalid signal
        assertEquals(200, w.muvadu(0, 1000))
        assertEquals(-67, w.muvadu(0, -333))
        assertEquals(0, w.muvadu(1, 2))
        assertEquals(WFDB_INVALID_SAMPLE, w.muvadu(9, 1000))
        assertEquals(1.0, w.aduphys(0, 1224))
        assertEquals(-0.62, w.aduphys(1, 900))
        assertTrue(w.aduphys(5, 300).isNaN())
        assertEquals(1224, w.physadu(0, 1.0))
        assertEquals(924, w.physadu(1, -0.5023))
        assertEquals(WFDB_INVALID_SAMPLE, w.physadu(5, 1.5))
        w.wfdbquit()
        isig(w, "fmt16") // 100(-5)/mV, 150(5)/uV, 200(15)/mmHg
        assertEquals(1000, w.adumuv(0, 100))
        assertEquals(1000, w.adumuv(1, 150))
        assertEquals(-35, w.adumuv(2, -7))
        assertEquals(100, w.muvadu(0, 1000))
        assertEquals(150, w.muvadu(1, 1000))
        assertEquals(-500, w.muvadu(2, -2500))
        assertEquals(1.0, w.aduphys(0, 95))
        assertEquals(0.033333333333333333, w.aduphys(1, 10))
        assertEquals(-0.089999999999999997, w.aduphys(2, -3))
        assertEquals(95, w.physadu(0, 1.0))
        assertEquals(-333, w.physadu(1, -2.25))
        assertEquals(95, w.physadu(2, 0.4))
        w.wfdbverbose()
    }

    @Test
    fun sampleRandomAccess() = withData("sample") { _, w ->
        isig(w, "100s")
        assertEquals(0, w.sample_valid())
        assertEquals(995, w.sample(0, 0))
        assertEquals(1, w.sample_valid())
        assertEquals(970, w.sample(1, 1000))
        assertEquals(1, w.sample_valid())
        assertEquals(975, w.sample(0, 21599))
        assertEquals(1, w.sample_valid())
        assertEquals(975, w.sample(0, 21600))
        assertEquals(0, w.sample_valid())
        assertEquals(995, w.sample(0, 5))
        assertEquals(1, w.sample_valid())
        assertEquals(1011, w.sample(1, -3))
        assertEquals(1, w.sample_valid())
        assertEquals(-32768, w.sample(2, 0))
        assertEquals(-1, w.sample_valid())
    }

    @Test
    fun getframeMultifrequency() = withData("mfreq") { _, w ->
        isig(w, "mfreq") // 1, 2 and 4 samples per frame
        assertEquals(1, w.getspf())
        assertEquals(100.0, w.getifreq())
        assertEquals(listOf(3, 138, 218, 2699, 219, -1316, 1120, 1973), frame(w, 7))
        assertEquals(listOf(3, 2677, 1201, 275, -989, 1822, 2762, 1927), frame(w, 7))
        assertEquals(listOf(3, -597, -455, 181), vec(w, 3))
        w.isigsettime(599)
        assertEquals(listOf(3, -1394, 715, 558, 2215, -1785, 860, -491), frame(w, 7))
        assertEquals(-1, frame(w, 7)[0])
        w.wfdbquit()
        w.setgvmode(WFDB_HIGHRES)
        isig(w, "mfreq")
        assertEquals(4, w.getspf())
        assertEquals(400.0, w.getifreq())
        assertEquals(listOf(3, 138, 218, 2699, 219, -1316, 1120, 1973), frame(w, 7))
        assertEquals(listOf(3, 2677, 1201, -989), vec(w, 3))
        assertEquals(listOf(3, 2677, 1201, 1822), vec(w, 3))
        w.wfdbquit()
        w.setgvmode(0)
    }

    @Test
    fun isgsettimeGroups() = withData("groups") { _, w ->
        isig(w, "twog") // group 0: signal 0; group 1: signals 1 and 2
        assertEquals(listOf(3, 1020, 977, 316), vec(w, 3))
        assertEquals(0, w.isgsettime(1, 100))
        assertEquals(listOf(3, 1880, -630, 83), vec(w, 3))
        assertEquals(listOf(3, 325, 245, 1597), vec(w, 3))
        assertEquals(0, w.isgsettime(0, 500))
        assertEquals(listOf(3, -1823, 338, -709), vec(w, 3))
        assertEquals(0, w.isgsettime(1, 1001))
        assertEquals(-1, vec(w, 3)[0])
    }

    @Test
    fun tnextvecGetseginfo() = withData("tnextvec") { _, w ->
        isig(w, "100s")
        assertTrue(segs(w).isEmpty())
        assertEquals(5L, w.tnextvec(0, 5))
        assertEquals(0L, w.tnextvec(1, 0))
        w.wfdbquit()
        isig(w, "multi")
        assertEquals(listOf("100s 21600 0", "null 1800 21600", "100s 21600 23400"), segs(w))
        assertEquals(0L, w.tnextvec(0, 0))
        assertEquals(21599L, w.tnextvec(0, 21599))
        assertEquals(23500L, w.tnextvec(1, 21700))
        assertEquals(44999L, w.tnextvec(0, 44999))
        assertEquals(-1L, w.tnextvec(0, 45000))
        w.wfdbquit()
        isig(w, "vlay")
        assertEquals(listOf("vlay_0 0 0", "fmt16 1500 0", "~ 200 1500", "fmt212 1501 1700"), segs(w))
        w.wfdbquiet()
        assertEquals(0L, w.tnextvec(0, 0))
        assertEquals(1700L, w.tnextvec(1, 1499))
        assertEquals(-1L, w.tnextvec(2, 1500))
        assertEquals(-1L, w.tnextvec(0, 1600))
        assertEquals(-1L, w.tnextvec(5, 0))
        w.wfdbverbose()
    }

    @Test
    fun skewAndStart() = withData("skew") { _, w ->
        isig(w, "skew")
        assertEquals(0, w.wfdbgetskew(0))
        assertEquals(3, w.wfdbgetskew(1))
        assertEquals(7, w.wfdbgetskew(2))
        assertEquals(0, w.wfdbgetskew(3))
        assertEquals(listOf(3, -7, 21, -32768), vec(w, 3))
        w.wfdbsetiskew(1, 2)
        w.wfdbsetiskew(2, 100000) // too large: ignored
        w.wfdbsetiskew(0, -1) // negative: ignored
        assertEquals(0, w.wfdbgetskew(0))
        assertEquals(2, w.wfdbgetskew(1))
        assertEquals(7, w.wfdbgetskew(2))
        w.wfdbquit()
        isig(w, "prolog")
        assertEquals(100L, w.wfdbgetstart(0))
        assertEquals(100L, w.wfdbgetstart(2))
        assertEquals(0L, w.wfdbgetstart(3))
        w.wfdbquit()
        isig(w, "100s")
        assertEquals(0L, w.wfdbgetstart(0))
    }

    @Test
    fun getframeDeskew() = withData("deskew") { _, w ->
        isig(w, "skew")
        assertEquals(listOf(3, -7, 21, -32768), frame(w, 3))
        assertEquals(listOf(3, 4, -14, -85), frame(w, 3))
        w.isigsettime(1497)
        assertEquals(listOf(-1, -32755, 16705, -32768), frame(w, 3))
        assertEquals(listOf(-1, -32751, -14, 16705), frame(w, 3))
    }

    @Test
    fun uncalibratedSignals() = withData("uncal") { _, w ->
        w.wfdbquiet()
        isig(w, "null") // gain 0: wfdb-x: no default gain
        assertEquals(WFDB_INVALID_SAMPLE, w.adumuv(0, 100))
        assertEquals(WFDB_INVALID_SAMPLE, w.muvadu(1, 100))
        assertTrue(w.aduphys(0, 100).isNaN())
        assertEquals(WFDB_INVALID_SAMPLE, w.physadu(1, 0.5))
        assertEquals(listOf(2, -32768, -32768), vec(w, 2))
        w.wfdbverbose()
    }

    @Test
    fun multifrequencyResampling() = withData("resampling") { _, w ->
        isig(w, "mfreq")
        assertEquals(0, w.setifreq(200.0))
        assertEquals(listOf(3, 138, 1459, 499), vec(w, 3))
        assertEquals(listOf(3, 2677, 738, 1381), vec(w, 3))
        assertEquals(listOf(3, 2677, 738, 1381), vec(w, 3))
        w.wfdbquit()
        isig(w, "mfreq")
        assertEquals(869, w.sample(2, 10))
        assertEquals(1, w.sample_valid())
        assertEquals(637, w.sample(1, 599))
        assertEquals(1, w.sample_valid())
        w.wfdbquit()
        isig(w, "multi")
        assertEquals(0, w.isigsettime(100))
        assertEquals(23450L, w.tnextvec(0, 21650))
        assertEquals(listOf(2, 969, 996), vec(w, 2))
    }

    @Test
    fun outputPrologSkewFlush() = withData("prologout") { d, w ->
        w.setcfreq(0.0)
        val si = Array(2) {
            Siginfo(
                fname = "out.dat".latin1(), desc = (if (it == 1) "second" else "first").latin1(), units = "mV".latin1(),
                gain = 100.0, group = 0, fmt = 16, adcres = 12,
            )
        }
        w.setsampfreq(100.0)
        assertEquals(2, w.osigfopen(si, 2))
        assertEquals(0, w.wfdbputprolog("PROLOG!".latin1(), 7, 0))
        w.wfdbsetskew(1, 4)
        for (i in 0 until 5) w.putvec(intArrayOf(i, -i))
        w.wfdbflush()
        assertEquals(27, d.read("out.dat")!!.size)
        assertEquals(0, w.newheader("out"))
        assertEquals(0, w.putinfo("info line"))
        w.wfdbquit()
        assertEquals(
            "out 2 100 5\r\nout.dat 16+7 100/mV 12 0 0 10 0 first\r\nout.dat 16:4+7 100/mV 12 0 0 -10 0 second\r\n#info line\r\n",
            str(d.read("out.hea")),
        )
        assertContentEquals(unhex("50524f4c4f4721 0000 0000 0100 ffff 0200 feff 0300 fdff 0400 fcff"), d.read("out.dat"))

        w.setsampfreq(100.0)
        si[0].fname = "out2.dat".latin1()
        si[1].fname = "out2.dat".latin1()
        w.osigfopen(si, 2)
        w.wfdbsetstart(0, 512)
        w.putvec(intArrayOf(1, 2))
        w.newheader("out2")
        w.wfdbquit()
        assertEquals(
            "out2 2 100 1\r\nout2.dat 16+512 100/mV 12 0 1 1 0 first\r\nout2.dat 16+512 100/mV 12 0 2 2 0 second\r\n",
            str(d.read("out2.hea")),
        )
        assertEquals(4, d.read("out2.dat")!!.size)
    }

    @Test
    fun setheaderTruncatesStrings() = withData("sethdr") { d, w ->
        // As in C (strtok), units end at their first space, descriptions
        // at their first line ending.
        val si = arrayOf(
            Siginfo(fname = "t.dat".latin1(), desc = "a b\nc".latin1(), units = " mV x".latin1(), gain = 10.0, fmt = 16, spf = 1),
        )
        w.setsampfreq(10.0)
        assertEquals(0, w.setheader("t", si, 1))
        w.wfdbquit()
        assertEquals("t 1 10 0\r\nt.dat 16 10/mV 0 0 0 0 0 a b\r\n", str(d.read("t.hea")))
        assertEquals(" mV", str(si[0].units))
        assertEquals("a b", str(si[0].desc))
    }

    @Test
    fun infoStrings() = withData("info") { d, w ->
        val xform = "Produced by xform from record 100, beginning at 0:0"
        assertEquals(" 69 M 1085 1629 x1", str(w.getinfo("100s")))
        assertEquals(" Aldomet, Inderal", str(w.getinfo(null)))
        assertEquals(xform, str(w.getinfo(null)))
        assertEquals(0, w.setinfo("newrec"))
        assertEquals(0, w.putinfo("first"))
        assertEquals(0, w.putinfo("second"))
        assertEquals(0, w.setinfo(null))
        w.wfdbquiet()
        assertEquals(-1, w.putinfo("third"))
        w.wfdbverbose()
        assertEquals("#first\r\n#second\r\n", str(d.read("newrec.info")))
        assertEquals("first", str(w.getinfo("newrec")))
        assertEquals("second", str(w.getinfo(null)))
        assertNull(w.getinfo(null))
        assertEquals(0, w.setinfo("100s"))
        assertEquals(0, w.putinfo("extra"))
        w.wfdbquit()
        assertEquals(" 69 M 1085 1629 x1", str(w.getinfo("100s")))
        assertEquals(" Aldomet, Inderal", str(w.getinfo(null)))
        assertEquals(xform, str(w.getinfo(null)))
        assertEquals("extra", str(w.getinfo(null)))
        isig(w, "fmt16")
        assertNull(w.getinfo(null))
    }

    @Test
    fun freeinfo() = withData("freeinfo") { d, w ->
        // After wfdb_freeinfo, getinfo(NULL) rereads the info strings of the
        // open input record from the first, or fails if there is none.
        val first = " 69 M 1085 1629 x1"
        val second = " Aldomet, Inderal"
        assertEquals(first, str(w.getinfo("100s")))
        assertEquals(second, str(w.getinfo(null)))
        w.wfdb_freeinfo()
        w.wfdbquiet()
        assertNull(w.getinfo(null))
        assertEquals("getinfo: caller did not specify record name\n", str(w.wfdberror()))
        w.wfdbverbose()
        isig(w, "100s")
        assertEquals(first, str(w.getinfo(null)))
        assertEquals(second, str(w.getinfo(null)))
        w.wfdb_freeinfo()
        assertEquals(first, str(w.getinfo(null)))
        w.wfdb_freeinfo()
        w.wfdb_freeinfo()
        assertEquals(first, str(w.getinfo(null)))
        w.wfdbquit()
        // the same on the default instance (of this thread)
        run {
            val prev = wfdbx_set_input_dir(d.dir)
            assertEquals(first, str(getinfo("100s")))
            assertEquals(second, str(getinfo(null)))
            wfdb_freeinfo()
            wfdbquiet()
            assertNull(getinfo(null))
            wfdbverbose()
            isigopen("100s", null, 8)
            assertEquals(first, str(getinfo(null)))
            assertEquals(second, str(getinfo(null)))
            wfdb_freeinfo()
            assertEquals(first, str(getinfo(null)))
            wfdbquit()
            wfdbx_set_input_dir(prev)
        }
    }

    @Test
    fun setmsheaderSegments() = withData("msheader") { d, w ->
        val names = arrayOf("100s", "null", "100s")
        assertEquals(0, w.setmsheader("msrec", names, 3))
        w.wfdbquiet()
        assertEquals(-1, w.setmsheader("msbad", names, 0))
        assertEquals(-4, w.setmsheader("msbad", arrayOf("100s", "fmt16"), 2))
        w.wfdbverbose()
        w.wfdbquit()
        assertEquals("msrec/3 2 360 45000\r\n100s 21600\r\nnull 1800\r\n100s 21600\r\n", str(d.read("msrec.hea")))
        assertEquals(2, isig(w, "msrec"))
        assertEquals(listOf("100s 21600 0", "null 1800 21600", "100s 21600 23400"), segs(w))
        w.isigsettime(21599)
        assertEquals(listOf(2, 975, 989), vec(w, 2))
        assertEquals(listOf(2, -32768, -32768), vec(w, 2))
    }

    // -----------------------------------------------------------------------
    // Round trips in every storage format (including FLAC), written with
    // osigfopen/putvec/newheader and read with getvecs and sample()

    @Test
    fun signalRoundtrip() = withData("roundtrip") { _, w ->
        val ranges = listOf(
            8 to 1000L, 16 to 32767L, 61 to 32767L, 80 to 127L, 160 to 32767L, 212 to 2047L, 310 to 511L, 311 to 511L,
            24 to 8388607L, 32 to 2147483647L, 508 to 127L, 516 to 32767L, 524 to 8388607L,
        )
        for ((fmt, hi) in ranges) {
            for (nsig in 1..3) {
                val rng = GlibcRand(fmt * 10 + nsig)
                val n = if (fmt >= 500) 5003 else 1001
                val x = IntArray(n * nsig)
                if (fmt == 8) {
                    for (s in 0 until nsig) {
                        var v = 0
                        for (i in 0 until n) {
                            v += rng.rand() % 121 - 60
                            x[i * nsig + s] = v
                        }
                    }
                } else {
                    for (i in x.indices) {
                        val r = (rng.rand().toLong() shl 31) or rng.rand().toLong()
                        x[i] = (r % (2 * hi) - hi + 1).toInt()
                    }
                }
                writeRec(w, "rt", x, nsig, 250.0, fmt)
                var y = readAllBulk(w, "rt", 77)
                assertEquals(y, readAll(w, "rt").first, "format $fmt, $nsig signals (getvec)")
                if ((fmt == 310 || fmt == 311) && (n * nsig) % 3 == 2) {
                    // A final group of two samples is written in 4 bytes, so
                    // the file appears to contain an extra (zero) sample.
                    for (s in 0 until nsig) assertEquals(0, y[y.size - nsig + s])
                    y = y.subList(0, y.size - nsig)
                }
                assertEquals(x.toList(), y, "format $fmt, $nsig signals")
                // random access with the per-sample interface
                w.isigopen("rt", null, nsig)
                for (t in listOf(n - 1, 0, n / 2, 3, n - 2)) {
                    for (s in 0 until nsig) assertEquals(x[t * nsig + s], w.sample(s, t.toLong()))
                }
                w.wfdbquit()
            }
        }
    }

    /** getvecs returns exactly what getvec does. */
    @Test
    fun getvecsEqualsGetvec() = withData("getvecs") { _, w ->
        w.wfdbquiet()
        for (rec in listOf(
            "fmt212", "fmt310", "fmt311", "fmt8", "twog", "100s", "skew", "mfreq", "multi", "vlay",
            "fmt212b", "fmt310b", "fmt311b", "fmtblk", "prolog", "fms", "null", "flac16", "flacmf",
        )) {
            val reference = readAll(w, rec).first
            for (chunk in listOf(1, 7, 1000, 100000)) assertEquals(reference, readAllBulk(w, rec, chunk), "$rec $chunk")
            w.wfdbx_bulk_read(false)
            assertEquals(reference, readAllBulk(w, rec), rec)
            w.wfdbx_bulk_read(true)
        }
        w.wfdbverbose()
    }

    /** A signal file shorter than its header says: getvec returns -3 (unexpected EOF), getvecs the frames read. */
    @Test
    fun truncatedSignalFile() = withData("truncated") { d, w ->
        w.wfdbquiet()
        val x = intArrayOf(1, 2, 3, 4, 5, 6, 7, 8)
        writeRec(w, "tr", x, 2, 100.0)
        writeRec(w, "ok", x, 2, 100.0)
        // 2 of the 4 frames (format 16)
        writeFile(d.path("tr.dat"), d.read("tr.dat")!!.copyOf(8))
        val si = Array(2) { Siginfo() }
        assertEquals(2, w.isigopen("tr", si, 2))
        val v = IntArray(2)
        assertEquals(2, w.getvec(v))
        assertEquals(2, w.getvec(v))
        assertEquals(-3, w.getvec(v))
        w.wfdbquit()
        val buf = IntArray(20)
        assertEquals(2, w.isigopen("tr", si, 2))
        assertEquals(GetvecsResult(2, -3), w.getvecs_status(buf, 10))
        w.wfdbquit()
        assertEquals(2, w.isigopen("tr", si, 2))
        assertEquals(2L, w.getvecs(buf, 10))
        w.wfdbquit()
        assertEquals(2, w.isigopen("ok", si, 2))
        assertEquals(GetvecsResult(4, -1), w.getvecs_status(buf, 10))
        assertEquals(x.toList(), buf.copyOf(8).toList())
        w.wfdbquit()
        assertEquals(2, w.isigopen("ok", si, 2))
        // a first read that fails gives its status
        w.isigsettime(4)
        assertEquals(GetvecsResult(-1, -1), w.getvecs_status(buf, 10))
        assertEquals(GetvecsResult(0, 0), w.getvecs_status(buf, 0))
        w.wfdbquit()
        w.wfdbverbose()
    }

    /** The default instance (top-level functions). */
    @Test
    fun defaultInstanceFunctions() {
        val d = DataDir("default")
        run {
            val prev = wfdbx_set_input_dir(d.dir)
            assertEquals(2, isigopen("100s", null, 0))
            assertEquals(21600L, strtim("e"))
            val v = IntArray(2)
            assertEquals(2, isigopen("100s", null, 2))
            assertEquals(2, getvec(v))
            assertEquals(listOf(995, 1011), v.toList())
            val buf = IntArray(2 * 30000)
            assertEquals(21599L, getvecs(buf, 30000))
            assertEquals(360.0, sampfreq(null))
            assertEquals("    1:00", str(timstr(21600)))
            wfdbquit()
            wfdbx_set_input_dir(prev)
        }
        d.remove()
    }

    /**
     * After a failed seek (past the end of a FLAC stream), libFLAC aborts the
     * decoding of the next block in the C library: getvec fails, and so do
     * later seeks; a seek to the current time is not performed.
     */
    @Test
    fun flacFailedSeek() = withData("flacseek") { _, w ->
        w.wfdbquiet()
        assertEquals(3, isig(w, "flac16"))
        assertEquals(-1, w.isigsettime(99999))
        assertEquals(listOf(-3, 0, 0, 0), vec(w, 3))
        assertEquals(-1, w.isigsettime(0))
        assertEquals(listOf(-3, 0, 0, 0), vec(w, 3))
        w.wfdbquit()
        isig(w, "flac16")
        assertEquals(-1, w.isigsettime(99999))
        assertEquals(0, w.isigsettime(5))
        assertEquals(listOf(3, -77, -57, -47), vec(w, 3))
        w.wfdbquit()
        isig(w, "flac16")
        assertEquals(listOf(3, -31, -38, -33), vec(w, 3))
        assertEquals(-1, w.isigsettime(9001))
        assertEquals(0, w.isigsettime(1))
        assertEquals(listOf(-3, 0, 0, 0), vec(w, 3))
        w.wfdbverbose()
    }

    @Test
    fun flacRecords() = withData("flacrec") { _, w ->
        // multi-frequency FLAC record, and EDF input
        assertEquals(2, isig(w, "flacmf"))
        val v = IntArray(8)
        assertEquals(2, w.getframe(v))
        w.wfdbquit()
        val (a, stat) = readAll(w, "flac8")
        assertEquals(-1, stat)
        assertEquals(2 * 5000, a.size)
        assertEquals(listOf(-31, -42, -13), listOf(a[0], a[2], a[4]))
        assertEquals(-86, a[a.size - 1])
    }

    // -----------------------------------------------------------------------
    // EDF input

    @Test
    fun edfInput() = withData("edf") { _, w ->
        // 100s.edf holds the samples of 100s (EDF has no checksums).
        val n = w.isigopen("100s.edf", null, 0)
        assertEquals(2, n)
        val si = Array(2) { Siginfo() }
        assertEquals(2, w.isigopen("100s.edf", si, 2))
        assertEquals(360.0, w.sampfreq(null))
        assertEquals(1, w.getgvmode() and WFDB_HIGHRES)
        assertEquals(16, si[0].fmt)
        assertEquals("100s.edf", str(si[0].fname))
        val v = IntArray(2)
        assertEquals(2, w.getvec(v))
        assertEquals("[04:39:57 15/10/2026]", str(w.timstr(0)))
        assertEquals(listOf(995, 1011), v.toList())
        assertNull(w.getinfo(null as ByteArray?))
        w.wfdbquit()
        w.setgvmode(0)
        val e = readAll(w, "100s.edf").first
        w.setgvmode(0)
        assertEquals(2 * 25200, e.size) // (7 EDF blocks of 3600 samples; the last one is padding)
        assertEquals(listOf(995, 1011), e.subList(0, 2))
        assertEquals(listOf(-32768, -32768), e.subList(e.size - 2, e.size))
        w.wfdbquiet()
        assertEquals(-2, w.isigopen("100s.atr", null, 0)) // not EDF
        assertEquals("init: '${w.wfdb_filename().latin1()}' is not EDF or EDF+\n", str(w.wfdberror()))
        w.wfdbverbose()
    }

    // -----------------------------------------------------------------------
    // wfdb-x: no default sampling frequency, gain, ADC resolution or units
    // (t_nodefaults in tests/reference/api_expect.c; see docs/DIVERGENCES.md)

    /** A header without a sampling frequency (as written by t_nodefaults). */
    private fun writeNf(d: DataDir) = writeFile(
        d.path("nf.hea"),
        "nf 2\n100s.dat 212 200 11 1024 995 21537 0 MLII\n100s.dat 212 200 11 1024 1011 -3962 0 V5\n",
    )

    /** A header without ADC resolutions or units (as written by t_nodefaults). */
    private fun writeNr(d: DataDir) = writeFile(d.path("nr.hea"), "nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n")

    @Test
    fun nodefaultsTimeNeedsFreq() = withData("needsfreq") { _, w ->
        // (the counter frequency is defined when the C test runs, since it
        // survives wfdbquit after t_counter)
        w.setcfreq(10.0)
        for ((s, x) in listOf(
            "s10" to 0, "e" to 0, "i" to 0, "o" to 0, "c10" to 1, "f3" to 1, "10" to 1, "1:0" to 1,
            "[10:00:00]" to 1, " s5" to 0, "" to 1,
        )) {
            assertEquals(x, w.wfdbx_time_needs_freq(s), s)
        }
        // "c" needs a frequency only while the counter frequency is defined
        w.setcfreq(0.0)
        assertEquals(0, w.wfdbx_time_needs_freq("c10"))
        assertEquals(1, wfdbx_time_needs_freq("1:0"))
    }

    @Test
    fun nodefaultsLibrary() = withData("nodefaults") { d, w ->
        w.wfdbquiet()
        // no input record: no sampling frequency
        assertEquals(0L, w.strtim("1:0"))
        assertEquals("strtim: sampling frequency is not specified\n", str(w.wfdberror()))
        assertEquals(10L, w.strtim("s10"))
        assertEquals("s360", str(w.timstr(360)))
        assertEquals("timstr: sampling frequency is not specified\n", str(w.wfdberror()))
        assertEquals("s360", str(w.mstimstr(-360)))
        assertEquals("mstimstr: sampling frequency is not specified\n", str(w.wfdberror()))
        // a header without a sampling frequency
        writeNf(d)
        assertEquals(2, isig(w, "nf"))
        assertEquals(0.0, w.sampfreq(null))
        assertEquals(0.0, w.getifreq())
        assertEquals(-1, w.setifreq(100.0))
        assertEquals("setifreq: sampling frequency is not specified\n", str(w.wfdberror()))
        assertEquals(0L, w.strtim("2"))
        assertEquals(0L, w.strtim("e"))
        assertEquals("s100", str(w.mstimstr(100)))
        w.wfdbquit()
        // a frequency set by the caller applies
        assertEquals(0, w.setsampfreq(500.0))
        assertEquals(2, isig(w, "nf"))
        assertEquals(500.0, w.sampfreq(null))
        assertEquals(1000L, w.strtim("2"))
        assertEquals("    0:00.200", str(w.mstimstr(100)))
        w.wfdbquit()
        assertEquals(0.0, w.sampfreq("nf"))
        w.wfdbquit()
        // uncalibrated signals (record null) and invalid signal numbers
        isig(w, "null")
        assertTrue(w.aduphys(0, 100).isNaN())
        assertEquals("aduphys: signal 0 is uncalibrated\n", str(w.wfdberror()))
        assertEquals(-32768, w.physadu(0, 1.0))
        assertEquals("physadu: signal 0 is uncalibrated\n", str(w.wfdberror()))
        assertEquals(-32768, w.adumuv(1, 100))
        assertEquals(-32768, w.muvadu(1, 100))
        assertEquals("muvadu: signal 1 is uncalibrated\n", str(w.wfdberror()))
        w.wfdbquit()
        isig(w, "100s")
        assertEquals(0.5, w.aduphys(0, 1124))
        assertEquals(924, w.physadu(1, -0.5))
        assertEquals(500, w.adumuv(0, 100))
        assertEquals(200, w.muvadu(0, 1000))
        assertTrue(w.aduphys(5, 100).isNaN())
        assertEquals("aduphys: invalid signal number 5\n", str(w.wfdberror()))
        assertEquals(-32768, w.physadu(5, 1.0))
        assertEquals(-32768, w.adumuv(2, 100))
        assertEquals(-32768, w.muvadu(2, 100))
        assertEquals("muvadu: invalid signal number 2\n", str(w.wfdberror()))
        w.wfdbquit()
        // no default ADC resolution (0) or units (null)
        writeNr(d)
        val si = Array(8) { Siginfo() }
        assertEquals(2, w.isigopen("nr", si, 8))
        assertEquals(listOf(0, 0), listOf(si[0].adcres, si[1].adcres))
        assertNull(si[0].units)
        w.wfdbquit()
        w.isigopen("100s", si, 8)
        assertEquals(listOf(11, 11), listOf(si[0].adcres, si[1].adcres))
        w.wfdbquit()
        w.wfdbverbose()
    }

    // -----------------------------------------------------------------------
    // wfdb-x: legacy mode, the behavior of the original package (t_legacy in
    // tests/reference/api_expect.c; see docs/DIVERGENCES.md)

    private fun approx(x: Double, y: Double) = kotlin.math.abs(x - y) < 1e-12

    @Test
    fun legacyLibrary() = withData("legacy") { d, w ->
        assertEquals(0, w.wfdbx_get_legacy()) // off by default
        assertEquals(0, w.wfdbx_set_legacy(1))
        assertEquals(1, w.wfdbx_get_legacy())
        w.setwfdb(d.dir) // (legacy mode: the WFDB path)
        // amplitude conversion (gain 200, baseline 1024; invalid signal
        // numbers: gain 200, baseline 0)
        isig(w, "100s")
        assertEquals(listOf(1000, -185, 5, -5, 500), listOf(w.adumuv(0, 200), w.adumuv(0, -37), w.adumuv(1, 1), w.adumuv(0, -1), w.adumuv(7, 100)))
        assertEquals(listOf(200, -67, 0, 200), listOf(w.muvadu(0, 1000), w.muvadu(0, -333), w.muvadu(1, 2), w.muvadu(9, 1000)))
        assertTrue(approx(w.aduphys(0, 1224), 1.0))
        assertTrue(approx(w.aduphys(1, 900), -0.62))
        assertTrue(approx(w.aduphys(5, 300), 1.5))
        assertEquals(listOf(1224, 924, 300), listOf(w.physadu(0, 1.0), w.physadu(1, -0.5023), w.physadu(5, 1.5)))
        assertTrue(approx(w.aduphys(5, 100), 0.5))
        assertEquals(200, w.physadu(5, 1.0))
        assertEquals(500, w.adumuv(2, 100))
        assertEquals(20, w.muvadu(2, 100))
        w.wfdbquit()
        w.setwfdb(d.dir)
        // uncalibrated signals (record null): gain 200
        isig(w, "null")
        assertEquals(listOf(500, 20), listOf(w.adumuv(0, 100), w.muvadu(1, 100)))
        assertTrue(approx(w.aduphys(0, 100), 0.5))
        assertEquals(100, w.physadu(1, 0.5))
        assertEquals(200, w.physadu(0, 1.0))
        w.wfdbquit()
        w.setwfdb(d.dir)
        w.wfdbquiet()
        // no input record: 1 sample per second
        assertEquals(60L, w.strtim("1:0"))
        assertEquals(10L, w.strtim("s10"))
        assertEquals("    6:00", str(w.timstr(360)))
        assertEquals("    6:00.000", str(w.mstimstr(-360)))
        // a header without a sampling frequency: 250 Hz
        writeNf(d)
        assertEquals(2, isig(w, "nf"))
        assertEquals(250.0, w.sampfreq(null))
        assertEquals(250.0, w.getifreq())
        assertEquals(500L, w.strtim("2"))
        assertEquals(0L, w.strtim("e"))
        assertEquals("    0:00.400", str(w.mstimstr(100)))
        assertEquals(0, w.setifreq(100.0))
        assertEquals(100.0, w.getifreq())
        w.wfdbquit()
        w.setwfdb(d.dir)
        assertEquals(250.0, w.sampfreq("nf"))
        w.wfdbquit()
        w.setwfdb(d.dir)
        // setifreq with an input record but no frequency
        isig(w, "100s")
        w.setsampfreq(0.0)
        assertEquals(-1, w.setifreq(100.0))
        assertEquals("setifreq: no open input record\n", str(w.wfdberror()))
        w.wfdbquit()
        w.setwfdb(d.dir)
        // ADC resolution inferred from the format, or WFDB_DEFRES
        writeNr(d)
        val si = Array(8) { Siginfo() }
        assertEquals(2, w.isigopen("nr", si, 8))
        assertEquals(listOf(12, 12), listOf(si[0].adcres, si[1].adcres))
        w.wfdbquit()
        w.setwfdb(d.dir)
        writeFile(d.path("nr3.hea"), "nr3 5 360 10\nfmt16.dat 16\nfmt80.dat 80\nfmt310.dat 310\nfmt160.dat 160\nfmt24.dat 24\n")
        assertEquals(5, w.isigopen("nr3", si, 8))
        assertEquals(listOf(12, 8, 10, 16, 12), si.take(5).map { it.adcres })
        w.wfdbquit()
        w.wfdbverbose()
        assertEquals(1, w.wfdbx_set_legacy(0))
        assertEquals(0, w.wfdbx_get_legacy())
    }

    // -----------------------------------------------------------------------
    // wfdb-x: getvec's checksum error; an output signal file is never one of
    // the input files

    @Test
    fun checksumError() = withData("cksum") { d, w ->
        w.wfdbquiet()
        writeRec(w, "ck", intArrayOf(1, 2, 3, 4, 5, 6, 7, 8), 2, 100.0)
        // change one sample: the checksum in the header no longer matches
        val dat = d.read("ck.dat")!!
        dat[4] = 30
        writeFile(d.path("ck.dat"), dat)
        // the C-style API: getvec stops at the checksum frame
        val si = Array(2) { Siginfo() }
        assertEquals(2, w.isigopen("ck", si, 2))
        val v = IntArray(2)
        assertEquals(listOf(2, 2, 2, -4), (0 until 4).map { w.getvec(v) })
        assertEquals(listOf(7, 8), v.toList())
        assertEquals("getvec: checksum error in signal 0\n", str(w.wfdberror()))
        w.wfdbquit()
        // getvecs: the same, with the frame of the -4 status stored
        assertEquals(2, w.isigopen("ck", si, 2))
        val buf = IntArray(20)
        assertEquals(GetvecsResult(3, -4), w.getvecs_status(buf, 10))
        assertEquals(listOf(1, 2, 30, 4, 5, 6, 7, 8), buf.copyOf(8).toList())
        w.wfdbquit()
        // wfdb-x (for the high-level read): the message recorded, not printed
        assertEquals(2, w.isigopen("ck", si, 2))
        w.wfdbverbose()
        val p = w.wfdbxSetCksumQuiet(true)
        assertEquals(GetvecsResult(3, -4), w.getvecs_status(buf, 10))
        w.wfdbxSetCksumQuiet(p)
        assertEquals("getvec: checksum error in signal 0\n", str(w.wfdberror()))
        // (header checksum 1 + 3 + 5 + 7, samples read 1 + 30 + 5 + 7)
        assertEquals(listOf(-27, 0), w.wfdbxCksumResiduals().toList())
        w.wfdbquit()
    }

    private fun outSpec(fname: String) = arrayOf(Siginfo(fname = fname.latin1(), desc = "x".latin1(), fmt = 16, gain = 200.0, adcres = 16))

    @Test
    fun outputFileIsInputFile() = withData("outin") { d, w ->
        w.wfdbquiet()
        val si = Array(3) { Siginfo() }
        val v = IntArray(3)
        for (name in listOf("fmt16.dat", "./fmt16.dat")) {
            assertEquals(3, w.isigopen("fmt16", si, 3))
            assertEquals(-3, w.osigfopen(outSpec(name), 1), name)
            assertEquals("osigfopen: output file $name is also an input file\n", str(w.wfdberror()))
            assertEquals(3, w.getvec(v)) // the input is intact
            assertEquals(9000, d.read("fmt16.dat")!!.size)
            w.wfdbquit()
        }
        // osigopen: the same check, with its name
        assertEquals(3, w.isigopen("fmt16", si, 3))
        val so = Array(3) { Siginfo() }
        assertEquals(-3, w.osigopen("fmt16", so, 3))
        assertEquals("osigopen: output file fmt16.dat is also an input file\n", str(w.wfdberror()))
        w.wfdbquit()
        // another file: written
        assertEquals(3, w.isigopen("fmt16", si, 3))
        assertEquals(1, w.osigfopen(outSpec("new16.dat"), 1))
        w.wfdbquit()
        // a segment of a multi-segment record not open yet
        writeFile(d.path("ms2.hea"), "ms2/2 2 360 23400\nnull 1800\n100s 21600\n")
        val s2 = Array(2) { Siginfo() }
        assertEquals(2, w.isigopen("ms2", s2, 2))
        assertEquals(-3, w.osigfopen(outSpec("100s.dat"), 1))
        assertEquals(64800, d.read("100s.dat")!!.size)
        assertEquals(1, w.osigfopen(outSpec("other.dat"), 1))
        w.wfdbquit()
        // legacy mode: the original behavior (the input is truncated)
        w.wfdbx_set_legacy(1)
        w.setwfdb(d.dir)
        assertEquals(3, w.isigopen("fmt16", si, 3))
        assertEquals(1, w.osigfopen(outSpec("fmt16.dat"), 1))
        w.wfdbquit()
        w.wfdbx_set_legacy(0)
        assertEquals(0, d.read("fmt16.dat")!!.size)
    }

    // -----------------------------------------------------------------------
    // wfdb-x: record names with directories (only the last component is
    // checked when writing; the header names files relative to its
    // directory)

    @Test
    fun dottedDirectory() = withData("dotted") { d, w ->
        w.wfdbquiet()
        val x = IntArray(10) { it }
        for (name in listOf("my.data/rec", "${d.dir}/a.b/c.d/rec")) {
            val si = spec("$name.dat", 1, 16, 100.0)
            writeRec(w, name, x, 1, 100.0, 16, si)
            val hea = readFile("${if (name.startsWith("/")) "" else d.dir + "/"}$name.hea")!!
            assertTrue(hea.startsWith("rec 1 100 10\r\nrec.dat 16 "), name)
            assertEquals(x.toList(), readAll(w, name).first, name)
        }
        // newheader with a record name containing a directory
        val si = arrayOf(
            Siginfo(fname = "my.data/nh.dat".latin1(), desc = "x".latin1(), units = "mV".latin1(), gain = 100.0, fmt = 16, adcres = 16),
        )
        assertEquals(1, w.osigfopen(si, 1))
        w.setsampfreq(100.0)
        assertTrue(w.putvec(intArrayOf(5)) > 0)
        assertEquals(0, w.newheader("my.data/nh"))
        w.wfdbquit()
        assertTrue(d.read("my.data/nh.hea")!!.startsWith("nh 1 100 1\r\nnh.dat 16 "))
        assertEquals(listOf(5), readAll(w, "my.data/nh").first)
        // setheader's siarray is not changed
        assertEquals(0, w.setheader("my.data/nh", si, 1))
        w.wfdbquit()
        assertEquals("my.data/nh.dat", str(si[0].fname))
        // the last component must be a valid record name
        assertEquals(-1, w.newheader("rec.1"))
        assertEquals("init: illegal character 46 in record name\n", str(w.wfdberror()))
        // legacy mode: the whole name is checked, and names are written as
        // given
        w.wfdbx_set_legacy(1)
        assertEquals(-1, w.newheader("my.data/rec2"))
        assertEquals("init: illegal character 46 in record name\n", str(w.wfdberror()))
        writeRec(w, "out/rec", x, 1, 100.0, 16, spec("out/rec.dat", 1, 16, 100.0))
        assertTrue(d.read("out/rec.hea")!!.startsWith("out/rec 1 100 10\r\nout/rec.dat 16 "))
        w.wfdbx_set_legacy(0)
    }

    @Test
    fun readHeaderErrors() = withData("hdrerrors") { d, w ->
        w.wfdbquiet()
        val cases = listOf(
            "" to "init: record bad header is empty\n",
            "# only a comment\n" to "init: can't find record name in record bad header\n",
            "other 1 100\n" to "init: record name in record bad header is incorrect\n",
            "bad\n" to "init: obsolete format in record bad header\n",
            "bad 1 -5\n" to "init: sampling frequency in record bad header is incorrect\n",
            "bad 1 100 -3\n" to "init: number of samples in record bad header is incorrect\n",
            "bad 1 100 10\n" to "init: unexpected EOF in header file for record bad\n",
            "bad 1 100 10\nbad.dat 17\n" to "init: illegal format for signal 0, record bad\n",
            "bad 2 100 10\nbad.dat 16\nbad.dat 212\n" to "init: error in specification of signal 0 or 1\n",
            "bad/2 1 100 10\nx 5\n" to "init: unexpected EOF in header file for record bad\n",
            "bad/1 1 100 10\nx\n" to "init: length must be specified for segment x in record bad\n",
            "bad/1 1 100 10\n+x 5\n" to "init: `+x' is not a valid segment name in record bad\n",
            "#wfdb 11.0\nbad 1\n" to "init: reading record bad requires WFDB library version 11.0.0 or later\n" +
                "  (the most recent version is always available from http://physionet.org)\n",
        )
        for ((text, msg) in cases) {
            writeFile(d.path("bad.hea"), text)
            assertTrue(w.isigopen("bad", null, 0) < 0, text)
            assertEquals(msg, str(w.wfdberror()), text)
        }
        // a header line with every field
        writeFile(d.path("all.hea"), "all 1 100/1000(5) 10 10:00:00 01/01/2000\nall.dat 16x2:4+6 200(3)/mV 12 1 2 3 0 desc  x\n")
        val si = arrayOf(Siginfo())
        assertEquals(1, w.isigopen("all", si, 0 - 1))
        val s = si[0]
        assertEquals(listOf(16, 2, 12, 1, 2, 3, 0, 3), listOf(s.fmt, s.spf, s.adcres, s.adczero, s.initval, s.cksum, s.bsize, s.baseline))
        assertEquals(200.0, s.gain)
        assertEquals("mV", str(s.units))
        assertEquals("desc  x", str(s.desc))
        assertEquals(10L, s.nsamp)
        assertEquals(1000.0, w.getcfreq())
        assertEquals(5.0, w.getbasecount())
        assertEquals(6L, w.wfdbgetstart(0))
        assertEquals("[10:00:00 01/01/2000]", str(w.timstr(0)))
    }
}
