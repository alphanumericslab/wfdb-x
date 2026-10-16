//! Tests of the C standard library emulation (`wfdbx::cstd`). Expected
//! values were produced by glibc on x86-64 Linux (most are ported from
//! python/tests/test_cstd.py and matlab/tests/test_csprintf.m,
//! test_cstd_parse.m and test_cstd_rand.m).
//
// Part of wfdb-x, Reza Sameni, Oct 2026.
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

#![allow(clippy::approx_constant, clippy::needless_range_loop)]

use wfdbx::cstd::{
    self, atof, atoi, atol, d2i, d2l, fgets_lines, sprintf, sscanf, strtod, strtol, strtoul, Arg,
    GlibcRand, ScanArg, Strtok,
};
use wfdbx::{cformat, csscanf};

fn s(v: Vec<u8>) -> String {
    String::from_utf8_lossy(&v).into_owned()
}

#[test]
fn printf_integers() {
    assert_eq!(s(cformat!(b"%d", 42)), "42");
    assert_eq!(s(cformat!(b"%d", -7)), "-7");
    assert_eq!(
        s(cformat!(b"%5d|%-5d|%05d", 42, -42, -42)),
        "   42|-42  |-0042"
    );
    assert_eq!(s(cformat!(b"%+d % d %+d", 5, 5, 0)), "+5  5 +0");
    assert_eq!(s(cformat!(b"%.3d|%8.3d", -5, 7)), "-005|     007");
    assert_eq!(
        s(cformat!(
            b"%ld %lld %li",
            1i64 << 60,
            -3i64,
            123456789012i64
        )),
        "1152921504606846976 -3 123456789012"
    );
    assert_eq!(s(cformat!(b"%u %u", -1, 7)), "4294967295 7");
    assert_eq!(s(cformat!(b"%lu", -1i64)), "18446744073709551615");
    assert_eq!(
        s(cformat!(b"%x %X %#x %o %#o", 255, 255, 255, 8, 8)),
        "ff FF 0xff 10 010"
    );
    assert_eq!(s(cformat!(b"%x %08x", -1, -2)), "ffffffff fffffffe");
    assert_eq!(
        s(cformat!(b"%hd %hu %hhd", 70000, -1, 200)),
        "4464 65535 -56"
    );
    assert_eq!(s(cformat!(b"%c%c%c", 65, b'b', 321)), "AbA");
    assert_eq!(s(cformat!(b"[%3c|%-3c]", b'x', b'y')), "[  x|y  ]");
    assert_eq!(s(cformat!(b"%llu", 1u64 << 63)), "9223372036854775808");
    assert_eq!(
        s(cformat!(b"[%.0d][%#.0o][%#x][%+u][% x]", 0, 0, 0, 5, 5)),
        "[][0][0][5][5]"
    );
    // A long printed with %d: the low 32 bits (as C on x86-64).
    assert_eq!(s(cformat!(b"%d", 4294967297i64)), "1");
    // Doubles given to integer conversions (as the MATLAB port).
    assert_eq!(
        s(cformat!(b"%d %d %d", 2.7, -2.7, f64::NAN)),
        "2 -2 -2147483648"
    );
}

#[test]
fn printf_strings() {
    assert_eq!(
        s(cformat!(
            b"%s|%10s|%-10s|%.2s|%5.1s",
            "abc",
            "abc",
            "abc",
            "abc",
            "abc"
        )),
        "abc|       abc|abc       |ab|    a"
    );
    assert_eq!(s(cformat!(b"[%s]", "")), "[]");
    let null: Option<Vec<u8>> = None;
    assert_eq!(s(cformat!(b"%s", null)), "(null)");
    assert_eq!(s(cformat!(b"[%.3s]", null)), "[]");
    assert_eq!(s(cformat!(b"[%05s]", "ab")), "[   ab]");
    assert_eq!(s(cformat!(b"100%% %d%%", 5)), "100% 5%");
    assert_eq!(s(cformat!(b"%5.2f%%\t%s\n", 99.5, "x")), "99.50%\tx\n");
    assert_eq!(s(cformat!(b"no conversions")), "no conversions");
    assert_eq!(s(cformat!(b"")), "");
    assert_eq!(s(cformat!(b"[%y][%5%]")), "[%y][%]");
    // Byte strings that are not UTF-8 pass through.
    assert_eq!(cformat!(b"%s", b"\xe9\xff".to_vec()), b"\xe9\xff");
    // A C string ends at its first NUL.
    assert_eq!(cformat!(b"%s|", b"ab\0cd"), b"ab|");
}

