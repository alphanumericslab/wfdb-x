# Tests of csprintf() (glibc printf semantics); cases from
# matlab/tests/test_csprintf.m, checked against glibc.
#
# Part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

cases <- list(
  list("42", "%d", 42),
  list("-7", "%d", -7),
  list("   42|-42  |-0042", "%5d|%-5d|%05d", 42, -42, -42),
  list("+5  5 +0", "%+d % d %+d", 5, 5, 0),
  list("-005|     007", "%.3d|%8.3d", -5, 7),
  list("1152921504606846976 -3 123456789012", "%ld %lld %li", 2^60, -3, 123456789012),
  list("4294967295 7", "%u %u", -1, 7),
  list("18446744073709551615", "%lu", -1),
  list("ff FF 0xff 10 010", "%x %X %#x %o %#o", 255, 255, 255, 8, 8),
  list("ffffffff fffffffe", "%x %08x", -1, -2),
  list("4464 65535 -56", "%hd %hu %hhd", 70000, -1, 200),
  list("AbA", "%c%c%c", 65, "b", 321),
  list("[  x|y  ]", "[%3c|%-3c]", "x", "y"),
  list("abc|       abc|abc       |ab|    a", "%s|%10s|%-10s|%.2s|%5.1s", "abc", "abc", "abc", "abc", "abc"),
  list("[]", "[%s]", ""),
  list("0.0001 1e-05 123456 1.23457e+06 -0", "%g %g %g %g %g", 0.0001, 0.00001, 123456, 1234567, -0),
  list("100000 1e+15 0.3", "%g %g %g", 100000, 1e15, 0.1 + 0.2),
  list("0.1 0.333333333333333 0.10000000000000001", "%.12g %.15g %.17g", 0.1, 1/3, 0.1),
  list("1.00000 2.00 1E-10", "%#g %#.3g %G", 1, 2, 1e-10),
  list("1.500000 0 2 2 0.1", "%f %.0f %.0f %.0f %.1f", 1.5, 0.5, 1.5, 2.5, 0.05),
  list("2.001 1.00    -3.1416 2.50      |", "%.3f %.2f %10.4f %-10.2f|", 2.0005, 1.005, -3.14159, 2.5),
  list("1.234568e+04 1.23e-04 1.000000E+100 2e+10", "%e %.2e %E %.0e", 12345.678, 0.000123456, 1e100, 2.5e10),
  list(paste0("1000000000000000052504760255204420248704468581108159154915854115511802457988908195786371375080447864043704443832883878176942523235360430575644792184786706982848387200926575803737830233794788090059368953234970799945081119038967640880074652742780142494579258788820056842838115669472196386865459400540160.000000",
              " 4.940656e-324 1.79769e+308"), "%f %e %g", 1e300, 5e-324, 1.7976931348623157e308),
  list("+1.000  1.000 -001.500", "%+.3f % .3f %08.3f", 1, 1, -1.5),
  list("    42|42    |3.14|   2.500", "%*d|%-*d|%.*f|%*.*f", 6, 42, 6, 42, 2, 3.14159, 8, 3, 2.5),
  list("42    |", "%*d|", -6, 42),
  list("100% 5%", "100%% %d%%", 5),
  list("tab\there\n", "tab\there\n"),
  list("99.50%\tx\n", "%5.2f%%\t%s\n", 99.5, "x"),
  list("360 0.002777777778", "%.10g %.10g", 360, 1/360),
  list("1.235 -0.000000", "%.3lf %lf", 1.23456, -0),
  list("nan", "%g", NaN),
  list("-nan", "%g", -NaN),
  list("-nan", "%g", 0/0),
  list("inf", "%f", Inf),
  list("-inf", "%f", -Inf),
  list("  inf|", "%5.2f|", Inf),
  list("-inf  |", "%-6g|", -Inf),
  list("+inf", "%+g", Inf),
  list(" nan", "% g", NaN),
  list("INF", "%E", Inf),
  list("NAN", "%G", NaN),
  list("     inf", "%08.3f", Inf),
  list("INF", "%F", Inf),
  list("1.500000", "%F", 1.5),
  list("2", "%d", 2.7),
  list("-2", "%d", -2.7),
  list("-2147483648", "%d", NaN),
  list("-9223372036854775808", "%ld", NaN),
  list("(null)", "%s", NULL),
  list("[]", "[%.3s]", NULL),
  list("1", "%d", TRUE),
  list("-5", "%d", -5L),
  list("x", "%c", "xyz"),
  list("ab'", "%s", "ab'"),
  list("9223372036854775808", "%llu", 2^63),
  list("2147483648 -2147483648 80000000", "%u %d %x", 2147483648, -2147483648, 2147483648),
  list("    1e+20|", "%9.0e|", 1e20),
  list("+00042", "%+06d", 42),
  list("[%y][%]", "[%y][%5%]"),
  list("37777777777", "%o", -1),
  list("1777777777777777777777", "%lo", -1),
  list("0X00FF", "%#06X", 255),
  list("      0x1234567890", "%#18lx", 78187493520),
  list("12345678901234567168", "%lu", 12345678901234567890),
  list("-1234567890123", "%d", -1234567890123),
  list("  -00001234567890123", "%20.17ld", -1234567890123),
  list("", "%.0d", 0),
  list("0", "%#.0o", 0),
  list("-0001.5", "%07.1f", -1.5))

for (k in seq_along(cases)) {
  c <- cases[[k]]
  for (rep in 1:2) {        # the second call uses the cached format
    got <- do.call(csprintf, c[-1L])
    expect_equal(rawToChar(got), c[[1L]], paste0("csprintf(\"", c[[2L]], "\") case ", k))
  }
}

f <- "%d|%5s|%g|%x|%c\n"
expect_equal(rawToChar(csprintf(f, 12, "ab", 0.5, 255, "q")), "12|   ab|0.5|ff|q\n", "fast path")
expect_equal(rawToChar(csprintf(f, 12, "ab", 0.5, 255, 113)), "12|   ab|0.5|ff|q\n", "numeric %c")
expect_equal(rawToChar(csprintf(f, 12, "", NaN, -1, "q")), "12|     |nan|ffffffff|q\n", "general path")
expect_equal(rawToChar(csprintf("no conversions")), "no conversions", "plain text")
expect_equal(csprintf(""), raw(0), "empty format")
expect_equal(csprintf("%c", 0), as.raw(0), "%c of NUL")
expect_equal(csprintf("%s|", as.raw(c(0x41, 0xff, 0, 0x42))), as.raw(c(0x41, 0xff, 0x7c)), "%s raw stops at NUL")
expect_equal(csprintf("%-4s|", as.raw(c(0xe9))), as.raw(c(0xe9, 0x20, 0x20, 0x20, 0x7c)), "%s byte width")
expect_equal(csprintf("%3s", rawToChar(as.raw(c(0xe9, 0xe8)))), as.raw(c(0x20, 0xe9, 0xe8)), "%s high bytes")

# vectorized
expect_equal(csprintf_v("%5.2f|%d\n", c(1, NaN, -Inf), 3),
             c(" 1.00|3\n", "  nan|3\n", " -inf|3\n"), "csprintf_v")
expect_equal(csprintf_v("%u %s", c(-1, 5), c("a", "b")), c("4294967295 a", "5 b"), "csprintf_v %u %s")
expect_equal(csprintf_v("%-3s|%c", c("ab", "c"), c(65, 66)), c("ab |A", "c  |B"), "csprintf_v %-3s %c")
expect_equal(csprintf_v("%d", numeric(0)), character(0), "csprintf_v empty")

# cprintf output goes to the stdout buffer
