# Tests of legacy mode (WFDB-x): the original package's behavior, on request
# (docs/DIVERGENCES.md, "Legacy mode"): the library functions (t_legacy() of
# tests/reference/api_expect.c, whose expected values were produced by the C
# library with tests/reference/divergences.patch applied), the recognition
# of --legacy by the tools, and the legacy argument of the high-level API.
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
  d <- tempfile("wfdbx-legacy")
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
  errmsg <- function(expr) tryCatch({
    expr
    ""
  }, error = function(e) conditionMessage(e))
  writeLines(c("nf 2", "100s.dat 212 200 11 1024 995 21537 0 MLII",
               "100s.dat 212 200 11 1024 1011 -3962 0 V5"), "nf.hea")
  writeLines(c("nr 2 360 21600", "100s.dat 212 200", "100s.dat 212 200"), "nr.hea")

  # ---- t_legacy
  expect_equal(wfdbx_set_legacy(TRUE), FALSE, "wfdbx_set_legacy 1")
  expect_equal(wfdbx_get_legacy(), TRUE, "wfdbx_get_legacy")
  # amplitude conversion (gain 200, baseline 1024; invalid signal numbers:
  # gain 200, baseline 0)
  isig("100s")
  expect_equal(c(adumuv(0, 200), adumuv(0, -37), adumuv(1, 1), adumuv(0, -1), adumuv(7, 100)),
               c(1000, -185, 5, -5, 500), "legacy adumuv")
  expect_equal(c(muvadu(0, 1000), muvadu(0, -333), muvadu(1, 2), muvadu(9, 1000)),
               c(200, -67, 0, 200), "legacy muvadu")
  expect_equal(aduphys(0, 1224), 1, "legacy aduphys 0 1224")
  expect_equal(aduphys(1, 900), -0.62, "legacy aduphys 1 900")
  expect_equal(aduphys(5, 300), 1.5, "legacy aduphys 5 300 (invalid signal)")
  expect_equal(c(physadu(0, 1.0), physadu(1, -0.5023), physadu(5, 1.5)), c(1224, 924, 300),
               "legacy physadu")
  expect_equal(aduphys(5, 100), 0.5, "legacy aduphys 5 100 (invalid signal)")
  expect_equal(physadu(5, 1.0), 200, "legacy physadu 5 1.0 (invalid signal)")
  expect_equal(adumuv(2, 100), 500, "legacy adumuv 2 100 (invalid signal)")
  expect_equal(muvadu(2, 100), 20, "legacy muvadu 2 100 (invalid signal)")
  wfdbquit()
  # uncalibrated signals (record null): gain 200
  isig("null")
  expect_equal(c(adumuv(0, 100), muvadu(1, 100)), c(500, 20), "legacy null adumuv")
  expect_equal(aduphys(0, 100), 0.5, "legacy null aduphys 0 100")
  expect_equal(physadu(1, 0.5), 100, "legacy null physadu 1 0.5")
  expect_equal(physadu(0, 1.0), 200, "legacy null physadu 0 1.0")
  wfdbquit()
  wfdbquiet()
  # no input record: 1 sample per second
  expect_equal(strtim("1:0"), 60, "legacy strtim 1:0 (no frequency)")
  expect_equal(strtim("s10"), 10, "legacy strtim s10 (no frequency)")
  expect_equal(timstr(360), "    6:00", "legacy timstr 360 (no frequency)")
  expect_equal(mstimstr(-360), "    6:00.000", "legacy mstimstr -360 (no frequency)")
  # a header without a sampling frequency: 250 Hz
  expect_equal(isig("nf"), 2, "legacy isigopen nf")
  expect_equal(sampfreq(NULL), 250, "legacy sampfreq nf")
  expect_equal(getifreq(), 250, "legacy getifreq nf")
  expect_equal(strtim("2"), 500, "legacy strtim 2 (nf)")
  expect_equal(strtim("e"), 0, "legacy strtim e (nf)")
  expect_equal(mstimstr(100), "    0:00.400", "legacy mstimstr 100 (nf)")
  expect_equal(setifreq(100), 0, "legacy setifreq 100 (nf)")
  expect_equal(getifreq(), 100, "legacy getifreq nf (100)")
  wfdbquit()
  expect_equal(sampfreq("nf"), 250, "legacy sampfreq nf (record)")
  wfdbquit()
  # setifreq with an input record but no frequency
  isig("100s")
  setsampfreq(0)
  expect_equal(setifreq(100), -1, "legacy setifreq 100 (frequency 0)")
  expect_equal(wfdberror(), "setifreq: no open input record\n", "legacy setifreq error")
  wfdbquit()
  # ADC resolution inferred from the format, or WFDB_DEFRES
  r <- isigopen("nr", 8)
  expect_equal(r$nsig, 2, "legacy isigopen nr")
  expect_equal(c(r$si[[1]]$adcres, r$si[[2]]$adcres), c(12, 12), "legacy nr adcres")
  wfdbquit()
  writeLines(c("nr3 5 360 10", "fmt16.dat 16", "fmt80.dat 80", "fmt310.dat 310",
               "fmt160.dat 160", "fmt24.dat 24"), "nr3.hea")
  r <- isigopen("nr3", 8)
  expect_equal(r$nsig, 5, "legacy isigopen nr3")
  expect_equal(vapply(r$si, function(s) s$adcres, 0), c(12, 8, 10, 16, 12), "legacy nr3 adcres")
  wfdbquit()
  wfdbverbose()
  expect_equal(wfdbx_set_legacy(FALSE), TRUE, "wfdbx_set_legacy 0")
  expect_equal(wfdbx_get_legacy(), FALSE, "wfdbx_get_legacy (off)")

  # ---- wfdbx_legacy_args: only "--legacy" as the first argument
  a <- wfdbx_legacy_args(c("rdsamp", "-r", "100s", "--legacy"))
  check(!a$legacy && identical(a$argv, c("rdsamp", "-r", "100s", "--legacy")) &&
          !wfdbx_get_legacy(), "wfdbx_legacy_args: not first")
  a <- wfdbx_legacy_args(c("rdsamp", "--legacy", "-r", "100s"))
  check(a$legacy && identical(a$argv, c("rdsamp", "-r", "100s")) && wfdbx_get_legacy(),
        "wfdbx_legacy_args: first")
  wfdbx_set_legacy(FALSE)
  check(!wfdbx_legacy_args("rdsamp")$legacy, "wfdbx_legacy_args: no arguments")
  # a tool run with --legacy restores the previous setting afterwards
  seen <- NULL
  st <- app_run(function(argv) {
    seen <<- list(legacy = wfdbx_get_legacy(), argv = argv)
    0
  }, c("tool", "--legacy", "-x"))
  check(st == 0 && isTRUE(seen$legacy) && identical(seen$argv, c("tool", "-x")) &&
          !wfdbx_get_legacy(), "app_run --legacy")

  # ---- high-level API: legacy = TRUE
  x <- matrix(c(1, 2, 3, -4, -5, -6), 3, 2)
  expect_equal(errmsg(write_record("lg", x, 100)), "gains must be specified",
               "write_record without gains (modern)")
  write_record("lg", x, 100, legacy = TRUE)
  check(!wfdbx_get_legacy(), "write_record legacy: setting restored")
  si <- read_header("lg")$siginfo
  check(si[[1]]$gain == 200 && si[[2]]$gain == 200 && si[[1]]$adcres == 16 &&
          is.null(si[[1]]$units), "write_record legacy: gain 200, adcres 16, no units")
  write_record("lg8", x, 100, fmt = 80, gains = c(100, 0), legacy = TRUE)
  check(read_header("lg8")$siginfo[[1]]$adcres == 8, "write_record legacy: adcres 8 for format 80")
  # physical values of an uncalibrated signal: gain 200
  expect_equal(errmsg(read_record("lg8", physical = TRUE)),
               "signal 1 of record lg8 is uncalibrated", "read_record physical uncalibrated")
  r <- read_record("lg8", physical = TRUE, legacy = TRUE)
  check(isTRUE(all.equal(r$signals[, 2], x[, 2] / 200)) &&
          isTRUE(all.equal(r$signals[, 1], x[, 1] / 100)), "read_record legacy physical: gain 200")
  check(!wfdbx_get_legacy(), "read_record legacy: setting restored")
  write_record("lg8", x / 200, 100, fmt = 80, gains = c(100, 0), physical = TRUE, legacy = TRUE)
  check(all(read_record("lg8")$signals[, 2] == x[, 2]), "write_record legacy physical gain 0")
  # the uncalibrated null record, in physical units
  r <- read_record("null", sampto = 3, physical = TRUE, legacy = TRUE)
  check(r$fs == 360 && nrow(r$signals) == 3, "read_record legacy null physical")
  # a header without a frequency: 250 Hz, time strings at 250 Hz
  r <- read_record("nf", sampto = "0:1", legacy = TRUE)
  check(r$fs == 250 && nrow(r$signals) == 250, "read_record legacy nf")
  expect_equal(errmsg(read_record("nf", sampto = "0:1")),
               "sampling frequency of record nf is not specified", "read_record nf (modern)")
  expect_equal(read_header("nr", legacy = TRUE)$siginfo[[1]]$adcres, 12, "read_header legacy nr")
  expect_equal(read_header("nr")$siginfo[[1]]$adcres, 0, "read_header nr (modern)")
  # read_annotations: 250 Hz without a header, unless fs is given
  file.copy("100s.atr", "nohea.atr")
  wfdbquiet()
  a <- read_annotations("nohea", "atr", sampto = "0:10", legacy = TRUE)
  b <- read_annotations("nohea", "atr", sampto = "0:10", fs = 360, legacy = TRUE)
  wfdbverbose()
  all <- read_annotations("100s", "atr")
  check(nrow(a) == sum(all$sample < 2500) && attr(a, "fs") == 250,
        "read_annotations legacy without header: 250 Hz")
  check(nrow(b) == sum(all$sample < 3600), "read_annotations legacy fs = 360")
  # the setting is restored after an error, and legacy = FALSE keeps it
  check(nzchar(errmsg(read_record("nosuchrecord", legacy = TRUE))) && !wfdbx_get_legacy(),
        "legacy setting restored after an error")
  wfdbx_set_legacy(TRUE)
  r <- read_record("nf", sampto = 2)
  check(r$fs == 250 && wfdbx_get_legacy(), "legacy = FALSE keeps the global setting")
  wfdbx_set_legacy(FALSE)
}