#[test]
fn printf_floats() {
    let cases: &[(&str, &[u8], &[f64])] = &[
        (
            "0.0001 1e-05 123456 1.23457e+06 -0",
            b"%g %g %g %g %g",
            &[0.0001, 0.00001, 123456.0, 1234567.0, -0.0],
        ),
        (
            "100000 1e+15 0.3",
            b"%g %g %g",
            &[100000.0, 1e15, 0.1 + 0.2],
        ),
        (
            "0.1 0.333333333333333 0.10000000000000001",
            b"%.12g %.15g %.17g",
            &[0.1, 1.0 / 3.0, 0.1],
        ),
        ("1.00000 2.00 1E-10", b"%#g %#.3g %G", &[1.0, 2.0, 1e-10]),
        (
            "1.500000 0 2 2 0.1",
            b"%f %.0f %.0f %.0f %.1f",
            &[1.5, 0.5, 1.5, 2.5, 0.05],
        ),
        (
            "2.001 1.00    -3.1416 2.50      |",
            b"%.3f %.2f %10.4f %-10.2f|",
            &[2.0005, 1.005, -3.14159, 2.5],
        ),
        (
            "1.234568e+04 1.23e-04 1.000000E+100 2e+10",
            b"%e %.2e %E %.0e",
            &[12345.678, 0.000123456, 1e100, 2.5e10],
        ),
        (
            "+1.000  1.000 -001.500",
            b"%+.3f % .3f %08.3f",
            &[1.0, 1.0, -1.5],
        ),
        ("360 0.002777777778", b"%.10g %.10g", &[360.0, 1.0 / 360.0]),
        ("1.235 -0.000000", b"%.3lf %lf", &[1.23456, -0.0]),
        (
            "4.940656e-324 1.79769e+308",
            b"%e %g",
            &[5e-324, 1.7976931348623157e308],
        ),
        (
            "inf -inf   inf| +inf INF NAN      inf INF",
            b"%f %f %5.2f| %+g %E %G %08.3f %F",
            &[
                f64::INFINITY,
                f64::NEG_INFINITY,
                f64::INFINITY,
                f64::INFINITY,
                f64::INFINITY,
                f64::NAN,
                f64::INFINITY,
                f64::INFINITY,
            ],
        ),
        ("1.500000", b"%F", &[1.5]),
        // glibc quirk: '#' with a rounding carry from fixed to exponential.
        (
            "1.e+06 1.e+02 1.0e+06 10. 0.0001 0.00010",
            b"%#g %#.2g %#.2g %#.2g %#.1g %#.2g",
            &[
                999999.5,
                99.5,
                999999.5,
                9.9999995,
                0.0000999995,
                0.0000999995,
            ],
        ),
        ("-0.0 0 1e+01", b"%.1f %.0f %.1g", &[-0.04, 0.5, 9.5]),
    ];
    for (want, fmt, vals) in cases {
        let args: Vec<Arg> = vals.iter().map(|&v| Arg::Float(v)).collect();
        assert_eq!(
            s(sprintf(fmt, &args)),
            *want,
            "format {}",
            String::from_utf8_lossy(fmt)
        );
    }
    let nan = f64::NAN;
    assert_eq!(s(cformat!(b"%g", nan)), "nan");
    assert_eq!(s(cformat!(b"%g", -nan)), "-nan");
    // 0.0/0.0 computed by an x86 FPU is the "default NaN", with the sign bit.
    assert_eq!(
        s(cformat!(b"%g", f64::from_bits(0xfff8_0000_0000_0000))),
        "-nan"
    );
    assert_eq!(
        s(cformat!(b"% g|%-6g|", nan, f64::NEG_INFINITY)),
        " nan|-inf  |"
    );
    // 1e300 printed exactly.
    let big = s(cformat!(b"%f", 1e300));
    assert!(big.starts_with("1000000000000000052504760255204420248704468581108159154915854115511802457988908195786371375080447864043704443832883878176942523235360430575644792184786706982848387200926575803737830233794788090059368953234970799945081119038967640880074652742780142494579258788820056842838115669472196386865459400540160.000000"));
    assert_eq!(s(cformat!(b"%.20f", 0.1)), "0.10000000000000000555");
    assert_eq!(s(cformat!(b"%.0f %.0f %.0f", 0.5, 1.5, -2.5)), "0 2 -2");
    assert_eq!(s(cformat!(b"%.3e", 1e-320)), "1.000e-320");
}

