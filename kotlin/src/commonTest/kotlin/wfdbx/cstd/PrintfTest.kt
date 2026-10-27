// Tests of the printf emulation (ports of rust/tests/cstd.rs). Expected
// values were produced by glibc on x86-64 Linux.
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

package wfdbx.cstd

import kotlin.test.Test
import kotlin.test.assertContentEquals
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PrintfTest {
    private fun s(v: ByteArray) = v.latin1()

    @Test
    fun integers() {
        assertEquals("42", s(cformat("%d", 42)))
        assertEquals("-7", s(cformat("%d", -7)))
        assertEquals("   42|-42  |-0042", s(cformat("%5d|%-5d|%05d", 42, -42, -42)))
        assertEquals("+5  5 +0", s(cformat("%+d % d %+d", 5, 5, 0)))
        assertEquals("-005|     007", s(cformat("%.3d|%8.3d", -5, 7)))
        assertEquals("1152921504606846976 -3 123456789012", s(cformat("%ld %lld %li", 1L shl 60, -3L, 123456789012L)))
        assertEquals("4294967295 7", s(cformat("%u %u", -1, 7)))
        assertEquals("18446744073709551615", s(cformat("%lu", -1L)))
        assertEquals("ff FF 0xff 10 010", s(cformat("%x %X %#x %o %#o", 255, 255, 255, 8, 8)))
        assertEquals("ffffffff fffffffe", s(cformat("%x %08x", -1, -2)))
        assertEquals("4464 65535 -56", s(cformat("%hd %hu %hhd", 70000, -1, 200)))
        assertEquals("AbA", s(cformat("%c%c%c", 65, 'b'.code.toByte(), 321)))
        assertEquals("[  x|y  ]", s(cformat("[%3c|%-3c]", 'x', 'y')))
        assertEquals("9223372036854775808", s(cformat("%llu", 1UL shl 63)))
        assertEquals("[][0][0][5][5]", s(cformat("[%.0d][%#.0o][%#x][%+u][% x]", 0, 0, 0, 5, 5)))
        // A long printed with %d: the low 32 bits (as C on x86-64).
        assertEquals("1", s(cformat("%d", 4294967297L)))
        // Doubles given to integer conversions (as the MATLAB port).
        assertEquals("2 -2 -2147483648", s(cformat("%d %d %d", 2.7, -2.7, Double.NaN)))
        assertEquals("-9223372036854775808", s(cformat("%ld", Long.MIN_VALUE)))
    }

    @Test
    fun strings() {
        assertEquals("abc|       abc|abc       |ab|    a", s(cformat("%s|%10s|%-10s|%.2s|%5.1s", "abc", "abc", "abc", "abc", "abc")))
        assertEquals("[]", s(cformat("[%s]", "")))
        assertEquals("(null)", s(cformat("%s", null)))
        assertEquals("[]", s(cformat("[%.3s]", null)))
        assertEquals("[   ab]", s(cformat("[%05s]", "ab")))
        assertEquals("100% 5%", s(cformat("100%% %d%%", 5)))
        assertEquals("99.50%\tx\n", s(cformat("%5.2f%%\t%s\n", 99.5, "x")))
        assertEquals("no conversions", s(cformat("no conversions")))
        assertEquals("", s(cformat("")))
        assertEquals("[%y][%]", s(cformat("[%y][%5%]")))
        // Byte strings that are not UTF-8 pass through.
        assertContentEquals(byteArrayOf(0xe9.toByte(), 0xff.toByte()), cformat("%s", byteArrayOf(0xe9.toByte(), 0xff.toByte())))
        // A C string ends at its first NUL.
        assertEquals("ab|", s(cformat("%s|", "ab\u0000cd".latin1())))
    }

    @Test
    fun floats() {
        val cases = listOf(
            Triple("0.0001 1e-05 123456 1.23457e+06 -0", "%g %g %g %g %g", listOf(0.0001, 0.00001, 123456.0, 1234567.0, -0.0)),
            Triple("100000 1e+15 0.3", "%g %g %g", listOf(100000.0, 1e15, 0.1 + 0.2)),
            Triple("0.1 0.333333333333333 0.10000000000000001", "%.12g %.15g %.17g", listOf(0.1, 1.0 / 3.0, 0.1)),
            Triple("1.00000 2.00 1E-10", "%#g %#.3g %G", listOf(1.0, 2.0, 1e-10)),
            Triple("1.500000 0 2 2 0.1", "%f %.0f %.0f %.0f %.1f", listOf(1.5, 0.5, 1.5, 2.5, 0.05)),
            Triple("2.001 1.00    -3.1416 2.50      |", "%.3f %.2f %10.4f %-10.2f|", listOf(2.0005, 1.005, -3.14159, 2.5)),
            Triple("1.234568e+04 1.23e-04 1.000000E+100 2e+10", "%e %.2e %E %.0e", listOf(12345.678, 0.000123456, 1e100, 2.5e10)),
            Triple("+1.000  1.000 -001.500", "%+.3f % .3f %08.3f", listOf(1.0, 1.0, -1.5)),
            Triple("360 0.002777777778", "%.10g %.10g", listOf(360.0, 1.0 / 360.0)),
            Triple("1.235 -0.000000", "%.3lf %lf", listOf(1.23456, -0.0)),
            Triple("4.940656e-324 1.79769e+308", "%e %g", listOf(5e-324, 1.7976931348623157e308)),
            Triple(
                "inf -inf   inf| +inf INF NAN      inf INF", "%f %f %5.2f| %+g %E %G %08.3f %F",
                listOf(
                    Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.POSITIVE_INFINITY, Double.POSITIVE_INFINITY,
                    Double.POSITIVE_INFINITY, Double.fromBits(0x7ff8000000000000L), Double.POSITIVE_INFINITY, Double.POSITIVE_INFINITY,
                ),
            ),
            Triple("1.500000", "%F", listOf(1.5)),
            // glibc quirk: '#' with a rounding carry from fixed to exponential.
            Triple(
                "1.e+06 1.e+02 1.0e+06 10. 0.0001 0.00010", "%#g %#.2g %#.2g %#.2g %#.1g %#.2g",
                listOf(999999.5, 99.5, 999999.5, 9.9999995, 0.0000999995, 0.0000999995),
            ),
            Triple("-0.0 0 1e+01", "%.1f %.0f %.1g", listOf(-0.04, 0.5, 9.5)),
        )
        for ((want, fmt, vals) in cases) assertEquals(want, s(sprintf(fmt, *vals.toTypedArray())), "format $fmt")
        val nan = Double.fromBits(0x7ff8000000000000L)
        val negNan = Double.fromBits(-0x8000000000000L) // 0xfff8000000000000: x86's 0.0/0.0
        assertEquals("nan", s(cformat("%g", nan)))
        assertEquals("-nan", s(cformat("%g", negNan)))
        assertEquals(" nan|-inf  |", s(cformat("% g|%-6g|", nan, Double.NEGATIVE_INFINITY)))
        // 1e300 printed exactly.
        val big = s(cformat("%f", 1e300))
        assertTrue(big.startsWith("1000000000000000052504760255204420248704468581108159154915854115511802457988908195786371375080447864043704443832883878176942523235360430575644792184786706982848387200926575803737830233794788090059368953234970799945081119038967640880074652742780142494579258788820056842838115669472196386865459400540160.000000"))
        assertEquals("0.10000000000000000555", s(cformat("%.20f", 0.1)))
        assertEquals("0 2 -2", s(cformat("%.0f %.0f %.0f", 0.5, 1.5, -2.5)))
        assertEquals("1.000e-320", s(cformat("%.3e", 1e-320)))
        assertEquals("2.225073858507201e-308", s(cformat("%.16g", 2.2250738585072014e-308)))
        assertEquals("1e+300", s(cformat("%g", 1e300)))
    }

    @Test
    fun star() {
        assertEquals("    42|42    |3.14|   2.500", s(cformat("%*d|%-*d|%.*f|%*.*f", 6, 42, 6, 42, 2, 3.14159, 8, 3, 2.5)))
        assertEquals("42    |", s(cformat("%*d|", -6, 42)))
        assertEquals("2.500000|", s(cformat("%.*f|", -1, 2.5)))
    }

    @Test
    fun conversions() {
        assertEquals(2, d2i(2.7))
        assertEquals(-2, d2i(-2.7))
        assertEquals(Int.MIN_VALUE, d2i(Double.NaN))
        assertEquals(Int.MIN_VALUE, d2i(3e9))
        assertEquals(-2147483648, d2i(-2147483648.9))
        assertEquals(2147483647, d2i(2147483647.9))
        assertEquals(Long.MIN_VALUE, d2l(1e19))
        assertEquals(-3L, cdiv(-7, 2))
        assertEquals(-1L, cmod(-7, 2))
    }

    /** fixedFast gives the same text as sprintf("%W.Pf") whenever it applies. */
    @Test
    fun fixedFastMatchesSprintf() {
        val g = GlibcRand(7)
        val values = mutableListOf(
            0.0, -0.0, 0.5, -0.5, 1.5, 2.5, 0.125, 0.0005, -0.0004, 1e-300, 5e-324, 123456.789, 1e15, 2e19,
            -2048.0, 4096.0 / 200.0, 0.1, 0.7, 1099511627776.0, 2199023255552.0, 9.2e18, 0.000000001, 0.0000000005,
        )
        repeat(2000) {
            val a = (g.rand() - RAND_MAX / 2).toDouble()
            val b = (g.rand() % 1000 + 1).toDouble()
            values.add(a / b)
        }
        var used = 0
        for (x in values) for (prec in 0..10) for (width in intArrayOf(0, 7, 15)) {
            val buf = ByteVec()
            if (fixedFast(buf, x, width, prec)) {
                used++
                val fmt = "%$width.${prec}f"
                assertEquals(s(cformat(fmt, x)), buf.toString(), "$x $fmt")
            }
        }
        assertTrue(used > 50_000)
    }

    /** The exact conversion against values whose decimal expansions are known. */
    @Test
    fun exactExpansions() {
        assertEquals("0.1000000000000000055511151231257827021181583404541015625", s(cformat("%.55f", 0.1)))
        assertEquals("4.94066e-324", s(cformat("%g", 5e-324)))
        assertEquals("4.9406564584124654e-324", s(cformat("%.16e", 5e-324)))
        assertEquals("1.7976931348623157e+308", s(cformat("%.16e", Double.MAX_VALUE)))
        assertEquals("123456789012345680", s(cformat("%.0f", 123456789012345678.0)))
        assertEquals("0.000123", s(cformat("%g", 0.000123)))
        assertEquals("1.5e-05", s(cformat("%g", 0.000015)))
    }
}
