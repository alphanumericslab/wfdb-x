# Tests of the argument checks of the high-level functions (highlevel.R,
# highlevel_annot.R): high-resolution reads that always make progress, and
# the decisions of the third review (WFDB-x): write_record and
# write_annotations check their arguments before any file is created,
# read_record takes whole sample numbers only, and every error leaves the
# library state clean (no open signals or annotators).
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

old <- getwd()
d <- tempfile("wfdbx-hl")
dir.create(d)
setwd(d)
on.exit({
  wfdbquit()
  wfdbverbose()
  setwd(old)
  unlink(d, recursive = TRUE)
  wfdbio_reset()
  sig_reset()
}, add = TRUE)
wfdbquit()

errmsg <- function(expr) tryCatch({
  expr
  ""
}, error = function(e) conditionMessage(e))
# the library state is clean: no open signals or annotators, the getvec
# mode, legacy flag and directories as before
clean <- function() {
  .sig$nisig == 0 && .sig$nosig == 0 && length(.ann$iad) == 0 &&
    length(.ann$oad) == 0 && getgvmode() == WFDB_LOWRES && !wfdbx_get_legacy() &&
    is.null(wfdbx_get_output_dir())
}
# expr fails with message msg, creates no file, and leaves the state clean
fails <- function(expr, msg, label) {
  before <- list.files(all.files = TRUE, no.. = TRUE)
  wfdbquiet()
  m <- errmsg(expr)
  wfdbverbose()
  expect_equal(m, msg, label)
  expect_equal(list.files(all.files = TRUE, no.. = TRUE), before, paste(label, ": no file"))
  check(clean(), paste(label, ": state clean"))
}

# ---- high-resolution reads always make progress (developer review,
# Finding 1): blocks of at least one alignment unit
spf <- c(1024, rep(1, 511))
write_record("mixed", matrix(0, 1, sum(spf)), 1, gains = 200, adcres = 16, units = "mV",
             samps_per_frame = spf)
t0 <- proc.time()[["elapsed"]]
r1 <- read_record("mixed", highres = TRUE, sampto = 1)
r2 <- read_record("mixed", highres = TRUE)
expect_equal(dim(r1$signals), c(1L, 512L), "highres 512 signals: sampto 1")
expect_equal(dim(r2$signals), c(1024L, 512L), "highres 512 signals: to the end")
write_record("big", matrix(1:16384, 1, 16384), 1, gains = 200, adcres = 16, units = "mV",
             samps_per_frame = 16384)
r3 <- read_record("big", highres = TRUE, sampto = 1)
r4 <- read_record("big", highres = TRUE)
expect_equal(as.vector(r3$signals), 1, "highres spf 16384: sampto 1")
expect_equal(as.vector(r4$signals), as.numeric(1:16384), "highres spf 16384: to the end")
check(proc.time()[["elapsed"]] - t0 < 60, "highres reads finish at once")
check(clean(), "highres reads: state clean")

# ---- write_record: the metadata are checked before any file is created
x <- matrix(1:6, 3, 2)
w <- function(...) {
  a <- list(record = "w", signals = x, fs = 250, gains = 200, adcres = 12, units = "mV")
  b <- list(...)
  a[names(b)] <- b
  do.call(write_record, a)
}
fails(w(fs = Inf), "fs must be finite and > 0", "write_record fs Inf")
fails(w(fs = NaN), "fs must be finite and > 0", "write_record fs NaN")
fails(w(fs = 0), "fs must be finite and > 0", "write_record fs 0")
fails(w(fs = -1, legacy = TRUE), "fs must be finite and > 0", "write_record fs -1, legacy")
fails(w(gains = NaN), "gains must be specified", "write_record gain NaN")
fails(w(gains = c(200, Inf)), "gains must be finite", "write_record gain Inf")
fails(w(gains = -Inf, legacy = TRUE), "gains must be finite", "write_record gain -Inf, legacy")
fails(w(base_time = "garbage"), "invalid base_time 'garbage'", "write_record base_time")
fails(w(record = ""), "record name must not be empty", "write_record empty name")
fails(w(signals = matrix(0, 3, 0)), "at least one signal is required", "write_record 0 signals")
fails(w(gains = c(200, 300, 400)), "gains must have one value per signal",
      "write_record 3 gains for 2 signals")
fails(w(baselines = c(5, 6, 7)), "baselines must have one value per signal",
      "write_record 3 baselines for 2 signals")
fails(w(units = c("mV", "mV", "mV")), "units must have one value per signal",
      "write_record 3 units for 2 signals")
# (a negative gain and a gain of 0 are allowed; a valid base time is kept)
w(gains = c(-200, 0), base_time = "12:30:00 01/02/2003")
h <- read_header("w")
expect_equal(h$base_time, "[12:30:00 01/02/2003]", "write_record base_time round trip")
expect_equal(vapply(h$siginfo, function(s) s$gain, 0), c(-200, 0), "write_record gains -200, 0")
check(clean(), "write_record: state clean")