#[test]
fn printf_star() {
    assert_eq!(
        s(cformat!(
            b"%*d|%-*d|%.*f|%*.*f",
            6,
            42,
            6,
            42,
            2,
            3.14159,
            8,
            3,
            2.5
        )),
        "    42|42    |3.14|   2.500"
    );
    assert_eq!(s(cformat!(b"%*d|", -6, 42)), "42    |");
    assert_eq!(s(cformat!(b"%.*f|", -1, 2.5)), "2.500000|");
}

#[test]
fn printf_fast_equals_slow() {
    let mut x = 0x9e37_79b9_7f4a_7c15u64;
    for _ in 0..100_000 {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        let v = f64::from_bits(x & 0x7fff_ffff_ffff_ffff);
        if !v.is_finite() {
            continue;
        }
        let p = (x >> 59) as usize;
        assert_eq!(
            cstd::fast_digits_exp(v, p + 1),
            cstd::slow_digits_exp(v, p + 1)
        );
        assert_eq!(cstd::fast_digits_fixed(v, p), cstd::slow_digits_fixed(v, p));
    }
}

#[test]
fn conversions() {
    assert_eq!(d2i(2.7), 2);
    assert_eq!(d2i(-2.7), -2);
    assert_eq!(d2i(f64::NAN), i32::MIN);
    assert_eq!(d2i(3e9), i32::MIN);
    assert_eq!(d2i(-2147483648.9), -2147483648);
    assert_eq!(d2i(2147483647.9), 2147483647);
    assert_eq!(d2l(1e19), i64::MIN);
    assert_eq!(cstd::cdiv(-7, 2), -3);
    assert_eq!(cstd::cmod(-7, 2), -1);
}

#[test]
fn strtol_cases() {
    assert_eq!(strtol(b"  -12abc", 10), (-12, 5));
    assert_eq!(strtol(b"abc", 10), (0, 0));
    assert_eq!(strtol(b"0x1f", 16), (31, 4));
    assert_eq!(strtol(b"99999999999999999999", 10).0, i64::MAX);
    assert_eq!(strtol(b"-99999999999999999999", 10).0, i64::MIN);
    assert_eq!(strtol(&b"x 360 rest"[1..], 10), (360, 4));
    assert_eq!(strtol(b"017", 0), (15, 3));
    assert_eq!(strtol(b"0x", 0), (0, 1));
    assert_eq!(strtol(b"0xg", 16), (0, 1));
    assert_eq!(strtol(b"+", 10), (0, 0));
    assert_eq!(strtol(b"12345678901234567", 10), (12345678901234567, 17));
    assert_eq!(strtol(b"zz", 36), (1295, 2));
    assert_eq!(strtoul(b"-1", 10), (u64::MAX, 2));
    assert_eq!(strtoul(b"99999999999999999999", 10), (u64::MAX, 20));
    assert_eq!(atoi(b" 42x"), 42);
    assert_eq!(atoi(b"4294967297"), 1);
    assert_eq!(atoi(b"x"), 0);
    assert_eq!(atol(b"-5000000000"), -5000000000);
}

