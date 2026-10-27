# apps_ad2m.R: ad2m -- convert an AHA-format signal file to MIT format.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of convert/ad2m.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in signal parameters: the new options -F
# FREQ, -G GAIN, -R BITS and -U UNITS give the sampling frequency, gain, ADC
# resolution and units, and are required (-U unless the gain is 0; the original
# assumed those of the AHA database: 250 Hz, 400 adu/mV, 12 bits and
# millivolts); the -f and -t times are converted at the -F frequency; --legacy,
# as the first argument, restores the original behavior. Each change is marked
# "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
#
# Original C program: convert/ad2m.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1983-2007 George B. Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The input file becomes the standard input (C freopen: stdin_freopen).
# Uncompressed files are read as record "16" (two format 16 signals on the
# standard input) and copied in blocks; compressed files are decoded with
# vector operations.

app_ad2m <- function(args = character(0)) {
  app_run(.ad2m_main, c("ad2m", args))
}

.AD2M_EODF <- 32768            # AHA end-of-data flag (0100000)
.AD2M_CHUNK <- 65536           # sample vectors copied at a time

.ad2m_help <- function(pname) {
  ceprintf("usage: %s -i AHAFILE [ OPTIONS ... ]\n", pname)
  h <- c(
    "where AHAFILE is the name of the AHA-format input signal file,",
    "and OPTIONS may include:",
    " -c         process a compressed input file (default if AHAFILE ends",
    "             with .CMP or .cmp;  otherwise old AHA tape format assumed)",
    " -f TIME    begin at specified TIME (default: 0, i.e., the beginning",
    "             of the input file)",
    " -F FREQ    sampling frequency in Hz (required; AHA database: 250)",
    " -G GAIN    gain in adu per physical unit (required; AHA database: 400)",
    " -h         print this usage summary",
    # (sic: a missing comma in the C source joins these two lines)
    paste0(" -r RECORD  specify the name of the output RECORD (default: use the,",
           "            input file name, less path info and extension, as RECORD)"),
    " -R BITS    ADC resolution in bits (required; AHA database: 12)",
    " -t TIME    stop at specified TIME (default: 35 minutes after the",
    "             starting time if RECORD=x2xx or x3xx, 3 hours if",
    "             RECORD=x0xx or x1xx, or the end of the input file)",
    " -U UNITS   physical units (required unless the gain is 0; AHA: mV)")
  h <- .app_help_text(h, h[c(7L, 8L, 11L, 15L)])     # (-F, -G, -R, -U)
  cerr(paste0(h, "\n", collapse = ""))
}

