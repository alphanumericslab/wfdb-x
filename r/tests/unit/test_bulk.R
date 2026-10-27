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
  bulk_off <- function(n, full = FALSE) NULL
  # (rows read by .bulk_frames)
  bulk_count <- 0
  bulk_counted <- function(n, full = FALSE) {
    r <- bulk_orig(n, full)
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