#[test]
fn strtod_cases() {
    assert_eq!(strtod(b"1.5e2x"), (150.0, 5));
    assert_eq!(strtod(b" .25"), (0.25, 4));
    assert_eq!(strtod(b"x"), (0.0, 0));
    assert_eq!(strtod(b"0x10").0, 16.0);
    assert_eq!(strtod(b"0x1.8p1").0, 3.0);
    assert_eq!(strtod(b"0x"), (0.0, 1));
    assert_eq!(strtod(b"1e"), (1.0, 1));
    assert_eq!(strtod(b"1e+"), (1.0, 1));
    assert_eq!(strtod(b"-Infinity!"), (f64::NEG_INFINITY, 9));
    assert_eq!(strtod(b"inf"), (f64::INFINITY, 3));
    assert_eq!(strtod(b"infin").1, 3);
    let (v, e) = strtod(b"nan(12)x");
    assert!(v.is_nan() && e == 7);
    let (v, e) = strtod(b"-nan(");
    assert!(v.is_nan() && v.is_sign_negative() && e == 4);
    assert_eq!(strtod(&b"a 7."[1..]), (7.0, 3));
    assert_eq!(strtod(b"0.1").0, 0.1);
    assert_eq!(strtod(b"1e400").0, f64::INFINITY);
    assert_eq!(strtod(b"1e-400").0, 0.0);
    assert_eq!(strtod(b"2.4703282292062328e-324").0, 5e-324);
    assert_eq!(strtod(b"2.4703282292062327e-324").0, 0.0);
    assert_eq!(strtod(b"1e99999999999999999999999").0, f64::INFINITY);
    assert_eq!(strtod(b"0x1p-1075").0, 0.0);
    assert_eq!(strtod(b"0x1.0000000000001p-1075").0, 5e-324);
    assert_eq!(strtod(b"0x1.fffffffffffff8p1023").0, f64::INFINITY);
    assert_eq!(atof(b" -2.5e1q"), -25.0);
}

#[test]
fn sscanf_cases() {
    let mut x = -1.0f64;
    assert_eq!(csscanf!(b"", b"%lf", &mut x), -1);
    assert_eq!(csscanf!(b"   ", b"%lf", &mut x), -1);
    assert_eq!(csscanf!(b"x", b"%lf", &mut x), 0);
    assert_eq!(x, -1.0); // untouched
    let (mut a, mut b, mut c, mut d) = (0i64, Vec::new(), 0i32, 0i32);
    let mut e = 0i32;
    assert_eq!(
        csscanf!(
            b"12 N 1 2 3",
            b"%lld%s%d%d%d",
            &mut a,
            &mut b,
            &mut c,
            &mut d,
            &mut e
        ),
        5
    );
    assert_eq!((a, b.as_slice(), c, d, e), (12, &b"N"[..], 1, 2, 3));
    let (mut d1, mut m1, mut y1) = (0i32, 0i32, 0i32);
    assert_eq!(
        csscanf!(b"01.02.85", b"%d%*c%d%*c%d", &mut d1, &mut m1, &mut y1),
        3
    );
    assert_eq!((d1, m1, y1), (1, 2, 85));
    let mut v = [0i32; 6];
    {
        let [v0, v1, v2, v3, v4, v5] = &mut v;
        assert_eq!(
            csscanf!(
                b"[10:20:30 1/2/2000]",
                b"[%d:%d:%d %d/%d/%d",
                v0,
                v1,
                v2,
                v3,
                v4,
                v5
            ),
            6
        );
    }
    assert_eq!(v, [10, 20, 30, 1, 2, 2000]);
    let (mut l1, mut l2, mut ch) = (0i64, 0i64, 0u8);
    assert_eq!(
        csscanf!(b"1,2,\"Q", b"%lld,%lld,\"%c", &mut l1, &mut l2, &mut ch),
        3
    );
    assert_eq!((l1, l2, ch), (1, 2, b'Q'));
    let (mut s1, mut s2) = (Vec::new(), Vec::new());
    assert_eq!(csscanf!(b"abcdef", b"%3s%s", &mut s1, &mut s2), 2);
    assert_eq!((s1.as_slice(), s2.as_slice()), (&b"abc"[..], &b"def"[..]));
    let (mut h, mut i1, mut i2) = (0i32, 0i32, 0i32);
    assert_eq!(
        csscanf!(b"ff 0x10 017", b"%x %i %i", &mut h, &mut i1, &mut i2),
        3
    );
    assert_eq!((h, i1, i2), (255, 16, 15));
    let mut n1 = 0i32;
    let mut n2 = 77i32;
    assert_eq!(csscanf!(b"5", b"%d%d", &mut n1, &mut n2), 1);
    assert_eq!(n2, 77);
    assert_eq!(csscanf!(b"", b"x%d", &mut n1), -1);
    assert_eq!(csscanf!(b"12", b"%*d%d", &mut n1), -1);
    assert_eq!(csscanf!(b"12 x", b"%*d%d", &mut n1), 0);
    // glibc consumes an incomplete exponent.
    let mut rest = Vec::new();
    assert_eq!(csscanf!(b"100ergs", b"%lf%s", &mut x, &mut rest), 2);
    assert_eq!((x, rest.as_slice()), (100.0, &b"rgs"[..]));
    assert_eq!(csscanf!(b"99999999999", b"%d", &mut n1), 1);
    assert_eq!(n1, 1215752191);
    let mut u = 0u32;
    assert_eq!(csscanf!(b"-1", b"%u", &mut u), 1);
    assert_eq!(u, u32::MAX);
    // Explicit ScanArg form.
    let mut z = 0i32;
    assert_eq!(sscanf(b" 7", b"%d", &mut [ScanArg::I32(&mut z)]), 1);
    assert_eq!(z, 7);
}

