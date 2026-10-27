# apps_a2m.R: a2m -- convert an AHA-format annotation file to MIT format.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of convert/a2m.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency: the new option -F
# FREQ gives it when the record has no header or its header gives none, and is
# then required (the original assumed 250 Hz, or 1 sample per second without a
# header); annotation times given in milliseconds (AHA file types 1 to 3) are
# converted at the record's sampling frequency (the original assumed 4 ms per
# sample); --legacy, as the first argument, restores the original behavior.
# Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the
# reasons.
#
# Original C program: convert/a2m.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1983-2010 George B. Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The input file becomes the standard input (C freopen: stdin_freopen), as
# the library reads AHA annotation files of types 0-2 from "-".  Files of
# type 3 (compressed, 6-byte records) are decoded with vector operations.

app_a2m <- function(args = character(0)) {
  app_run(.a2m_main, c("a2m", args))
}

.a2m_help <- function(pname) {
  ceprintf("usage: %s -i AHAFILE [ OPTIONS ... ]\n", pname)
  h <- c(
    "where AHAFILE is the name of the AHA-format input annotation file,",
    "and OPTIONS may include:",
    " -a ANNOTATOR  specify the output annotator name (default: 'atr')",
    " -F FREQ       sampling frequency, if the record header does not specify",
    "                one (AHA database: 250)",
    " -h            print this usage summary",
    " -r RECORD     specify the name of the output RECORD (default: use the",
    "                input file name, less path info and extension, as RECORD)",
    " -s TIME       shift annotations by TIME",
    "                (defaults: 0 for TYPE 0,",
    "                      5:0 for TYPE 1, (or TYPE 3 if RECORD=x2xx or x3xx)",
    "                   2:30:0 for TYPE 2, (or TYPE 3 if RECORD=x0xx or x1xx)",
    " -t TYPE       specify type of file to be converted:",
    "                0 for files produced by WFDB applications in AHA format,",
    "                1 for short-format tape files,",
    "                2 for long-format tape files, or",
    "                3 for compressed files from AHA DB CD-ROMs or diskettes",
    "                (defaults: 3 if AHAFILE ends in .ANO or .ano, else 0)")
  h <- .app_help_text(h, h[4:5])          # (-F)
  cerr(paste0(h, "\n", collapse = ""))
}

# The default record name (shared with ad2m): the input file name without
# its directory and its extension (from the first '.' after the first
# character).
.a2m_basename_record <- function(ifname) {
  b <- charToRaw(ifname)
  k <- which(b == charToRaw("/"))
  if (length(k)) b <- b[-seq_len(k[length(k)])]
  j <- which(b[-1L] == charToRaw("."))
  if (length(j)) b <- b[seq_len(j[1L])]
  rawToChar(b)
}

# The second character of a record name, if it has exactly 4 (AHA record
# names: x0xx and x1xx are long-format, x2xx and x3xx short-format).
.a2m_aha_digit <- function(record) {
  if (nchar(record, type = "bytes") == 4L) substr(record, 2L, 2L) else ""
}

