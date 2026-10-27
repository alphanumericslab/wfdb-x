# apps_md2a.R: md2a -- convert an MIT-format signal file to AHA format.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of convert/md2a.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior).
#
# Original C program: convert/md2a.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2001 George B. Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The samples are copied in blocks (getframes/putframes).

app_md2a <- function(args = character(0)) {
  app_run(.md2a_main, c("md2a", args))
}

.MD2A_EODF <- 32768            # AHA end-of-data flag (0100000)
.MD2A_MAXSIG <- 32             # WFDB_MAXSIG
.MD2A_CHUNK <- 65536           # sample vectors copied at a time

.md2a_help <- function(pname) {
  ceprintf("usage: %s -o AHAFILE -r RECORD [ OPTIONS ... ]\n", pname)
  h <- c(
    "where AHAFILE is the name of the AHA-format output signal file,",
    "RECORD is the record name, and OPTIONS may include:",
    " -h         print this usage summary",
    " -n NEWREC  create a header file for the output signal file, so it",
    "             may be read as record NEWREC")
  cerr(paste0(h, "\n", collapse = ""))
}

.md2a_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  nrec <- NULL
  ofname <- NULL
  record <- NULL
  i <- 2L
  while (i <= argc) {
    a <- argv[i]
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "h") {
        .md2a_help(pname)
        cexit(1)
      } else if (c == "n") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: new record name must follow -n\n", pname)
          cexit(1)
        }
        nrec <- argv[i]
      } else if (c == "o") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: name of AHA-format output file must follow -o\n", pname)
          cexit(1)
        }
        ofname <- argv[i]
      } else if (c == "r") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: record name must follow -r\n", pname)
          cexit(1)
        }
        record <- argv[i]
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
  if (is.null(ofname) || is.null(record)) {
    .md2a_help(pname)
    cexit(1)
  }
  r <- isigopen(record, .MD2A_MAXSIG)
  nsig <- r$nsig
  if (nsig < 1) cexit(2)
  if (!is.null(nrec) && newheader(nrec) < 0) cexit(3)
  s <- lapply(r$si, function(si) {
    si$fname <- ofname
    si$desc <- ""
    si$group <- 0
    si$fmt <- 16
    si
  })
  if (osigfopen(s, nsig) < nsig) cexit(4)
  # while (getvec(x) == nsig && putvec(x) == nsig) ;
  # (x has one element per output sample of a frame, at least WFDB_MAXSIG,
  # initially zero, of which getvec sets the first nsig; in C, x is an
  # uninitialized array of WFDB_MAXSIG: see "Undefined behaviors" in
  # docs/KNOWN_C_BEHAVIORS.md)
  nout <- sum(vapply(s, function(si) max(si$spf, 1), 0))
  pad <- max(nout - nsig, 0)
  repeat {
    g <- getframes(.MD2A_CHUNK, nsig)   # (getvec(x) == nsig)
    v <- g$v
    if (nrow(v) > 0L) {
      if (pad > 0) v <- cbind(v, matrix(0, nrow(v), pad))
      if (putframes(v) != nsig) break
    }
    if (g$stat != nsig) break
  }
  if (!is.null(nrec)) newheader(nrec)
  putvec(c(rep(.MD2A_EODF, nsig), numeric(pad)))
  wfdbquit()
  0
}