# ---- write_annotations: checked before the file is created
wa <- function(...) {
  a <- list(record = "w", annotator = "a", sample = c(1, 2, 3), symbol = "N")
  b <- list(...)
  a[names(b)] <- b
  do.call(write_annotations, a)
}
tmsg <- "annotation times must be integers within the range of a 64-bit integer"
fails(wa(sample = c(1, NA, 3)), tmsg, "write_annotations time NA")
fails(wa(sample = c(1, NaN, 3)), tmsg, "write_annotations time NaN")
fails(wa(sample = c(1, Inf, 3)), tmsg, "write_annotations time Inf")
fails(wa(sample = c(1, -Inf, 3)), tmsg, "write_annotations time -Inf")
fails(wa(sample = c(1, 1.5, 3)), tmsg, "write_annotations time 1.5")
fails(wa(sample = c(1, 2^70)), tmsg, "write_annotations time 2^70")
fails(wa(sample = 2^63), tmsg, "write_annotations time 2^63")
fails(wa(symbol = NULL, code = c(1, NA, 1)), "code must not be NA, NaN or infinite",
      "write_annotations code NA")
fails(wa(subtype = c(0, NaN, 0)), "subtype must not be NA, NaN or infinite",
      "write_annotations subtype NaN")
fails(wa(chan = NA), "chan must not be NA, NaN or infinite", "write_annotations chan NA")
fails(wa(num = c(0, 0, NA)), "num must not be NA, NaN or infinite", "write_annotations num NA")
fails(wa(fs = NaN), "fs must be finite and > 0", "write_annotations fs NaN")
fails(wa(fs = Inf), "fs must be finite and > 0", "write_annotations fs Inf")
fails(wa(fs = 0), "fs must be finite and > 0", "write_annotations fs 0")
fails(wa(symbol = c("N", "V", "N"), code = c(1, 1, 1)), "symbols and codes disagree at annotation 1",
      "write_annotations symbols and codes disagree")
fails(wa(sample = c(1, NA), legacy = TRUE), tmsg, "write_annotations time NA, legacy")
# symbols and codes that agree (an empty symbol agrees with any code);
# a read_annotations -> write_annotations round trip
wa(sample = c(1, 2, 3, 4), symbol = c("N", "V", "", "N"), code = c(1, 5, 42, 1),
   subtype = c(0, 1, 2, 3), chan = 1, num = c(0, -1, 2, 3), aux = c(NA, "x", NA, "(N"), fs = 250)
a <- read_annotations("w", "a")
expect_equal(a$code, c(1, 5, 42, 1), "write_annotations symbols and codes agree")
expect_equal(a$symbol[3L], "[42]", "read_annotations: code 42 has no mnemonic")
write_annotations("w", "b", a$sample, symbol = a$symbol, code = a$code, subtype = a$subtype,
                  chan = a$chan, num = a$num, aux = a$aux, fs = attr(a, "fs"))
check(identical(readBin("w.a", "raw", 1000), readBin("w.b", "raw", 1000)),
      "read_annotations -> write_annotations round trip")
write_annotations("w", "c", a, fs = attr(a, "fs"))
check(identical(readBin("w.a", "raw", 1000), readBin("w.c", "raw", 1000)),
      "round trip of the data frame")
wa(annotator = "d", sample = c(0, 2^40))
expect_equal(read_annotations("w", "d")$sample, c(0, 2^40), "write_annotations a large time")
check(clean(), "write_annotations: state clean")

# ---- read_record: whole sample numbers; everything closed on any error
wmsg <- function(name) paste(name, "must be a whole number")
fails(read_record("w", sampfrom = 1.5), wmsg("sampfrom"), "read_record sampfrom 1.5")
fails(read_record("w", sampfrom = NaN), wmsg("sampfrom"), "read_record sampfrom NaN")
fails(read_record("w", sampfrom = NA), wmsg("sampfrom"), "read_record sampfrom NA")
fails(read_record("w", sampfrom = Inf), wmsg("sampfrom"), "read_record sampfrom Inf")
fails(read_record("w", sampto = 2.5), wmsg("sampto"), "read_record sampto 2.5")
fails(read_record("w", sampto = NaN), wmsg("sampto"), "read_record sampto NaN")
fails(read_record("w", sampto = Inf), wmsg("sampto"), "read_record sampto Inf")
fails(read_record("w", sampto = -Inf, highres = TRUE, legacy = TRUE), wmsg("sampto"),
      "read_record sampto -Inf, highres, legacy")
fails(read_record("w", sampfrom = -1), "sampfrom must not be negative", "read_record sampfrom -1")
fails(read_record("w", sampfrom = 2^64), "sampfrom is beyond the range of a 64-bit integer",
      "read_record sampfrom 2^64")
# errors after the signals are open
fails(read_record("w", channels = 5), "record w has no signal 5", "read_record channel 5")
fails(read_record("w", channels = NA, highres = TRUE), "missing value where TRUE/FALSE needed",
      "read_record channel NA")
fails(read_record("w", sampfrom = 10), "can't seek to sample 10 of record w",
      "read_record sampfrom past the end")
expect_equal(read_record("w", sampfrom = 1, sampto = 3)$signals, x[2:3, ] + 0,
             "read_record whole numbers")
expect_equal(read_record("w", sampto = NULL)$signals, x + 0, "read_record sampto NULL: to the end")
check(clean(), "read_record: state clean")
