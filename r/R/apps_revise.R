# apps_revise.R: revise -- convert an obsolete-format header file into a
# current one.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of convert/revise.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in ADC resolution: a missing resolution
# stays unspecified (the original assumed 12 bits); --legacy, as the first
# argument, restores the original behavior. Each change is marked "WFDB-x:" in
# the code; docs/DIVERGENCES.md gives the reasons.
#
# Original C program: convert/revise.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1999 George B. Moody; revised 2018 by Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

app_revise <- function(args = character(0)) {
  app_run(.revise_main, c("revise", args))
}

# readoldheader() of revise.c: the siginfo lists of the signals described
# by the old-style header of record (or a negative status).
.revise_readoldheader <- function(record) {
  WFDB_MAXSIG <- 32                         # (signals in C's static array)
  LINEBUF <- 256                            # fgets() buffer size
  sep <- " \t\n"
  f <- wfdb_open("header", record, WFDB_READ)
  if (is.null(f)) {
    wfdb_error("init: can't open header for record %s\n", record)
    return(-1)
  }
  lines <- fgets_lines(wf_readall(f), LINEBUF, as_raw = TRUE)
  is_std <- isTRUE(f$is_std)
  wf_close(f)
  li <- 0L
  fgets <- function() {
    if (li >= length(lines)) return(NULL)
    li <<- li + 1L
    lines[[li]]
  }
  bad <- function() {
    wfdb_error("init: incorrect format in record %s header\n", record)
    -2
  }
  # the first token of the next line (NULL if none); t is its strtok state
  t <- NULL
  nexttok <- function() {
    line <- fgets()
    if (is.null(line)) return(NULL)
    t <<- strtok_new(line)
    strtok_next(t, sep)
  }
  repeat {
    line <- fgets()
    if (is.null(line)) {
      wfdb_error("init: can't find record name in record %s header\n", record)
      return(-2)
    }
    t <- strtok_new(line)
    p <- strtok_next(t, sep)
    if (!is.null(p) && !startsWith(p, "#")) break
  }
  if (!is_std && p != record) {
    wfdb_error("init: record name in record %s header is incorrect\n", record)
    return(-2)
  }
  if (!is.null(strtok_next(t, sep))) {
    ceprintf("The header for record %s appears not to be an old-style header.\n", record)
    return(-2)
  }
  p <- nexttok()
  if (is.null(p)) return(bad())
  ng <- atoi(p)
  nsamples <- 0
  si <- list()
  s <- 0
  g <- 0
  while (g < ng) {
    cur <- siginfo(group = g)
    p <- nexttok()
    if (is.null(p)) return(bad())
    cur$fname <- p
    p <- nexttok()
    if (is.null(p)) return(bad())
    cur$gain <- atof(p)
    p <- nexttok()
    if (is.null(p) || atof(p) <= 0) return(bad())
    setsampfreq(atof(p))
    # format, block size and number of signals, encoded in two fields
    p <- nexttok()
    if (is.null(p)) return(bad())
    i <- atoi(p)
    p <- strtok_next(t, sep)
    mpx <- if (!is.null(p)) atoi(p) else 1
    if (mpx == 0) mpx <- 1
    if (i != 8 && i != 16) {
      cur$bsize <- i
      if (mpx < 0) {
        mpx <- -mpx
        cur$fmt <- 8
      } else {
        cur$fmt <- 16
      }
    } else {
      cur$fmt <- i
      cur$bsize <- 0
    }
    p <- strtok_next(t, sep)
    # (WFDB-x: the C program, and legacy mode, assumed WFDB_DEFRES)
    cur$adcres <- if (!is.null(p)) atoi(p) else if (wfdbx_get_legacy()) WFDB_DEFRES else 0
    p <- strtok_next(t, sep)
    cur$adczero <- if (!is.null(p)) atoi(p) else 0
    p <- nexttok()
    if (is.null(p)) return(bad())
    cur$initval <- atoi(p)
    p <- strtok_next(t, sep)
    ns <- if (!is.null(p)) strtol(p)[1L] else 0
    if (ns < 0) return(bad())
    if (nsamples == 0) {
      nsamples <- ns
    } else if (ns > 0 && ns != nsamples) {
      wfdb_error("warning (init):\n")
      wfdb_error(" record %s durations are inconsistent\n", record)
      if (nsamples > ns) nsamples <- ns
    }
    p <- strtok_next(t, sep)
    if (!is.null(p)) {
      cur$cksum <- atoi(p)
      cur$nsamp <- ns
    } else {
      cur$cksum <- 0
      cur$nsamp <- 0
    }
    si[[length(si) + 1L]] <- cur
    # while (++s < WFDB_MAXSIG && --mpx > 0) copy the signal: when s
    # reaches WFDB_MAXSIG, mpx is not decremented, so a record with exactly
    # WFDB_MAXSIG signals is rejected below (see docs/KNOWN_C_BEHAVIORS.md)
    repeat {
      s <- s + 1
      if (s >= WFDB_MAXSIG) break
      mpx <- mpx - 1
      if (mpx <= 0) break
      si[[length(si) + 1L]] <- si[[length(si)]]
    }
    if (s == WFDB_MAXSIG && (mpx > 0 || g < ng - 1)) {
      wfdb_error("init: too many signals in record %s\n", record)
      return(-2)
    }
    g <- g + 1
  }
  for (k in seq_len(s)) si[[k]]$desc <- .f("record %s, signal %d", record, k - 1)
  si
}

.revise_main <- function(argv) {
  if (length(argv) < 2L) {
    ceprintf("usage: %s record\n", argv[1L])
    ceprintf(" This program converts obsolete-format header files into new ones.\n")
    cexit(1)
  }
  record <- argv[2L]
  if (startsWith(record, "header.")) record <- substring(record, 8L)
  si <- .revise_readoldheader(record)
  if (is.numeric(si)) cexit(2)
  setheader(record, si, length(si))
  0
}
