# Tests of the block formatting of rdsamp and of the vectorized time
# strings: each block of lines (.rdsamp_lines of the columns made by
# .rdsamp_formatter, .rdsamp_samplenum, .rdsamp_fixedpoint and
# .rdsamp_timecols) is compared with the same lines formatted directly with
# csprintf_v and pasted, on random data (invalid samples, narrow and wide
# ranges, values of different widths, times near ties of the rounding);
# the time strings given as pieces (.fmstimstr_v0) with those given as
# strings and with mstimstr.
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

# (lines pasted from character columns: the reference)
ref_lines <- function(...) charToRaw(paste0(..., "\n", collapse = ""))
lines_of <- function(cols) .rdsamp_lines(cols)

# ---- sample columns: tables kept between blocks, extended, or bypassed
set.seed(1)
fmts <- list(list("\t%7d", 0, 1), list(",%d", 0, 1), list("\t%7.3f", 12, 200),
             list("\t%15.8f", -3, 0.37), list(",%.3f", 0, 1e-3))
for (fm in fmts) {
  vfmt <- fm[[1L]]
  b <- fm[[2L]]
  g <- fm[[3L]]
  physical <- !grepl("d$", vfmt)
  invalid <- if (!physical) csprintf_v(vfmt, WFDB_INVALID_SAMPLE) else
    if (startsWith(vfmt, ",")) ",-" else "\t      -"
  f <- .rdsamp_formatter(if (physical) function(x) csprintf_v(vfmt, (x - b) / g) else
    function(x) csprintf_v(vfmt, x), invalid)
  ok <- TRUE
  for (blk in 1:12) {
    m <- base::sample(c(1, 7, 500, 5000), 1)
    span <- base::sample(c(10, 4000, 70000, 3e6), 1)
    x <- floor(runif(m, -span, span)) + base::sample(c(0, 1e5), 1)
    if (blk %% 3 == 0) x[runif(m) < 0.1] <- WFDB_INVALID_SAMPLE
    if (blk == 6) x[] <- WFDB_INVALID_SAMPLE
    ref <- if (physical) csprintf_v(vfmt, (x - b) / g) else csprintf_v(vfmt, x)
    ref[x == WFDB_INVALID_SAMPLE] <- invalid
    ok <- ok && identical(lines_of(list(f(x))), ref_lines(ref))
  }
  check(ok, paste(".rdsamp_formatter", vfmt))
}

# ---- sample numbers
ok <- TRUE
for (from in c(0, 1, 990, 999, 1000, 65536, 2147483000, 2^40 - 5)) {
  for (m in c(1, 20, 3000)) {
    tv <- from + seq_len(m) - 1
    for (tfmt in c("%15d", "%d"))
      ok <- ok && identical(lines_of(.rdsamp_samplenum(tv, tfmt)), ref_lines(csprintf_v(tfmt, tv)))
  }
}
check(ok, ".rdsamp_samplenum")

# ---- times in seconds, minutes, hours (decimals), with ties of the
# rounding (16 Hz: 1/16 s = 0.0625 s)
ok <- TRUE
for (freq in c(360, 16, 0.37, 333.333, 1000, 8000 / 60, 250 * 3600, 1e6)) {
  for (from in c(0, 1, 12345, 1e9)) {
    tv <- from + seq_len(2000) - 1
    for (tfmt in c("%15.3f", "%.3f", "%15.5f", "%.5f", "%15.7f", "%.7f"))
      ok <- ok && identical(lines_of(.rdsamp_fixedpoint(tv / freq, tfmt)),
                            ref_lines(csprintf_v(tfmt, tv / freq)))
  }
}
check(ok, ".rdsamp_fixedpoint")

# ---- columns together (time, samples), as rdsamp writes them
x1 <- floor(runif(3000, -2048, 2048))
x2 <- floor(runif(3000, -40000, 40000))
x2[c(1, 50, 3000)] <- WFDB_INVALID_SAMPLE
f1 <- .rdsamp_formatter(function(x) csprintf_v(",%.3f", x / 200), ",-")
f2 <- .rdsamp_formatter(function(x) csprintf_v(",%.3f", x / 200), ",-")
tv <- 5000 + seq_len(3000) - 1
r2 <- csprintf_v(",%.3f", x2 / 200)
r2[x2 == WFDB_INVALID_SAMPLE] <- ",-"
check(identical(lines_of(c(.rdsamp_fixedpoint(tv / 360, "%.3f"), list(f1(x1), f2(x2)))),
                ref_lines(csprintf_v("%.3f", tv / 360), csprintf_v(",%.3f", x1 / 200), r2)),
      "rdsamp columns together")

# ---- time strings as pieces, and as rdsamp's columns
if (.mode == "source") {
  on.exit({
    wfdbquit()
    sig_reset()
  }, add = TRUE)
  wfdbquit()
  sts <- function() {
    st <- .sig
    list(st$time_string, st$date_string, st$pdays)
  }
  for (bt in list(NULL, "23:59:30.250", "23:50:00 28/02/2000")) {
    for (f in c(360, 0.37, 1000)) {
      sig_reset()
      setsampfreq(f)
      if (!is.null(bt)) setbasetime(bt)
      tf <- .tfreq()
      for (t in list(seq_len(5000) - 1, 1e6 + seq_len(3000), c(5, 1e7, 3e8))) {
        for (sg in c(1, -1)) {
          if (sg < 0 && is.null(bt)) next
          tt <- sg * t
          a <- .fmstimstr_v0(tt, tf)
          sa <- sts()
          p <- .fmstimstr_v0(tt, tf, pieces = TRUE)
          lab <- sprintf("time strings, base %s, %g Hz, sign %d", bt %||% "none", f, sg)
          check(identical(a$s, vapply(tt, mstimstr, "")), paste(lab, "= mstimstr"))
          if (is.null(p$p)) next
          check(identical(do.call(paste0, lapply(p$p, function(q) q$tab[q$i])), a$s) &&
                  identical(p$d, a$d) && identical(sts(), sa), paste(lab, "pieces"))
          check(identical(lines_of(.rdsamp_timecols(p$p, TRUE, FALSE)),
                          ref_lines(paste0("'", sub("^ +", "", a$s), "'"))), paste(lab, "csv"))
          tc <- .rdsamp_timecols(p$p, FALSE, TRUE)
          if (!is.null(tc))
            check(identical(lines_of(tc), ref_lines(sprintf("%15s", a$s))), paste(lab, "%15s"))
        }
      }
    }
  }
}
