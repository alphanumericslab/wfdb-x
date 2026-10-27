# Tests of the WFDB-x divergence "no built-in sampling frequency, gain, ADC
# resolution or units"
# (docs/DIVERGENCES.md): the library functions (t_nodefaults() of
# tests/reference/api_expect.c, whose expected values were produced by the
# C library with tests/reference/divergences.patch applied), and the rules
# of the high-level API (read_record, write_record, read_annotations).
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

if (.mode == "source") {
  datasrc <- file.path(dirname(dirname(.rdir)), "tests", "data")
  old <- getwd()
  oldpath <- Sys.getenv("WFDB", unset = NA)
  d <- tempfile("wfdbx-nodef")
  dir.create(d)
  file.copy(list.files(datasrc, full.names = TRUE, all.files = FALSE), d, recursive = TRUE)
  setwd(d)
  on.exit({
    wfdbquit()
    wfdbverbose()
    setwd(old)
    if (is.na(oldpath)) Sys.unsetenv("WFDB") else Sys.setenv(WFDB = oldpath)
    unlink(d, recursive = TRUE)
    wfdbio_reset()
    sig_reset()
  }, add = TRUE)
  wfdbquit()
  setwfdb(".")
  isig <- function(record) isigopen(record, 8)$nsig
  # the message of the error raised by expr ("" if none)
  errmsg <- function(expr) tryCatch({
    expr
    ""
  }, error = function(e) conditionMessage(e))

  # ---- t_nodefaults: wfdbx_time_needs_freq (in api_expect.c, the counter
  # frequency set by t_counter is still defined)
  setcfreq(10)
  ts <- c("s10", "e", "i", "o", "c10", "f3", "10", "1:0", "[10:00:00]", " s5", "")
  expect_equal(vapply(ts, wfdbx_time_needs_freq, 0L, USE.NAMES = FALSE),
               c(0L, 0L, 0L, 0L, 1L, 1L, 1L, 1L, 1L, 0L, 1L), "wfdbx_time_needs_freq")
  setcfreq(0)
  expect_equal(wfdbx_time_needs_freq("c10"), 0L, "wfdbx_time_needs_freq c10 (no cfreq)")
  expect_equal(wfdbx_time_needs_freq("\t\r\ni"), 0L, "wfdbx_time_needs_freq leading space")

  # no input record: no sampling frequency
  wfdbquiet()
  expect_equal(strtim("1:0"), 0, "strtim 1:0 (no frequency)")
  expect_equal(wfdberror(), "strtim: sampling frequency is not specified\n", "strtim error")
  expect_equal(strtim("s10"), 10, "strtim s10 (no frequency)")
  expect_equal(timstr(360), "s360", "timstr 360 (no frequency)")
  expect_equal(wfdberror(), "timstr: sampling frequency is not specified\n", "timstr error")
  expect_equal(mstimstr(-360), "s360", "mstimstr -360 (no frequency)")
  expect_equal(wfdberror(), "mstimstr: sampling frequency is not specified\n", "mstimstr error")

  # a header without a sampling frequency
  writeLines(c("nf 2", "100s.dat 212 200 11 1024 995 21537 0 MLII",
               "100s.dat 212 200 11 1024 1011 -3962 0 V5"), "nf.hea")
  expect_equal(isig("nf"), 2, "isigopen nf")
  expect_equal(sampfreq(NULL), 0, "sampfreq nf")
  expect_equal(getifreq(), 0, "getifreq nf")
  expect_equal(setifreq(100), -1, "setifreq 100 (nf)")
  expect_equal(wfdberror(), "setifreq: sampling frequency is not specified\n", "setifreq error")
  expect_equal(strtim("2"), 0, "strtim 2 (nf)")
  expect_equal(strtim("e"), 0, "strtim e (nf)")
  expect_equal(mstimstr(100), "s100", "mstimstr 100 (nf)")
  wfdbquit()
  # a frequency set by the caller applies
  expect_equal(setsampfreq(500), 0, "setsampfreq 500")
  expect_equal(isig("nf"), 2, "isigopen nf after setsampfreq")
  expect_equal(sampfreq(NULL), 500, "sampfreq 500")
  expect_equal(strtim("2"), 1000, "strtim 2")
  expect_equal(mstimstr(100), "    0:00.200", "mstimstr 100")
  wfdbquit()
  expect_equal(sampfreq("nf"), 0, "sampfreq nf (record)")
  wfdbquit()
  # uncalibrated signals (record null) and invalid signal numbers
  isig("null")
  expect_equal(aduphys(0, 100), NaN, "aduphys 0 100 (uncalibrated)")
  expect_equal(wfdberror(), "aduphys: signal 0 is uncalibrated\n", "aduphys error")
  expect_equal(physadu(0, 1.0), -32768, "physadu 0 1.0 (uncalibrated)")
  expect_equal(wfdberror(), "physadu: signal 0 is uncalibrated\n", "physadu error")
  expect_equal(adumuv(1, 100), -32768, "adumuv 1 100 (uncalibrated)")
  expect_equal(muvadu(1, 100), -32768, "muvadu 1 100 (uncalibrated)")
  expect_equal(wfdberror(), "muvadu: signal 1 is uncalibrated\n", "muvadu error")
  wfdbquit()
  isig("100s")
  expect_equal(aduphys(0, 1124), 0.5, "aduphys 0 1124")
  expect_equal(physadu(1, -0.5), 924, "physadu 1 -0.5")
  expect_equal(adumuv(0, 100), 500, "adumuv 0 100")
  expect_equal(muvadu(0, 1000), 200, "muvadu 0 1000")
  expect_equal(aduphys(5, 100), NaN, "aduphys 5 100 (invalid signal)")
  expect_equal(wfdberror(), "aduphys: invalid signal number 5\n", "aduphys invalid error")
  expect_equal(physadu(5, 1.0), -32768, "physadu 5 1.0 (invalid signal)")
  expect_equal(adumuv(2, 100), -32768, "adumuv 2 100 (invalid signal)")
  expect_equal(muvadu(2, 100), -32768, "muvadu 2 100 (invalid signal)")
  expect_equal(wfdberror(), "muvadu: invalid signal number 2\n", "muvadu invalid error")
  wfdbquit()
  # no default ADC resolution: 0 if the header does not give it; units NULL
  writeLines(c("nr 2 360 21600", "100s.dat 212 200", "100s.dat 212 200"), "nr.hea")
  r <- isigopen("nr", 8)
  expect_equal(r$nsig, 2, "isigopen nr")
  expect_equal(c(r$si[[1]]$adcres, r$si[[2]]$adcres), c(0, 0), "nr adcres")
  expect_equal(r$si[[1]]$units, NULL, "nr units")
  wfdbquit()
  r <- isigopen("100s", 8)
  expect_equal(c(r$si[[1]]$adcres, r$si[[2]]$adcres), c(11, 11), "100s adcres")
  wfdbquit()
  wfdbverbose()

  # ---- write_record: gains, ADC resolutions and units (of calibrated
  # signals) required, fs > 0, gain 0 only for ADC units
  x <- matrix(c(1, 2, 3, -4, -5, -6), 3, 2)
  expect_equal(errmsg(write_record("hl", x, 100)), "gains must be specified",
               "write_record without gains")
  expect_equal(errmsg(write_record("hl", x, 100, gains = NULL)), "gains must be specified",
               "write_record gains NULL")
  check(nzchar(errmsg(write_record("hl", x, 0, gains = 200, adcres = 16, units = "mV"))),
        "write_record fs 0")
  check(nzchar(errmsg(write_record("hl", x, gains = 200, adcres = 16, units = "mV"))),
        "write_record without fs")
  expect_equal(errmsg(write_record("hl", x, 100, gains = 200, units = "mV")),
               "ADC resolution(s) must be specified", "write_record without adcres")
  expect_equal(errmsg(write_record("hl", x, 100, gains = 200, adcres = c(16, 0), units = "mV")),
               "ADC resolution(s) must be specified", "write_record adcres 0")
  expect_equal(errmsg(write_record("hl", x, 100, gains = 200, adcres = 16)),
               "units must be specified", "write_record without units")
  expect_equal(errmsg(write_record("hl", x, 100, gains = 200, adcres = 16,
                                   units = list("mV", NULL))),
               "units must be specified", "write_record units missing for signal 1")
  expect_equal(errmsg(write_record("hl", x, 100, gains = 200, adcres = 16, units = c("mV", ""))),
               "units must be specified", "write_record empty units")
  expect_equal(errmsg(write_record("hl", x / 100, 100, gains = c(100, 0), adcres = 16,
                                   units = "mV", physical = TRUE)),
               "signal 1 is uncalibrated", "write_record physical uncalibrated")
  write_record("hl", x, 100, gains = c(100, 0), adcres = 12, units = list("mV", NULL))
  r <- read_record("hl")
  check(r$fs == 100 && identical(r$gains, c(100, 0)) && all(r$signals == x),
        "write_record uncalibrated ADC units")
  check(identical(r$units, list("mV", NULL)) && r$siginfo[[1]]$adcres == 12 &&
        r$siginfo[[2]]$adcres == 12, "write_record units (none for gain 0) and adcres")
  r <- read_record("nr", sampto = 2)
  check(r$siginfo[[1]]$adcres == 0 && is.null(r$units[[1]]),
        "read_record: unspecified ADC resolution 0, units NULL")
  expect_equal(errmsg(read_record("hl", physical = TRUE)),
               "signal 1 of record hl is uncalibrated", "read_record physical uncalibrated")
  r <- read_record("hl", channels = 0, physical = TRUE)
  check(isTRUE(all.equal(r$signals[, 1], x[, 1] / 100)), "read_record physical calibrated")

  # ---- read_record: fs 0 for a header without a frequency
  r <- read_record("nf", sampto = 5)
  check(r$fs == 0 && nrow(r$signals) == 5, "read_record nf")
  expect_equal(r$base_time, NULL, "read_record nf: no base_time")
  r <- read_record("nf", sampfrom = "s2", sampto = "s4")
  check(r$sampfrom == 2 && nrow(r$signals) == 2, "read_record nf sample-number strings")
  expect_equal(errmsg(read_record("nf", sampto = "0:1")),
               "sampling frequency of record nf is not specified", "read_record nf time string")
  expect_equal(errmsg(read_record("nf", sampfrom = "1")),
               "sampling frequency of record nf is not specified", "read_record nf sampfrom")
  r <- read_record("nf", sampto = 3, physical = TRUE)
  check(isTRUE(all.equal(r$signals[1, ], c(-0.145, -0.065))), "read_record nf physical")

  # ---- read_annotations: optional sampling frequency
  file.copy("100s.atr", "nf.atr")
  a <- read_annotations("nf", "atr")
  check(nrow(a) > 0 && attr(a, "fs") == 0, "read_annotations nf: fs 0")
  expect_equal(errmsg(read_annotations("nf", "atr", sampto = "0:10")),
               "sampling frequency of record nf is not specified",
               "read_annotations nf time string")
  b <- read_annotations("nf", "atr", sampto = "s3600")
  check(nrow(b) > 0 && all(b$sample < 3600), "read_annotations nf sample-number string")
  b <- read_annotations("nf", "atr", sampto = "0:10", fs = 360)
  check(attr(b, "fs") == 360 && nrow(b) == sum(a$sample < 3600), "read_annotations nf fs = 360")
  b <- read_annotations("100s", "atr", sampto = "0:10", fs = 1000)
  check(attr(b, "fs") == 360 && nrow(b) == sum(a$sample < 3600),
        "read_annotations fs ignored when the header gives one")
  file.copy("100s.atr", "nohea.atr")
  wfdbquiet()
  a2 <- read_annotations("nohea", "atr")
  b <- read_annotations("nohea", "atr", sampto = "0:10", fs = 360)
  wfdbverbose()
  check(attr(a2, "fs") == 0 && nrow(a2) == nrow(a), "read_annotations without header")
  check(attr(b, "fs") == 360 && nrow(b) == sum(a$sample < 3600),
        "read_annotations without header, fs = 360")
  check(nzchar(errmsg(read_annotations("nf", "atr", fs = 0))), "read_annotations fs 0")
}
