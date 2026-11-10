# apps_time2sec.R: time2sec -- convert a time interval to seconds.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/time2sec.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: with -r, a record whose header cannot be read,
# or gives no sampling frequency, is an error (exit status 2; "time2sec:
# sampling frequency of record REC is not specified"), since WFDB-x assumes
# no sampling frequency: the original used the default of 250 Hz (WFDB-x,
# 1.2.2; see docs/DIVERGENCES.md). The --legacy option (as the first
# argument) restores the original behavior.
#
# Original C program: app/time2sec.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2003-2009 George B. Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE-GPL.

app_time2sec <- function(args = character(0)) {
  app_run(.time2sec_main, c("time2sec", args))
}

.time2sec_main <- function(argv) {
  argc <- length(argv)
  if (argc == 4L && argv[2L] == "-r") {
    # WFDB-x: in normal mode, no sampling frequency is assumed: a record
    # whose header cannot be read, or gives none, is an error (the
    # original used the default of 250 Hz; a frequency of 0 gave a
    # meaningless result with the exit status 0)
    if (isigopen(argv[3L], 0)$nsig < 0 && !wfdbx_get_legacy()) cexit(2)
    if (isTRUE(sampfreq(NULL) <= 0) && !wfdbx_get_legacy())
      .app_nofreq(argv[1L], argv[3L], 2)
    t <- strtim(argv[4L])
    if (t < 0) t <- -t
    sf <- sampfreq(NULL)
    # (legacy mode, as in C: with no sampling frequency, t / sf is
    # infinite or NaN)
    seconds <- d2l(t / sf)                              # (long)
    t <- t - seconds * sf
    milliseconds <- cint32(d2l((t * 1000) / sf + 0.5))  # int = (long)
    if (milliseconds >= 1000) {
      seconds <- seconds + 1
      milliseconds <- milliseconds - 1000
    }
    cprintf("%ld", seconds)
    if (milliseconds != 0) cprintf(".%03d", milliseconds)
    cprintf("\n")
    cexit(0)
  } else if (argc == 2L && !startsWith(argv[2L], "-")) {
    setsampfreq(1000)                     # strtim() then gives milliseconds
    cprintf("%.12g\n", strtim(argv[2L]) / 1000)
    cexit(0)
  }
  ceprintf("usage: %s [-r RECORD] TIME\n", argv[1L])
  ceprintf(" where TIME (in hh:mm:ss format) is a time interval\n")
  ceprintf(" to be converted into seconds.  Enclose TIME in\n")
  ceprintf(" square brackets (e.g., [9:0:0]) to convert a time\n")
  ceprintf(" of day to the elapsed time in seconds from the\n")
  ceprintf(" beginning of the (optionally) specified RECORD.\n")
  cexit(1)
}
