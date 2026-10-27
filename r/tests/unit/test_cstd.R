# Tests of the C library emulation (cstd.R): integers, parsing, strtok,
# sscanf, fgets, rand.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It tests wfdb-x; it has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

# integer types
expect_equal(cdiv(-7, 2), -3, "cdiv(-7,2)")
expect_equal(cmod(-7, 2), -1, "cmod(-7,2)")
expect_equal(cdiv(7, -2), -3, "cdiv(7,-2)")
expect_equal(cmod(7, -2), 1, "cmod(7,-2)")
expect_equal(cdiv(c(9, -9), 4), c(2, -2), "cdiv vector")
expect_equal(cint16(32768), -32768, "cint16(0x8000)")
expect_equal(cint16(c(65535, 32767, -32769)), c(-1, 32767, 32767), "cint16")
expect_equal(cuint16(-1), 65535, "cuint16(-1)")
expect_equal(cint32(2147483648), -2147483648, "cint32(2^31)")
expect_equal(cint32(-2147483649), 2147483647, "cint32(-2^31-1)")
expect_equal(cint32(4294967296 + 5), 5, "cint32(2^32+5)")
expect_equal(cuint32(-1), 4294967295, "cuint32(-1)")
expect_equal(cint8(c(128, 255, 127, -129)), c(-128, -1, 127, 127), "cint8")
expect_equal(cuint8(c(-1, 256, 300)), c(255, 0, 44), "cuint8")
expect_equal(d2i(c(2.9, -2.9, NaN, 2147483648, -2147483648.5, -2147483649)),
             c(2, -2, -2147483648, -2147483648, -2147483648, -2147483648), "d2i")
expect_equal(d2i(2147483647.9), 2147483647, "d2i max")

# strtol (1-based positions)
expect_equal(strtol("  -12abc"), c(-12, 6), "strtol -12abc")
expect_equal(strtol("abc"), c(0, 1), "strtol abc")
expect_equal(strtol("0x1f", 16), c(31, 5), "strtol 0x1f")
expect_equal(strtol("99999999999999999999")[1], 2^63, "strtol overflow")
expect_equal(strtol("-99999999999999999999")[1], -2^63, "strtol underflow")
expect_equal(strtol("x 360 rest", 10, 2), c(360, 6), "strtol at pos")
expect_equal(strtol("017", 0), c(15, 4), "strtol base 0 octal")
expect_equal(strtol("0x", 0), c(0, 2), "strtol 0x")
expect_equal(strtol("+", 10), c(0, 1), "strtol sign only")
expect_equal(strtol("12345678901234567", 10), c(12345678901234568, 18), "strtol long")  # (the nearest double)
expect_equal(strtol("zz", 36), c(1295, 3), "strtol base 36")
expect_equal(strtol("100", 10, 1, -2147483648, 99)[1], 99, "strtol clamp")
expect_equal(strtol(as.raw(c(49, 50, 0, 51))), c(12, 3), "strtol stops at NUL")
expect_equal(atoi(" 42x"), 42, "atoi")
expect_equal(atoi("4294967297"), 1, "atoi wraps")
expect_equal(atoi("99999999999999999999"), -1, "atoi LONG_MAX")
expect_equal(atoi("12345678901234567891"), -1, "atoi clamp")
expect_equal(atoi("1234567890123456789"), cint32(2112454933), "atoi big exact")
expect_equal(atoi("x"), 0, "atoi none")
expect_equal(atof(" -2.5e1q"), -25, "atof")

# strtod
expect_equal(strtod("1.5e2x"), c(150, 6), "strtod 1.5e2x")
expect_equal(strtod(" .25"), c(0.25, 5), "strtod .25")
expect_equal(strtod("x"), c(0, 1), "strtod x")
expect_equal(strtod("0x10")[1], 16, "strtod 0x10")
expect_equal(strtod("0x1.8p1")[1], 3, "strtod hex float")
expect_equal(strtod("1e"), c(1, 2), "strtod 1e")
expect_equal(strtod("1e+"), c(1, 2), "strtod 1e+")
expect_equal(strtod("-Infinity!"), c(-Inf, 10), "strtod -Infinity")
expect_equal(strtod("inf"), c(Inf, 4), "strtod inf")
r <- strtod("nan(12)x")
check(is.nan(r[1]) && r[2] == 8, "strtod nan(...)")
check(!.nan_neg(strtod("nan")[1]) && .nan_neg(strtod("-nan")[1]), "strtod nan signs")
expect_equal(strtod("a 7.", 2), c(7, 5), "strtod at pos")
expect_equal(strtod("0.1")[1], 0.1, "strtod 0.1 exact")
expect_equal(strtod("1e400")[1], Inf, "strtod overflow")
expect_equal(strtod("-1e400")[1], -Inf, "strtod -overflow")
expect_equal(strtod("1e-400")[1], 0, "strtod underflow")
expect_equal(strtod("-0")[1], 0, "strtod -0")
check(1 / strtod("-0")[1] == -Inf, "strtod -0 sign")
# (expected values built exactly from integers below 2^53 and powers of 2,
# not from long decimal literals, whose parsing by R is not always
# correctly rounded: the literal 8000.8159627 is 0x1.f40d0e2ee7742p+12)
check(identical(strtod("08000.8159627")[1], 0x1f40d0e2ee7741 * 2^-40), "strtod correctly rounded")
check(identical(strtod("1.7976931348623158e308")[1], (2 - 2^-52) * 2^1023), "strtod DBL_MAX")
expect_equal(strtod("1.7976931348623159e308")[1], Inf, "strtod rounds to inf")
expect_equal(strtod("2.4703282292062327e-324")[1], 0, "strtod half min subnormal")
expect_equal(strtod("2.4703282292062328e-324")[1], 2^-1074, "strtod above half min subnormal")
check(identical(strtod("0x1.00000000000018p0")[1], 1 + 2^-51), "strtod hex rounding")
expect_equal(strtod("0x3p-1076")[1], 2^-1074, "strtod hex subnormal")
expect_equal(strtod("123456789012345678901234567890")[1], 7017705969039166 * 2^44, "strtod 30 digits")

