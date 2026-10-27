# calib.R: the calibration list (port of lib/calib.c): calopen, getcal,
# putcal, newcal, flushcal.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of lib/calib.c from the WFDB Software Package 10.7.0,
# by George B. Moody. The translation follows the logic and behavior of the
# original code, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language.
#
# Original C code: lib/calib.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1991-2013 George B. Moody; revised 2019-2022 by
#   Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# Calibration entries are calinfo() lists (ecgcodes.R): low, high, scale,
# sigtype, units, caltype.

WFDB_AC_COUPLED <- 0
WFDB_DC_COUPLED <- 1
WFDB_CAL_SQUARE <- 2
WFDB_CAL_SINE <- 4
WFDB_CAL_SAWTOOTH <- 6
WFDB_CAL_UNDEF <- 8

.cal <- new.env(parent = emptyenv())
.cal$list <- list()

#' Read a calibration file (default: $WFDBCAL, or "wfdbcal") into the
#' calibration list, which it replaces unless the name begins with '+'.
#' Returns 0, or -2 if the file can't be read.
calopen <- function(cfname = NULL) {
  if (is.null(cfname)) {
    cfname <- cgetenv("WFDBCAL")
    if (is.null(cfname)) cfname <- DEFWFDBCAL
  }
  if (startsWith(cfname, "+")) {
    cfname <- substr(cfname, 2L, nchar(cfname, type = "bytes"))
  } else {
    flushcal()
  }
  cfile <- wfdb_open(cfname, NULL, WFDB_READ)
  if (is.null(cfile)) {
    wfdb_error("calopen: can't read calibration file %s\n", cfname)
    return(-2)
  }
  entries <- .cal$list
  repeat {
    line <- wf_getline(cfile)
    if (length(line) == 0L) break
    b <- cbytes(line)
    i <- 1L
    while (i <= length(b) && b[i] %in% c(32L, 9L, 13L)) i <- i + 1L
    if (i <= length(b) && b[i] == 35L) next          # '#'
    tok <- strtok_new(b[seq.int(i, length.out = max(0L, length(b) - i + 1L))])
    p1 <- strtok_next(tok, "\t")
    p2 <- if (!is.null(p1)) strtok_next(tok, " \t")
    p3 <- if (!is.null(p2)) strtok_next(tok, " \t")
    p4 <- if (!is.null(p3)) strtok_next(tok, " \t")
    p5 <- if (!is.null(p4)) strtok_next(tok, " \t")
    p6 <- if (!is.null(p5)) strtok_next(tok, " \t\r\n")
    if (is.null(p6)) next
    c <- calinfo()
    c$sigtype <- if (p1 == "*") "" else p1
    if (p2 == "-") {
      c$caltype <- WFDB_AC_COUPLED
      c$low <- 0
    } else {
      c$caltype <- WFDB_DC_COUPLED
      c$low <- strtod(p2)[1L]
    }
    if (p3 == "-") {
      c$high <- c$low <- 0
    } else {
      c$high <- strtod(p3)[1L]
    }
    if (p4 == "square") {
      c$caltype <- c$caltype + WFDB_CAL_SQUARE
    } else if (p4 == "sine") {
      c$caltype <- c$caltype + WFDB_CAL_SINE
    } else if (p4 == "sawtooth") {
      c$caltype <- c$caltype + WFDB_CAL_SAWTOOTH
    }
    c$scale <- strtod(p5)[1L]
    c$units <- p6
    entries[[length(entries) + 1L]] <- c
  }
  .cal$list <- entries
  wf_close(cfile)
  0
}

#' Find the first calibration entry whose signal type is a prefix of desc
#' and whose units are units (NULL matches anything):
#' list(stat = 0, cal = the entry), or list(stat = -1, cal = NULL).
getcal <- function(desc, units) {
  for (c in .cal$list) {
    if ((is.null(desc) || startsWith(desc, c$sigtype)) &&
        (is.null(units) || units == c$units))
      return(list(stat = 0, cal = c))
  }
  list(stat = -1, cal = NULL)
}

#' Append an entry (a calinfo()) to the calibration list.  Returns 0.
putcal <- function(cal) {
  entries <- .cal$list
  entries[[length(entries) + 1L]] <- cal
  .cal$list <- entries
  0
}

#' Write the calibration list to a file.  Returns 0, or -1.
newcal <- function(cfname) {
  if (wfdb_checkname(cfname, "calibration file") < 0) return(-1)
  cfile <- wfdb_open(cfname, NULL, WFDB_WRITE)
  if (is.null(cfile)) {
    wfdb_error("newcal: can't create calibration file %s\n", cfname)
    return(-1)
  }
  for (c in .cal$list) {
    ct <- c$caltype
    out <- list(csprintf("%s\t", if (!is.null(c$sigtype) && nzchar(c$sigtype)) c$sigtype else "*"),
                if (bitwAnd(as.integer(ct), WFDB_DC_COUPLED)) csprintf("%g ", c$low) else charToRaw("- "),
                if (c$high != c$low) csprintf("%g ", c$high) else charToRaw("- "))
    pt <- bitwAnd(as.integer(ct), bitwNot(WFDB_DC_COUPLED))
    pulsetype <- if (pt == WFDB_CAL_SQUARE) "square" else if (pt == WFDB_CAL_SINE) "sine" else
      if (pt == WFDB_CAL_SAWTOOTH) "sawtooth" else "undefined"
    out[[4L]] <- csprintf("%s %g %s\r\n", pulsetype, c$scale, c$units)
    wf_write(cfile, unlist(out, use.names = FALSE))
  }
  errflag <- wf_ferror(cfile)
  if (wf_close(cfile) != 0) errflag <- TRUE
  if (errflag) {
    wfdb_error("newcal: write error in calibration file\n")
    return(-1)
  }
  0
}

#' Empty the calibration list.
flushcal <- function() {
  .cal$list <- list()
  invisible()
}
