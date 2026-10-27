# apps_rr2ann.R: rr2ann -- convert a series of RR intervals to an
# annotation file.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/rr2ann.c from the WFDB Software Package 10.7.0,
# by George B. Moody. The translation follows the logic and behavior of the
# original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency: -F FREQ is
# required when the record has no header or its header gives none (the original
# assumed 250 Hz); --legacy, as the first argument, restores the original
# behavior. Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md
# gives the reasons.
#
# Original C program: app/rr2ann.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2000 George B. Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# Input lines holding a single number (the usual form) are converted with
# vector operations; other input is handled line by line, exactly as the C
# program does (sscanf leaves its variables unchanged when a conversion
# fails, so that a blank line repeats the previous interval).

app_rr2ann <- function(args = character(0)) {
  app_run(.rr2ann_main, c("rr2ann", args))
}

.rr2ann_help <- function(pname) {
  ceprintf("usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...] <TEXT-FILE\n", pname)
  h <- c("where RECORD and ANNOTATOR specify the output, and OPTIONS may include:",
         paste0(" -F FREQ     use FREQ as the sampling frequency (effective only if the",
                "               header file does not exist or does not specify it)"),
         " -h          print this usage summary",
         " -T          TEXT-FILE contains times of occurrence, not RR intervals",
         " -x N        multiply input by N to obtain RR in sample intervals",
         "               (default: N = 1)",
         " -w          copy annotation types from second column of input",
         "TEXT-FILE should contain a column of RR intervals (or times of occurrence,",
         "if the -T option is specified), in units of sample intervals (unless the",
         "-x option is used to specify a conversion factor).   The first token on",
         "each line is taken as an RR interval, and (if the -w option is specified)",
         "the second token is taken as an annotation mnemonic (N, V, etc.);  anything",
         "else on the same line is ignored, as are empty lines, spaces and tabs at",
         "the beginning of a line non-numeric tokens and anything following them on",
         "the same line, negative intervals, and zero intervals.  The output consists",
         "of a binary annotation file (RECORD.ANNOTATOR), and (if it does not exist",
         "already) a text header file (RECORD.hea).")
  if (wfdbx_get_legacy())                # wfdb-x: legacy mode (original help)
    h[2L] <- paste0(" -F FREQ     use FREQ as the sampling frequency (effective only if no",
                    "               header file exists;  default: 250)")
  for (s in h) ceprintf("%s\n", s)
}

.rr2ann_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  record <- ainame <- NULL
  sps <- 0
  xfactor <- 1
  Tflag <- wflag <- 0
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
        ainame <- argv[i]
      } else if (c == "F") {
        i <- i + 1L
        if (i <= argc) sps <- atof(argv[i])
        if (i > argc || sps <= 0) {
          ceprintf("%s: sampling frequency (> 0) must follow -F\n", pname)
          cexit(1)
        }
      } else if (c == "h") {
        .rr2ann_help(pname)
        cexit(0)
      } else if (c == "r") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: record name must follow -r\n", pname)
          cexit(1)
        }
        record <- argv[i]
      } else if (c == "T") {
        Tflag <- 1
      } else if (c == "x") {
        i <- i + 1L
        if (i <= argc) xfactor <- atof(argv[i])
        if (i > argc || xfactor <= 0) {
          ceprintf("%s: an input multiplier (> 0) must follow -x\n", pname)
          cexit(1)
        }
      } else if (c == "w") {
        wflag <- 1
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
  if (is.null(record) || is.null(ainame)) {
    .rr2ann_help(pname)
    cexit(1)
  }
  wfdbquiet()
  # wfdb-x: no default sampling frequency (the C program assumed 250 Hz); -F
  # specifies one if the record header does not.
  f <- sampfreq(record)
  if (f <= 0) {
    wfdbverbose()            # re-enable error reporting
    if (sps == 0) {
      if (wfdbx_get_legacy()) sps <- WFDB_DEFFREQ    # wfdb-x: legacy mode
      else .app_nofreq(pname, record, 1, useF = TRUE)
    }
    setsampfreq(sps)
    # no header: create one (legacy mode, as the C program: in any case)
    if ((f < 0 || wfdbx_get_legacy()) && newheader(record) < 0) cexit(2)
  } else {
    wfdbverbose()
    if (sps != 0)
      ceprintf("%s (warning): -F option ignored (using %g for sampling frequency)\n",
               pname, sampfreq(NULL))
  }
  if (annopen(record, list(anninfo(ainame, WFDB_WRITE)), 1) < 0) cexit(3)
  data <- stdin_bytes()
  lines <- fgets_lines(data, 1024L)
  n <- length(lines)
  rr <- NULL
  if (!wflag && n > 0L && (!l10n_info()$MBCS || !any(data >= as.raw(128L)))) {
    # fast path: every line is a decimal number alone (no exponent)
    re <- "^[ \t\n\v\f\r]*([+-]?[0-9]{1,15}(\\.[0-9]{0,15})?)[ \t\n\v\f\r]*$"
    if (all(grepl(re, lines, perl = TRUE))) {
      s <- sub(re, "\\1", lines, perl = TRUE)
      # (integers are converted exactly by as.numeric; decimals by strtod,
      # which is correctly rounded as glibc's)
      rr <- as.numeric(s)
      d <- which(grepl(".", s, fixed = TRUE))
      if (length(d)) rr[d] <- vapply(s[d], function(x) strtod(x)[1L], 0, USE.NAMES = FALSE)
    }
  }
  if (!is.null(rr)) {
    typ <- rep(NORMAL, n)
  } else {
    rr <- numeric(n)
    typ <- numeric(n)
    keep <- logical(n)
    v1 <- 0
    at <- NORMAL
    for (k in seq_len(n)) {
      if (!wflag) {
        r <- csscanf(lines[k], "%lf")
        if (r$n == 0L) next
        if (r$n > 0L) v1 <- r$v[[1L]]
      } else {
        r <- csscanf(lines[k], "%lf%s")
        if (length(r$v)) v1 <- r$v[[1L]]
        if (r$n < 2L) next
        at <- strann(r$v[[2L]])
        if (at == NOTQRS) next
      }
      rr[k] <- v1
      typ[k] <- at
      keep[k] <- TRUE
    }
    rr <- rr[keep]
    typ <- typ[keep]
  }
  ok <- rr > 0
  rr <- rr[ok]
  typ <- typ[ok]
  tt <- rr * xfactor
  if (!Tflag) {
    # (sequential double sums, as C adds them: cumsum() accumulates in
    # extended precision)
    t <- 0
    for (k in seq_along(tt)) {
      t <- t + tt[k]
      tt[k] <- t
    }
  }
  .putann_bulk(0, list(time = trunc(tt + 0.5), anntyp = typ))
  wfdbquit()
  0
}
