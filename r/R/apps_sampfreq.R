# apps_sampfreq.R: sampfreq -- print the sampling frequency of a record.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/sampfreq.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior). Through
# the library, a record whose header gives no sampling frequency has the
# frequency 0, which is printed (the original printed 250); see
# docs/DIVERGENCES.md.
#
# Original C program: app/sampfreq.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1998-2012 George B. Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

app_sampfreq <- function(args = character(0)) {
  app_run(.sampfreq_main, c("sampfreq", args))
}

.sampfreq_help <- function(pname) {
  ceprintf("usage: %s [OPTION] RECORD\n", pname)
  ceprintf("%s", paste0(
    " where RECORD is the name of the input record\n",
    " and OPTION may be either of:\n",
    "  -a   list all signals and their sampling frequencies\n",
    "  -h   show this help\n",
    "  -H   show the maximum sampling frequency of a multifrequency record)\n",
    " If no OPTION is used, show the base sampling frequency (frame rate).\n"))
}

.sampfreq_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  if (argc == 1L) {
    .sampfreq_help(pname)
    cexit(1)
  }
  if (argc == 2L) {
    cprintf("%g\n", sampfreq(argv[2L]))
    cexit(0)
  }
  if (argc == 3L && argv[2L] %in% c("-a", "-H")) {
    si <- list()
    nsig <- isigopen(argv[3L], 0)$nsig
    if (nsig > 0) si <- isigopen(argv[3L], nsig)$si
    if (argv[2L] == "-H") {
      setgvmode(WFDB_HIGHRES)
      cprintf("%g\n", sampfreq(NULL))
      cexit(0)
    }
    setgvmode(WFDB_LOWRES)
    freq <- sampfreq(NULL)
    for (i in seq_len(max(nsig, 0)))
      cprintf("%s\t%g\n", si[[i]]$desc, si[[i]]$spf * freq)
  }
  0
}
