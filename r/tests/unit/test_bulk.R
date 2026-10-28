# Tests of the block reads of getframes() and read_record() (port of the
# bulk tests of python/tests/test_signals.py): multi-frequency records in
# every reading mode, multi-segment records of fixed and variable layout
# (with null segments), every record of tests/data, getframes() mixed with
# getvec() and isigsettime(); and the signal names of the high-level
# readers, without the white space at their ends.  Each read is compared
# with the same read with the block path turned off (frame by frame,
# through getvec).
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It tests WFDB-x; it has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

if (.mode == "source") {
  datasrc <- file.path(dirname(dirname(.rdir)), "tests", "data")
  old <- getwd()
  d <- tempfile("wfdbx-bulk")
  dir.create(d)
  file.copy(list.files(datasrc, full.names = TRUE, all.files = FALSE), d, recursive = TRUE)
  setwd(d)
  # The block path is turned off by replacing .bulk_frames (NULL: never
  # used); blocks are limited to 1229 vectors, so that a record is read in
  # several of them.
  benv <- environment(.getframes)
  rebind <- function(name, value) {
    locked <- bindingIsLocked(name, benv)
    if (locked) unlockBinding(name, benv)
    assign(name, value, envir = benv)
    if (locked) lockBinding(name, benv)
  }
  bulk_orig <- get(".bulk_frames", envir = benv)
  max_orig <- get(".BULK_MAXFRAMES", envir = benv)
  on.exit({
    rebind(".bulk_frames", bulk_orig)
    rebind(".BULK_MAXFRAMES", max_orig)
    wfdbquit()
    wfdbverbose()
    setwd(old)
    unlink(d, recursive = TRUE)
    wfdbio_reset()
    sig_reset()
  }, add = TRUE)
  wfdbquit()
  rebind(".BULK_MAXFRAMES", 1229)
  bulk_off <- function(n, full = FALSE, int = FALSE) NULL
  # (rows read by .bulk_frames)
  bulk_count <- 0
  bulk_counted <- function(n, full = FALSE, int = FALSE) {
    r <- bulk_orig(n, full, int)
    if (!is.null(r)) bulk_count <<- bulk_count + nrow(r)
    r
  }

  # read_record with the block path on and off: identical results (or the
  # same error)
  read_both <- function(record, args = list()) {
    rd <- function() tryCatch(suppressWarnings(do.call(read_record, c(list(record), args))),
                              error = function(e) paste("error:", conditionMessage(e)))
    a <- rd()
    rebind(".bulk_frames", bulk_off)
    b <- tryCatch(rd(), finally = rebind(".bulk_frames", bulk_orig))
    identical(a, b)
  }
  # rows read by read_record, and how many of them in blocks
  bulk_rows <- function(record, ...) {
    bulk_count <<- 0
    rebind(".bulk_frames", bulk_counted)
    r <- tryCatch(read_record(record, ...), finally = rebind(".bulk_frames", bulk_orig))
    c(nrow(r$signals), bulk_count)
  }
  argstr <- function(a) paste(names(a), vapply(a, paste, "", collapse = ","), sep = "=",
                              collapse = " ")

  ranges <- c("8" = 1000, "16" = 32767, "61" = 32767, "80" = 127, "160" = 32767,
              "212" = 2047, "310" = 511, "311" = 511, "24" = 8388607, "32" = 2147483647)
  # A random multi-frequency record (spf: samples per frame of each signal;
  # n frames), with invalid samples (also at the start); returns its frames.
  mf_record <- function(name, fmt, spf, n, gains = 200, names = NULL) {
    cols <- sum(spf)
    if (fmt == 8) {
      x <- apply(matrix(sample.int(121, n * cols, replace = TRUE) - 61, n, cols), 2, cumsum)
      x <- matrix(x, n, cols)
    } else {
      hi <- ranges[[as.character(fmt)]]
      x <- matrix(floor(runif(n * cols, -hi + 1, hi + 1)), n, cols)
      x[runif(n * cols) < 0.01] <- WFDB_INVALID_SAMPLE
      x[1:2, 1] <- WFDB_INVALID_SAMPLE
    }
    write_record(name, x, 250, fmt = fmt, gains = gains, adcres = 16, units = "mV",
                 samps_per_frame = spf, names = names)
    x
  }
  modes <- list(list(), list(pad = TRUE), list(highres = TRUE),
                list(highres = TRUE, pad = TRUE), list(physical = TRUE),
                list(sampfrom = 1234), list(sampfrom = 7, sampto = 1500),
                list(highres = TRUE, sampfrom = 3, sampto = 901),
                list(channels = c(1, 0, 1)))

  # ---- multi-frequency records (python test_bulk_read_multifrequency,
  # with records ten times shorter: reading frame by frame takes R about
  # 0.15 ms per frame)
  for (fmt in as.numeric(names(ranges))) {
    set.seed(fmt + 1)
    for (spf in list(c(4, 1, 1, 1), c(2, 3), c(1, 2), c(8, 1), c(3, 3, 1))) {
      n <- 1599 + sample.int(800, 1)
      mf_record("m", fmt, spf, n)
      lab <- sprintf("multifrequency fmt %d spf %s", fmt, paste(spf, collapse = ","))
      for (a in modes) check(read_both("m", a), paste(lab, argstr(a)))
      rb <- bulk_rows("m", highres = TRUE)
      check(rb[1] - rb[2] <= 4 * max(spf), paste(lab, "read in blocks"))
    }
  }

  # ---- multi-segment records (python test_bulk_read_multisegment)
  set.seed(11)
  write_segments <- function(name, fmt, spf, lens, ...) {
    segs <- character(0)
    for (k in seq_along(lens)) {
      seg <- sprintf("%s_%d", name, k)
      mf_record(seg, fmt, spf, lens[k], ...)
      segs <- c(segs, sprintf("%s %d", seg, lens[k]))
    }
    segs
  }
  sn <- c("ECG", "ABP", "RESP")
  # fixed layout
  segs <- write_segments("fx", 212, c(4, 1, 1), c(9000, 7001, 12000), names = sn)
  writeLines(c("fx/3 3 250 28001", segs), "fx.hea")
  for (a in c(modes, list(list(sampfrom = 8999, sampto = 16002))))
    check(read_both("fx", a), paste("fixed layout", argstr(a)))
  expect_equal(dim(read_record("fx")$signals), c(28001L, 3L), "fixed layout: size")
  rb <- bulk_rows("fx")
  check(rb[1] - rb[2] <= 2 * 3, "fixed layout: read in blocks")
  # variable layout: a segment with all the signals, a null segment, one
  # with a subset in another order with other gains, one with a signal of
  # another format
  writeLines(c("vl_0 3 250 0", "~ 0x4 400(10)/mV 12 0 0 0 0 ECG",
               "~ 0 100/mV 16 0 0 0 0 ABP", "~ 0 50/mV 16 0 0 0 0 RESP"), "vl_0.hea")
  s1 <- write_segments("va", 16, c(4, 1, 1), 5000, names = sn, gains = c(400, 100, 50))
  s2 <- write_segments("vb", 16, c(1, 4), 6003, names = c("RESP", "ECG"), gains = c(25, 200))
  s3 <- write_segments("vc", 212, 1, 4000, names = "ABP", gains = 100)
  segs <- c("vl_0 0", s1, "~ 2500", s2, s3)
  writeLines(c(sprintf("vl/%d 3 250 17503", length(segs)), segs), "vl.hea")
  wfdbquiet()
  for (a in c(modes, list(list(sampfrom = 4990, sampto = 9000))))
    check(read_both("vl", a), paste("variable layout", argstr(a)))
  rb <- bulk_rows("vl")
  check(rb[1] - rb[2] <= 2 * 6, "variable layout: read in blocks")
  wfdbverbose()
  r <- read_record("vl", physical = TRUE)
  expect_equal(dim(r$signals), c(17503L, 3L), "variable layout: size")
  check(all(is.na(r$signals[5001:7500, ])), "variable layout: null segment")

  # ---- every test record (python test_bulk_read_test_records)
  wfdbquiet()
  for (h in sort(list.files(datasrc, pattern = "\\.hea$"), method = "radix")) {
    rec <- sub("\\.hea$", "", h)
    for (a in list(list(), list(pad = TRUE), list(highres = TRUE),
                   list(highres = TRUE, pad = TRUE), list(sampfrom = 3)))
      check(read_both(rec, a), paste("test record", rec, argstr(a)))
  }
  wfdbverbose()

  # ---- getframes mixed with getvec and isigsettime (python
  # test_bulk_multifrequency_interleaved): the same vectors, statuses and
  # library state as getvec alone, in high resolution also from the middle
  # of a frame
  set.seed(5)
  mf_record("mf", 212, c(4, 1, 3), 20001)
  state <- function() {
    st <- .sig
    list(st$istime, st$gvc, lapply(st$isd[seq_len(st$nisig)], function(is)
      c(is$samp, is$info$cksum, is$info$nsamp)))
  }
  steps <- list(c("f", 999), c("v", 3), c("f", 4097), c("t", 17), c("v", 1),
                c("f", 9001), c("v", 2), c("t", 30), c("f", 200000))
  for (hr in c(FALSE, TRUE)) {
    out <- list()
    for (bulk in c(TRUE, FALSE)) {
      if (!bulk) rebind(".bulk_frames", bulk_off)
      got <- list()
      ok <- isigopen("mf", 3)$nsig == 3
      setgvmode(bitwOr(if (hr) WFDB_HIGHRES else WFDB_LOWRES, WFDB_GVPAD))
      for (st in steps) {
        k <- as.numeric(st[2])
        got[[length(got) + 1L]] <- switch(st[1],
          f = getframes(k),
          v = lapply(seq_len(k), function(i) getvec()),
          t = isigsettime(k))
        got[[length(got) + 1L]] <- state()
      }
      wfdbquit()
      rebind(".bulk_frames", bulk_orig)
      out[[length(out) + 1L]] <- got
    }
    check(ok && identical(out[[1L]], out[[2L]]),
          paste("getframes mixed with getvec, highres", hr))
  }

  # ---- single-frequency records, one group of 1 to 4 signals, every
  # format: the frames as decoded (formats 212 with 2 signals, 310 and 311
  # with 3: a frame is one packing unit), clean (no invalid sample) or with
  # invalid samples (also first and last), lengths that are not a multiple
  # of the block or of the packing unit
  sf_record <- function(name, fmt, nsig, n, clean, gains = 200, baselines = 0) {
    hi <- c(ranges, "508" = 127, "516" = 32767, "524" = 8388607)[[as.character(fmt)]]
    if (fmt == 8) {
      x <- apply(matrix(sample.int(121, n * nsig, replace = TRUE) - 61, n, nsig), 2, cumsum)
      x <- matrix(x, n, nsig)
    } else {
      x <- matrix(floor(runif(n * nsig, -hi + 1, hi + 1)), n, nsig)
      x[1L, ] <- -hi + 1
      x[2L, ] <- hi
      if (!clean) {
        x[runif(n * nsig) < 0.01] <- WFDB_INVALID_SAMPLE
        x[1L, 1L] <- WFDB_INVALID_SAMPLE
        x[n, nsig] <- WFDB_INVALID_SAMPLE
      }
    }
    write_record(name, x, 250, fmt = fmt, gains = gains, baselines = baselines,
                 adcres = 16, units = "mV")
    x
  }
  sf_modes <- list(list(), list(pad = TRUE), list(sampfrom = 7, sampto = 1301))
  for (fmt in c(as.numeric(names(ranges)), 508, 516, 524)) {
    set.seed(fmt + 3)
    for (nsig in 1:4) {
      for (clean in c(TRUE, FALSE)) {
        n <- 1300 + sample.int(400, 1)
        x <- sf_record("sf", fmt, nsig, n, clean)
        lab <- sprintf("single frequency fmt %d nsig %d clean %s", fmt, nsig, clean)
        ms <- if (nsig == 3) c(sf_modes, list(list(physical = TRUE), list(channels = c(2, 0)))) else sf_modes
        for (a in ms) check(read_both("sf", a), paste(lab, argstr(a)))
        if (clean && fmt != 8) {
          # (a final partial packing unit of formats 310 and 311 reads as
          # one more frame)
          y <- read_record("sf")$signals
          check(nrow(y) - n <= 1 && identical(y[seq_len(n), , drop = FALSE], x),
                paste(lab, "samples"))
        }
        rb <- bulk_rows("sf")
        check(rb[1] - rb[2] <= 6, paste(lab, "read in blocks"))
      }
    }
  }
  # two groups (signal files) of different formats
  set.seed(21)
  xa <- sf_record("ga", 212, 2, 2001, TRUE)
  xb <- sf_record("gb", 16, 1, 2001, FALSE)
  h <- c(readLines("ga.hea"), readLines("gb.hea")[-1L])
  h[1L] <- sub("^ga 2", "g2 3", h[1L])
  writeLines(h, "g2.hea")
  for (a in c(sf_modes, list(list(physical = TRUE))))
    check(read_both("g2", a), paste("two groups", argstr(a)))
  check(identical(read_record("g2")$signals, cbind(xa, xb)), "two groups: samples")

  # getframes mixed with getvec and isigsettime on single-frequency
  # records: the same vectors, statuses and library state (samples, as
  # doubles; checksums; lengths) as getvec alone
  for (fmt in c(16, 212, 311, 24, 32)) {
    for (nsig in c(2, 3)) {
      set.seed(fmt + nsig)
      sf_record("sfm", fmt, nsig, 20001, clean = nsig == 2)
      out <- list()
      for (bulk in c(TRUE, FALSE)) {
        if (!bulk) rebind(".bulk_frames", bulk_off)
        got <- list()
        isigopen("sfm", nsig)
        setgvmode(if (nsig == 3) WFDB_GVPAD else WFDB_LOWRES)
        for (st in steps) {
          k <- as.numeric(st[2])
          got[[length(got) + 1L]] <- switch(st[1],
            f = getframes(k),
            v = lapply(seq_len(k), function(i) getvec()),
            t = isigsettime(k))
          got[[length(got) + 1L]] <- state()
        }
        wfdbquit()
        rebind(".bulk_frames", bulk_orig)
        out[[length(out) + 1L]] <- got
      }
      check(identical(out[[1L]], out[[2L]]),
            sprintf("getframes mixed with getvec, single frequency fmt %d nsig %d", fmt, nsig))
    }
  }

  # .getframes_full (getframe for each frame) with the block path on and
  # off: the frames, and the library state before the end of the record
  # (reading to the end, only the frames: at the end, the frame-by-frame
  # path reads further in the groups that are not yet at their end)
  full_both <- function(record, n) {
    out <- list()
    for (bulk in c(TRUE, FALSE)) {
      if (!bulk) rebind(".bulk_frames", bulk_off)
      wfdbquit()
      isigopen(record, isigopen(record, 0)$nsig)
      r <- .getframes_full(n)
      out[[length(out) + 1L]] <- if (is.finite(n)) list(r, state()) else r
      wfdbquit()
      rebind(".bulk_frames", bulk_orig)
    }
    identical(out[[1L]], out[[2L]])
  }
  for (rec in c("m", "sf", "g2", "sfm"))
    for (n in c(1000, Inf))
      check(full_both(rec, n), paste(".getframes_full, record", rec, n, "frames"))

  # physical units: (sample - baseline) / gain, NA for invalid samples, with
  # the same and with different gains and baselines
  set.seed(23)
  for (gb in list(list(200, 0), list(c(200, 100, 3.5), c(0, 7, -20)), list(400, -3))) {
    x <- sf_record("ph", 212, 3, 1501, FALSE, gains = gb[[1L]], baselines = gb[[2L]])
    y <- read_record("ph", physical = TRUE)$signals
    g <- rep_len(gb[[1L]], 3)
    b <- rep_len(gb[[2L]], 3)
    ref <- x
    for (k in 1:3) ref[, k] <- (x[, k] - b[k]) / g[k]
    ref[x == WFDB_INVALID_SAMPLE] <- NA
    check(identical(y, ref), paste("physical units, gains", paste(g, collapse = ",")))
  }

  # ---- signal names without white space (python test_names_without_spaces)
  writeLines(c("sp 3 250 4", "fmt16.dat 16 200/mV 16 0 0 0 0 III ",
               "fmt16.dat 16 200/mV 16 0 0 0 0 ABP\t ",
               "fmt16.dat 16 200/mV 16 0 0 0 0 PLETH"), "sp.hea")
  for (lg in c(FALSE, TRUE)) {
    r <- read_record("sp", legacy = lg)
    expect_equal(r$names, c("III", "ABP", "PLETH"), paste("names, legacy", lg))
    expect_equal(vapply(r$siginfo, function(s) s$desc, ""), c("III", "ABP", "PLETH"),
                 paste("read_record desc, legacy", lg))
    h <- read_header("sp", legacy = lg)
    expect_equal(vapply(h$siginfo, function(s) s$desc, ""), c("III", "ABP", "PLETH"),
                 paste("read_header desc, legacy", lg))
    r2 <- read_record("sp", channels = list("ABP", "III ", 2))
    expect_equal(r2$names, c("ABP", "III", "PLETH"), paste("channels by name, legacy", lg))
    check(identical(r2$signals, r$signals[, c(2, 1, 3)]), paste("channels by name: samples", lg))
  }
  si <- isigopen("sp", 3)$si
  expect_equal(vapply(si, function(s) s$desc, ""), c("III ", "ABP\t ", "PLETH"),
               "isigopen keeps the white space")
  wfdbquit()
}
