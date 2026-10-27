# apps_sortann.R: sortann -- rearrange annotations in canonical order.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/sortann.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency: the new option -F
# FREQ gives it when the record has no header or its header gives none, and is
# then required for the -f and -t times (the original assumed 250 Hz); an
# out-of-order annotation at time 0 (num 0, chan 0) is no longer lost, nor are
# those inserted after it; --legacy, as the first argument, restores the
# original behavior. Each change is marked "wfdb-x:" in the code;
# docs/DIVERGENCES.md gives the reasons.
#
# Original C program: app/sortann.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1997-2010 George B. Moody; revised 2017-2018 by
#   Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The annotations are read in bulk; input that is already in order is
# recognized with vector operations, and out-of-order input is sorted with
# the doubly-linked list algorithm of sortann.c (which also determines
# which duplicates are discarded; .ann_sort_order in annot.R, which also
# sorts output annotation files when they are closed).

app_sortann <- function(args = character(0)) {
  app_run(.sortann_main, c("sortann", args))
}

.sortann_help <- function(pname) {
  ceprintf("usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n", pname)
  h <- c("where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
         " -f TIME    start at specified TIME",
         " -F FREQ    sampling frequency, if the record header does not specify one",
         " -h         print this usage summary",
         " -o OUTANN  write output as annotator OUTANN (required with -f or -t)",
         " -t TIME    stop at specified TIME",
         "The sorted output replaces the input if -o is omitted, the input is in",
         "the current directory, and the input is not already sorted.")
  h <- .app_help_text(h, h[3L])           # (-F)
  for (s in h) ceprintf("%s\n", s)
}

.sortann_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  record <- NULL
  in_name <- out_name <- NULL
  from <- to <- 0
  Ffreq <- 0
  i <- 2L
  while (i <= argc) {
    a <- argv[i]
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "a") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: annotator must follow -a\n", pname)
          cexit(1)
        }
        in_name <- argv[i]
      } else if (c == "f") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: starting time must follow -f\n", pname)
          cexit(1)
        }
        from <- i
      } else if (c == "F" && !wfdbx_get_legacy()) {  # frequency follows (WFDB-x)
        i <- i + 1L
        Ffreq <- .app_Fopt(pname, if (i <= argc) argv[i] else NULL)
      } else if (c == "h") {
        .sortann_help(pname)
        cexit(0)
      } else if (c == "o") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: annotator must follow -o\n", pname)
          cexit(1)
        }
        out_name <- argv[i]
      } else if (c == "r") {
        if (nchar(a, type = "bytes") > 2L) setwfdb(substr(a, 3L, nchar(a, type = "bytes")))
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: input record name must follow -r\n", pname)
          cexit(1)
        }
        record <- argv[i]
      } else if (c == "t") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: end time must follow -t\n", pname)
          cexit(1)
        }
        to <- i
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
  if (is.null(record) || is.null(in_name)) {
    .sortann_help(pname)
    cexit(1)
  }
  if ((from || to) && is.null(out_name)) {
    ceprintf("%s: -o required when using -f or -t options\n", pname)
    cexit(1)
  }
  if (!is.null(out_name) && in_name == out_name) {
    ceprintf("%s: must specify different annotator names after -a and -o\n", pname)
    cexit(1)
  }
  Sys.setenv(WFDBANNSORT = "0")
  # wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
  # the record had no header); -F specifies one.  It is needed only to
  # convert the -f and -t times.
  sps <- sampfreq(record)
  if (wfdbx_get_legacy()) {              # wfdb-x: legacy mode (original behavior)
    if (sps < 0) setsampfreq(sps <- WFDB_DEFFREQ)
  } else if (sps <= 0 && Ffreq > 0) {
    setsampfreq(sps <- Ffreq)
  }
  if (sps <= 0 && !wfdbx_get_legacy() &&
      ((from && wfdbx_time_needs_freq(argv[from])) ||
       (to && wfdbx_time_needs_freq(argv[to]))))
    .app_nofreq(pname, record, 1, useF = TRUE)
  if (annopen(record, list(anninfo(in_name, WFDB_READ)), 1) < 0) cexit(2)
  if (from) {
    from <- strtim(argv[from])
    if (from < 0) from <- -from
  }
  if (to) {
    to <- strtim(argv[to])
    if (to < 0) to <- -to
  }
  tps <- getiaorigfreq(0)
  if (tps > 0) {
    setafreq(tps)
    setiafreq(0, tps)
    if (wfdbx_get_legacy() || sps > 0) {
      from <- trunc(from * tps / sps + 0.5)
      to <- trunc(to * tps / sps + 0.5)
    } else if (from || to) {           # wfdb-x: no default sampling frequency
      .app_nofreq(pname, record, 1, useF = TRUE)
    }
  }
  A <- .getann_bulk(0, Inf)
  keep <- !(A$time < from | (to > 0 & A$time >= to))
  idx <- which(keep)
  so <- .ann_sort_order(A$time[idx], A$num[idx], A$chan[idx],
                        legacy = wfdbx_get_legacy())   # (wfdb-x: no annotation lost)
  iannclose(0)
  if (so$in_order && is.null(out_name)) {
    ceprintf("%s: input is already ordered -- no output written\n", pname)
    cexit(0)
  }
  if (from == 0 && to == 0 && is.null(out_name)) out_name <- in_name
  if (annopen(record, list(anninfo(out_name, WFDB_WRITE)), 1) < 0) cexit(2)
  k <- idx[so$order]
  k <- k[A$anntyp[k] != NOTQRS]
  .putann_bulk(0, list(time = A$time[k], anntyp = A$anntyp[k], subtyp = A$subtyp[k],
                       chan = A$chan[k], num = A$num[k], aux = A$aux[k]))
  wfdbquit()
  0
}
