# apps_rdann.R: rdann -- print an annotation file in ASCII form.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/rdann.c from the WFDB Software Package 10.7.0,
# by T. Baker and George B. Moody. The translation follows the logic and
# behavior of the original program, but it is new code, not the original C
# code.
#
# Changes from the original: no built-in sampling frequency: the new option -F
# FREQ gives it when the record has no header or its header gives none, and is
# then required (the original assumed 250 Hz); --legacy, as the first argument,
# restores the original behavior. Each change is marked "wfdb-x:" in the code;
# docs/DIVERGENCES.md gives the reasons.
#
# Original C program: app/rdann.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1981-2010 George B. Moody; revised 2017-2018 by
#   Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The annotations are read in blocks (.getann_bulk) and their lines
# formatted with vector operations; the result is exactly that of the C
# program's loop of getann calls.

app_rdann <- function(args = character(0)) {
  app_run(.rdann_main, c("rdann", args))
}

.rdann_help <- function(pname) {
  ceprintf("usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n", pname)
  h <- c("where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
         " -c CHAN             print annotations with specified CHAN only",
         " -e                  * show annotation times as elapsed times",
         " -f TIME             start at specified TIME",
         " -F FREQ             sampling frequency, if the record header does not",
         "                      specify one",
         " -h                  print this usage summary",
         " -n NUM              print annotations with specified NUM only",
         " -p TYPE [TYPE ...]  print annotations of specified TYPEs only",
         " -s SUBTYPE          print annotations with specified SUBTYPE only",
         " -t TIME             stop at specified TIME",
         " -v                  print column headings",
         " -x                  * use alternate time format (seconds, minutes, hours)",
         "* Only one of -e and -x can be used.")
  h <- .app_help_text(h, h[5:6])          # (-F)
  for (s in h) ceprintf("%s\n", s)
}

