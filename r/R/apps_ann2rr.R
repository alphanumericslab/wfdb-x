# apps_ann2rr.R: ann2rr -- extract a list of intervals from an annotation
# file.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/ann2rr.c from the WFDB Software Package 10.7.0,
# by George B. Moody. The translation follows the logic and behavior of the
# original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency: the new option -F
# FREQ gives it when the record has no header or its header gives none, and is
# then required for time arguments and for intervals and times in units of time
# (the original assumed 250 Hz); --legacy, as the first argument, restores the
# original behavior. Each change is marked "WFDB-x:" in the code;
# docs/DIVERGENCES.md gives the reasons.
#
# Original C program: app/ann2rr.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1995-2009 George B. Moody; revised 2018-2020 by
#   Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The annotations are read in blocks (.getann_bulk) and the output lines
# are computed with vector operations, except with -i h, -i m or -i s,
# where each interval's end time depends on the rounding of the previous
# one (one annotation at a time, as in C).

app_ann2rr <- function(args = character(0)) {
  app_run(.ann2rr_main, c("ann2rr", args))
}

.ann2rr_help <- function(pname) {
  h <- c("usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
         "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
         " -A      print all intervals between annotations (default: print only RR",
         "          intervals; overrides -c, -p)",
         " -c      print intervals between consecutive valid annotations only",
         " -f TIME start at specified TIME",
         " -F FREQ sampling frequency, if the record header does not specify one",
         " -h      print this usage summary",
         " -i FMT  print intervals using format FMT (see below for values of FMT)",
         " -p TYPE [TYPE ...]  print intervals ending with annotations of specified",
         "                      TYPEs only (use mnemonics such as N or V for TYPE)",
         " -P TYPE [TYPE ...]  print intervals beginning with specified types only",
         " -t TIME stop at specified TIME",
         " -v FMT  print times of ends of intervals using format FMT (see below)",
         " -V FMT  print times of beginnings of intervals using format FMT (see below)",
         " -w      print annotations that end intervals",
         " -W      print annotations that begin intervals",
         "By default, the output contains the RR intervals only, unless one or more",
         "of -v, -V, -w, or -W are used.  Intervals and times are printed in units of",
         "sample intervals, unless a format is specified using -i, -v, or -V.",
         "Formats can be 'h' (hours), 'm' (minutes), 's' (seconds), 't' (hh:mm:ss);",
         "when used with -v or -V, format 'T' yields dates and times if available,",
         "or the format can be omitted to obtain times in sample intervals.  Formats",
         "'h', 'm', and 's' may be followed by a number between 0 and 15, specifying",
         "the number of decimal places (default: 3).  For example, to obtain intervals",
         "in seconds with 8 decimal places, use '-i s8'.")
  h <- .app_help_text(h, h[7L])           # (-F)
  ceprintf(h[1L], pname)
  for (i in 2:length(h)) {
    ceprintf("%s\n", h[i])
    if ((i - 1L) %% 23L == 0L) {
      # (C reads a line from the standard input here)
      cerr("--More--")
      cerr("\033[A\033[2K")
    }
  }
}

.ann2rr_digits <- function(a, default) {
  r <- csscanf(substr(a, 2L, nchar(a, type = "bytes")), "%d")
  if (r$n == 1L) r$v[[1L]] else default
}

# %d of times (vectorized).
.ann2rr_d <- function(x) {
  if (all(abs(x) < .Machine$integer.max)) sprintf("%d", as.integer(x)) else csprintf_v("%lld", x)
}

# WFDB-x: whether output format f (of -i, -v or -V) is a unit of time, which
# needs the sampling frequency.
.ann2rr_time_format <- function(f) f %in% c("h", "m", "s", "t", "T")

