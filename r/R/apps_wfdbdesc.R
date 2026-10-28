# apps_wfdbdesc.R: wfdbdesc -- describe signal specifications.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/wfdbdesc.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency, gain, ADC
# resolution or units: an unspecified sampling frequency or ADC resolution is
# shown as "not specified" (lengths are then given in sample intervals only), a
# gain of 0 as "uncalibrated" (the original: "uncalibrated; assume 200"), and
# unspecified units as "adu/nd" (the original assumed 250 Hz, 12 bits and
# millivolts); --legacy, as the first argument, restores the original behavior.
# Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the
# reasons.
#
# Original C program: app/wfdbdesc.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1989-2012 George B. Moody; revised 2018-2020 by
#   Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

app_wfdbdesc <- function(args = character(0)) {
  app_run(.wfdbdesc_main, c("wfdbdesc", args))
}

.wfdbdesc_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  msrec <- 0
  if (argc < 2L) {
    ceprintf("usage: %s RECORD [-readable]\n", pname)
    cexit(1)
  }
  rec <- argv[2L]
  nsig <- isigopen(rec, 0)$nsig
  if (nsig < 0) cexit(2)
  s <- list()
  if (nsig > 0 && argc > 2L && startsWith("-readable", argv[3L])) {
    r <- isigopen(rec, nsig)
    nsig <- r$nsig
    s <- r$si
  } else if (nsig > 0) {
    r <- isigopen(rec, -nsig)
    nsig <- r$nsig
    s <- r$si
  }
  cprintf("Record %s", rec)
  setgvmode(WFDB_LOWRES)
  t <- strtim("e")
  if (nsig > 0 && (s[[1L]]$fmt == 0 || s[[1L]]$nsamp != 0) && s[[1L]]$nsamp != t) {
    msrec <- 1
    cprintf(" (a %s-layout multi-segment record)\n",
            if (s[[1L]]$nsamp == 0) "variable" else "fixed")
    if (s[[1L]]$nsamp != 0) {
      cout("----------------------------------------------\n")
      cout("The following data apply to the entire record:\n")
      cout("----------------------------------------------")
    }
  }
  info <- getinfo(rec)
  if (!is.null(info)) {
    cout("\nNotes\n=====\n")
    while (!is.null(info)) {
      cprintf("%s\n", info)
      info <- getinfo(NULL)
    }
    cout("=====\n")
  }
  # WFDB-x: if the sampling frequency is not specified, times are not shown
  # (the C program assumed 250 Hz).  In legacy mode, the output is that of the
  # C program.
  legacy <- wfdbx_get_legacy()
  freq <- sampfreq(NULL)
  showtimes <- freq > 0 || legacy
  p <- if (showtimes) mstimstr(0) else ""
  cprintf("\nStarting time: %s\n", if (startsWith(p, "[")) p else "not specified")
  cout("Length: ")
  done <- FALSE
  if (!showtimes && (nsig < 1 || t > 0)) {
    cprintf("%d sample intervals\n", t)
    done <- TRUE
  } else if (nsig < 1 || t > 0) {
    cprintf("%s (%d sample intervals)\n", if (t > 0) mstimstr(t) else "0", t)
    done <- TRUE
  } else if (s[[1L]]$fmt) {
    fn <- s[[1L]]$fname
    nbytes <- if (!is.null(fn) && file.exists(fn) && !dir.exists(fn))
      suppressWarnings(file.size(fn)) else NA
    if (!is.na(nbytes)) {
      nbytes <- nbytes - wfdbgetstart(0)
      framesize <- 0
      for (k in seq_len(nsig)) {
        if (s[[k]]$group != 0) break
        framesize <- framesize + s[[k]]$spf
      }
      f <- s[[1L]]$fmt
      t <- if (f %in% c(8, 80)) {
        cdiv(nbytes, framesize)
      } else if (f %in% c(16, 61, 160)) {
        cdiv(nbytes, 2 * framesize)
      } else if (f == 24) {
        cdiv(nbytes, 3 * framesize)
      } else if (f == 32) {
        cdiv(nbytes, 4 * framesize)
      } else if (f == 212) {
        cdiv(2 * nbytes, 3 * framesize)
      } else if (f %in% c(310, 311)) {
        cdiv(3 * nbytes, 4 * framesize)
      } else {
        -1
      }
      if (t >= 0 && !showtimes) {
        cprintf("%d sample intervals [from signal file size]\n", t)
      } else if (t >= 0) {
        cprintf("%s (%d sample intervals) [from signal file size]\n", mstimstr(t), t)
      } else {
        cout("not specified\n")
      }
      done <- TRUE
    }
  }
  if (!done) cout("not specified\n")
  if (showtimes) {
    cprintf("Sampling frequency: %.12g Hz\n", freq)
  } else {
    cout("Sampling frequency: not specified\n")
  }
  cprintf("%d signal%s\n", nsig, if (nsig == 1) "" else "s")
  if (nsig < 1) cexit(2)
  if (msrec && s[[1L]]$nsamp != 0) {
    cout("----------------------------------------------\n")
    cout("The following data apply to the first segment:\n")
    cout("----------------------------------------------\n")
    if (showtimes) {
      cprintf("Segment length: %s (%d sample intervals)\n", mstimstr(s[[1L]]$nsamp),
              s[[1L]]$nsamp)
    } else {
      cprintf("Segment length: %d sample intervals\n", s[[1L]]$nsamp)
    }
  }
  for (i in seq_len(nsig)) {
    si <- s[[i]]
    cprintf("Group %d, Signal %d:\n", si$group, i - 1)
    cprintf(" File: %s\n", if (si$fmt) si$fname else "[none]")
    cprintf(" Description: %s\n", si$desc)
    cout(" Gain: ")
    if (legacy) {                             # WFDB-x: as in the C program
      if (si$gain == 0) cprintf("uncalibrated; assume %g", WFDB_DEFGAIN)
      else cprintf("%.12g", si$gain)
      cprintf(" adu/%s\n", if (!is.null(si$units)) si$units else "mV")
    } else if (si$gain == 0) {                # WFDB-x: no default gain
      cout("uncalibrated\n")
    } else {
      cprintf("%.12g adu/%s\n", si$gain, if (!is.null(si$units)) si$units else "nd")  # WFDB-x: C: mV
    }
    cprintf(" Initial value: %d\n", si$initval)
    if (si$fmt != 0) cprintf(" Storage format: %d", si$fmt)
    if (si$spf > 1) cprintf(" (%d samples per frame)", si$spf)
    if (si$fmt != 0 || si$spf > 1) cout("\n")
    cout(" I/O: ")
    if (si$bsize == 0) {
      cout("can be unbuffered\n")
    } else {
      cprintf("%d-byte blocks\n", si$bsize)
    }
    if (si$adcres > 0 || legacy) {
      cprintf(" ADC resolution: %d bits\n", si$adcres)
    } else {                                  # WFDB-x: no default resolution
      cout(" ADC resolution: not specified\n")
    }
    cprintf(" ADC zero: %d\n", si$adczero)
    cprintf(" Baseline: %d\n", si$baseline)
    if (si$nsamp > 0) cprintf(" Checksum: %d\n", si$cksum)
  }
  0
}
