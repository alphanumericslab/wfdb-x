# Unit tests of WFDB-x for Julia. Expected values were produced by glibc on
# x86-64 Linux (most are ported from rust/tests/cstd.rs and
# rust/tests/wfdbio.rs, themselves ported from the Python and MATLAB tests).
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It tests WFDB-x; it has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

using Test
using WFDBX
const W = WFDBX

s(v) = String(copy(v))
cf(fmt, args...) = s(W.cformat(fmt, args...))

# Run f() and restore the environment variables of the library afterwards
# (setwfdb exports WFDB in legacy mode).
keeping_wfdb_env(f) = withenv(f, (k => get(ENV, k, nothing) for k in W._WFDB_ENV)...)

function tmpdir(name)
    d = joinpath(tempdir(), "wfdbx-jltest-$name-$(getpid())")
    rm(d; force=true, recursive=true)
    mkpath(d)
    d
end

# The library's messages on the standard error while f() runs.
function lib_stderr(f)
    p = W.cproc()
    p.err_capture = UInt8[]
    try
        f()
        return String(copy(p.err_capture))
    finally
        p.err_capture = nothing
    end
end

@testset "WFDBX" begin

@testset "printf integers" begin
    @test cf("%d", 42) == "42"
    @test cf("%d", -7) == "-7"
    @test cf("%5d|%-5d|%05d", 42, -42, -42) == "   42|-42  |-0042"
    @test cf("%+d % d %+d", 5, 5, 0) == "+5  5 +0"
    @test cf("%.3d|%8.3d", -5, 7) == "-005|     007"
    @test cf("%ld %lld %li", Int64(1) << 60, Int64(-3), 123456789012) ==
          "1152921504606846976 -3 123456789012"
    @test cf("%u %u", -1, 7) == "4294967295 7"
    @test cf("%lu", Int64(-1)) == "18446744073709551615"
    @test cf("%x %X %#x %o %#o", 255, 255, 255, 8, 8) == "ff FF 0xff 10 010"
    @test cf("%x %08x", -1, -2) == "ffffffff fffffffe"
    @test cf("%hd %hu %hhd", 70000, -1, 200) == "4464 65535 -56"
    @test cf("%c%c%c", 65, UInt8('b'), 321) == "AbA"
    @test cf("[%3c|%-3c]", UInt8('x'), 'y') == "[  x|y  ]"
    @test cf("%llu", UInt64(1) << 63) == "9223372036854775808"
    @test cf("[%.0d][%#.0o][%#x][%+u][% x]", 0, 0, 0, 5, 5) == "[][0][0][5][5]"
    @test cf("%d", 4294967297) == "1"       # a long printed with %d: low 32 bits
    @test cf("%d %d %d", 2.7, -2.7, NaN) == "2 -2 -2147483648"
    @test cf("%.30d", 1) == "0" ^ 29 * "1"
    @test cf("%d %d", typemin(Int32), typemax(Int32)) == "-2147483648 2147483647"
    @test cf("%ld", typemin(Int64)) == "-9223372036854775808"
    @test cf("%d", true) == "1"
    @test cf("%d %u", Int8(-1), UInt8(255)) == "-1 255"
end

@testset "printf strings" begin
    @test cf("%s|%10s|%-10s|%.2s|%5.1s", "abc", "abc", "abc", "abc", "abc") ==
          "abc|       abc|abc       |ab|    a"
    @test cf("[%s]", "") == "[]"
    @test cf("%s", nothing) == "(null)"
    @test cf("[%.3s]", nothing) == "[]"
    @test cf("[%05s]", "ab") == "[   ab]"
    @test cf("100%% %d%%", 5) == "100% 5%"
    @test cf("%5.2f%%\t%s\n", 99.5, "x") == "99.50%\tx\n"
    @test cf("no conversions") == "no conversions"
    @test cf("") == ""
    @test cf("[%y][%5%]") == "[%y][%]"
    @test W.cformat("%s", UInt8[0xe9, 0xff]) == UInt8[0xe9, 0xff]
    @test W.cformat("%s|", b"ab\0cd") == b"ab|"
    @test W.cformat(b"%s-%d", view(b"xyz", 1:2), 3) == b"xy-3"
    @test cf("%d %s") == "0 (null)"         # missing arguments
    @test cf("abc%") == "abc%"
    @test cf("%5") == "%5"
end

