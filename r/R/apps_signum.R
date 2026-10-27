# apps_signum.R: signum -- print the numbers of the signals of a record
# that have the given names.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/signum.c from the WFDB Software Package 10.7.0,
# by George B. Moody. The translation follows the logic and behavior of the
# original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior).
#
# Original C program: app/signum.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2008 George B. Moody; revised 2021 by Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The option parsing is shared with signame (.signame_args).

app_signum <- function(args = character(0)) {
  app_run(.signum_main, c("signum", args))
}

.signum_helplines <- c(
  "usage: %s -r RECORD [OPTIONS ...]\n",
  "where RECORD is the name of the input record, and OPTIONS may include:",
  " -h          print this usage summary",
  " -s SIGNAL [SIGNAL ...]  print signal number(s) for the specified signal(s)")

.signum_main <- function(argv) {
  p <- .signame_args(argv, TRUE, .signum_helplines)
  descs <- lapply(p$si, function(s) s$desc)
  for (i in seq_len(p$nosig)) {
    name <- argv[p$isiglist + i]
    found <- which(vapply(descs, function(d) !is.null(d) && d == name, NA))
    # all the matching signal numbers, separated by tabs; X if none
    cprintf("%s\n", if (length(found)) paste(found - 1L, collapse = "\t") else "X")
  }
  wfdbquit()
  0
}