.rdann_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  arg <- function(i) argv[i + 1L]          # C's argv[i]
  record <- NULL
  ainame <- NULL
  cflag <- nflag <- sflag <- 0
  chanmatch <- nummatch <- submatch <- 0
  eflag <- vflag <- xflag <- 0
  afrom <- anum <- ato <- bfrom <- bnum <- bto <- 0
  from <- 0
  to <- 0
  Ffreq <- 0
  flag <- logical(ACMAX + 1)
  if (argc >= 3L && !startsWith(arg(1L), "-")) {
    ainame <- arg(1L)
    record <- arg(2L)
    i <- 3L
    if (argc > 3L) {
      from <- 3L
      i <- 4L
    }
    if (argc > 4L) {
      to <- 4L
      i <- 5L
    }
    if (argc <= 5L) {
      flag[1L] <- TRUE
    } else {
      while (i < argc && !startsWith(arg(i), "-")) {
        j <- strann(arg(i))
        if (isann(j)) flag[j + 1L] <- TRUE
        i <- i + 1L
      }
    }
  } else {
    i <- 1L
    flag[1L] <- TRUE
  }
  while (i < argc) {
    a <- arg(i)
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "a") {
        i <- i + 1L
        if (i >= argc) {
          ceprintf("%s: annotator must follow -a\n", pname)
          cexit(1)
        }
        ainame <- arg(i)
      } else if (c == "c") {
        i <- i + 1L
        if (i >= argc) {
          ceprintf("%s: chan value (between -128 and 127) must follow -c\n", pname)
          cexit(1)
        }
        chanmatch <- cint8(atoi(arg(i)))
        cflag <- 1
      } else if (c == "e") {
        eflag <- 1
        xflag <- 0
      } else if (c == "f") {
        i <- i + 1L
        if (i >= argc) {
          ceprintf("%s: starting time must follow -f\n", pname)
          cexit(1)
        }
        from <- i
      } else if (c == "F" && !wfdbx_get_legacy()) {  # frequency follows (wfdb-x)
        i <- i + 1L
        Ffreq <- .app_Fopt(pname, if (i < argc) arg(i) else NULL)
      } else if (c == "h") {
        .rdann_help(pname)
        cexit(0)
      } else if (c == "n") {
        i <- i + 1L
        if (i >= argc) {
          ceprintf("%s: num value (between -128 and 127) must follow -n\n", pname)
          cexit(1)
        }
        nummatch <- cint8(atoi(arg(i)))
        nflag <- 1
      } else if (c == "p") {
        i <- i + 1L
        j <- if (i < argc) strann(arg(i)) else 0
        if (i >= argc || !isann(j)) {
          ceprintf("%s: annotation mnemonic(s) must follow -p\n", pname)
          cexit(1)
        }
        flag[j + 1L] <- TRUE
        i <- i + 1L
        while (i < argc && !startsWith(arg(i), "-")) {
          j <- strann(arg(i))
          if (isann(j)) flag[j + 1L] <- TRUE
          i <- i + 1L
        }
        if (i == argc || startsWith(arg(i), "-")) i <- i - 1L
        flag[1L] <- FALSE
      } else if (c == "r") {
        i <- i + 1L
        if (i >= argc) {
          ceprintf("%s: input record name must follow -r\n", pname)
          cexit(1)
        }
        record <- arg(i)
      } else if (c == "s") {
        i <- i + 1L
        if (i >= argc) {
          ceprintf("%s: subtyp value (between -128 and 127) must follow -s\n", pname)
          cexit(1)
        }
        submatch <- cint8(atoi(arg(i)))
        sflag <- 1
      } else if (c == "t") {
        i <- i + 1L
        if (i >= argc) {
          ceprintf("%s: end time must follow -t\n", pname)
          cexit(1)
        }
        to <- i
      } else if (c == "v") {
        vflag <- 1
      } else if (c == "x") {
        xflag <- 1
        eflag <- 0
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
    .rdann_help(pname)
    cexit(1)
  }
  # wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
  # the record had no header); -F specifies one.
  sps <- sampfreq(record)
  if (wfdbx_get_legacy()) {              # wfdb-x: legacy mode (original behavior)
    if (sps < 0) setsampfreq(sps <- WFDB_DEFFREQ)
  } else {
    if (sps <= 0 && Ffreq > 0) setsampfreq(sps <- Ffreq)
    if (sps <= 0) .app_nofreq(pname, record, 1, useF = TRUE)
  }
  if (annopen(record, list(anninfo(ainame, WFDB_READ)), 1) < 0) cexit(2)
  tps <- getiaorigfreq(0)
  if (tps < sps) tps <- sps
  sprec <- 3
  n <- 1000
  while (n < tps) {
    sprec <- sprec + 1
    n <- n * 10
  }
  tpm <- 60 * tps
  mprec <- 5
  n <- 100000
  while (n < tpm) {
    mprec <- mprec + 1
    n <- n * 10
  }
  tph <- 60 * tpm
  hprec <- 7
  n <- 10000000
  while (n < tph) {
    hprec <- hprec + 1
    n <- n * 10
  }
  qrs <- function(a) isqrs(a) != 0
  if (from) {
    fa <- arg(from)
    if (startsWith(fa, "a")) {
      afrom <- strtol(fa, 10, 2)[1L]
      if (afrom < 0) afrom <- from <- 0
      while (anum < afrom) {
        A <- .getann_bulk(0, afrom - anum, noaux = TRUE)
        anum <- anum + length(A$time)
        bnum <- bnum + sum(qrs(A$anntyp))
        if (A$stat != 0) break
      }
      if (anum < afrom) cexit(2)
    } else if (startsWith(fa, "b") || startsWith(fa, "#")) {
      bfrom <- strtol(fa, 10, 2)[1L]
      if (bfrom < 0) bfrom <- from <- 0
      while (bnum < bfrom) {
        # (each annotation adds at most 1 to bnum: none is read beyond C)
        A <- .getann_bulk(0, bfrom - bnum, noaux = TRUE)
        anum <- anum + length(A$time)
        bnum <- bnum + sum(qrs(A$anntyp))
        if (A$stat != 0) break
      }
      if (bnum < bfrom) cexit(2)
    } else if (iannsettime(strtim(fa)) < 0) {
      cexit(2)
    }
  }
  if (to) {
    ta <- arg(to)
    if (startsWith(ta, "a")) {
      ato <- strtol(ta, 10, 2)[1L]
      if (ato < 0) ato <- 0
      bto <- 0
      to <- 0
    } else if (startsWith(ta, "b")) {
      bto <- strtol(ta, 10, 2)[1L]
      if (bto < 0) bto <- 0
      ato <- 0
      to <- 0
    } else if (startsWith(ta, "#")) {
      bto <- strtol(ta, 10, 2)[1L]
      if (bto < 1) bto <- 1
      bto <- bto + bnum
      ato <- 0
      to <- 0
    } else {
      ato <- bto <- 0
      to <- strtim(ta)
      if (to < 0) to <- -to
    }
  }
  if (vflag) {
    if (eflag) {
      cout("Elapsed time  Sample #  ")
    } else if (xflag) {
      cout("  Seconds   Minutes     Hours  ")
    } else {
      s <- mstimstr(-1)
      if (grepl("/", s, fixed = TRUE)) {
        cout("      Time       Date     Sample #  ")
      } else if (startsWith(s, "[")) {
        cout("      Time     Sample #  ")
      } else {
        cout("      Time   Sample #  ")
      }
    }
    cout("Type  Sub Chan  Num\tAux\n")
  }
  setifreq(tps)
  setiafreq(0, tps)
  xfmt <- sprintf("%%%d.%df %%%d.%df %%%d.%df", sprec + 6, sprec, mprec + 4, mprec,
                  hprec + 2, hprec)
  # (annotations are read 4096 at a time; one at a time from AHA files,
  # where reading an annotation may print a message, so that no
  # annotation is read beyond the last one C reads)
  chunk <- if (.ann$iad[[1L]]$P$aha) 1 else 4096
  done <- FALSE
  while (!done) {
    A <- .getann_bulk(0, chunk, noaux = FALSE, nofail = TRUE)
    m <- length(A$time)
    if (m == 0L) {
      if (A$stat == 1) getann(0)            # the failing call (prints any error)
      break
    }
    sn <- if (tps == sps) A$time else floor(A$time * sps / tps + 0.5)
    at <- A$anntyp
    last <- m
    if (to != 0) {
      k <- match(TRUE, sn > to)
      if (!is.na(k)) {
        last <- k - 1L
        done <- TRUE
      }
    }
    if (ato) {
      k <- ato - anum
      if (k <= last) {
        last <- max(k, 1)
        done <- TRUE
      }
    }
    isq <- qrs(at)
    if (bto) {
      k <- match(TRUE, bnum + cumsum(isq) >= bto & isq)
      if (!is.na(k) && k <= last) {
        last <- k
        done <- TRUE
      }
    }
    idx <- seq_len(last)
    if (ato) anum <- anum + last
    if (bto) bnum <- bnum + sum(isq[idx])
    sel <- if (flag[1L]) rep(TRUE, last) else {
      ok <- isann(at[idx])
      r <- logical(last)
      r[ok] <- flag[at[idx][ok] + 1]
      r
    }
    if (cflag) sel <- sel & A$chan[idx] == chanmatch
    if (nflag) sel <- sel & A$num[idx] == nummatch
    if (sflag) sel <- sel & A$subtyp[idx] == submatch
    q <- which(sel)
    if (length(q)) {
      tq <- A$time[q]
      mn <- annstr(at[q])
      sb <- A$subtyp[q]
      ch <- A$chan[q]
      nm <- A$num[q]
      auxs <- character(length(q))
      aq <- A$aux[q]
      ha <- which(lengths(aq) > 0L)
      if (length(ha)) auxs[ha] <- paste0("\t", .aux_strings(aq[ha]))
      if (xflag) {
        line <- paste0(sprintf(xfmt, tq / tps, tq / tpm, tq / tph),
                       sprintf("%6s%5d%5d%5d", mn, as.integer(sb), as.integer(ch), as.integer(nm)))
      } else {
        ts <- .fmstimstr_v(if (eflag) tq else -tq, .tfreq())
        snq <- sn[q]
        line <- if (all(abs(snq) < .Machine$integer.max)) {
          sprintf("%s  %7d%6s%5d%5d%5d", ts, as.integer(snq), mn, as.integer(sb), as.integer(ch),
                  as.integer(nm))
        } else {
          paste0(ts, "  ", .fmt_d(snq, 7L),
                 sprintf("%6s%5d%5d%5d", mn, as.integer(sb), as.integer(ch), as.integer(nm)))
        }
      }
      cout(paste0(line, auxs, "\n", collapse = ""))
    }
    if (A$stat != 0 && !done) {
      if (A$stat == 1) getann(0)
      break
    }
  }
  0
}

# %Nd of integer-valued doubles (vectorized).
.fmt_d <- function(x, w) {
  if (length(x) && all(abs(x) < .Machine$integer.max)) sprintf(paste0("%", w, "d"), as.integer(x)) else
    csprintf_v(paste0("%", w, "lld"), x)
}