@testset "printf floats" begin
    cases = [
        ("0.0001 1e-05 123456 1.23457e+06 -0", "%g %g %g %g %g", [0.0001, 0.00001, 123456.0, 1234567.0, -0.0]),
        ("100000 1e+15 0.3", "%g %g %g", [100000.0, 1e15, 0.1 + 0.2]),
        ("0.1 0.333333333333333 0.10000000000000001", "%.12g %.15g %.17g", [0.1, 1.0 / 3.0, 0.1]),
        ("1.00000 2.00 1E-10", "%#g %#.3g %G", [1.0, 2.0, 1e-10]),
        ("1.500000 0 2 2 0.1", "%f %.0f %.0f %.0f %.1f", [1.5, 0.5, 1.5, 2.5, 0.05]),
        ("2.001 1.00    -3.1416 2.50      |", "%.3f %.2f %10.4f %-10.2f|", [2.0005, 1.005, -3.14159, 2.5]),
        ("1.234568e+04 1.23e-04 1.000000E+100 2e+10", "%e %.2e %E %.0e", [12345.678, 0.000123456, 1e100, 2.5e10]),
        ("+1.000  1.000 -001.500", "%+.3f % .3f %08.3f", [1.0, 1.0, -1.5]),
        ("360 0.002777777778", "%.10g %.10g", [360.0, 1.0 / 360.0]),
        ("1.235 -0.000000", "%.3lf %lf", [1.23456, -0.0]),
        ("4.940656e-324 1.79769e+308", "%e %g", [5e-324, 1.7976931348623157e308]),
        ("inf -inf   inf| +inf INF NAN      inf INF", "%f %f %5.2f| %+g %E %G %08.3f %F",
         [Inf, -Inf, Inf, Inf, Inf, NaN, Inf, Inf]),
        ("1.500000", "%F", [1.5]),
        # glibc quirk: '#' with a rounding carry from fixed to exponential.
        ("1.e+06 1.e+02 1.0e+06 10. 0.0001 0.00010", "%#g %#.2g %#.2g %#.2g %#.1g %#.2g",
         [999999.5, 99.5, 999999.5, 9.9999995, 0.0000999995, 0.0000999995]),
        ("-0.0 0 1e+01", "%.1f %.0f %.1g", [-0.04, 0.5, 9.5]),
    ]
    for (want, fmt, vals) in cases
        @test cf(fmt, vals...) == want
    end
    @test cf("%g", NaN) == "nan"
    @test cf("%g", -NaN) == "-nan"
    @test cf("%g", reinterpret(Float64, 0xfff8000000000000)) == "-nan"
    @test cf("% g|%-6g|", NaN, -Inf) == " nan|-inf  |"
    @test startswith(cf("%f", 1e300), "1000000000000000052504760255204420248704468581108159154915854115511802457988908195786371375080447864043704443832883878176942523235360430575644792184786706982848387200926575803737830233794788090059368953234970799945081119038967640880074652742780142494579258788820056842838115669472196386865459400540160.000000")
    @test cf("%.20f", 0.1) == "0.10000000000000000555"
    @test cf("%.0f %.0f %.0f", 0.5, 1.5, -2.5) == "0 2 -2"
    @test cf("%.3e", 1e-320) == "1.000e-320"
    @test cf("%e", 1e-300) == "1.000000e-300"
    @test cf("%g %g", 1f0, Float32(0.1)) == "1 0.1"
    @test cf("%f", 3) == "3.000000"           # integer argument to %f
    @test cf("%.40f", 1 / 3) == "0.3333333333333333148296162562473909929395"
    @test cf("%.45e", 1 / 3) == "3.333333333333333148296162562473909929394721985e-01"
end

@testset "printf star" begin
    @test cf("%*d|%-*d|%.*f|%*.*f", 6, 42, 6, 42, 2, 3.14159, 8, 3, 2.5) == "    42|42    |3.14|   2.500"
    @test cf("%*d|", -6, 42) == "42    |"
    @test cf("%.*f|", -1, 2.5) == "2.500000|"
end

@testset "printf fast path equals slow path" begin
    x = 0x9e3779b97f4a7c15
    for _ in 1:100_000
        x ⊻= x << 13; x ⊻= x >> 7; x ⊻= x << 17
        v = reinterpret(Float64, x & 0x7fffffffffffffff)
        isfinite(v) || continue
        p = Int(x >> 59)
        @test W._fast_digits_exp(v, p + 1) == W._slow_digits_exp(v, p + 1)
        @test W._fast_digits_fixed(v, p) == W._slow_digits_fixed(v, p)
    end
end

@testset "conversions" begin
    @test W.d2i(2.7) == 2
    @test W.d2i(-2.7) == -2
    @test W.d2i(NaN) == typemin(Int32)
    @test W.d2i(3e9) == typemin(Int32)
    @test W.d2i(-2147483648.9) == -2147483648
    @test W.d2i(2147483647.9) == 2147483647
    @test W.d2l(1e19) == typemin(Int64)
    @test W.d2l(-1e18) == -1000000000000000000
    @test W.cdiv(-7, 2) == -3
    @test W.cmod(-7, 2) == -1
    @test W.cdiv(typemin(Int64), -1) == typemin(Int64)
end

