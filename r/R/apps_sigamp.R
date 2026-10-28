# apps_sigamp.R: sigamp -- measure signal amplitudes.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/sigamp.c from the WFDB Software Package 10.7.0,
# by George B. Moody. The translation follows the logic and behavior of the
# original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency or gain: the record
# must give the sampling frequency (the measurement windows are in seconds),
# and with -p the gain of each signal (the original assumed 250 Hz and 200
# adu/mV); --legacy, as the first argument, restores the original behavior.
# Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the
# reasons.
#
# Original C program: app/sigamp.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1991-2009 George B. Moody; revised 2018 by Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# Each measurement window is read with getframes() (exactly the getvec
# calls of the C program) and reduced with vector operations.

app_sigamp <- function(args = character(0)) {
  app_run(.sigamp_main, c("sigamp", args))
}

.SIGAMP_NMAX <- 300        # default number of measurements per signal

.sigamp_help <- function(pname) {
  h <- c(
    "where OPTIONS may include any of:",
    " -a ANN      specify annotator, measure amplitudes near QRS annotations",
    " -d DT1 DT2  set measurement window relative to QRS annotations",
    "              defaults: DT1 = 0.05 (seconds before annotation);",
    "              DT2 = 0.05 (seconds after annotation)",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    paste0(" -n NMAX     make up to NMAX measurements per signal (default: NMAX = ",
           .SIGAMP_NMAX, ")"),
    " -p          print results in physical units (default: ADC units)",
    "              -p may be followed by a character to choose a time format:",
    "  -pd         print time of day and date if known",
    "  -pe         print elapsed time as <hours>:<minutes>:<seconds>",
    "  -ph         print elapsed time in hours",
    "  -pm         print elapsed time in minutes",
    "  -ps         print elapsed time in seconds (default)",
    "  -pS         print elapsed time in sample intervals",
    " -q          quick mode: print individual measurements only",
    " -t TIME     stop at specified time",
    " -v          verbose mode: print individual measurements and trimmed means",
    " -w DTW      set RMS amplitude measurement window",
    "              default: DTW = 1 (second)")
  ceprintf("usage: %s -r RECORD [OPTIONS ...]\n", pname)
  for (s in h) ceprintf("%s\n", s)
}