#[test]
fn strtok_cases() {
    let mut t = Strtok::new(b"  a  b\tc\r\n");
    let d = b" \t\r\n";
    assert_eq!(t.next(d), Some(&b"a"[..]));
    assert_eq!(t.next(d), Some(&b"b"[..]));
    assert_eq!(t.next(d), Some(&b"c"[..]));
    assert_eq!(t.next(d), None);
    assert_eq!(t.next(d), None);
    let mut t = Strtok::new(b"x 0 MLII lead\r\n");
    t.next(b" ");
    t.next(b" ");
    assert_eq!(t.next(b"\r\n"), Some(&b"MLII lead"[..]));
    let mut t = Strtok::new(b"abc");
    assert_eq!(t.next(b" "), Some(&b"abc"[..]));
    assert_eq!(t.next(b" "), None);
    let mut t = Strtok::new(b"   ");
    assert_eq!(t.next(b" "), None);
    let mut t = Strtok::new(b"a b");
    t.next(b" ");
    assert_eq!(t.rest(), b"b");
}

#[test]
fn fgets_cases() {
    let v: Vec<&[u8]> = fgets_lines(b"abc\ndefgh", 4).collect();
    assert_eq!(v, vec![&b"abc"[..], b"\n", b"def", b"gh"]);
    let v: Vec<&[u8]> = fgets_lines(b"a\nbc\n", 100).collect();
    assert_eq!(v, vec![&b"a\n"[..], b"bc\n"]);
    assert_eq!(fgets_lines(b"", 10).count(), 0);
    let v: Vec<&[u8]> = fgets_lines(b"\n\nx", 10).collect();
    assert_eq!(v, vec![&b"\n"[..], b"\n", b"x"]);
}

#[test]
fn glibc_rand() {
    // Values from glibc (seed: first three values, sum of the first 100000).
    let cases: [(u32, [i32; 3], i64); 6] = [
        (0, [1804289383, 846930886, 1681692777], 107345864261546),
        (1, [1804289383, 846930886, 1681692777], 107345864261546),
        (42, [71876166, 708592740, 1483128881], 107493762466152),
        (12345, [383100999, 858300821, 357768173], 107265696684802),
        (
            4294967295,
            [254925627, 1205188300, 366127624],
            107479458668323,
        ),
        (
            2147483648,
            [1336741213, 1210407648, 1447044896],
            107447831310714,
        ),
    ];
    for (seed, first, sum) in cases {
        let mut r = GlibcRand::new(seed);
        let mut total = 0i64;
        for i in 0..100000 {
            let v = r.rand();
            if i < 3 {
                assert_eq!(v, first[i], "seed {seed}");
            }
            total += v as i64;
        }
        assert_eq!(total, sum, "seed {seed}");
    }
    assert_eq!(GlibcRand::default().rand(), 1804289383);
    cstd::srand(42);
    assert_eq!(cstd::rand(), 71876166);
    assert_eq!(cstd::RAND_MAX, 2147483647);
}

#[test]
fn prog_name() {
    assert_eq!(cstd::prog_name(b"/usr/bin/rdsamp"), b"rdsamp");
    assert_eq!(cstd::prog_name(b"rdsamp"), b"rdsamp");
}