@testset "strtol" begin
    @test W.strtol("  -12abc", 10) == (-12, 5)
    @test W.strtol("abc", 10) == (0, 0)
    @test W.strtol("0x1f", 16) == (31, 4)
    @test W.strtol("99999999999999999999", 10)[1] == typemax(Int64)
    @test W.strtol("-99999999999999999999", 10)[1] == typemin(Int64)
    @test W.strtol(view(b"x 360 rest", 2:10), 10) == (360, 4)
    @test W.strtol("017", 0) == (15, 3)
    @test W.strtol("0x", 0) == (0, 1)
    @test W.strtol("0xg", 16) == (0, 1)
    @test W.strtol("+", 10) == (0, 0)
    @test W.strtol("12345678901234567", 10) == (12345678901234567, 17)
    @test W.strtol("zz", 36) == (1295, 2)
    @test W.strtoul("-1", 10) == (typemax(UInt64), 2)
    @test W.strtoul("99999999999999999999", 10) == (typemax(UInt64), 20)
    @test W.atoi(" 42x") == 42
    @test W.atoi("4294967297") == 1
    @test W.atoi("x") == 0
    @test W.atol("-5000000000") == -5000000000
end

@testset "strtod" begin
    @test W.strtod("1.5e2x") == (150.0, 5)
    @test W.strtod(" .25") == (0.25, 4)
    @test W.strtod("x") == (0.0, 0)
    @test W.strtod("0x10")[1] == 16.0
    @test W.strtod("0x1.8p1")[1] == 3.0
    @test W.strtod("0x") == (0.0, 1)
    @test W.strtod("1e") == (1.0, 1)
    @test W.strtod("1e+") == (1.0, 1)
    @test W.strtod("-Infinity!") == (-Inf, 9)
    @test W.strtod("inf") == (Inf, 3)
    @test W.strtod("infin")[2] == 3
    v, e = W.strtod("nan(12)x")
    @test isnan(v) && e == 7
    v, e = W.strtod("-nan(")
    @test isnan(v) && signbit(v) && e == 4
    @test W.strtod(view(b"a 7.", 2:4)) == (7.0, 3)
    @test W.strtod("0.1")[1] == 0.1
    @test W.strtod("1e400")[1] == Inf
    @test W.strtod("-1e400")[1] == -Inf
    @test W.strtod("1e-400")[1] == 0.0
    @test signbit(W.strtod("-1e-400")[1])
    @test W.strtod("2.4703282292062328e-324")[1] == 5e-324
    @test W.strtod("2.4703282292062327e-324")[1] == 0.0
    @test W.strtod("1e99999999999999999999999")[1] == Inf
    @test W.strtod("0x1p-1075")[1] == 0.0
    @test W.strtod("0x1.0000000000001p-1075")[1] == 5e-324
    @test W.strtod("0x1.fffffffffffff8p1023")[1] == Inf
    @test W.atof(" -2.5e1q") == -25.0
    @test W.strtof("0.1") == (0.1f0, 3)
    @test W.strtof("1e39")[1] == Inf32
end

@testset "sscanf" begin
    x = Ref(-1.0)
    @test W.csscanf("", "%lf", x) == -1
    @test W.csscanf("   ", "%lf", x) == -1
    @test W.csscanf("x", "%lf", x) == 0
    @test x[] == -1.0      # untouched
    a = Ref{Int64}(0); b = UInt8[]; c = Ref{Int32}(0); d = Ref{Int32}(0); e = Ref{Int32}(0)
    @test W.csscanf("12 N 1 2 3", "%lld%s%d%d%d", a, b, c, d, e) == 5
    @test (a[], s(b), c[], d[], e[]) == (12, "N", 1, 2, 3)
    d1, m1, y1 = Ref{Int32}(0), Ref{Int32}(0), Ref{Int32}(0)
    @test W.csscanf("01.02.85", "%d%*c%d%*c%d", d1, m1, y1) == 3
    @test (d1[], m1[], y1[]) == (1, 2, 85)
    v = [Ref{Int32}(0) for _ in 1:6]
    @test W.csscanf("[10:20:30 1/2/2000]", "[%d:%d:%d %d/%d/%d", v...) == 6
    @test [r[] for r in v] == [10, 20, 30, 1, 2, 2000]
    l1, l2, ch = Ref{Int64}(0), Ref{Int64}(0), Ref{UInt8}(0)
    @test W.csscanf("1,2,\"Q", "%lld,%lld,\"%c", l1, l2, ch) == 3
    @test (l1[], l2[], ch[]) == (1, 2, UInt8('Q'))
    s1, s2 = UInt8[], UInt8[]
    @test W.csscanf("abcdef", "%3s%s", s1, s2) == 2
    @test (s(s1), s(s2)) == ("abc", "def")
    h, i1, i2 = Ref{Int32}(0), Ref{Int32}(0), Ref{Int32}(0)
    @test W.csscanf("ff 0x10 017", "%x %i %i", h, i1, i2) == 3
    @test (h[], i1[], i2[]) == (255, 16, 15)
    n1, n2 = Ref{Int32}(0), Ref{Int32}(77)
    @test W.csscanf("5", "%d%d", n1, n2) == 1
    @test n2[] == 77
    @test W.csscanf("", "x%d", n1) == -1
    @test W.csscanf("12", "%*d%d", n1) == -1
    @test W.csscanf("12 x", "%*d%d", n1) == 0
    rest = UInt8[]
    @test W.csscanf("100ergs", "%lf%s", x, rest) == 2
    @test (x[], s(rest)) == (100.0, "rgs")
    @test W.csscanf("99999999999", "%d", n1) == 1
    @test n1[] == 1215752191
    u = Ref{UInt32}(0)
    @test W.csscanf("-1", "%u", u) == 1
    @test u[] == typemax(UInt32)
    z = Ref{Int32}(0)
    @test W.csscanf(" 7", "%d", z) == 1 && z[] == 7
    set = UInt8[]
    @test W.csscanf("]b-c]x", "%[]a-c]", set) == 1 && s(set) == "]b"
    @test W.csscanf("019a", "%[0-9]", set) == 1 && s(set) == "019"
    @test W.csscanf("a b", "%d", nothing) == 0
