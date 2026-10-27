// Tests of the C parsing functions and glibc's rand (ports of
// rust/tests/cstd.rs). Expected values were produced by glibc.
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

package wfdbx.cstd

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ParseTest {
    private fun b(s: String) = s.latin1()
    private fun l(r: LongEnd) = Pair(r.value, r.end)
    private fun d(r: DoubleEnd) = Pair(r.value, r.end)

    @Test
    fun strtolCases() {
        assertEquals(Pair(-12L, 5), l(strtol(b("  -12abc"), 10)))
        assertEquals(Pair(0L, 0), l(strtol(b("abc"), 10)))
        assertEquals(Pair(31L, 4), l(strtol(b("0x1f"), 16)))
        assertEquals(Long.MAX_VALUE, strtol(b("99999999999999999999"), 10).value)
        assertEquals(Long.MIN_VALUE, strtol(b("-99999999999999999999"), 10).value)
        assertEquals(Pair(360L, 5), l(strtol(b("x 360 rest"), 10, 1)))
        assertEquals(Pair(15L, 3), l(strtol(b("017"), 0)))
        assertEquals(Pair(0L, 1), l(strtol(b("0x"), 0)))
        assertEquals(Pair(0L, 1), l(strtol(b("0xg"), 16)))
        assertEquals(Pair(0L, 0), l(strtol(b("+"), 10)))
        assertEquals(Pair(12345678901234567L, 17), l(strtol(b("12345678901234567"), 10)))
        assertEquals(Pair(1295L, 2), l(strtol(b("zz"), 36)))
        assertEquals(Pair(-1L, 2), l(strtoul(b("-1"), 10)))
        assertEquals(Pair(-1L, 20), l(strtoul(b("99999999999999999999"), 10)))
        assertEquals(Long.MIN_VALUE, strtol(b("-9223372036854775808"), 10).value)
        assertEquals(42, atoi(b(" 42x")))
        assertEquals(1, atoi(b("4294967297")))
        assertEquals(0, atoi(b("x")))
        assertEquals(-5000000000L, atol(b("-5000000000")))
        assertEquals(Pair(7L, 1), l(strtol(b("7\u00008"), 10)))
    }

    @Test
    fun strtodCases() {
        assertEquals(Pair(150.0, 5), d(strtod(b("1.5e2x"))))
        assertEquals(Pair(0.25, 4), d(strtod(b(" .25"))))
        assertEquals(Pair(0.0, 0), d(strtod(b("x"))))
        assertEquals(16.0, strtod(b("0x10")).value)
        assertEquals(3.0, strtod(b("0x1.8p1")).value)
        assertEquals(Pair(0.0, 1), d(strtod(b("0x"))))
        assertEquals(Pair(1.0, 1), d(strtod(b("1e"))))
        assertEquals(Pair(1.0, 1), d(strtod(b("1e+"))))
        assertEquals(Pair(Double.NEGATIVE_INFINITY, 9), d(strtod(b("-Infinity!"))))
        assertEquals(Pair(Double.POSITIVE_INFINITY, 3), d(strtod(b("inf"))))
        assertEquals(3, strtod(b("infin")).end)
        val r = strtod(b("nan(12)x"))
        assertTrue(r.value.isNaN() && r.end == 7)
        val r2 = strtod(b("-nan("))
        assertTrue(r2.value.isNaN() && (r2.value.toRawBits() < 0) && r2.end == 4)
        assertEquals(Pair(7.0, 4), d(strtod(b("a 7."), 1)))
        assertEquals(0.1, strtod(b("0.1")).value)
        assertEquals(Double.POSITIVE_INFINITY, strtod(b("1e400")).value)
        assertEquals(0.0, strtod(b("1e-400")).value)
        assertEquals(5e-324, strtod(b("2.4703282292062328e-324")).value)
        assertEquals(0.0, strtod(b("2.4703282292062327e-324")).value)
        assertEquals(Double.POSITIVE_INFINITY, strtod(b("1e99999999999999999999999")).value)
        assertEquals(0.0, strtod(b("0x1p-1075")).value)
        assertEquals(5e-324, strtod(b("0x1.0000000000001p-1075")).value)
        assertEquals(Double.POSITIVE_INFINITY, strtod(b("0x1.fffffffffffff8p1023")).value)
        assertEquals(-25.0, atof(b(" -2.5e1q")))
        assertEquals(0.1f, strtof(b("0.1")).value)
        assertEquals(1.0e-3, strtod(b("1.e-3")).value)
    }

    @Test
    fun sscanfCases() {
        val x = CDouble(-1.0)
        assertEquals(-1, sscanf("", "%lf", x))
        assertEquals(-1, sscanf("   ", "%lf", x))
        assertEquals(0, sscanf("x", "%lf", x))
        assertEquals(-1.0, x.v) // untouched
        val a = CLong()
        val bb = CBytes()
        val c = CInt()
        val dd = CInt()
        val e = CInt()
        assertEquals(5, sscanf("12 N 1 2 3", "%lld%s%d%d%d", a, bb, c, dd, e))
        assertEquals(12L, a.v)
        assertEquals("N", bb.v.latin1())
        assertEquals(listOf(1, 2, 3), listOf(c.v, dd.v, e.v))
        val d1 = CInt()
        val m1 = CInt()
        val y1 = CInt()
        assertEquals(3, sscanf("01.02.85", "%d%*c%d%*c%d", d1, m1, y1))
        assertEquals(listOf(1, 2, 85), listOf(d1.v, m1.v, y1.v))
        val v = Array(6) { CInt() }
        assertEquals(6, sscanf("[10:20:30 1/2/2000]", "[%d:%d:%d %d/%d/%d", *v))
        assertEquals(listOf(10, 20, 30, 1, 2, 2000), v.map { it.v })
        val l1 = CLong()
        val l2 = CLong()
        val ch = CChar()
        assertEquals(3, sscanf("1,2,\"Q", "%lld,%lld,\"%c", l1, l2, ch))
        assertEquals(Triple(1L, 2L, 'Q'.code), Triple(l1.v, l2.v, ch.v))
        val s1 = CBytes()
        val s2 = CBytes()
        assertEquals(2, sscanf("abcdef", "%3s%s", s1, s2))
        assertEquals(Pair("abc", "def"), Pair(s1.v.latin1(), s2.v.latin1()))
        val h = CInt()
        val i1 = CInt()
        val i2 = CInt()
        assertEquals(3, sscanf("ff 0x10 017", "%x %i %i", h, i1, i2))
        assertEquals(listOf(255, 16, 15), listOf(h.v, i1.v, i2.v))
        val n1 = CInt()
        val n2 = CInt(77)
        assertEquals(1, sscanf("5", "%d%d", n1, n2))
        assertEquals(77, n2.v)
        assertEquals(-1, sscanf("", "x%d", n1))
        assertEquals(-1, sscanf("12", "%*d%d", n1))
        assertEquals(0, sscanf("12 x", "%*d%d", n1))
        // glibc consumes an incomplete exponent.
        val rest = CBytes()
        assertEquals(2, sscanf("100ergs", "%lf%s", x, rest))
        assertEquals(100.0, x.v)
        assertEquals("rgs", rest.v.latin1())
        assertEquals(1, sscanf("99999999999", "%d", n1))
        assertEquals(1215752191, n1.v)
        val u = CInt()
        assertEquals(1, sscanf("-1", "%u", u))
        assertEquals(-1, u.v) // UINT_MAX
        val z = CInt()
        assertEquals(1, sscanf(" 7", "%d", z))
        assertEquals(7, z.v)
    }

    /** %[...] scan sets: expected results from glibc (sscanf(input, fmt "%n", buf, &n), buf = "?" and n = -1 initially). */
    @Test
    fun sscanfScansets() {
        data class Case(val fmt: String, val input: String, val ret: Int, val buf: String, val n: Int)
        val cases = listOf(
            Case("%[0-9]%n", "123abc", 1, "123", 3),
            Case("%[^0-9]%n", "abc123", 1, "abc", 3),
            Case("%[]abc]%n", "]a]bx", 1, "]a]b", 4),
            Case("%[^]]%n", "abc]def", 1, "abc", 3),
            Case("%[-a]%n", "-a-b", 1, "-a-", 3),
            Case("%[a-]%n", "a--ab", 1, "a--a", 4),
            Case("%[a-c-e]%n", "abcdefg", 1, "abcde", 5),
            Case("%[z-a]%n", "z-ab", 1, "z-a", 3),
            Case("%[^-0-9]%n", "abc-1", 1, "abc", 3),
            Case("%[]-a]%n", "]^_`abc", 1, "]^_`a", 5),
            Case("%[0-9%n", "123", 0, "?", -1),
            Case("%3[0-9]%n", "12345", 1, "123", 3),
            Case("%[^\n]%n", "line one\nx", 1, "line one", 8),
            Case("%[a-a]%n", "aab", 1, "aa", 2),
            Case("%[^]-]%n", "ab]c", 1, "ab", 2),
            Case("%[0-9]%n", "abc", 0, "?", -1),
            Case("%[0-9]%n", "", -1, "?", -1),
            Case("%[]]%n", "]]x", 1, "]]", 2),
            Case("%[^]%n", "abc", 0, "?", -1),
            Case("%[-]%n", "--x", 1, "--", 2),
            Case("%[^-]%n", "ab-c", 1, "ab", 2),
            Case("%[a-z0-9_]%n", "ab_9.x", 1, "ab_9", 4),
            Case("%[A-Fa-f0-9]x%n", "1aFx", 1, "1aF", 4),
            Case("%*[a-c]%[d-f]%n", "abcdef", 1, "def", 6),
            Case("%[0-9", "", 0, "?", -1),
            Case("x%[0-9", "x", 0, "?", -1),
        )
        for (c in cases) {
            val buf = CBytes(b("?"))
            val n = CInt(-1)
            val r = sscanf(c.input, c.fmt, buf, n)
            assertEquals(Triple(c.ret, c.buf, c.n), Triple(r, buf.v.latin1(), n.v), c.fmt)
        }
    }

    @Test
    fun strtokCases() {
        val t = Strtok(b("  a  b\tc\r\n"))
        val d = " \t\r\n"
        assertEquals("a", t.next(d)?.latin1())
        assertEquals("b", t.next(d)?.latin1())
        assertEquals("c", t.next(d)?.latin1())
        assertNull(t.next(d))
        assertNull(t.next(d))
        val t2 = Strtok(b("x 0 MLII lead\r\n"))
        t2.next(" ")
        t2.next(" ")
        assertEquals("MLII lead", t2.next("\r\n")?.latin1())
        val t3 = Strtok(b("abc"))
        assertEquals("abc", t3.next(" ")?.latin1())
        assertNull(t3.next(" "))
        assertNull(Strtok(b("   ")).next(" "))
        val t4 = Strtok(b("a b"))
        t4.next(" ")
        assertEquals("b", t4.rest().latin1())
    }

    @Test
    fun fgetsCases() {
        assertEquals(listOf("abc", "\n", "def", "gh"), fgetsLines(b("abc\ndefgh"), 4).map { it.latin1() })
        assertEquals(listOf("a\n", "bc\n"), fgetsLines(b("a\nbc\n"), 100).map { it.latin1() })
        assertEquals(0, fgetsLines(b(""), 10).size)
        assertEquals(listOf("\n", "\n", "x"), fgetsLines(b("\n\nx"), 10).map { it.latin1() })
    }

    @Test
    fun glibcRand() {
        // Values from glibc (seed: first three values, sum of the first 100000).
        data class Case(val seed: Int, val first: List<Int>, val sum: Long)
        val cases = listOf(
            Case(0, listOf(1804289383, 846930886, 1681692777), 107345864261546L),
            Case(1, listOf(1804289383, 846930886, 1681692777), 107345864261546L),
            Case(42, listOf(71876166, 708592740, 1483128881), 107493762466152L),
            Case(12345, listOf(383100999, 858300821, 357768173), 107265696684802L),
            Case(-1, listOf(254925627, 1205188300, 366127624), 107479458668323L), // 4294967295
            Case(Int.MIN_VALUE, listOf(1336741213, 1210407648, 1447044896), 107447831310714L), // 2147483648
        )
        for (c in cases) {
            val r = GlibcRand(c.seed)
            var total = 0L
            for (i in 0 until 100000) {
                val v = r.rand()
                if (i < 3) assertEquals(c.first[i], v, "seed ${c.seed}")
                total += v
            }
            assertEquals(c.sum, total, "seed ${c.seed}")
        }
        assertEquals(1804289383, GlibcRand().rand())
        srand(42)
        assertEquals(71876166, rand())
        assertEquals(2147483647, RAND_MAX)
    }

    @Test
    fun progNameAndBytes() {
        assertEquals("rdsamp", progName(b("/usr/bin/rdsamp")).latin1())
        assertEquals("rdsamp", progName(b("rdsamp")).latin1())
        assertContentEquals(b("ab"), cstr(b("ab\u0000cd")))
        assertTrue(beq(b("x"), "x"))
    }
}