# strtok
t <- strtok_new("  a  b\tc\r\n")
d <- " \t\r\n"
expect_equal(list(strtok_next(t, d), strtok_next(t, d), strtok_next(t, d), strtok_next(t, d)),
             list("a", "b", "c", NULL), "strtok tokens")
t <- strtok_new("x 0 MLII lead\r\n")
strtok_next(t, " ")
strtok_next(t, " ")
expect_equal(strtok_next(t, "\r\n"), "MLII lead", "strtok rest of line")
t <- strtok_new("abc")
expect_equal(strtok_next(t, " "), "abc", "strtok single")
expect_equal(strtok_next(t, " "), NULL, "strtok end")
t <- strtok_new("   ")
expect_equal(strtok_next(t, " "), NULL, "strtok only delimiters")
t <- strtok_new("a b")
strtok_next(t, " ")
expect_equal(strtok_rest(t), "b", "strtok rest")

# sscanf
r <- csscanf("", "%lf")
expect_equal(r$n, -1L, "sscanf empty")
expect_equal(r$v, list(), "sscanf empty values")
expect_equal(csscanf("   ", "%lf")$n, -1L, "sscanf blank")
expect_equal(csscanf("x", "%lf"), list(n = 0L, v = list()), "sscanf x")
expect_equal(csscanf("12 N 1 2 3", "%lld%s%d%d%d"), list(n = 5L, v = list(12, "N", 1, 2, 3)),
             "sscanf values")
expect_equal(csscanf("01.02.85", "%d%*c%d%*c%d"), list(n = 3L, v = list(1, 2, 85)), "sscanf date")
expect_equal(csscanf("12 N", "%lld%s%d%d%d"), list(n = 2L, v = list(12, "N")), "sscanf partial")
expect_equal(csscanf("[10:20:30 1/2/2000]", "[%d:%d:%d %d/%d/%d")$v,
             list(10, 20, 30, 1, 2, 2000), "sscanf literal")
expect_equal(csscanf("1,2,\"Q", "%d,%d,\"%c"), list(n = 3L, v = list(1, 2, "Q")), "sscanf %c")
expect_equal(csscanf("abcdef", "%3s%s"), list(n = 2L, v = list("abc", "def")), "sscanf width")
expect_equal(csscanf("ff 0x10 017", "%x %i %i"), list(n = 3L, v = list(255, 16, 15)), "sscanf hex")
expect_equal(csscanf("1.5 2", "%lf%lf"), list(n = 2L, v = list(1.5, 2)), "sscanf doubles")
expect_equal(csscanf("5", "%d%d")$n, 1L, "sscanf eof after first")
expect_equal(csscanf("", "x%d")$n, -1L, "sscanf eof at literal")
expect_equal(csscanf("4294967297", "%d")$v, list(1), "sscanf %d wraps")
expect_equal(csscanf("70000", "%hd")$v, list(4464), "sscanf %hd")
expect_equal(csscanf("10%", "%d%%")$n, 1L, "sscanf %%")

# fgets
expect_equal(fgets_lines(charToRaw("abc\ndefgh"), 4), c("abc", "\n", "def", "gh"), "fgets_lines")
expect_equal(fgets_lines(charToRaw("a\nbc\n"), 100), c("a\n", "bc\n"), "fgets_lines short")
expect_equal(length(fgets_lines(raw(0), 10)), 0L, "fgets_lines empty")
expect_equal(fgets_lines(charToRaw("\n\nx"), 10), c("\n", "\n", "x"), "fgets_lines blank lines")
expect_equal(fgets_lines(as.raw(c(0x61, 0, 0x62, 10, 0x63)), 10), c("a", "c"), "fgets_lines NUL")
expect_equal(fgets_lines(as.raw(c(0x61, 0, 0x62, 10)), 10, as_raw = TRUE),
             list(as.raw(c(0x61, 0, 0x62, 10))), "fgets_lines raw")
expect_equal(fgets_lines(charToRaw("abcdefg\nhi"), 3), c("ab", "cd", "ef", "g\n", "hi"),
             "fgets_lines long lines")

# glibc rand
g <- glibc_rand_new(0)
expect_equal(c(glibc_rand(g), glibc_rand(g), glibc_rand(g)), c(1804289383, 846930886, 1681692777),
             "rand after srand(0)")
glibc_srand(g, 0)
x <- glibc_rand(g, 1000)
glibc_srand(g, 1)
y <- vapply(1:1000, function(i) glibc_rand(g), 0)
expect_equal(x, y, "vectorized rand = scalar rand; srand(0) = srand(1)")
expect_equal(glibc_rand(glibc_rand_new(42), 2), c(71876166, 708592740), "rand after srand(42)")

# byte strings
expect_equal(cstr(as.raw(c(0x61, 0x62, 0, 0x63))), "ab", "cstr")
expect_equal(cbytes("ab"), c(97L, 98L), "cbytes")