end

@testset "strtok" begin
    t = W.Strtok("  a  b\tc\r\n")
    d = " \t\r\n"
    @test W.strtok(t, d) == b"a"
    @test W.strtok(t, d) == b"b"
    @test W.strtok(t, d) == b"c"
    @test W.strtok(t, d) === nothing
    @test W.strtok(t, d) === nothing
    t = W.Strtok("x 0 MLII lead\r\n")
    W.strtok(t, " "); W.strtok(t, " ")
    @test W.strtok(t, "\r\n") == b"MLII lead"
    t = W.Strtok("abc")
    @test W.strtok(t, " ") == b"abc"
    @test W.strtok(t, " ") === nothing
    t = W.Strtok("   ")
    @test W.strtok(t, " ") === nothing
    t = W.Strtok("a b")
    W.strtok(t, " ")
    @test W.strtok_rest(t) == b"b"
    @test W.strtok_pos(t) == 3
end

@testset "fgets_lines" begin
    @test collect(W.fgets_lines("abc\ndefgh", 4)) == [b"abc", b"\n", b"def", b"gh"]
    @test collect(W.fgets_lines("a\nbc\n", 100)) == [b"a\n", b"bc\n"]
    @test isempty(collect(W.fgets_lines("", 10)))
    @test collect(W.fgets_lines("\n\nx", 10)) == [b"\n", b"\n", b"x"]
end

@testset "glibc rand" begin
    cases = [(0, [1804289383, 846930886, 1681692777], 107345864261546),
             (1, [1804289383, 846930886, 1681692777], 107345864261546),
             (42, [71876166, 708592740, 1483128881], 107493762466152),
             (12345, [383100999, 858300821, 357768173], 107265696684802),
             (4294967295, [254925627, 1205188300, 366127624], 107479458668323),
             (2147483648, [1336741213, 1210407648, 1447044896], 107447831310714)]
    for (seed, first, sum) in cases
        r = W.GlibcRand(seed)
        total = 0
        for i in 1:100000
            v = W.glibc_rand!(r)
            i <= 3 && @test v == first[i]
            total += v
        end
        @test total == sum
    end
    @test W.glibc_rand!(W.GlibcRand()) == 1804289383
    W.csrand(42)
    @test W.crand() == 71876166
    @test W.RAND_MAX == 2147483647
end

@testset "misc cstd" begin
    @test W.prog_name("/usr/bin/rdsamp") == b"rdsamp"
    @test W.prog_name("rdsamp") == b"rdsamp"
    @test W.cstr(UInt8[0x61, 0x00, 0x62]) == b"a"
    @test W.c_isspace(UInt8('\v')) && !W.c_isspace(UInt8('x'))
    @test W.c_toupper(UInt8('a')) == UInt8('A')
end