/// `%[...]` scan sets: expected results from glibc 2.x (`sscanf(input,
/// fmt "%n", buf, &n)` with `buf = "?"` and `n = -1` initially).
#[test]
fn sscanf_scansets() {
    // (format, input, return value, buffer, %n)
    type Case = (&'static [u8], &'static [u8], i32, &'static [u8], i32);
    let cases: &[Case] = &[
        (b"%[0-9]%n", b"123abc", 1, b"123", 3),
        (b"%[^0-9]%n", b"abc123", 1, b"abc", 3),
        (b"%[]abc]%n", b"]a]bx", 1, b"]a]b", 4),
        (b"%[^]]%n", b"abc]def", 1, b"abc", 3),
        (b"%[-a]%n", b"-a-b", 1, b"-a-", 3),
        (b"%[a-]%n", b"a--ab", 1, b"a--a", 4),
        (b"%[a-c-e]%n", b"abcdefg", 1, b"abcde", 5),
        (b"%[z-a]%n", b"z-ab", 1, b"z-a", 3),
        (b"%[^-0-9]%n", b"abc-1", 1, b"abc", 3),
        (b"%[]-a]%n", b"]^_`abc", 1, b"]^_`a", 5),
        (b"%[0-9%n", b"123", 0, b"?", -1),
        (b"%3[0-9]%n", b"12345", 1, b"123", 3),
        (b"%[^\n]%n", b"line one\nx", 1, b"line one", 8),
        (b"%[a-a]%n", b"aab", 1, b"aa", 2),
        (b"%[^]-]%n", b"ab]c", 1, b"ab", 2),
        (b"%[0-9]%n", b"abc", 0, b"?", -1),
        (b"%[0-9]%n", b"", -1, b"?", -1),
        (b"%[]]%n", b"]]x", 1, b"]]", 2),
        (b"%[^]%n", b"abc", 0, b"?", -1),
        (b"%[-]%n", b"--x", 1, b"--", 2),
        (b"%[^-]%n", b"ab-c", 1, b"ab", 2),
        (b"%[a-z0-9_]%n", b"ab_9.x", 1, b"ab_9", 4),
        (b"%[A-Fa-f0-9]x%n", b"1aFx", 1, b"1aF", 4),
        (b"%*[a-c]%[d-f]%n", b"abcdef", 1, b"def", 6),
        (b"%[0-9", b"", 0, b"?", -1),
        (b"x%[0-9", b"x", 0, b"?", -1),
    ];
    for &(fmt, input, ret, buf, n) in cases {
        let mut b = b"?".to_vec();
        let mut nn = -1i32;
        let r = csscanf!(input, fmt, &mut b, &mut nn);
        assert_eq!(
            (r, b.as_slice(), nn),
            (ret, buf, n),
            "{:?}",
            String::from_utf8_lossy(fmt)
        );
    }
}

/// `fixed_fast` gives the same text as `sprintf("%W.Pf")` whenever it
/// applies.
#[test]
fn fixed_fast_matches_sprintf() {
    let mut g = cstd::GlibcRand::new(7);
    let mut values = vec![
        0.0,
        -0.0,
        0.5,
        -0.5,
        1.5,
        2.5,
        0.125,
        0.0005,
        -0.0004,
        1e-300,
        5e-324,
        123456.789,
        1e15,
        2e19,
        -2048.0,
        4096.0 / 200.0,
        0.1,
        0.7,
        2f64.powi(40),
        2f64.powi(41),
    ];
    for _ in 0..2000 {
        let a = f64::from(g.rand() - cstd::RAND_MAX / 2);
        let b = f64::from(g.rand() % 1000 + 1);
        values.push(a / b);
    }
    let mut used = 0;
    for &x in &values {
        for prec in 0..=10u32 {
            for width in [0usize, 7, 15] {
                let mut buf = Vec::new();
                if cstd::fixed_fast(&mut buf, x, width, prec) {
                    used += 1;
                    let fmt = format!("%{width}.{prec}f");
                    assert_eq!(buf, cformat!(fmt.as_bytes(), x), "{x} {fmt}");
                }
            }
        }
    }
    assert!(used > 50_000);
}