.ad2m_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  cflag <- FALSE
  ifname <- NULL
  record <- NULL
  t <- 0
  start_time <- 0
  end_time <- 0
  fstr <- tstr <- NULL                      # wfdb-x: -f and -t, converted once -F is known
  Ffreq <- 0                                # wfdb-x: -F, -G, -R and -U
  Ggain <- NULL
  Rres <- 0
  Uunits <- NULL
  opt <- function() if (i <= argc) argv[i] else NULL
  legacy <- wfdbx_get_legacy()
  if (legacy) {
    # wfdb-x: in legacy mode, the parameters of the AHA database, set by the C
    # program (250 Hz, 400 adu/mV, 12 bits, and no units, i.e., millivolts);
    # -F, -G, -R and -U are not options then.
    Ffreq <- 250
    Ggain <- 400
    Rres <- 12
    setsampfreq(250)
  }
  i <- 2L
  while (i <= argc) {
    a <- argv[i]
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "c") {
        cflag <- TRUE
      } else if (c == "f") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: start time must follow -f\n", pname)
          cexit(1)
        }
        if (legacy) start_time <- strtim(argv[i])   # wfdb-x: as in the C program
        else fstr <- argv[i]
      } else if (c == "h") {
        .ad2m_help(pname)
        cexit(1)
      } else if (c == "i") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: name of AHA-format input file must follow -i\n", pname)
          cexit(1)
        }
        ifname <- argv[i]
      } else if (c == "r") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: record name must follow -r\n", pname)
          cexit(1)
        }
        record <- argv[i]
      } else if (c == "t") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: end time must follow -t\n", pname)
          cexit(1)
        }
        if (legacy) end_time <- strtim(argv[i])     # wfdb-x: as in the C program
        else tstr <- argv[i]
      } else if (c == "F" && !legacy) {     # sampling frequency (WFDB-x)
        i <- i + 1L
        Ffreq <- .app_Fopt(pname, opt())
      } else if (c == "G" && !legacy) {                # gain in adu per physical unit (WFDB-x)
        i <- i + 1L
        Ggain <- .app_Gopt(pname, opt())
      } else if (c == "R" && !legacy) {                # ADC resolution in bits (WFDB-x)
        i <- i + 1L
        Rres <- .app_Ropt(pname, opt())
      } else if (c == "U" && !legacy) {                # physical units (WFDB-x)
        i <- i + 1L
        Uunits <- .app_Uopt(pname, opt())
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
    .ad2m_help(pname)
    cexit(1)
  }
  # wfdb-x: the signal parameters must be given explicitly; the C program
  # assumed those of the AHA database (250 Hz, 400 adu/mV, 12 bits, and no
  # units, i.e., millivolts), as legacy mode does (the values set above for
  # legacy mode pass these checks, and no units are required then).
  .app_require_params(pname, Ffreq, Ggain, Rres, if (legacy) NA else Uunits)
  setsampfreq(Ffreq)
  if (!is.null(fstr)) start_time <- strtim(fstr)
  if (!is.null(tstr)) end_time <- strtim(tstr)
  if (end_time > 0 && end_time <= start_time) {
    .ad2m_help(pname)
    cexit(1)
  }
  n <- nchar(ifname, type = "bytes")
  if (!cflag && n > 4L && substr(ifname, n - 3L, n) %in% c(".CMP", ".cmp")) cflag <- TRUE
  if (!stdin_freopen(ifname)) {
    ceprintf("%s: can't read input file `%s'\n", pname, ifname)
    cexit(2)
  }
  if (is.null(record)) record <- .a2m_basename_record(ifname)
  d <- .a2m_aha_digit(record)
  if (end_time == 0) {
    if (d %in% c("2", "3")) {
      end_time <- strtim("35:0")
    } else if (d %in% c("0", "1")) {
      end_time <- strtim("3:0:0")
    }
  }
  if (end_time == 0) {
    ceprintf("%s: warning: end time not specified, output may be truncated\n", pname)
    ceprintf("               rerun with -t TIME to override\n")
    end_time <- start_time + strtim("100:0:0")
  }
  dfname <- paste0(record, ".dat")
  df <- siginfo(fname = dfname, desc = "", units = Uunits, gain = Ggain, fmt = 212,
                adcres = Rres, spf = 0)
  if (osigfopen(list(df, df), 2) < 0) cexit(3)
  if (!cflag) {
    if (isigopen("16", 2)$nsig < 2) cexit(2)
    if (start_time > 0) {
      t <- start_time
      if (isigsettime(t) < 0) cexit(2)
    }
    # while (getvec(v) == 2 && v[0] != EODF && putvec(v) > 0 && ++t < end_time) ;
    repeat {
      g <- getframes(.AD2M_CHUNK)
      v <- g$v
      n <- nrow(v)
      done <- FALSE
      k <- match(.AD2M_EODF, v[, 1L])
      if (!is.na(k)) {
        n <- k - 1L
        done <- TRUE
      }
      m <- max(end_time - t, 1)          # putvec calls left before end_time
      if (n >= m) {
        n <- m
        done <- TRUE
      }
      if (n > 0) {
        if (putframes(v[seq_len(n), 1:2, drop = FALSE]) <= 0) break
        t <- t + n
      }
      if (done || g$stat != 2) break
    }
    newheader(record)
    while (getframes(.AD2M_CHUNK)$stat >= 0) {}
  } else {
    nskip <- max(start_time - t, 0)
    nmax <- nskip + max(end_time - (t + nskip), 1)
    r <- .ad2m_getcvecs(stdin_bytes(), nmax)
    if (r$bad) ceprintf("unexpected EOF in input file\n")
    if (r$n > nskip) putframes(r$v[(nskip + 1):r$n, , drop = FALSE])
    newheader(record)
  }
  wfdbquit()
  0
}

# Up to nmax successive calls of getcvec() (the compressed AHA format: a
# pair of first differences in 2 bytes, or a pair of 16-bit differences in
# 4 bytes if the first byte has its high bit set).  Returns list(v =
# matrix of the n vectors decoded, n, bad = whether decoding stopped
# inside a vector, where getcvec prints "unexpected EOF").
.ad2m_getcvecs <- function(b, nmax) {
  b <- as.integer(b)
  nb <- length(b)
  # the chain of record starts from byte 1 (pointer doubling)
  long <- b >= 128L
  nxt <- pmin(seq_len(nb) + ifelse(long, 4L, 2L), nb + 1L)
  nxt <- c(nxt, nb + 1L)
  on <- logical(nb + 1L)
  on[1L] <- TRUE
  J <- nxt
  while (J[1L] <= nb) {
    on[J[on]] <- TRUE
    J <- J[J]
  }
  on[J[on]] <- TRUE
  pos <- which(on[seq_len(nb)])
  # a record that does not fit ends the decoding
  # (only the last one can be incomplete)
  nfit <- sum(pos + ifelse(long[pos], 3L, 1L) <= nb)
  bad <- nfit < length(pos) && nfit < nmax
  n <- min(nfit, nmax)
  pos <- pos[seq_len(n)]
  x <- b[pos]
  y <- b[pos + 1L]
  lg <- long[pos]
  d0 <- numeric(n)
  d1 <- numeric(n)
  s <- !lg
  d0[s] <- bitwAnd(x[s], 0x7f) - 128 * (bitwAnd(x[s], 0x40) != 0)
  d1[s] <- y[s] - 256 * (y[s] >= 128L)
  pl <- pos[lg]
  xl <- x[lg]
  d0[lg] <- (bitwAnd(xl, 0x3f) - 64 * (bitwAnd(xl, 0x40) != 0)) * 256 + y[lg]
  x2 <- b[pl + 2L]
  d1[lg] <- (x2 - 256 * (x2 >= 128L)) * 256 + b[pl + 3L]
  list(v = cint32(cbind(cumsum(d0), cumsum(d1))), n = n, bad = bad)
}