@testset "WfdbFile: write, read, seek" begin
    d = tmpdir("wrs")
    name = joinpath(d, "f.dat")
    f = W.cfopen(name, "wb")
    for i in 0:99_999
        W.wfdb_p16(f, i)
    end
    W.wfdb_p32(f, -2)
    @test W.ftell(f) == 200_004
    big = fill(0x07, 100_000)
    @test W.fwrite(f, big) == 100_000
    @test W.ftell(f) == 300_004
    @test W.fclose(f) == 0

    f = W.cfopen(name, "rb")
    ok = true
    for i in 0:99_999
        ok &= W.wfdb_g16(f) == Int32(i % UInt16 % Int16)
    end
    @test ok
    @test W.wfdb_g32(f) == -2
    @test W.ftell(f) == 200_004
    @test W.fseek(f, -10, W.SEEK_END) == 0
    buf = zeros(UInt8, 20)
    @test W.fread!(f, buf) == 10
    @test W.feof(f)
    @test W.getc(f) == W.EOF
    @test W.fseek(f, 4, W.SEEK_SET) == 0
    @test W.wfdb_g16(f) == 2
    @test W.fseek(f, 2, W.SEEK_CUR) == 0
    @test W.wfdb_g16(f) == 4
    @test W.ftell(f) == 10
    @test W.fseek(f, -1, W.SEEK_SET) == -1
    @test W.fwrite(f, b"x") == 0 && W.ferror(f)   # not open for writing
    W.fclose(f)

    # Read/write mode: writing after reading continues at the logical position.
    f = W.cfopen(name, "r+b")
    @test W.wfdb_g16(f) == 0
    @test W.fwrite(f, UInt8[0x09, 0x00]) == 2
    @test W.fseek(f, 0, W.SEEK_SET) == 0
    @test W.wfdb_g16(f) == 0
    @test W.wfdb_g16(f) == 9
    @test W.wfdb_g16(f) == 2
    @test W.fclose(f) == 0
    rm(d; recursive=true)
end

@testset "WfdbFile: append and lines" begin
    d = tmpdir("app")
    name = joinpath(d, "t.txt")
    f = W.cfopen(name, "w")
    W.cfprintf(f, "%s %d\n", "line", 1)
    W.fclose(f)
    f = W.cfopen(name, "ab")
    @test W.ftell(f) == 7
    W.cfprintf(f, "%s %d\nlast", "line", 2)
    @test W.ftell(f) == 18
    @test W.fclose(f) == 0
    f = W.cfopen(name, "rb")
    line = UInt8[]
    @test W.getline!(f, line) == 7
    @test line == b"line 1\n"
    @test W.fgets!(f, line, 4)
    @test line == b"lin"
    @test W.fgets!(f, line, 100)
    @test line == b"e 2\n"
    @test W.fgets!(f, line, 100)
    @test line == b"last"
    @test !W.fgets!(f, line, 100)
    @test W.getline!(f, line) == 0
    W.fclose(f)
    rm(d; recursive=true)
end

@testset "WfdbFile: memory" begin
    f = W.wfdb_memfile(UInt8[b"ab\ncd\x01\x80"; 0xff; 0xff])
    line = UInt8[]
    @test W.getline!(f, line) == 3
    @test line == b"ab\n"
    @test W.ftell(f) == 3
    @test W.getc(f) == Int32('c')
    @test W.fgets!(f, line, 2)
    @test line == b"d"
    @test W.wfdb_g16(f) == -32767
    @test W.fseek(f, -2, W.SEEK_END) == 0
    @test W.wfdb_g16(f) == -1
    @test W.getc(f) == W.EOF
    @test W.feof(f)
    @test W.getc(f) == W.EOF
    @test W.fseek(f, 0, W.SEEK_SET) == 0
    @test !W.feof(f)
    @test W.getc(f) == Int32('a')
    @test W.ungetc(f, Int32('z')) == Int32('z')
    @test W.getc(f) == Int32('z')
    @test W.read_to_end(f) == b"b\ncd\x01\x80\xff\xff"
end

# (legacy mode: the WFDB path; see test_files.jl for normal mode)
@testset "wfdb_open modes" begin keeping_wfdb_env() do
    d = tmpdir("open")
    w = Wfdb()
    W.wfdbx_set_legacy(w, true)
    W.wfdbquiet(w)
    W.setwfdb(w, d * " .")
    rec = joinpath(d, "sub", "r1")
    f = W.wfdb_open(w, "hea", rec, WFDB_WRITE)
    W.fwrite(f, "r1 0\n")
    W.fclose(f)
    @test endswith(s(W.wfdb_filename(w)), "sub/r1.hea")
    f = W.wfdb_open(w, "hea", rec, W.WFDB_APPEND)
    W.fwrite(f, "#x\n")
    W.fclose(f)
    @test read(joinpath(d, "sub", "r1.hea")) == b"r1 0\n#x\n"
    f = W.wfdb_open(w, "hea", "sub/r1", WFDB_READ)
    @test W.read_to_end(f) == b"r1 0\n#x\n"
    W.fclose(f)
    mkpath(joinpath(d, "sub", "r2"))
    write(joinpath(d, "sub", "r2", "r2.hea"), "r2 0\n")
    @test endswith(s(W.wfdbfile(w, "hea", "sub/r2/")), "sub/r2/r2.hea")
    @test endswith(s(W.wfdbfile(w, nothing, nothing)), "r2.hea")
    @test W.wfdbfile(w, "sub", nothing) === nothing        # a directory
    @test W.wfdb_fopen(w, joinpath(d, "sub"), "rb") === nothing
    @test W.wfdbfile(w, "sub/r1.hea", nothing) !== nothing
    @test W.wfdbfile(w, "sub/r1.hea", "") !== nothing
    @test W.wfdbfile(w, nothing, "sub/r1.hea") === nothing  # ".hea" stripped
    # %r in the WFDB path; the type truncated to 3 characters.
    mkpath(joinpath(d, "rec1"))
    write(joinpath(d, "rec1", "rec1.hea"), "rec1 0\n")
    write(joinpath(d, "rec1", "rec1.abc"), "x")
    w2 = Wfdb()
    W.wfdbx_set_legacy(w2, true)
    W.setwfdb(w2, joinpath(d, "%r"))
    W.wfdb_setirec(w2, "rec1")
    @test endswith(s(W.wfdbfile(w2, "hea", "rec1")), "rec1/rec1.hea")
    @test endswith(s(W.wfdbfile(w2, "abcdef", "rec1")), "rec1/rec1.abc")
    @test W.wfdbfile(w2, "hea", "nosuch") === nothing
    write(joinpath(d, "x"), "x")
    @test W.wfdb_fopen(w, joinpath(d, "sub", "..", "x"), "rb") === nothing     # (legacy)
    @test W.wfdb_fopen(Wfdb(), joinpath(d, "sub", "..", "x"), "rb") !== nothing
    # Output: missing directories are created.
    out = joinpath(d, "new", "dir", "file.txt")
    f = W.wfdb_fopen(w, out, "wb")
    W.cfprintf(f, "x=%d\n", 42)
    W.putc(f, 1)
    @test W.ftell(f) == 6
    @test W.fclose(f) == 0
    @test read(out) == b"x=42\n\x01"
    rm(d; recursive=true)
