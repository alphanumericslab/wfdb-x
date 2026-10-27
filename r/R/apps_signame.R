# apps_signame.R: signame -- print the names of the signals of a record.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/signame.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior).
#
# Original C program: app/signame.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2008 George B. Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# .signame_args() is the option parsing shared with signum.

app_signame <- function(args = character(0)) {
  app_run(.signame_main, c("signame", args))
}

.signame_helplines <- c(
  "usage: %s -r RECORD [OPTIONS ...]\n",
  "where RECORD is the name of the input record, and OPTIONS may include:",
  " -h          print this usage summary",
  " -s SIGNAL [SIGNAL ...]  print signal name(s) for the specified signal(s)",
  "If no -s option is given, the names of all signals in the record are output.")

.signame_help <- function(pname, lines) {
  ceprintf(lines[1L], pname)
  for (s in lines[-1L]) ceprintf("%s\n", s)
}

# Parse the options of signame and signum (needlist: -s is required) and
# read the record's header.  Returns list(si, nsig, isiglist, nosig), with
# isiglist the C index in argv of the first signal argument (0: none).
.signame_args <- function(argv, needlist, helplines) {
  pname <- argv[1L]
  argc <- length(argv)
  record <- NULL
  isiglist <- 0L
  nosig <- 0L
  i <- 1L
  while (i < argc) {
    a <- argv[i + 1L]
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "h") {
        .signame_help(pname, helplines)
        cexit(0)
      } else if (c == "r") {
        i <- i + 1L
        if (i >= argc) {
          ceprintf("%s: record name must follow -r\n", pname)
          cexit(1)
        }
        record <- argv[i + 1L]
      } else if (c == "s") {
        isiglist <- i + 1L
        while (i + 1L < argc && !startsWith(argv[i + 2L], "-")) {
          i <- i + 1L
          nosig <- nosig + 1L
        }
        if (nosig == 0L) {
          ceprintf("%s: signal list must follow -s\n", pname)
          cexit(1)
        }
      } else {
        ceprintf("%s: unrecognized option %s\n", pname, a)
        cexit(1)
      }
    } else {
      ceprintf("%s: unrecognized argument %s\n", pname, a)
      cexit(1)
    }
    i <- i + 1L
  }
  if (is.null(record) || (needlist && isiglist == 0L)) {
    .signame_help(pname, helplines)
    cexit(1)
  }
  nsig <- isigopen(record, 0)$nsig
  if (nsig <= 0) cexit(2)
  r <- isigopen(record, -nsig)
  if (r$nsig <= 0) cexit(2)
  list(si = r$si, nsig = r$nsig, isiglist = isiglist, nosig = nosig)
}

.signame_main <- function(argv) {
  p <- .signame_args(argv, FALSE, .signame_helplines)
  if (p$isiglist) {
    for (i in seq_len(p$nosig)) {
      j <- atoi(argv[p$isiglist + i])
      # (The C version also accepts j == nsig, reading past the end of its
      # array; see docs/KNOWN_C_BEHAVIORS.md.)
      d <- if (j >= 0 && j < p$nsig) p$si[[j + 1]]$desc else "[INVALID]"
      cprintf("%s\n", d)
    }
  } else {
    for (s in p$si) cprintf("%s\n", s$desc)
  }
  wfdbquit()
  0
}