.sigamp_main <- function(argv) {
  # values for timeunits
  SECONDS <- 1; MINUTES <- 2; HOURS <- 3; TIMSTR <- 4; HHMMSS <- 7; SAMPLES <- 8
  pname <- argv[1L]
  argc <- length(argv)
  arg <- function(i) argv[i + 1L]          # C argv[i]
  ch <- function(a, k) {                    # C a[k] (0-based), "" past the end
    b <- charToRaw(a)
    if (k < length(b)) rawToChar(b[k + 1L]) else ""
  }
  ainame <- NULL
  record <- NULL
  dt1 <- 0; dt2 <- 0; dtw <- 0              # argv indices, then times
  from <- 0; to <- 0
  gvmode <- 0
  nmax <- .SIGAMP_NMAX
  pflag <- 0; qflag <- 0; vflag <- 0
  timeunits <- SECONDS
  i <- 1
  while (i < argc) {
    a <- arg(i)
    if (ch(a, 0) != "-") {
      ceprintf("%s: unrecognized argument %s\n", pname, a)
      cexit(1)
    }
    c <- ch(a, 1)
    if (c == "a") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: annotator name must follow -a\n", pname)
        cexit(1)
      }
      ainame <- arg(i)
    } else if (c == "d") {
      i <- i + 1
      if (i >= argc - 1) {
        ceprintf("%s: DT1 and DT2 must follow -d\n", pname)
        cexit(1)
      }
      dt1 <- i               # converted once the sampling frequency is known
      i <- i + 1
    } else if (c == "f") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: start time must follow -f\n", pname)
        cexit(1)
      }
      from <- i
    } else if (c == "h") {
      .sigamp_help(pname)
      cexit(0)
    } else if (c == "H") {
      gvmode <- WFDB_HIGHRES
    } else if (c == "n") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: number of measurements must follow -n\n", pname)
        cexit(1)
      }
      nmax <- atoi(arg(i))
      if (nmax < 1) nmax <- .SIGAMP_NMAX
    } else if (c == "p") {
      pflag <- 1
      timeunits <- switch(ch(a, 2), d = TIMSTR, e = HHMMSS, h = HOURS,
                          m = MINUTES, S = SAMPLES, SECONDS)
    } else if (c == "q") {
      qflag <- 1
    } else if (c == "r") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: record name must follow -r\n", pname)
        cexit(1)
      }
      record <- arg(i)
    } else if (c == "t") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: stop time must follow -t\n", pname)
        cexit(1)
      }
      to <- i
    } else if (c == "v") {
      vflag <- 1
    } else if (c == "w") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: window size must follow -w\n", pname)
        cexit(1)
      }
      dtw <- i
    } else {
      ceprintf("%s: unrecognized option %s\n", pname, a)
      cexit(1)
    }
    i <- i + 1
  }
  if (is.null(record)) {
    .sigamp_help(pname)
    cexit(1)
  }

  if (gvmode == 0) {
    p <- cgetenv("WFDBGVMODE")
    if (!is.null(p)) gvmode <- atoi(p)
  }
  setgvmode(bitwOr(gvmode, WFDB_GVPAD))
  nsig <- isigopen(record, 0)$nsig
  if (nsig <= 0) cexit(2)
  r <- isigopen(record, nsig)
  if (r$nsig != nsig) cexit(2)
  gain <- vapply(r$si, function(s) s$gain, 0)
  # WFDB-x: no default gain (the C program assumed 200 adu/mV for
  # uncalibrated signals).
  if (wfdbx_get_legacy()) {          # WFDB-x: legacy mode (original behavior)
    gain[gain == 0] <- WFDB_DEFGAIN
  } else if (pflag && any(gain == 0)) {
    .app_uncalibrated(pname, which(gain == 0)[1L] - 1, record, 2)
  }
  amp <- matrix(0, nsig, nmax)              # amp[, k]: measurement k
  # WFDB-x: no default sampling frequency (the C program assumed 250 Hz); the
  # measurement windows are defined in seconds.
  sfreq <- sampfreq(NULL)
  if (sfreq <= 0) {
    if (wfdbx_get_legacy()) sfreq <- WFDB_DEFFREQ     # WFDB-x: legacy mode
    else .app_nofreq(pname, record, 2)
  }

  # Adjust timeunits if the starting time is undefined.
  if ((timeunits == TIMSTR || timeunits == HHMMSS) && !startsWith(timstr(0), "["))
    timeunits <- HHMMSS
  if (timeunits == HOURS) {
    sfreq <- sfreq * 3600
  } else if (timeunits == MINUTES) {
    sfreq <- sfreq * 60
  }
  if (from > 0) from <- strtim(arg(from))
  if (to > 0) to <- strtim(arg(to))
  if (from < 0) from <- -from
  if (to < 0) to <- -to
  if (from >= to) to <- strtim("e")

  namp <- 0
  tm <- numeric(nmax)                       # tm[k]: time of measurement k
  # Print the measurements k (columns of amp), made at times t.
  printamps <- function(t, k) {
    ts <- if (timeunits == TIMSTR) {
      .fmstimstr_v(-t, .tfreq())            # mstimstr(-t)
    } else if (timeunits == HHMMSS) {
      .fmstimstr_v(t, .tfreq())             # mstimstr(t)
    } else if (timeunits == SAMPLES) {
      csprintf_v("%ld", t)
    } else {
      csprintf_v("%lf", t / sfreq)
    }
    x <- amp[, k, drop = FALSE]
    if (pflag) x <- x / gain
    xs <- matrix(csprintf_v("\t%g", x), nsig)
    cout(paste0(ts, apply(xs, 2L, paste0, collapse = ""), "\n", collapse = ""))
  }

  # getrms() of one window: v1 holds its dtw vectors as first read (for the
  # mean), v2 as read again after isigsettime() (v2[1, ] - v1[1, ] corrects
  # the DC error that the seek may introduce in difference formats, as in
  # C).  Returns the RMS amplitude of each signal.
  rms <- function(v1, v2) {
    vmean <- colSums(v1) / dtw + v2[1L, ] - v1[1L, ]   # (sums of integers: exact)
    d <- d2i(v2 - rep(vmean, each = dtw))   # (int)(vv - vmean)
    d <- d * d
    vsum <- if (max(d) * dtw < 2^53) {
      colSums(d)                            # exact
    } else {
      apply(d, 2L, function(x) Reduce(`+`, x, 0))     # in the order of C
    }
    sqrt(vsum / dtw)
  }

  # Read m vectors (one per row); NULL if any getvec call would fail.
  readv <- function(m) {
    g <- getframes(m, nsig)          # (getvec(vv) < nsig: failure)
    if (nrow(g$v) < m || g$stat < nsig) NULL else g$v
  }

  if (!is.null(ainame)) {
    # windows are relative to annotations
    if (dtw > 0) {
      ceprintf("%s: -a and -w options cannot be used together;\n", pname)
      ceprintf("  -w option is being ignored\n")
    }
    if (annopen(record, anninfo(ainame, WFDB_READ), 1) < 0) cexit(2)
    if (dt1 == 0) {
      dt2 <- strtim("0.05")
      dt1 <- -dt2
    } else {
      p <- arg(dt1 + 1)
      dt2 <- if (startsWith(p, "-")) -strtim(substring(p, 2L)) else strtim(p)
      p <- arg(dt1)
      dt1 <- if (startsWith(p, "-")) strtim(substring(p, 2L)) else -strtim(p)
      if (dt1 > dt2) {
        tmp <- dt1
        dt1 <- dt2
        dt2 <- tmp
      }
    }
    if (dt1 == dt2) dt2 <- dt2 + 1
    if (iannsettime(from) < 0) cexit(2)
    repeat {
      g <- getann(0)
      if (g$stat != 0 || namp >= nmax || !(to == 0 || g$annot$time < to)) break
      if (map1(g$annot$anntyp) == NORMAL) {
        # getptp(): peak-to-peak amplitudes from t + dt1 to t + dt2
        t <- g$annot$time
        if (isigsettime(t + dt1) < 0) break
        v <- readv(1 + dt2 - dt1)
        if (is.null(v)) break
        rg <- apply(v, 2L, range)
        amp[, namp + 1] <- cint32(rg[2L, ] - rg[1L, ])
        tm[namp + 1] <- t
        namp <- namp + 1
      }
    }
  } else {
    # windows are consecutive nonoverlapping segments
    if (dt1 > 0) {
      ceprintf("%s: -d option must be used with -a;\n", pname)
      ceprintf("  -d option is being ignored\n")
    }
    if (dtw == 0 || (dtw <- strtim(arg(dtw))) <= 0) dtw <- strtim("1")
    if (from > 0 && isigsettime(from) < 0) cexit(2)
    t <- from
    while (namp < nmax && (to == 0 || t < to)) {
      # getrms(): read the window, then again after isigsettime(t)
      v1 <- readv(dtw)
      if (is.null(v1)) break
      if (isigsettime(t) < 0) break
      v2 <- readv(dtw)
      if (is.null(v2)) break
      amp[, namp + 1] <- rms(v1, v2)
      tm[namp + 1] <- t
      namp <- namp + 1
      t <- t + dtw
    }
  }
  # (the individual measurements, printed together: the same output as
  # printing each one when it is made)
  if ((vflag || qflag) && namp > 0) printamps(tm[seq_len(namp)], seq_len(namp))

  # Trimmed means of the amplitudes (unless -q).
  if (qflag == 0) {
    jlow <- namp %/% 20
    jhigh <- namp - jlow
    if (vflag) cprintf("Trimmed mean")
    for (k in seq_len(nsig)) {
      vals <- sort(amp[k, seq_len(namp)])
      a <- 0
      for (j in seq_len(jhigh - jlow)) a <- a + vals[jlow + j]   # C order
      a <- a / (jhigh - jlow)               # (0/0: -nan, as in C on x86)
      cprintf("\t%g", if (pflag) a / gain[k] else a)
    }
    cprintf("\n")
  }
  0
}