end end

# (legacy mode; setwfdb exports WFDB, restored afterwards)
@testset "WFDB path functions" begin keeping_wfdb_env() do
    w = Wfdb()
    W.wfdbx_set_legacy(w, true)
    W.setwfdb(w, "a b")
    @test W.getwfdb(w) == b"a b"
    @test W.cgetenv("WFDB") == b"a b"
    W.resetwfdb(w)
    @test W.getwfdb(w) == b"a b"
    w2 = Wfdb()
    W.wfdbx_set_legacy(w2, true)
    first = W.getwfdb(w2)
    W.setwfdb(w2, "x")
    W.resetwfdb(w2)
    @test W.getwfdb(w2) == first
    d = tmpdir("at")
    write(joinpath(d, "p"), "dir1 dir2\r\n")
    W.setwfdb(w, "@" * joinpath(d, "p"))
    @test W.getwfdb(w) == b"dir1 dir2"
    rm(d; recursive=true)
    prefixes(w) = [s(c.prefix) for c in w.io.path_list]
    W.wfdb_parse_path(w, ". /usr/local/database http://physionet.org/physiobank/database")
    @test prefixes(w) == [".", "/usr/local/database", "http://physionet.org/physiobank/database"]
    @test w.io.path_list[3].ptype == W.WFDB_NET
    W.wfdb_parse_path(w, "a:b;c\td")
    @test prefixes(w) == ["a", "b", "c", "d"]
    W.wfdb_parse_path(w, "")
    @test isempty(w.io.path_list)
    w.io.wfdbpath = Vector{UInt8}(". a b")
    W.wfdb_parse_path(w, ". a b")
    W.wfdb_addtopath(w, "b/100s.hea")
    @test prefixes(w) == [".", "b", "a"]
    W.wfdb_addtopath(w, "x/y/100s.hea")
    @test prefixes(w) == [".", "x/y", "b", "a"]
    W.wfdb_addtopath(w, "100s.hea")
    @test length(prefixes(w)) == 4
    W.wfdb_addtopath(w, "./100s.hea")
    @test length(prefixes(w)) == 4
    @test W.wfdb_striphea("100s.hea") == b"100s"
    @test W.wfdb_striphea(".hea") == b".hea"
    w3 = Wfdb()
    @test W.wfdb_getirec(w3) === nothing
    W.wfdb_setirec(w3, "a/b/rec")
    @test W.wfdb_getirec(w3) == b"rec"
    W.wfdb_setirec(w3, "-")
    @test W.wfdb_getirec(w3) == b"rec"
end end

@testset "errors and versions" begin
    w = Wfdb()
    W.wfdbquiet(w)
    @test W.wfdberror(w) == b"WFDB library version 10.7.0 (Jun 10 2022).\n"
    W.wfdb_error(w, "x %d\n", 5)
    @test W.wfdberror(w) == b"x 5\n"
    @test W.wfdb_checkname(w, "a-b_c~/9", "record") == 0
    @test W.wfdb_checkname(w, "a.b", "record") == -1
    @test W.wfdberror(w) == b"init: illegal character 46 in record name\n"
    @test W.wfdb_checkname(w, "", "record") == -1
    @test W.wfdbversion() == b"10.7.0"
    @test W.wfdbldflags() == b""
    @test W.wfdbcflags() == b""
    @test W.wfdbdefwfdb() == b". /usr/local/database http://physionet.org/physiobank/database"
    @test W.wfdbdefwfdbcal() == b"wfdbcal"
    @test W.wfdb_me_fatal(w) == 1
    W.wfdbmemerr(w, 0)
    @test W.wfdb_me_fatal(w) == 0
    # Independent instances.
    a, b = Wfdb(), Wfdb()
    W.wfdb_setirec(a, "rec_a")
    @test W.wfdb_getirec(b) === nothing
