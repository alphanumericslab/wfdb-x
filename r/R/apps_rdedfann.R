# apps_rdedfann.R: rdedfann -- print the annotations of an EDF+ file (in
# the text format read by wrann).
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of convert/rdedfann.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior).
#
# Original C program: convert/rdedfann.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2008-2014 George B. Moody; bug fix and -x option contributed
#   by Luca Citi, 2014.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The frames are read in bulk (.getframes_full, the equivalent of the C
# program's getframe calls); the bytes of the annotation signal go through
# the C program's TAL state machine, with its buffers (the duration of a
# TAL without one repeats the last one: see docs/KNOWN_C_BEHAVIORS.md).

app_rdedfann <- function(args = character(0)) {
  app_run(.rdedfann_main, c("rdedfann", args))
}

.rdedfann_help <- function(pname) {
  ceprintf("usage: %s -r RECORD [OPTIONS ...]\n", pname)
  h <- c("where RECORD is the name of the input EDF+ record, and OPTIONS may include:",
         " -F FREQ     set the sampling frequency to FREQ Hz\n",
         " -h          print this usage summary",
         " -v          print column headings",
         " -x          print EDF+ annotation text in aux (default: print in anntyp)")
  for (s in h) ceprintf("%s\n", s)
}

.rdedfann_main <- function(argv) {
  TAL_BUFSIZE <- 1024L                      # size of the C program's TAL buffers
  CHUNK <- 65536                            # frames read at a time
  # TAL delimiters and states
  PLUS <- 0x2b; DC4 <- 0x14; NAK <- 0x15    # '+', '\024', '\025'
  IDLE <- 0; ONSET <- 1; DURATION <- 2; TEXT <- 3; TEXT_END <- 4
  pname <- argv[1L]
  argc <- length(argv)
  arg <- function(i) argv[i + 1L]          # C argv[i]
  record <- NULL
  sfreq <- 0
  vflag <- 0
  xflag <- 0
  i <- 1
  while (i < argc) {
    a <- arg(i)
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "F") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: sampling frequency must follow -F\n", pname)
          cexit(1)
        }
        r <- csscanf(arg(i), "%lf")
        if (r$n == 1) sfreq <- r$v[[1L]]
        if (sfreq <= 0) sfreq <- 1
      } else if (c == "h") {
        .rdedfann_help(pname)
        cexit(0)
      } else if (c == "r") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: record name must follow -r\n", pname)
          cexit(1)
        }
        record <- arg(i)
      } else if (c == "v") {
        vflag <- 1
      } else if (c == "x") {
        xflag <- 1
      } else {
        ceprintf("%s: unrecognized option %s\n", pname, a)
        cexit(1)
      }
    } else {
      ceprintf("%s: unrecognized argument %s\n", pname, a)
      cexit(1)
    }
    i <- i + 1
  }
  if (is.null(record)) {
    .rdedfann_help(pname)
    cexit(1)
  }
  setgvmode(WFDB_HIGHRES)
  nsig <- isigopen(record, 0)$nsig
  if (nsig <= 0) cexit(2)
  r <- isigopen(record, nsig)
  if (r$nsig <= 0) cexit(2)
  aindex <- 0
  alen <- 0
  framelen <- 0
  for (s in r$si) {
    if (identical(s$desc, "EDF Annotations")) {
      aindex <- framelen
      alen <- s$spf
    }
    framelen <- framelen + s$spf
  }
  if (alen == 0) {
    ceprintf("%s: record %s has no EDF annotations\n", pname, record)
    wfdbquit()
    cexit(3)
  }
  if (sfreq > 0) {
    setgvmode(WFDB_LOWRES)
    setsampfreq(sfreq)
  } else {
    sfreq <- sampfreq(NULL)
  }
  if (vflag) cprintf("      Time   Sample #  Type  Sub Chan  Num\tAux\n")

  # The TAL parser (state, buffers and positions as in C; the buffers hold
  # byte codes, the positions are 0-based).
  state <- IDLE
  onset <- duration <- text <- integer(TAL_BUFSIZE)
  op <- dp <- tp <- 0L
  str <- function(b) {                      # the C string in buffer b
    z <- match(0L, b)
    rawToChar(as.raw(b[seq_len(if (is.na(z)) length(b) else z - 1L)]))
  }
  proc <- function(x) {
    if (state == IDLE) {
      if (x == 0) return()
      if (x != PLUS) {
        ceprintf("%s: unexpected character '%c' in input\n", pname, x)
      } else {
        state <<- ONSET
        op <<- dp <<- tp <<- 0L
        text[1L] <<- 0L
      }
    } else if (state == ONSET) {
      if (x == NAK) {
        x <- 0
        state <<- DURATION
      } else if (x == DC4) {
        x <- 0
        state <<- TEXT
      }
      op <<- op + 1L
      onset[op] <<- x
    } else if (state == DURATION) {
      if (x == DC4) {
        x <- 0
        state <<- TEXT
      }
      dp <<- dp + 1L
      duration[dp] <<- x
    } else if (state == TEXT) {
      if (x == DC4) {
        x <- 0
        state <<- TEXT_END
      }
      tp <<- tp + 1L
      text[tp] <<- x
    } else {
      if (text[1L] != 0L) {
        t <- d2i(atof(str(onset)) * sfreq + 0.5)
        txt <- chartr(" \t", "__", str(text))
        cprintf("%s  %7d %5s%5d%5d%5d\t%s", if (t != 0) mstimstr(t) else "    0:00.000",
                t, if (xflag) "\"" else txt, 0, 0, 0, if (xflag) txt else "")
        if (duration[1L] != 0L)
          cprintf("%sduration: %s", if (xflag) " " else "\t", str(duration))
        cout("\n")
      }
      if (x != 0) {
        text[1L] <<- x
        tp <<- 1L
        state <<- TEXT
      } else {
        state <<- IDLE
      }
    }
  }
  repeat {
    fr <- .getframes_full(CHUNK)
    A <- fr$v[, aindex + seq_len(alen), drop = FALSE]
    for (f in seq_len(nrow(A))) {
      state <- IDLE
      for (x in A[f, ]) {
        if (x == 0 && state == IDLE) break
        x <- cint32(x)
        proc(bitwAnd(x, 0xFF))
        proc(bitwAnd(bitwShiftR(x, 8L), 0xFF))
      }
    }
    if (fr$stat < 0 || nrow(A) < CHUNK) break
  }
  wfdbquit()
  0
}
