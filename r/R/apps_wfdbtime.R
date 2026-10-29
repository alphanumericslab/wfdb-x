# apps_wfdbtime.R: wfdbtime -- convert between times and sample numbers.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/wfdbtime.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency: the record must
# give it (the original assumed 250 Hz); --legacy, as the first argument,
# restores the original behavior. Each change is marked "WFDB-x:" in the code;
# docs/DIVERGENCES.md gives the reasons.
#
# Original C program: app/wfdbtime.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2001 George B. Moody; revised 2017-2018 by Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

app_wfdbtime <- function(args = character(0)) {
  app_run(.wfdbtime_main, c("wfdbtime", args))
}

.wfdbtime_main <- function(argv) {
  argc <- length(argv)
  record <- NULL
  i <- 1L
  while (i < argc) {
    a <- argv[i + 1L]
    if (a == "-r") {
      if (!is.null(record)) wfdbquit()
      i <- i + 1L
      if (i == argc) break
      record <- argv[i + 1L]
      if (isigopen(record, 0)$nsig < 0) cexit(2)
      if (!wfdbx_get_legacy() && isTRUE(sampfreq(NULL) <= 0))  # WFDB-x: no default frequency
                                                       # (except in legacy mode)
        .app_nofreq(argv[1L], record, 2)
    } else if (!is.null(record)) {
      t <- strtim(a)
      if (t < 0) t <- -t
      sbuf <- csprintf("s%ld", t)
      cprintf("%15s\t%15s", sbuf, if (t == 0) "0:00.000" else mstimstr(t))
      cprintf("\t%15s\n", mstimstr(-t))
    }
    i <- i + 1L
  }
  if (is.null(record)) {
    ceprintf("usage: %s [ -r RECORD [ TIME ] ]\n", argv[1L])
    ceprintf(" where RECORD is the name of the input record\n")
    ceprintf(" Each TIME is a time to be converted\n")
    cexit(1)
  }
  wfdbquit()
  0
}