end

@testset "ecgcodes" begin
    w = Wfdb()
    @test W.wfdb_isqrs(w, W.NORMAL) == 1
    @test W.wfdb_isqrs(w, W.NOISE) == 0
    @test W.wfdb_map1(w, W.APC) == W.NORMAL
    @test W.wfdb_map2(w, W.APC) == W.SVPB
    @test W.wfdb_map1(w, W.RONT) == W.PVC
    @test W.wfdb_setisqrs(w, 2, 300) == 44
    @test W.wfdb_isqrs(w, 2) == 44
    @test W.isqrs(Wfdb(), 2) == 1
    @test W.wfdb_annpos(w, W.RHYTHM) == W.APLOW
    @test W.ammap(Int('N')) == W.NORMAL
    @test W.ammap(Int(']')) == W.VFOFF
    @test W.ammap(Int('D')) == W.NOTQRS
    @test W.mamap(W.PVC, 0) == Int('V')
    @test W.mamap(W.NOISE, 0) == Int('O')
    @test W.mamap(W.NOISE, -1) == Int('U')
    @test W.mamap(W.VFON, 0) == Int('[')
    @test W.isann(0) == 0
    @test W.isann(W.ACMAX) == 1
end

# isann, isqrs, map1, map2, annpos, mamap(code, 0) and mamap(code, -1) of the
# codes -1 to 50 (from the C library), one row per code.
CODE_MAPS = [
    -1 0 0 0 0 0 79 79;
    0 0 0 0 0 0 79 79;
    1 1 1 1 1 1 78 78;
    2 1 1 1 1 1 78 78;
    3 1 1 1 1 1 78 78;
    4 1 1 1 9 1 78 78;
    5 1 1 5 5 1 86 86;
    6 1 1 6 6 1 70 70;
    7 1 1 1 9 1 78 78;
    8 1 1 1 9 1 78 78;
    9 1 1 1 9 1 78 78;
    10 1 1 5 5 1 69 69;
    11 1 1 1 1 1 78 78;
    12 1 1 1 1 1 80 80;
    13 1 1 1 1 1 81 81;
    14 1 0 0 0 2 79 85;
    15 1 0 0 0 0 79 79;
    16 1 0 0 0 2 79 79;
    17 1 0 0 0 0 79 79;
    18 1 0 0 0 2 79 79;
    19 1 0 0 0 2 79 79;
    20 1 0 0 0 2 79 79;
    21 1 0 0 0 2 79 79;
    22 1 0 0 0 2 79 79;
    23 1 0 0 0 2 79 79;
    24 1 0 0 0 2 79 79;
    25 1 1 1 1 1 78 78;
    26 1 0 0 0 2 79 79;
    27 1 0 0 0 2 79 79;
    28 1 0 0 0 3 79 79;
    29 1 0 0 0 2 79 79;
    30 1 1 30 30 1 81 81;
    31 1 1 5 5 1 79 79;
    32 1 0 0 0 1 91 91;
    33 1 0 0 0 1 93 93;
    34 1 1 1 1 1 78 78;
    35 1 1 1 1 1 78 78;
    36 1 0 0 0 2 79 79;
    37 1 0 0 0 2 79 79;
    38 1 1 1 1 1 78 78;
    39 1 0 0 0 2 79 79;
    40 1 0 0 0 2 79 79;
    41 1 1 5 5 1 82 82;
    42 1 0 0 0 0 79 79;
    43 1 0 0 0 0 79 79;
    44 1 0 0 0 0 79 79;
    45 1 0 0 0 0 79 79;
    46 1 0 0 0 0 79 79;
    47 1 0 0 0 0 79 79;
    48 1 0 0 0 0 79 79;
    49 1 0 0 0 0 79 79;
    50 0 0 0 0 0 79 79
]

@testset "code maps" begin
    w = Wfdb()
    for r in eachrow(CODE_MAPS)
        c = r[1]
        @test [c, W.isann(c), W.isqrs(c), W.map1(c), W.map2(c), W.annpos(c),
               W.mamap(c, 0), W.mamap(c, -1)] == r
        @test [c, W.wfdb_isann(c), W.wfdb_isqrs(c), W.wfdb_map1(c), W.wfdb_map2(c),
               W.wfdb_annpos(c), W.wfdb_mamap(c, 0), W.wfdb_mamap(c, -1)] == r
        @test [c, W.isann(c), W.wfdb_isqrs(w, c), W.wfdb_map1(w, c), W.wfdb_map2(w, c),
               W.wfdb_annpos(w, c), W.mamap(c, 0), W.mamap(c, -1)] == r
    end
    @test [W.ammap(c) for c in Int('C'):Int('_')] ==
          [0, 0, 10, 6, 0, 0, 0, 0, 0, 0, 0, 1, 22, 12, 13, 41, 0, 0, 14, 5,
           0, 0, 0, 0, 32, 0, 33, 0, 0]