.a2m_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  ifname <- NULL
  record <- NULL
  oann <- "atr"
  typ <- -1
  offset <- 0L                 # index in argv of the time shift (0: none)
  Ffreq <- 0                   # wfdb-x: -F
  i <- 2L
  while (i <= argc) {
    a <- argv[i]
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "a") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: output annotator name must follow -a\n", pname)
          cexit(1)
        }
        oann <- argv[i]
      } else if (c == "F" && !wfdbx_get_legacy()) {  # frequency follows (wfdb-x)
        i <- i + 1L
        Ffreq <- .app_Fopt(pname, if (i <= argc) argv[i] else NULL)
      } else if (c == "h") {
        .a2m_help(pname)
        cexit(1)
      } else if (c == "i") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: name of AHA-format input file must follow -i\n", pname)
          cexit(1)
        }
        ifname <- argv[i]
        n <- nchar(ifname, type = "bytes")
        if (typ < 0 && n > 4L && substr(ifname, n - 3L, n) %in% c(".ANO", ".ano")) typ <- 3
      } else if (c == "r") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: record name must follow -a\n", pname)   # (sic)
          cexit(1)
        }
        record <- argv[i]
      } else if (c == "s") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: time shift must follow -s\n", pname)
          cexit(1)
        }
        offset <- i
      } else if (c == "t") {
        i <- i + 1L
        if (i <= argc) typ <- atoi(argv[i])
        if (i > argc || typ < 0 || typ > 3) {
          ceprintf("%s: file type (0-3) must follow -t\n", pname)
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
  if (is.null(ifname)) {
    .a2m_help(pname)
    cexit(1)
  }
  if (!stdin_freopen(ifname)) {
    ceprintf("%s: can't read input file `%s'\n", pname, ifname)
    cexit(2)
  }
  if (is.null(record)) record <- .a2m_basename_record(ifname)
  if (typ < 0) typ <- 0
  ai <- list(anninfo(oann, WFDB_WRITE))
  if (typ != 3) ai[[2L]] <- anninfo("-", WFDB_AHA_READ)
  if (annopen(record, ai, length(ai)) < 0) cexit(2)
  # wfdb-x: if the record header does not give the sampling frequency, -F
  # must give it.  (The C program assumed the rate of the AHA database, 250
  # Hz, if a header without a frequency existed, and 1 sample per second if
  # there was no header.)
  legacy <- wfdbx_get_legacy()
  if (legacy) {                           # wfdb-x: legacy mode (original behavior)
    if (sampfreq(record) == 0) setsampfreq(250)
  } else if (sampfreq(record) <= 0) {
    if (Ffreq > 0) {
      setsampfreq(Ffreq)
    } else {
      .app_nofreq(pname, record, 1, useF = TRUE)
    }
  }
  # Times in milliseconds (types 1-3) are converted at the sampling frequency
  # of the record (wfdb-x; the C program assumed 4 ms per sample, i.e., 250
  # Hz, whatever the record's frequency, as legacy mode does).
  ms2samp <- if (legacy) function(t) floor(t / 4) else function(t) trunc(t * sampfreq(NULL) / 1000)
  d <- .a2m_aha_digit(record)
  shift <- if (offset) {
    strtim(argv[offset])
  } else if (typ == 1 || (typ == 3 && d %in% c("2", "3"))) {
    strtim("5:0")
  } else if (typ == 2 || (typ == 3 && d %in% c("0", "1"))) {
    strtim("2:30:0")
  } else 0
  if (typ == 0) {
    repeat {
      r <- getann(0)
      if (r$stat < 0) break
      a <- r$annot
      if (a$chan != 0) {
        a$anntyp <- cint8(a$chan)
        a$chan <- 0
      }
      a$time <- a$time + shift
      if (putann(0, a) < 0) break
    }
  } else if (typ == 1 || typ == 2) {
    repeat {
      r <- getann(0)
      if (r$stat < 0) break
      a <- r$annot
      a$time <- ms2samp(a$time) + shift
      putann(0, a)
    }
  } else {
    .a2m_putcompressed(stdin_bytes(), shift, ms2samp)
  }
  wfdbquit()
  0
}

# Type 3: 6-byte records (code, 3-byte big-endian time in milliseconds, 2
# bytes unused), up to the first one whose second byte is 0xff or whose code
# maps to NOTQRS, or the end of the input.  ms2samp converts the times to
# samples.
.a2m_putcompressed <- function(b, shift, ms2samp) {
  REC <- 6L
  nr <- length(b) %/% REC
  if (nr == 0L) return(invisible())
  R <- matrix(as.integer(b[seq_len(REC * nr)]), REC)
  code <- cint8(R[1L, ])
  typ <- ammap(code)
  stop_at <- which(R[2L, ] == 0xff | typ == 0)
  n <- if (length(stop_at)) stop_at[1L] - 1L else nr
  if (n == 0L) return(invisible())
  k <- seq_len(n)
  t <- R[2L, k] * 65536 + R[3L, k] * 256 + R[4L, k]
  .putann_bulk(0, list(time = ms2samp(t) + shift, anntyp = typ[k],
                       subtyp = -(R[1L, k] == utf8ToInt("U"))))
  invisible()
}
