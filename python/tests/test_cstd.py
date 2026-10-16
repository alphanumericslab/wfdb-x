"""Tests of the C library emulation used by wfdb-x.

Part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

from wfdbx._cstd import (strtol, strtod, sscanf, Strtok, cdiv, cmod, int16,
                         GlibcRand, cfmt_float, fgets_lines, d2i, d2l,
                         INT_MIN, LONG_MIN)


def test_strtol():
    assert strtol("  -12abc") == (-12, 5)
    assert strtol("abc") == (0, 0)
    assert strtol("0x1f", 16) == (31, 4)
    assert strtol("99999999999999999999")[0] == 0x7FFFFFFFFFFFFFFF


def test_strtod():
    assert strtod("1.5e2x") == (150.0, 5)
    assert strtod(" .25") == (0.25, 4)
    assert strtod("x") == (0.0, 0)
    assert strtod("0x10")[0] == 16.0


def test_sscanf():
    assert sscanf("", "%lf") == (-1, [])
    assert sscanf("x", "%lf") == (0, [])
    assert sscanf("12 N 1 2 3", "%lld%s%d%d%d") == (5, [12, "N", 1, 2, 3])
    assert sscanf("01.02.85", "%d%*c%d%*c%d") == (3, [1, 2, 85])


def test_strtok():
    t = Strtok("  a  b\tc\r\n")
    assert [t.next(" \t\r\n") for _ in range(4)] == ["a", "b", "c", None]
    t = Strtok("x 0 MLII lead\r\n")
    t.next(" ")
    t.next(" ")
    assert t.next("\r\n") == "MLII lead"


def test_integer_arithmetic():
    assert cdiv(-7, 2) == -3 and cmod(-7, 2) == -1
    assert int16(0x8000) == -32768


def test_glibc_rand():
    r = GlibcRand(0)
    assert [r.rand() for _ in range(3)] == [1804289383, 846930886,
                                            1681692777]


def test_printf_nan():
    assert cfmt_float("%g", -float("nan")) == "-nan"
    assert cfmt_float("%7.3f", 1.0) == "  1.000"


def test_fgets():
    assert list(fgets_lines(b"abc\ndefgh", 4)) == ["abc", "\n", "def", "gh"]


def test_double_to_integer():
    # x86-64 conversions: truncation, and the most negative value for NaN
    # and out-of-range values.
    assert d2i(-2.7) == -2 and d2i(2147483647.9) == 2147483647
    assert d2i(2147483648.0) == INT_MIN and d2i(float("nan")) == INT_MIN
    assert d2i(-2147483648.9) == -2147483648
    assert d2l(-1e18) == -10 ** 18 and d2l(9.3e18) == LONG_MIN
    assert d2l(-9.3e18) == LONG_MIN and d2l(float("inf")) == LONG_MIN