end

@testset "code map setters" begin
    # on the default instance (restored afterwards)
    try
        @test W.wfdb_setisqrs(1, 0) == 0
        @test W.isqrs(1) == 0
        @test W.wfdb_setisqrs(60, 1) == 0
        @test W.wfdb_setisqrs(2, 300) == 44    # (stored in a char)
        @test W.isqrs(2) == 44
        @test W.wfdb_setmap1(14, W.PVC) == 5
        @test W.map1(14) == 5
        @test W.wfdb_setmap1(0, W.PVC) == 0
        @test W.wfdb_setmap2(14, W.SVPB) == 9
        @test W.map2(14) == 9
        @test W.wfdb_setmap2(-3, W.PVC) == 0
        @test W.wfdb_setannpos(14, 6) == 6
        @test W.annpos(14) == 6
        @test W.wfdb_setannpos(50, 2) == 0
        # the aliases without the wfdb_ prefix
        @test W.setisqrs(1, 1) == 1
        @test W.setmap1(14, W.NORMAL) == 1
        @test W.setmap2(14, W.NORMAL) == 1
        @test W.setannpos(14, 300) == 44
        @test W.annpos(14) == 44
    finally
        W.wfdb_setisqrs(1, 1)
        W.wfdb_setisqrs(2, 1)
        W.wfdb_setmap1(14, W.NOTQRS)
        W.wfdb_setmap2(14, W.NOTQRS)
        W.wfdb_setannpos(14, 2)
    end
    @test [W.isqrs(1), W.isqrs(2), W.map1(14), W.map2(14), W.annpos(14)] == [1, 1, 0, 0, 2]
    # on an instance (which does not change the default instance)
    w = Wfdb()
    @test W.wfdb_setmap1(w, 14, W.PVC) == 5
    @test W.wfdb_setmap1(w, 0, W.PVC) == 0
    @test W.wfdb_setmap2(w, 14, W.SVPB) == 9
    @test W.wfdb_setmap2(w, -3, W.PVC) == 0
    @test W.wfdb_setannpos(w, 14, 6) == 6
    @test W.wfdb_setannpos(w, 50, 2) == 0
    @test [W.map1(w, 14), W.map2(w, 14), W.annpos(w, 14)] == [5, 9, 6]
    @test [W.map1(14), W.map2(14), W.annpos(14)] == [0, 0, 2]
end

@testset "tools in-process" begin
    data = W.workload_data_source()
    if data !== nothing
        d = tmpdir("tools")
        for f in readdir(data)
            cp(joinpath(data, f), joinpath(d, f))
        end
        env = ("WFDBX_INPUT_DIR" => ".",)
        @test W.run_tool("wfdbwhich", ["100s.hea"]; dir=d, env=env) == (0, b"./100s.hea\n", UInt8[])
        st, out, err = W.run_tool("wfdbwhich", ["dat", "nosuch"]; dir=d, env=env)
        @test st == 2 && isempty(out)
        @test err == b"No file of type `dat' found for record `nosuch'\n(WFDB path = .)\n"
        st, out, err = W.run_tool("wfdbcat", ["100s.hea", "nosuch"]; dir=d, env=env)
        @test st == 0 && out == read(joinpath(d, "100s.hea"))
        @test err == b"wfdbcat: `nosuch' not found\n"
        @test W.run_tool("wfdbcat", String[]; dir=d)[1] == 1
        # The standard input.
        st, out, err = W.run_tool("wfdbcat", ["-"]; stdin=UInt8[0x00, 0xff, 0x41], dir=d)
        @test st == 0 && out == UInt8[0x00, 0xff, 0x41]
        rm(d; recursive=true)
    end
    @test "wfdbwhich" in W.tools()
    @test length(W.tools()) == 33
    @test all(t -> W.tool_function(t) isa Function, W.tools())
    @test W.tool_function("nosuch") === nothing
    @test W.tool_function("_run") === nothing
    # The driver's --version.
    driver = joinpath(dirname(@__DIR__), "bin", "wfdbx.jl")
    out = read(`$(Base.julia_cmd()) --startup-file=no --project=$(dirname(@__DIR__)) $driver --version`,
               String)
    @test out == "WFDB-x $(pkgversion(W))\n"
    @test occursin(r"^WFDB-x \d+\.\d+\.\d+\n$", out)
end

include("signals.jl")
include("test_annotations.jl")
include("test_flac.jl")
include("test_files.jl")
include("test_check.jl")

end