.ann2rr_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  record <- ainame <- NULL
  Aflag <- a0flag <- a1flag <- cflag <- 0
  pav <- 0                                # previous_annot_valid
  rrdigits <- t0digits <- t1digits <- 3
  rrformat <- t0format <- t1format <- ""
  t0flag <- t1flag <- 0
  a0f <- logical(ACMAX + 1)
  a1f <- logical(ACMAX + 1)
  a0f[1L] <- a1f[1L] <- TRUE
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
        ainame <- argv[i]
      } else if (c == "A") {
        Aflag <- 1
      } else if (c == "c") {
        cflag <- 1
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
        .ann2rr_help(pname)
        cexit(0)
      } else if (c == "i") {
        i <- i + 1L
        if (i > argc || startsWith(argv[i], "-")) {
          ceprintf("%s: interval output format must follow -i\n", pname)
          cexit(1)
        }
        rrformat <- substr(argv[i], 1L, 1L)
        rrdigits <- .ann2rr_digits(argv[i], rrdigits)
      } else if (c == "p" || c == "P") {
        i <- i + 1L
        j <- if (i <= argc) strann(argv[i]) else 0
        if (i > argc || !isann(j)) {
          ceprintf("%s: annotation mnemonic(s) must follow -%s\n", pname,
                   if (c == "p") "P" else "p")
          cexit(1)
        }
        tbl <- if (c == "p") a1f else a0f
        tbl[j + 1L] <- TRUE
        i <- i + 1L
        while (i <= argc && !startsWith(argv[i], "-")) {
          j <- strann(argv[i])
          if (isann(j)) tbl[j + 1L] <- TRUE
          i <- i + 1L
        }
        if (i > argc || startsWith(argv[i], "-")) i <- i - 1L
        tbl[1L] <- FALSE
        if (c == "p") a1f <- tbl else a0f <- tbl
      } else if (c == "r") {
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
      } else if (c == "v" || c == "V") {
        if (c == "v") t1flag <- 1 else t0flag <- 1
        i <- i + 1L
        if (i > argc || startsWith(argv[i], "-")) {
          i <- i - 1L
        } else if (c == "v") {
          t1format <- substr(argv[i], 1L, 1L)
          t1digits <- .ann2rr_digits(argv[i], t1digits)
        } else {
          t0format <- substr(argv[i], 1L, 1L)
          t0digits <- .ann2rr_digits(argv[i], t0digits)
        }
      } else if (c == "w") {
        a1flag <- 1
      } else if (c == "W") {
        a0flag <- 1
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
    .ann2rr_help(pname)
    cexit(1)
  }
  # WFDB-x: no default sampling frequency (the C program assumed 250 Hz if
  # the record had no header); -F specifies one.  It is needed for times and
  # intervals in units of time.
  sps <- sampfreq(record)
  if (wfdbx_get_legacy()) {              # WFDB-x: legacy mode (original behavior)
    if (sps < 0) setsampfreq(sps <- WFDB_DEFFREQ)
  } else if (sps <= 0 && Ffreq > 0) {
    setsampfreq(sps <- Ffreq)
  }
  if (sps <= 0 && !wfdbx_get_legacy() &&
      ((from && wfdbx_time_needs_freq(argv[from])) ||
       (to && wfdbx_time_needs_freq(argv[to])) ||
       .ann2rr_time_format(rrformat) ||
       (t0flag && .ann2rr_time_format(t0format)) ||
       (t1flag && .ann2rr_time_format(t1format))))
    .app_nofreq(pname, record, 1, useF = TRUE)
  spm <- 60 * sps
  sph <- 60 * spm
  if (annopen(record, list(anninfo(ainame, WFDB_READ)), 1) < 0) cexit(2)
  if (rrdigits < 0 || rrdigits > 15) rrdigits <- 3
  rrfstr <- sprintf("%%.%df", rrdigits)
  if (t0digits < 0 || t0digits > 15) t0digits <- 3
  t0fstr <- sprintf("%%.%df", t0digits)
  if (t1digits < 0 || t1digits > 15) t1digits <- 3
  t1fstr <- sprintf("%%.%df", t1digits)
  if (from) {
    from <- strtim(argv[from])
    if (from < 0) from <- -from
  }
  if (to) {
    to <- strtim(argv[to])
    if (to < 0) to <- -to
  }
  if (to > 0 && to < from) {
    tt <- from
    from <- to
    to <- tt
  }
  if (from > 0 && iannsettime(from) < 0) cexit(2)
  a0 <- NOTQRS
  t0 <- from
  unit <- function(f) switch(f, h = sph, m = spm, s = sps, NA)
  # time columns (-V, -v)
  tcol <- function(t, fmt, fstr, tflag0) {
    if (fmt %in% c("h", "m", "s")) return(sprintf(fstr, t / unit(fmt)))
    if (fmt == "t") {
      r <- character(length(t))
      z <- tflag0 & t == 0
      r[z] <- "    0:00.000"
      r[!z] <- .fmstimstr_v(t[!z], .tfreq())
      return(r)
    }
    if (fmt == "T") return(.fmstimstr_v(-t, .tfreq()))
    .ann2rr_d(t)
  }
  flagv <- function(tbl, a) {
    r <- logical(length(a))
    ok <- !is.na(a) & a >= 0 & a <= ACMAX
    r[ok] <- tbl[a[ok] + 1]
    r
  }
  seqmode <- rrformat %in% c("h", "m", "s")
  chunk <- if (.ann$iad[[1L]]$P$aha) 1 else 4096
  done <- FALSE
  while (!done) {
    A <- .getann_bulk(0, chunk, noaux = TRUE, nofail = TRUE)
    m <- length(A$time)
    if (m == 0L) {
      if (A$stat == 1) getann(0)            # the failing call (prints any error)
      break
    }
    last <- m
    if (to != 0) {
      k <- match(TRUE, A$time > to)
      if (!is.na(k)) {
        last <- k - 1L
        done <- TRUE
      }
    }
    if (last > 0L) {
      idx <- seq_len(last)
      a1 <- A$anntyp[idx]
      t1 <- A$time[idx]
      q <- isqrs(a1) != 0
      vend <- Aflag | (a1f[1L] & q) | flagv(a1f, a1)
      vstart <- Aflag | (a0f[1L] & q) | flagv(a0f, a1)
      if (seqmode) {
        # The interval is printed rounded to rrdigits decimals, and the end
        # time adjusted to the printed value (the start of the next
        # interval).  The printed value m / 10^rrdigits (m an integer) is
        # computed by rounding x * 10^rrdigits when that is certainly what
        # printf gives, otherwise from the printed string; m / 10^rrdigits
        # is then exactly what sscanf reads (a correctly rounded division).
        u <- unit(rrformat)
        p10 <- 10^rrdigits
        pr <- logical(last)
        t0v <- a0v <- xv <- t1a <- numeric(last)
        for (k in idx) {
          tk <- t1[k]
          if (vend[k] && (cflag == 0 || pav == 1)) {
            x <- (tk - t0) / u
            y <- x * p10
            f <- y - floor(y)
            # (rounding y directly gives the result of printf and strtod,
            # unless y is large or close to a tie)
            if (abs(y) < 2^40 && abs(f - 0.5) > 0.01) {
              frr <- round(y) / p10
            } else {
              rrstr <- sprintf(rrfstr, x)
              if (nchar(rrstr) > 19L) rrstr <- substr(rrstr, 1L, 19L)
              frr <- strtod(rrstr)[1L]
            }
            pr[k] <- TRUE
            t0v[k] <- t0
            a0v[k] <- a0
            xv[k] <- x
            tk <- trunc(t0 + frr * u + 0.5)
            t1a[k] <- tk
          }
          if (vstart[k]) {
            a0 <- a1[k]
            t0 <- tk
            pav <- 1
          } else if (cflag) {
            pav <- 0
          }
        }
        pr <- which(pr)
        if (length(pr)) {
          cols <- list()
          if (t0flag) cols[[length(cols) + 1L]] <- paste0(tcol(t0v[pr], t0format, t0fstr, TRUE), "\t")
          if (a0flag) cols[[length(cols) + 1L]] <-
            ifelse(a0v[pr] == NOTQRS, "[0]\t", paste0(annstr(a0v[pr]), "\t"))
          rrstr <- sprintf(rrfstr, xv[pr])
          long <- nchar(rrstr) > 19L
          rrstr[long] <- substr(rrstr[long], 1L, 19L)
          cols[[length(cols) + 1L]] <- rrstr
          if (a1flag) cols[[length(cols) + 1L]] <- paste0("\t", annstr(a1[pr]))
          if (t1flag) cols[[length(cols) + 1L]] <- paste0("\t", tcol(t1a[pr], t1format, t1fstr, FALSE))
          cols[[length(cols) + 1L]] <- "\n"
          cout(paste0(do.call(paste0, cols), collapse = ""))
        }
      } else {
        # a0, t0 and previous_annot_valid before each annotation
        js <- cummax(ifelse(vstart, idx, 0L))
        jb <- c(0L, js[-last])                # last valid start before k
        a0v <- ifelse(jb > 0L, a1[pmax(jb, 1L)], a0)
        t0v <- ifelse(jb > 0L, t1[pmax(jb, 1L)], t0)
        pv <- if (cflag) c(pav, as.numeric(vstart[-last])) else rep(1, last)
        pr <- which(vend & (cflag == 0 | pv == 1))
        if (length(pr)) {
          cols <- list()
          if (t0flag) cols[[length(cols) + 1L]] <- paste0(tcol(t0v[pr], t0format, t0fstr, TRUE), "\t")
          if (a0flag) cols[[length(cols) + 1L]] <-
            ifelse(a0v[pr] == NOTQRS, "[0]\t", paste0(annstr(a0v[pr]), "\t"))
          rr <- t1[pr] - t0v[pr]
          cols[[length(cols) + 1L]] <- if (rrformat == "t") {
            .fmstimstr_v(t1[pr], .tfreq())
          } else {
            .ann2rr_d(rr)
          }
          if (a1flag) cols[[length(cols) + 1L]] <- paste0("\t", annstr(a1[pr]))
          if (t1flag) cols[[length(cols) + 1L]] <- paste0("\t", tcol(t1[pr], t1format, t1fstr, FALSE))
          cols[[length(cols) + 1L]] <- "\n"
          cout(paste0(do.call(paste0, cols), collapse = ""))
        }
        if (js[last] > 0L) {
          a0 <- a1[js[last]]
          t0 <- t1[js[last]]
        }
        if (vstart[last]) pav <- 1 else if (cflag) pav <- 0
        if (!cflag && any(vstart)) pav <- 1
      }
    }
    if (A$stat != 0 && !done) {
      if (A$stat == 1) getann(0)
      break
    }
  }
  0
}
