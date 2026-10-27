# Tests of time and date conversion (port of python/tests/test_time.py and
# t_counter of python/tests/test_api.py; values checked against WFDB
# 10.7.0).
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

for (d in c("01/01/2000", "29/02/2000", "15/10/1582", "31/12/1999"))
  expect_equal(datstr(strdat(d)), paste0(" ", d), paste("datstr(strdat)", d))
# 29 February 1900 does not exist (Gregorian calendar)
expect_equal(datstr(strdat("29/02/1900")), " 01/03/1900", "29/02/1900")
expect_equal(strdat("bogus"), 0, "strdat(bogus)")

if (.mode == "source") {
  datasrc <- file.path(dirname(dirname(.rdir)), "tests", "data")
  oldpath <- Sys.getenv("WFDB", unset = NA)
  on.exit({
    wfdbquit()
    wfdbverbose()
    if (is.na(oldpath)) Sys.unsetenv("WFDB") else Sys.setenv(WFDB = oldpath)
    wfdbio_reset()
    sig_reset()
  }, add = TRUE)
  wfdbquit()
  setwfdb(datasrc)

  expect_equal(isigopen("100s", 0)$nsig, 2, "isigopen 100s")
  expect_equal(strtim("1:0"), 21600, "strtim(1:0)")
  expect_equal(timstr(21600), "    1:00", "timstr(21600)")
  expect_equal(mstimstr(1234), "    0:03.428", "mstimstr(1234)")
  expect_equal(strtim("s7"), 7, "strtim(s7)")
  expect_equal(strtim("e"), 21600, "strtim(e)")
  expect_equal(.fmstimstr_v(c(1234, 21600, 0), 360), c("    0:03.428", "    1:00.000", "    0:00.000"),
               "vectorized mstimstr")
  wfdbquit()

  isigopen("fmt16", 0)
  expect_equal(timstr(0), "[12:34:56 31/12/1999]", "timstr(0) absolute")
  expect_equal(strtim("[12:35:00]"), -803, "strtim([12:35:00])")
  expect_equal(mstimstr(-2500), "[12:35:06.789 31/12/1999]", "mstimstr(-2500)")
  expect_equal(.ftimstr_v(c(0, -2500), 250), c("[12:34:56 31/12/1999]", "[12:35:06 31/12/1999]"),
               "vectorized timstr")
  wfdbquit()

  # t_counter
  isigopen("100s", 8)
  expect_equal(getcfreq(), 360, "getcfreq")
  expect_equal(getbasecount(), 0, "getbasecount")
  setcfreq(1000)
  setbasecount(500.5)
  expect_equal(getcfreq(), 1000, "getcfreq 1000")
  expect_equal(getbasecount(), 500.5, "getbasecount 500.5")
  expect_equal(strtim("c1500.5"), 360, "strtim(c1500.5)")
  expect_equal(strtim("c500.5"), 0, "strtim(c500.5)")
  setcfreq(0)
  expect_equal(getcfreq(), 360, "getcfreq after setcfreq(0)")
  expect_equal(setbasetime("10:20:30 15/6/2001"), 0, "setbasetime")
  expect_equal(timstr(0), "[10:20:30 15/06/2001]", "timstr(0)")
  expect_equal(timstr(360), "    0:01", "timstr(360)")
  expect_equal(timstr(-360), "[10:20:31 15/06/2001]", "timstr(-360)")
  expect_equal(mstimstr(-1000), "[10:20:32.778 15/06/2001]", "mstimstr(-1000)")
  expect_equal(setbasetime("8:00"), 0, "setbasetime(8:00)")
  expect_equal(timstr(0), "[00:08:00]", "timstr(0) no date")
  expect_equal(timstr(-720), "[00:08:02]", "timstr(-720)")
  wfdbquiet()
  expect_equal(setbasetime("garbage"), -1, "setbasetime(garbage)")
  wfdbverbose()
  setcfreq(500)
  wfdbquit()
  expect_equal(getcfreq(), 500, "cfreq survives wfdbquit")
  setcfreq(0)
}
