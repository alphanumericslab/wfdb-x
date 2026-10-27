# Tests of the signal module (signal.R, highlevel.R): round trips in every
# (non-FLAC) storage format, getframes() == getvec(), multi-frequency and
# multi-segment records, header writing (port of python/tests/
# test_signals.py), and the signal parts of python/tests/test_api.py, whose
# expected values were produced by the C library
# (tests/reference/api_expect.c).
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
  oldpath <- Sys.getenv("WFDB", unset = NA)
  d <- tempfile("wfdbx-sig")
  dir.create(d)
  file.copy(list.files(datasrc, full.names = TRUE, all.files = FALSE), d, recursive = TRUE)
  setwd(d)
  on.exit({
    wfdbquit()
    wfdbverbose()
    setwd(old)
    if (is.na(oldpath)) Sys.unsetenv("WFDB") else Sys.setenv(WFDB = oldpath)
    unlink(d, recursive = TRUE)
    wfdbio_reset()
    sig_reset()
  }, add = TRUE)
  wfdbquit()
  setwfdb(".")
  rf <- function(name) readBin(name, "raw", file.size(name))
  isig <- function(record) isigopen(record, 8)$nsig
  vec <- function(n, f = getvec) {
    r <- f()
    v <- numeric(n)
    k <- min(n, length(r$v))
    v[seq_len(k)] <- r$v[seq_len(k)]
    c(r$stat, v)
  }

  # ---- round trips (python test_roundtrip)
  ranges <- c("8" = 1000, "16" = 32767, "61" = 32767, "80" = 127, "160" = 32767,
              "212" = 2047, "310" = 511, "311" = 511, "24" = 8388607, "32" = 2147483647)
  for (fmt in as.numeric(names(ranges))) {
    for (nsig in 1:3) {
      set.seed(fmt * 10 + nsig)
      hi <- ranges[[as.character(fmt)]]
      n <- 1001
      if (fmt == 8) {
        x <- apply(matrix(sample.int(121, n * nsig, replace = TRUE) - 61, n, nsig), 2, cumsum)
        x <- matrix(x, n, nsig)
      } else {
        x <- matrix(floor(runif(n * nsig, -hi + 1, hi + 1)), n, nsig)
      }
      write_record("rt", x, 250, fmt = fmt, gains = 200, adcres = 16, units = "mV")
      r <- read_record("rt")
      y <- r$signals
      lab <- paste0("roundtrip fmt ", fmt, " nsig ", nsig)
      if (fmt %in% c(310, 311) && (n * nsig) %% 3 == 2) {
        # a final group of two samples is written in 4 bytes: the file
        # appears to contain an extra (zero) sample, as with the C library
        check(all(y[nrow(y), ] == 0), paste(lab, "extra zero sample"))
        y <- y[-nrow(y), , drop = FALSE]
      }
      check(identical(dim(y), dim(x)) && all(y == x), lab)
      # the same with the per-sample interface (putvec) and getvec
      wfdbquit()
      si <- lapply(seq_len(nsig), function(k) siginfo(fname = "rt2.dat", desc = "", gain = 200,
                                                     fmt = fmt, adcres = 12))
      check(osigfopen(si, nsig) == nsig, paste(lab, "osigfopen"))
      setsampfreq(250)
      for (i in seq_len(n)) putvec(x[i, ])
      newheader("rt2")
      wfdbquit()
      check(identical(rf("rt.dat"), rf("rt2.dat")), paste(lab, "putvec == putframes"))
      isigopen("rt", nsig)
      ok <- TRUE
      for (t in c(n - 1, 0, n %/% 2, 3, n - 2)) {
        ok <- ok && all(vapply(seq_len(nsig) - 1, function(s) sample(s, t), 0) == x[t + 1, ])
      }
      check(ok, paste(lab, "sample()"))
      wfdbquit()
    }
  }

  # ---- getframes() == getvec()
  # (records with several groups of different lengths, without a record
  # length: FLAC groups, one of them ending with an odd number of frames
  # next to a format 212 group, whose frames are decoded in pairs)
  wfdbquiet()
  osigfopen(list(siginfo(fname = "fodd.dat", fmt = 516, gain = 200, adcres = 12)), 1)
  putframes(matrix(cint16(seq_len(4999) * 37), ncol = 1))
  osigfopen(list(siginfo(fname = "f212.dat", fmt = 212, gain = 200, adcres = 12)), 1)
  putframes(matrix((seq_len(8000) * 11) %% 4000 - 2000, ncol = 1))
  wfdbquit()
  wfdbverbose()
  writeLines(c("mixfl 2 250", "fodd.dat 516 200 12 0 0 0 0 a",
               "f212.dat 212 200 12 0 0 0 0 b"), "mixfl.hea")
  writeLines(c("twofl 5 250", sprintf("flac16.dat 516 200 12 0 0 0 0 s%d", 0:2),
               sprintf("flac8.dat 508 200 12 0 0 0 0 s%d", 3:4)), "twofl.hea")
  for (rec in c("fmt212", "fmt310", "fmt311", "fmt8", "twog", "100s", "mfreq", "skew",
                "multi", "vlay", "prolog", "mixfl", "twofl")) {
    for (mode in c(0, 1, 2, 3)) {
      wfdbquiet()
      n <- isigopen(rec, 0)$nsig
      isigopen(rec, n)
      setgvmode(mode)
      ref <- list()
      repeat {
        r <- getvec()
        if (r$stat < 0) break
        ref[[length(ref) + 1L]] <- r$v
      }
      ref <- do.call(rbind, ref)
      wfdbquit()
      isigopen(rec, n)
      setgvmode(mode)
      g <- getframes(Inf)
      wfdbquit()
      setgvmode(0)
      wfdbverbose()
      check(identical(dim(g$v), dim(ref)) && all(g$v == ref) && g$stat == r$stat,
            paste("getframes == getvec:", rec, "mode", mode))
    }
  }
  # ---- .getframes_full() == getframe()
  for (rec in c("fmt212", "fmt8", "twog", "100s", "mfreq", "skew", "multi", "vlay",
                "flacmf")) {
    for (mode in c(0, 1)) {
      wfdbquiet()
      n <- isigopen(rec, 0)$nsig
      isigopen(rec, n)
      setgvmode(mode)
      ref <- list()
      repeat {
        r <- getframe()
        if (r$stat < 0) break
        ref[[length(ref) + 1L]] <- r$v
      }
      ref <- do.call(rbind, ref)
      wfdbquit()
      isigopen(rec, n)
      setgvmode(mode)
      g <- .getframes_full(Inf)
      wfdbquit()
      setgvmode(0)
      wfdbverbose()
      check(identical(dim(g$v), dim(ref)) && all(g$v == ref) && g$stat == r$stat,
            paste(".getframes_full == getframe:", rec, "mode", mode))
    }
  }
  # in pieces, after a seek
  isigopen("100s", 2)
  isigsettime(1000)
  a <- getframes(7)$v
  b <- getframes(3000)$v
  wfdbquit()
  isigopen("100s", 2)
  isigsettime(1000)
  ref <- t(vapply(1:3007, function(i) getvec()$v, c(0, 0)))
  wfdbquit()
  check(all(rbind(a, b) == ref), "getframes in pieces")

  # ---- read_record
  r <- read_record("100s", sampto = 3, physical = TRUE)
  check(isTRUE(all.equal(r$signals, matrix(c(-0.145, -0.065), 3, 2, byrow = TRUE))),
        "physical units")
  lo <- read_record("mfreq", sampto = 10)
  hi <- read_record("mfreq", sampto = 20, highres = TRUE)
  check(identical(dim(lo$signals), c(10L, 3L)) && identical(dim(hi$signals), c(20L, 3L)),
        "multi-frequency dimensions")
  check(hi$fs == 400 && lo$fs == 100, "multi-frequency fs")
  wfdbquiet()
  r <- read_record("vlay", sampfrom = 1498, sampto = 1502)
  wfdbverbose()
  check(all(r$signals[3, ] == WFDB_INVALID_SAMPLE), "variable layout")
  r <- read_record("100s", channels = c("1", "0"), sampfrom = "0:1", sampto = "0:2")
  check(nrow(r$signals) == 360 && r$sampfrom == 360, "read_record times")
  check(length(r$comments) == 3, "read_record comments")

  # ---- header writing
  x <- matrix(0, 10, 2)
  write_record("hw", x, 125.5, fmt = 16, gains = c(100, 0), adcres = 16, units = c("mV", "uV"),
               names = c("lead I", "pressure"), base_time = "12:00:00 01/02/2003",
               comments = "c1")
  txt <- rawToChar(rf("hw.hea"))
  check(startsWith(txt, "hw 2 125.5 10 12:00:00 01/02/2003\r\n"), "header first line")
  check(grepl("hw.dat 16 100/mV 16 0 0 0 0 lead I\r\n", txt, fixed = TRUE), "header signal line")
  check(endsWith(txt, "#c1\r\n"), "header info")
  si <- read_header("hw")$siginfo
  check(length(si) == 2 && si[[2]]$desc == "pressure" && si[[2]]$units == "uV", "read_header")

  # ---- test_api.py: t_bufsize
  expect_equal(setibsize(0), 8192, "setibsize(0)")
  expect_equal(setibsize(1000), 1000, "setibsize(1000)")
  wfdbquiet()
  expect_equal(setibsize(-1), -2, "setibsize(-1)")
  expect_equal(setobsize(0), 8192, "setobsize(0)")
  expect_equal(setobsize(2000), 2000, "setobsize(2000)")
  expect_equal(setobsize(-5), -2, "setobsize(-5)")
  isig("100s")
  expect_equal(setibsize(512), -1, "setibsize after isigopen")
  wfdbverbose()
  wfdbquit()
  setibsize(0)
  setobsize(0)

  # ---- t_signals
  expect_equal(getgvmode(), 0, "getgvmode")
  expect_equal(isig("100s"), 2, "isig 100s")
  expect_equal(getifreq(), 360, "getifreq")
  expect_equal(getspf(), 1, "getspf")
  wfdbquit()
  isig("fmt16")
  expect_equal(vec(3), c(3, -7, 32, -33), "fmt16 v1")
  expect_equal(vec(3), c(3, 4, 53, -47), "fmt16 v2")
  expect_equal(vec(3), c(3, -20, 24, -27), "fmt16 v3")
  expect_equal(setifreq(100), 0, "setifreq(100)")
  expect_equal(getifreq(), 100, "getifreq 100")
  expect_equal(isigsettime(0), 0, "isigsettime(0)")
  expect_equal(vec(3), c(3, -7, 32, -33), "ifreq 100 v1")
  expect_equal(vec(3), c(3, -21, 23, -35), "ifreq 100 v2")
  expect_equal(vec(3), c(3, 7, -14, -44), "ifreq 100 v3")
  expect_equal(setifreq(1000), 0, "setifreq(1000)")
  expect_equal(getifreq(), 1000, "getifreq 1000")
  expect_equal(isigsettime(2), 0, "isigsettime(2)")
  expect_equal(vec(3), c(3, -7, 32, -33), "ifreq 1000 v1")
  for (i in 1:4) expect_equal(vec(3), c(3, 4, 53, -47), paste("ifreq 1000 v", i + 1))
  wfdbquiet()
  expect_equal(setifreq(-1), -1, "setifreq(-1)")
  wfdbverbose()
  expect_equal(getifreq(), 250, "getifreq after bad setifreq")
  setafreq(0)
  wfdbquit()
  isig("100s")
  setgvmode(WFDB_HIGHRES)
  expect_equal(getgvmode(), 1, "gvmode highres")
  setgvmode(bitwOr(WFDB_GVPAD, WFDB_LOWRES))
  expect_equal(getgvmode(), 2, "gvmode gvpad")
  setgvmode(7)
  expect_equal(getgvmode(), 3, "gvmode 7")
  setgvmode(0)
  wfdbquit()

  # ---- amplitude conversion (wfdb-x: invalid signal numbers give
  # WFDB_INVALID_SAMPLE or NaN; C assumed a gain of 200)
  isig("100s")
  wfdbquiet()
  expect_equal(c(adumuv(0, 200), adumuv(0, -37), adumuv(1, 1), adumuv(0, -1), adumuv(7, 100)),
               c(1000, -185, 5, -5, -32768), "adumuv")
  expect_equal(c(muvadu(0, 1000), muvadu(0, -333), muvadu(1, 2), muvadu(9, 1000)),
               c(200, -67, 0, -32768), "muvadu")
  expect_equal(c(aduphys(0, 1224), aduphys(1, 900), aduphys(5, 300)), c(1, -0.62, NaN),
               "aduphys")
  expect_equal(c(physadu(0, 1), physadu(1, -0.5023), physadu(5, 1.5)), c(1224, 924, -32768),
               "physadu")
  wfdbverbose()
  wfdbquit()
  isig("fmt16")
  expect_equal(c(adumuv(0, 100), adumuv(1, 150), adumuv(2, -7)), c(1000, 1000, -35),
               "adumuv fmt16")
  expect_equal(c(muvadu(0, 1000), muvadu(1, 1000), muvadu(2, -2500)), c(100, 150, -500),
               "muvadu fmt16")
  expect_equal(c(aduphys(0, 95), aduphys(1, 10), aduphys(2, -3)),
               c(1, 1 / 30, -0.09), "aduphys fmt16")
  expect_equal(c(physadu(0, 1), physadu(1, -2.25), physadu(2, 0.4)), c(95, -333, 95),
               "physadu fmt16")
  wfdbquit()

  # ---- sample()
  isig("100s")
  expect_equal(sample_valid(), 0, "sample_valid initial")
  expect_equal(c(sample(0, 0), sample_valid()), c(995, 1), "sample(0,0)")
  expect_equal(c(sample(1, 1000), sample_valid()), c(970, 1), "sample(1,1000)")
  expect_equal(c(sample(0, 21599), sample_valid()), c(975, 1), "sample(0,21599)")
  expect_equal(c(sample(0, 21600), sample_valid()), c(975, 0), "sample(0,21600)")
  expect_equal(c(sample(0, 5), sample_valid()), c(995, 1), "sample(0,5)")
  expect_equal(c(sample(1, -3), sample_valid()), c(1011, 1), "sample(1,-3)")
  expect_equal(c(sample(2, 0), sample_valid()), c(-32768, -1), "sample(2,0)")
  wfdbquit()

  # ---- getframe
  isig("mfreq")
  expect_equal(getspf(), 1, "mfreq getspf")
  expect_equal(getifreq(), 100, "mfreq getifreq")
  expect_equal(vec(7, getframe), c(3, 138, 218, 2699, 219, -1316, 1120, 1973), "getframe 1")
  expect_equal(vec(7, getframe), c(3, 2677, 1201, 275, -989, 1822, 2762, 1927), "getframe 2")
  expect_equal(vec(3), c(3, -597, -455, 181), "mfreq getvec")
  isigsettime(599)
  expect_equal(vec(7, getframe), c(3, -1394, 715, 558, 2215, -1785, 860, -491), "getframe 599")
  expect_equal(getframe()$stat, -1, "getframe at end")
  wfdbquit()
  setgvmode(WFDB_HIGHRES)
  isig("mfreq")
  expect_equal(getspf(), 4, "highres getspf")
  expect_equal(getifreq(), 400, "highres getifreq")
  expect_equal(vec(7, getframe), c(3, 138, 218, 2699, 219, -1316, 1120, 1973), "highres getframe")
  expect_equal(vec(3), c(3, 2677, 1201, -989), "highres getvec 1")
  expect_equal(vec(3), c(3, 2677, 1201, 1822), "highres getvec 2")
  wfdbquit()
  setgvmode(0)

  # ---- groups
  isig("twog")
  expect_equal(vec(3), c(3, 1020, 977, 316), "twog v1")
  expect_equal(isgsettime(1, 100), 0, "isgsettime(1,100)")
  expect_equal(vec(3), c(3, 1880, -630, 83), "twog v2")
  expect_equal(vec(3), c(3, 325, 245, 1597), "twog v3")
  expect_equal(isgsettime(0, 500), 0, "isgsettime(0,500)")
  expect_equal(vec(3), c(3, -1823, 338, -709), "twog v4")
  expect_equal(isgsettime(1, 1001), 0, "isgsettime(1,1001)")
  expect_equal(getvec()$stat, -1, "twog end")
  wfdbquit()

  # ---- segments
  segs <- function() lapply(getseginfo(), function(s) list(s$recname, s$nsamp, s$samp0))
  isig("100s")
  expect_equal(length(getseginfo()), 0L, "no segments")
  expect_equal(tnextvec(0, 5), 5, "tnextvec(0,5)")
  expect_equal(tnextvec(1, 0), 0, "tnextvec(1,0)")
  wfdbquit()
  isig("multi")
  expect_equal(segs(), list(list("100s", 21600, 0), list("null", 1800, 21600),
                            list("100s", 21600, 23400)), "multi segments")
  expect_equal(tnextvec(0, 0), 0, "multi tnextvec 1")
  expect_equal(tnextvec(0, 21599), 21599, "multi tnextvec 2")
  expect_equal(tnextvec(1, 21700), 23500, "multi tnextvec 3")
  expect_equal(tnextvec(0, 44999), 44999, "multi tnextvec 4")
  wfdbquiet()
  expect_equal(tnextvec(0, 45000), -1, "multi tnextvec 5")
  wfdbverbose()
  wfdbquit()
  isig("vlay")
  expect_equal(segs(), list(list("vlay_0", 0, 0), list("fmt16", 1500, 0), list("~", 200, 1500),
                            list("fmt212", 1501, 1700)), "vlay segments")
  wfdbquiet()
  expect_equal(tnextvec(0, 0), 0, "vlay tnextvec 1")
  expect_equal(tnextvec(1, 1499), 1700, "vlay tnextvec 2")
  expect_equal(tnextvec(2, 1500), -1, "vlay tnextvec 3")
  expect_equal(tnextvec(0, 1600), -1, "vlay tnextvec 4")
  expect_equal(tnextvec(5, 0), -1, "vlay tnextvec 5")
  wfdbverbose()
  wfdbquit()

  # ---- skew and start
  isig("skew")
  expect_equal(vapply(0:3, wfdbgetskew, 0), c(0, 3, 7, 0), "wfdbgetskew")
  expect_equal(c(wfdbgetskew(0), wfdbgetskew(1), wfdbgetskew(2), wfdbgetskew(3)),
               c(0, 3, 7, 0), "wfdbgetskew (scalar calls)")
  expect_equal(vec(3), c(3, -7, 21, -32768), "skew v1")
  wfdbsetiskew(1, 2)
  wfdbsetiskew(2, 100000)
  wfdbsetiskew(0, -1)
  expect_equal(vapply(0:2, wfdbgetskew, 0), c(0, 2, 7), "wfdbsetiskew")
  expect_equal(wfdbgetskew(1), 2, "wfdbgetskew after wfdbsetiskew")
  wfdbquit()
  isig("prolog")
  expect_equal(c(wfdbgetstart(0), wfdbgetstart(2), wfdbgetstart(3)), c(100, 100, 0),
               "wfdbgetstart")
  wfdbquit()
  isig("100s")
  expect_equal(wfdbgetstart(0), 0, "wfdbgetstart 100s")
  wfdbquit()

  # ---- output: prolog, skew, flush (the annotation part is in test_annot)
  setcfreq(0)
  si <- lapply(c("first", "second"), function(d)
    siginfo(fname = "out.dat", desc = d, units = "mV", gain = 100, group = 0, fmt = 16,
            adcres = 12))
  setsampfreq(100)
  expect_equal(osigfopen(si, 2), 2, "osigfopen")
  expect_equal(wfdbputprolog(charToRaw("PROLOG!"), 7, 0), 0, "wfdbputprolog")
  wfdbsetskew(1, 4)
  for (i in 0:4) putvec(c(i, -i))
  wfdbflush()
  expect_equal(file.size("out.dat"), 27, "out.dat size after flush")
  expect_equal(newheader("out"), 0, "newheader")
  expect_equal(putinfo("info line"), 0, "putinfo")
  wfdbquit()
  expect_equal(rawToChar(rf("out.hea")),
               paste0("out 2 100 5\r\n",
                      "out.dat 16+7 100/mV 12 0 0 10 0 first\r\n",
                      "out.dat 16:4+7 100/mV 12 0 0 -10 0 second\r\n",
                      "#info line\r\n"), "out.hea")
  expect_equal(rf("out.dat"), as.raw(c(0x50, 0x52, 0x4f, 0x4c, 0x4f, 0x47, 0x21, 0, 0, 0, 0,
                                       1, 0, 0xff, 0xff, 2, 0, 0xfe, 0xff, 3, 0, 0xfd, 0xff,
                                       4, 0, 0xfc, 0xff)), "out.dat")
  setsampfreq(100)
  si <- lapply(si, function(s) {
    s$fname <- "out2.dat"
    s
  })
  osigfopen(si, 2)
  wfdbsetstart(0, 512)
  putvec(c(1, 2))
  newheader("out2")
  wfdbquit()
  expect_equal(rawToChar(rf("out2.hea")),
               paste0("out2 2 100 1\r\n",
                      "out2.dat 16+512 100/mV 12 0 1 1 0 first\r\n",
                      "out2.dat 16+512 100/mV 12 0 2 2 0 second\r\n"), "out2.hea")
  expect_equal(file.size("out2.dat"), 4, "out2.dat size")

  # ---- info
  expect_equal(getinfo("100s"), " 69 M 1085 1629 x1", "getinfo 1")
  expect_equal(getinfo(NULL), " Aldomet, Inderal", "getinfo 2")
  expect_equal(getinfo(NULL), "Produced by xform from record 100, beginning at 0:0", "getinfo 3")
  expect_equal(setinfo("newrec"), 0, "setinfo")
  expect_equal(putinfo("first"), 0, "putinfo first")
  expect_equal(putinfo("second"), 0, "putinfo second")
  expect_equal(setinfo(NULL), 0, "setinfo(NULL)")
  wfdbquiet()
  expect_equal(putinfo("third"), -1, "putinfo without record")
  wfdbverbose()
  expect_equal(rawToChar(rf("newrec.info")), "#first\r\n#second\r\n", "newrec.info")
  expect_equal(getinfo("newrec"), "first", "getinfo newrec 1")
  expect_equal(getinfo(NULL), "second", "getinfo newrec 2")
  expect_equal(getinfo(NULL), NULL, "getinfo newrec end")
  expect_equal(setinfo("100s"), 0, "setinfo 100s")
  expect_equal(putinfo("extra"), 0, "putinfo extra")
  wfdbquit()
  expect_equal(getinfo("100s"), " 69 M 1085 1629 x1", "getinfo again 1")
  expect_equal(getinfo(NULL), " Aldomet, Inderal", "getinfo again 2")
  expect_equal(getinfo(NULL), "Produced by xform from record 100, beginning at 0:0",
               "getinfo again 3")
  expect_equal(getinfo(NULL), "extra", "getinfo again 4")
  isig("fmt16")
  expect_equal(getinfo(NULL), NULL, "getinfo fmt16")
  wfdbquit()

  # ---- wfdb_freeinfo: a later getinfo(NULL) rereads the info strings of the
  # current input record (here fmt16, opened above: the record name survives
  # wfdbquit, as in C) from the first; while they are kept, opening another
  # record does not reread them
  expect_equal(getinfo("100s"), " 69 M 1085 1629 x1", "freeinfo getinfo 1")
  expect_equal(getinfo(NULL), " Aldomet, Inderal", "freeinfo getinfo 2")
  wfdb_freeinfo()
  expect_equal(getinfo(NULL), "generated by gen_records for wfdb-x conformance tests",
               "getinfo after wfdb_freeinfo")
  isig("100s")
  expect_equal(getinfo(NULL), NULL, "getinfo after isigopen")
  wfdb_freeinfo()
  expect_equal(getinfo(NULL), " 69 M 1085 1629 x1", "getinfo rereads after wfdb_freeinfo")
  expect_equal(getinfo(NULL), " Aldomet, Inderal", "getinfo next after wfdb_freeinfo")
  wfdb_freeinfo()
  wfdb_freeinfo()
  expect_equal(getinfo(NULL), " 69 M 1085 1629 x1", "wfdb_freeinfo twice")
  wfdbquit()

  # ---- setmsheader
  expect_equal(setmsheader("msrec", c("100s", "null", "100s"), 3), 0, "setmsheader")
  wfdbquiet()
  expect_equal(setmsheader("msbad", c("100s", "null", "100s"), 0), -1, "setmsheader 0 segments")
  expect_equal(setmsheader("msbad", c("100s", "fmt16"), 2), -4, "setmsheader mismatch")
  wfdbverbose()
  wfdbquit()
  expect_equal(rawToChar(rf("msrec.hea")),
               "msrec/3 2 360 45000\r\n100s 21600\r\nnull 1800\r\n100s 21600\r\n", "msrec.hea")
  expect_equal(isig("msrec"), 2, "isig msrec")
  isigsettime(21599)
  expect_equal(vec(2), c(2, 975, 989), "msrec v1")
  expect_equal(vec(2), c(2, -32768, -32768), "msrec v2")
  wfdbquit()

  # ---- uncalibrated signals, deskewing, resampling
  isig("null")
  wfdbquiet()
  expect_equal(c(adumuv(0, 100), muvadu(1, 100)), c(-32768, -32768), "uncalibrated adumuv")
  expect_equal(c(aduphys(0, 100), physadu(1, 0.5)), c(NaN, -32768), "uncalibrated aduphys")
  wfdbverbose()
  expect_equal(vec(2), c(2, -32768, -32768), "null record")
  wfdbquit()
  isig("skew")
  expect_equal(vec(3, getframe), c(3, -7, 21, -32768), "deskew 1")
  expect_equal(vec(3, getframe), c(3, 4, -14, -85), "deskew 2")
  isigsettime(1497)
  expect_equal(vec(3, getframe), c(-1, -32755, 16705, -32768), "deskew end 1")
  expect_equal(vec(3, getframe), c(-1, -32751, -14, 16705), "deskew end 2")
  wfdbquit()
  isig("mfreq")
  expect_equal(setifreq(200), 0, "mfreq setifreq")
  expect_equal(vec(3), c(3, 138, 1459, 499), "mfreq 200 v1")
  expect_equal(vec(3), c(3, 2677, 738, 1381), "mfreq 200 v2")
  expect_equal(vec(3), c(3, 2677, 738, 1381), "mfreq 200 v3")
  setafreq(0)
  wfdbquit()
  isig("mfreq")
  expect_equal(c(sample(2, 10), sample_valid()), c(869, 1), "mfreq sample 1")
  expect_equal(c(sample(1, 599), sample_valid()), c(637, 1), "mfreq sample 2")
  wfdbquit()
  isig("multi")
  expect_equal(isigsettime(100), 0, "multi isigsettime")
  expect_equal(tnextvec(0, 21650), 23450, "multi tnextvec")
  expect_equal(vec(2), c(2, 969, 996), "multi getvec")
  wfdbquit()

  # After a failed seek (past the end of a FLAC stream), libFLAC aborts the
  # decoding of the next block in the C library: getvec fails, and so do
  # later seeks; a seek to the current time is not performed.
  expect_equal(isig("flac16"), 3, "isigopen flac16")
  expect_equal(isigsettime(99999), -1, "flac isigsettime 99999")
  expect_equal(vec(3), c(-3, 0, 0, 0), "flac getvec after failed seek")
  expect_equal(isigsettime(0), -1, "flac isigsettime 0 after abort")
  expect_equal(vec(3), c(-3, 0, 0, 0), "flac getvec after abort")
  wfdbquit()
  isig("flac16")
  expect_equal(isigsettime(99999), -1, "flac isigsettime 99999 (2)")
  expect_equal(isigsettime(5), 0, "flac isigsettime 5 after failed seek")
  expect_equal(vec(3), c(3, -77, -57, -47), "flac getvec 5")
  wfdbquit()
  isig("flac16")
  expect_equal(vec(3), c(3, -31, -38, -33), "flac getvec 0")
  expect_equal(isigsettime(9001), -1, "flac isigsettime 9001")
  expect_equal(isigsettime(1), 0, "flac isigsettime 1 (current time)")
  expect_equal(vec(3), c(-3, 0, 0, 0), "flac getvec after failed seek (2)")
  wfdbquit()

  # Frame numbers without a record: wfdb-x: no sampling frequency, so an
  # error and 0 (C: frame frequency 0, a division by zero giving LONG_MIN).
  wfdbquiet()
  expect_equal(strtim("f5"), 0, "strtim f5")
  expect_equal(wfdberror(), "strtim: sampling frequency is not specified\n", "strtim f5 error")
  wfdbverbose()
  # Times out of the range of WFDB_Time: the C conversion of the double gives
  # LONG_MIN on x86-64.
  setsampfreq(1)
  expect_equal(strtim("1e300"), -2^63, "strtim 1e300")
  expect_equal(strtim("1:1e300"), -2^63, "strtim 1:1e300")
  setsampfreq(0)

  # ---- putframes == putvec, byte for byte, with edge values and invalid
  # samples, and odd frame counts (padding of formats 212, 310, 311)
  lo <- c("8" = -128, "16" = -32768, "61" = -32768, "80" = -128, "160" = -32768,
          "212" = -2048, "310" = -512, "311" = -512, "24" = -8388608, "32" = -2147483648)
  write_both <- function(x, fmt) {
    out <- list()
    for (fast in c(TRUE, FALSE)) {
      wfdbquit()
      si <- lapply(seq_len(ncol(x)), function(k)
        siginfo(fname = "pf.dat", desc = "", gain = 200, fmt = fmt, adcres = 12))
      osigfopen(si, ncol(x))
      setsampfreq(360)
      if (fast) putframes(x) else for (i in seq_len(nrow(x))) putvec(x[i, ])
      newheader("pf")
      wfdbquit()
      out[[length(out) + 1L]] <- list(rf("pf.dat"), rf("pf.hea"))
    }
    out
  }
  ok <- TRUE
  for (fmt in as.numeric(names(lo))) {
    l <- lo[[as.character(fmt)]]
    for (nsig in 1:3) {
      for (n in c(1, 2, 3, 7, 1000)) {
        set.seed(fmt + 7 * nsig + n)
        if (fmt == 8) {
          dd <- matrix(sample.int(256, n * nsig, replace = TRUE) - 129, n, nsig)
          dd[1L, ] <- sample.int(2000, nsig) - 1000
          x <- apply(dd, 2, cumsum)
        } else {
          x <- floor(runif(n * nsig, l, -l))
          i <- seq_along(x) - 1
          x[i %% 5 == 0] <- l
          x[i %% 7 == 1] <- -l - 1
          x[i %% 11 == 2] <- WFDB_INVALID_SAMPLE
        }
        x <- matrix(x, n, nsig)
        o <- write_both(x, fmt)
        if (!identical(o[[1L]], o[[2L]])) {
          ok <- FALSE
          cat("putframes != putvec: fmt", fmt, "nsig", nsig, "n", n, "\n")
        }
      }
    }
  }
  check(ok, "putframes == putvec (signal files and headers, all formats)")

  # ---- the output directory (wfdbx_set_output_dir; port of t_outdir in
  # tests/reference/api_expect.c, python test_api.py::test_output_dir)
  setcfreq(0)
  setafreq(0)
  # (the annotation type table, as left by t_strings in api_expect.c)
  setanndesc(15, "my description")
  setannstr(42, "new")
  setanndesc(42, "")
  expect_equal(wfdbx_get_output_dir(), NULL, "output dir: none by default")
  dir.create("odir")
  expect_equal(wfdbx_set_output_dir("odir"), NULL, "output dir: set")
  expect_equal(wfdbx_get_output_dir(), "odir", "output dir: get")
  si <- list(siginfo(fname = "orec.dat", desc = "sig", gain = 200, fmt = 16, adcres = 12))
  setsampfreq(100)
  expect_equal(osigfopen(si, 1), 1, "output dir: osigfopen")
  for (i in 0:2) putvec(10 * i - 7)
  expect_equal(newheader("orec"), 0, "output dir: newheader")
  expect_equal(annopen("orec", list(anninfo("oat", WFDB_WRITE)), 1), 0, "output dir: annopen")
  tt <- c(30, 10, 20, 10, 5)              # (out of order, a duplicate)
  for (i in seq_along(tt)) putann(0, annotation(tt[i], if (i == 4) PVC else NORMAL))
  wfdbquiet()
  wfdbquit()
  wfdbverbose()
  expect_equal(wfdbx_set_output_dir(""), "odir", "output dir: previous value")
  expect_equal(wfdbx_get_output_dir(), NULL, "output dir: '' is none")
  expect_equal(wfdbx_set_output_dir("odir2"), NULL, "output dir: set again")
  expect_equal(wfdbx_set_output_dir(NULL), "odir2", "output dir: NULL is none")
  expect_equal(rf("odir/orec.hea"), charToRaw("orec 1 100 3\r\norec.dat 16 200 12 0 -7 9 0 sig\r\n"),
               "output dir: header")
  expect_equal(rf("odir/orec.dat"), as.raw(c(0xf9, 0xff, 0x03, 0x00, 0x0d, 0x00)),
               "output dir: signal file")
  h <- paste0("00581efc232320616e6e6f746174696f6e207479706520646566696e6974696f",
              "6e73005816fc3135205b31355d206d79206465736372697074696f6e005807fc",
              "3432206e65772000005815fc232320656e64206f6620646566696e6974696f6e",
              "730000ecffffffff0100050405140a040a040000")
  oat <- as.raw(strtoi(substring(h, seq(1, nchar(h), 2), seq(2, nchar(h), 2)), 16L))
  expect_equal(rf("odir/orec.oat"), oat,
               "output dir: sorted annotation file (as api_expect.c)")
  check(!file.exists("orec.hea"), "output dir: nothing in the current directory")
  # a missing output directory is created (as are the missing directories
  # of any output file name)
  wfdbx_set_output_dir("newdir")
  osigfopen(si, 1)
  annopen("orec", list(anninfo("oat", WFDB_WRITE)), 1)
  wfdbquit()
  wfdbx_set_output_dir(NULL)
  expect_equal(file.size(c("newdir/orec.dat", "newdir/orec.oat")), c(0, 2),
               "output dir: created")
  # reading the record from the output directory
  setwfdb("odir")
  expect_equal(isig("orec"), 1, "output dir: isigopen")
  expect_equal(lapply(1:3, function(i) vec(1)), list(c(1, -7), c(1, 3), c(1, 13)),
               "output dir: getvec")
  annopen("orec", list(anninfo("oat", WFDB_READ)), 1)
  got <- lapply(1:5, function(i) {
    r <- getann(0)
    if (r$stat != 0) r$stat else c(r$annot$time, r$annot$anntyp)
  })
  expect_equal(got, list(c(5, NORMAL), c(10, PVC), c(20, NORMAL), c(30, NORMAL), -1),
               "output dir: annotations")
  wfdbquit()
  setwfdb(".")
  # t_sortfix: an out-of-order annotation at time 0 is not lost (it is in
  # legacy mode, as by sortann), and in legacy mode with an output
  # directory, sortann runs in that directory
  if (.mode == "source") .wfdb_io$driver <- file.path(dirname(.rdir), "inst", "bin", "wfdbx.R")
  wfdbquiet()
  for (lg in c(FALSE, TRUE)) {
    wfdbx_set_legacy(lg)
    annopen("100s", list(anninfo(if (lg) "l0" else "m0", WFDB_WRITE)), 1)
    for (t in c(5, 0, 3)) putann(0, annotation(t, NORMAL))
    wfdbquit()
    wfdbx_set_output_dir("odir")
    annopen("orec", list(anninfo(if (lg) "lsrt" else "msrt", WFDB_WRITE)), 1)
    for (t in c(30, 10, 20)) putann(0, annotation(t, NORMAL))
    wfdbquit()
    wfdbx_set_output_dir(NULL)
  }
  wfdbx_set_legacy(FALSE)
  wfdbverbose()
  for (nm in c("m0", "l0")) {
    annopen("100s", list(anninfo(nm, WFDB_READ)), 1)
    expect_equal(.getann_bulk(0, Inf)$time, if (nm == "m0") c(0, 3, 5) else 5,
                 paste("t_sortfix:", nm))
    wfdbquit()
  }
  osrt <- c(oat[seq_len(length(oat) - 10L)], as.raw(c(0x0a, 0x04, 0x0a, 0x04, 0x0a, 0x04, 0, 0)))
  check(identical(rf("odir/orec.msrt"), osrt) && identical(rf("odir/orec.lsrt"), osrt),
        "t_sortfix: legacy sort in the output directory == modern (as api_expect.c)")
  annot_reset(tables = TRUE)

  # ---- write_record(..., dir = ) (WFDB-x)
  errmsg <- function(expr) tryCatch({
    expr
    ""
  }, error = function(e) conditionMessage(e))
  x <- matrix(0:19, 10, 2, byrow = TRUE)
  dir.create("out")
  prev <- wfdbx_set_output_dir("elsewhere")
  write_record("rec", x, 360, gains = 200, adcres = 12, units = "mV", dir = "out")
  expect_equal(wfdbx_get_output_dir(), "elsewhere", "write_record dir: output dir restored")
  wfdbx_set_output_dir(prev)
  expect_equal(sort(list.files("out")), c("rec.dat", "rec.hea"), "write_record dir: files")
  check(!file.exists("rec.hea") && !file.exists("rec.dat"), "write_record dir: not in .")
  hea <- readLines("out/rec.hea")
  check(hea[1L] == "rec 2 360 10" && startsWith(hea[2L], "rec.dat 16 "),
        "write_record dir: plain names in the header")
  setwfdb("out")
  check(all(read_record("rec")$signals == x), "write_record dir: read from dir")
  setwfdb(".")
  check(all(read_record("out/rec")$signals == x), "write_record dir: read as out/rec")
  expect_equal(errmsg(write_record("rec", x, 360, gains = 200, adcres = 12, units = "mV",
                                   dir = "nosuch")),
               "directory nosuch does not exist", "write_record dir: missing dir")
  expect_equal(errmsg(write_record("sub/rec", x, 360, gains = 200, adcres = 12, units = "mV",
                                   dir = "out")),
               "record name must not contain a directory when dir is given",
               "write_record dir: record with a directory")
  expect_error(write_record("rec", x, 360, dir = "out"), "write_record dir: no gains")
  expect_equal(wfdbx_get_output_dir(), NULL, "write_record dir: restored after an error")
  check(!file.exists("nosuch"), "write_record dir: missing dir not created")
  write_record("leg", x, 360, dir = "out", legacy = TRUE)
  # the dir checks come before any other validation (WFDB-x)
  x2 <- matrix(0:3, 2, 2)
  expect_equal(errmsg(write_record("sub/rec", x2, 0, dir = "out")),
               "record name must not contain a directory when dir is given",
               "write_record dir checks first: record")
  expect_equal(errmsg(write_record("rec", x2, 0, dir = "nosuch")),
               "directory nosuch does not exist", "write_record dir checks first: dir")
  expect_equal(errmsg(write_record("rec", x2, 360, dir = "out")), "gains must be specified",
               "write_record dir checks first: then the rest")
  check(startsWith(readLines("out/leg.hea")[1L], "leg 2 360 10"), "write_record dir: legacy")

  # ---- absolute paths (WFDB-x; python test_api.py::test_absolute_paths)
  rec <- file.path(normalizePath("."), "100s")
  wfdbquiet()
  expect_equal(isig(rec), 2, "absolute path: isigopen")
  expect_equal(vec(2), c(2, 995, 1011), "absolute path: getvec")
  expect_equal(wfdbfile("hea", rec), paste0(rec, ".hea"), "absolute path: wfdbfile")
  expect_equal(annopen(rec, list(anninfo("atr", WFDB_READ)), 1), 0, "absolute path: annopen")
  r <- getann(0)
  expect_equal(c(r$stat, r$annot$time, r$annot$anntyp), c(0, 18, 28), "absolute path: getann")
  wfdbquit()
  expect_equal(sampfreq(rec), 360, "absolute path: sampfreq")
  wfdbquit()
  expect_equal(isig(file.path(normalizePath("."), "nosuch")), -1, "absolute path: missing")
  wfdbquit()
  # legacy mode: as in C, an absolute name is searched for in the WFDB path
  # (here "./" + the name) ...
  wfdbx_set_legacy(TRUE)
  expect_equal(isig(rec), -1, "absolute path: legacy isigopen")
  expect_equal(annopen(rec, list(anninfo("atr", WFDB_READ)), 1), -3, "absolute path: legacy annopen")
  wfdbquit()
  # ... unless the WFDB path has an empty component
  setwfdb(";")
  expect_equal(isig(rec), 2, "absolute path: legacy, WFDB ';'")
  expect_equal(vec(2), c(2, 995, 1011), "absolute path: legacy, WFDB ';' getvec")
  wfdbquit()
  wfdbx_set_legacy(FALSE)
  expect_equal(isig(rec), 2, "absolute path: WFDB ';'")
  wfdbquit()
  setwfdb(".")
  wfdbverbose()

  # ---- a signal file shorter than its header says (getvec status -3,
  # unexpected EOF) is an error of read_record, not the end of the data;
  # the low-level API is unchanged
  wfdbquiet()
  x <- matrix(c(1, 3, 5, 7, 2, 4, 6, 8), 4, 2)
  for (name in c("tr", "ok"))
    write_record(name, x, 100, gains = 100, adcres = 16, units = "mV")
  writeBin(rf("tr.dat")[1:8], "tr.dat")     # 2 of the 4 frames (format 16)
  emsg <- function(expr) tryCatch({
    expr
    ""
  }, error = function(e) conditionMessage(e))
  for (lg in c(FALSE, TRUE)) {
    for (ph in c(FALSE, TRUE)) {
      # (1) the error, and the library is left usable
      expect_equal(emsg(read_record("tr", physical = ph, legacy = lg)),
                   "can't read signal data of record tr (getvec status -3)",
                   "truncated: error")
      expect_equal(unname(read_record("ok", legacy = lg)$signals), x,
                   "truncated: then a good record")
    }
    # reading only what the file holds is not an error
    expect_equal(unname(read_record("tr", sampto = 2, legacy = lg)$signals),
                 x[1:2, , drop = FALSE], "truncated: sampto 2")
    # (2) a sub-interval, and sampto past the end of a record whose header
    # gives its length (what there is, no error)
    expect_equal(unname(read_record("ok", sampfrom = 1, sampto = 3, legacy = lg)$signals),
                 x[2:3, , drop = FALSE], "sub-interval")
    expect_equal(unname(read_record("ok", sampto = 10, legacy = lg)$signals), x,
                 "sampto past the end")
  }
  # (3) the low-level API: getvec returns -3 at the end of the truncated
  # file, getframes the frames read and that status
  expect_equal(isigopen("tr", 2)$nsig, 2, "truncated: isigopen")
  expect_equal(c(vec(2)[1], vec(2)[1], vec(2)[1]), c(2, 2, -3), "truncated: getvec")
  wfdbquit()
  isigopen("tr", 2)
  g <- getframes(10)
  expect_equal(g$stat, -3, "truncated: getframes status")
  expect_equal(unname(g$v), x[1:2, , drop = FALSE], "truncated: getframes")
  wfdbquit()
  isigopen("ok", 2)
  g <- getframes(10)
  expect_equal(g$stat, -1, "complete: getframes status")
  expect_equal(unname(g$v), x, "complete: getframes")
  wfdbquit()
  wfdbverbose()

  # ---- a checksum error (getvec status -4) is a warning of read_record
  # (every frame, the last one included, is returned), not an error;
  # checksum_warning = FALSE turns it off; getvec's own message is not
  # printed during the read (it is recorded); the low-level API is unchanged
  CKSUM_MSG <- "checksum error in record ck: the signal data do not match the checksums in its header"
  x <- matrix(c(1, 3, 5, 7, 2, 4, 6, 8), 4, 2)
  write_record("ck", x, 100, gains = 100, adcres = 16, units = "mV")
  b <- rf("ck.dat")
  b[5:6] <- as.raw(c(9, 0))                # sample (1, 0): 3 -> 9
  writeBin(b, "ck.dat")
  y <- x
  y[2, 1] <- 9
  write_record("good", y, 100, gains = 100, adcres = 16, units = "mV")
  # (count what the library prints on the standard error output)
  senv <- environment(wfdb_error)
  cerr0 <- get("cerr", senv)
  printed <- character(0)
  assign("cerr", function(x) printed <<- c(printed, if (is.raw(x)) rawToChar(x) else x), envir = senv)
  catch <- function(expr) {
    ws <- character(0)
    val <- withCallingHandlers(expr, warning = function(w) {
      ws <<- c(ws, conditionMessage(w))
      invokeRestart("muffleWarning")
    })
    list(value = val, warnings = ws)
  }
  for (lg in c(FALSE, TRUE)) {
    good <- read_record("good", legacy = lg)$signals
    for (ph in c(FALSE, TRUE)) {
      printed <- character(0)
      r <- catch(read_record("ck", physical = ph, legacy = lg))
      expect_equal(r$warnings, CKSUM_MSG, "checksum: the warning")
      expect_equal(unname(r$value$signals), if (ph) y / 100 else y, "checksum: every frame")
      expect_equal(dim(r$value$signals), dim(good), "checksum: same length as with good checksums")
      check(!any(grepl("checksum", printed)), "checksum: getvec's message not printed")
      expect_equal(wfdberror(), "getvec: checksum error in signal 0\n", "checksum: recorded")
    }
    r <- catch(read_record("ck", checksum_warning = FALSE, legacy = lg))
    check(length(r$warnings) == 0L && identical(unname(r$value$signals), unname(good)),
          "checksum_warning = FALSE: no warning, the same frames")
    r <- catch(read_record("ck", sampto = 3, legacy = lg))
    check(length(r$warnings) == 0L && identical(unname(r$value$signals), y[1:3, ]),
          "checksum: not read to the end, no checksum")
    expect_equal(emsg(read_record("tr", legacy = lg)),
                 "can't read signal data of record tr (getvec status -3)",
                 "checksum: the truncated case is still an error")
  }
  # low-level API unchanged: getvec 2, 2, 2, -4 (the last frame filled),
  # getframes stops before it, and the message is printed
  printed <- character(0)
  isigopen("ck", 2)
  sts <- vapply(1:4, function(i) {
    r <- getvec()
    v <<- r$v
    r$stat
  }, 0)
  check(identical(sts, c(2, 2, 2, -4)) && identical(v[1:2], c(7, 8)), "checksum: getvec")
  wfdbquit()
  isigopen("ck", 2)
  g <- getframes(10)
  check(g$stat == -4 && identical(unname(g$v), y[1:3, ]), "checksum: getframes")
  wfdbquit()
  assign("cerr", cerr0, envir = senv)
  expect_equal(printed, rep("getvec: checksum error in signal 0\n", 2),
               "checksum: getvec's message printed by the C-style API")

  # ---- checksum_ok: FALSE when the samples do not match the checksums
  # (with or without the warning), TRUE otherwise; checksums are verified
  # only when the read reaches the end of the record
  for (lg in c(FALSE, TRUE)) {
    for (cw in c(TRUE, FALSE)) {
      r <- suppressWarnings(read_record("ck", checksum_warning = cw, legacy = lg))
      check(identical(r$checksum_ok, FALSE), paste("checksum_ok FALSE, warning", cw, "legacy", lg))
    }
    check(identical(read_record("good", legacy = lg)$checksum_ok, TRUE), "checksum_ok TRUE")
    check(identical(read_record("ck", sampto = 3, legacy = lg)$checksum_ok, TRUE),
          "checksum_ok TRUE: not read to the end")
  }

  # ---- high-resolution reads with a checksum error: getvec returns -4
  # for each vector of the frame at which the checksum is verified;
  # read_record keeps them all and reads on to the end (the same samples
  # as a record with good checksums), warns once, checksum_ok FALSE
  hr_pair <- function(spf, nframes, pos) {
    tspf <- sum(spf)
    x <- matrix(seq_len(nframes * tspf), nframes, tspf, byrow = TRUE)
    write_record("hrbad", x, 100, samps_per_frame = spf, gains = 100, adcres = 16, units = "mV")
    b <- rf("hrbad.dat")
    b[2 * pos + 1:2] <- as.raw(c(99, 0))      # stream sample pos (0-based): 99
    writeBin(b, "hrbad.dat")
    x[pos %/% tspf + 1, pos %% tspf + 1] <- 99
    write_record("hrgood", x, 100, samps_per_frame = spf, gains = 100, adcres = 16, units = "mV")
  }
  hr_cases <- list(list(spf = 2, nf = 4), list(spf = 3, nf = 4),
                   list(spf = c(1, 2), nf = 5), list(spf = c(2, 3), nf = 5))
  for (cs in hr_cases) {
    tspf <- sum(cs$spf)
    ispfmax <- max(cs$spf)
    for (pos in c(0, cs$nf * tspf - 1)) {      # first frame, last frame
      lab <- paste0("highres checksum spf ", paste(cs$spf, collapse = ","), " pos ", pos, ": ")
      hr_pair(cs$spf, cs$nf, pos)
      chs <- list(NULL, length(cs$spf) - 1)
      for (ch in chs) {
        good <- read_record("hrgood", channels = ch, highres = TRUE)
        expect_equal(nrow(good$signals), as.integer(cs$nf * ispfmax), paste0(lab, "good length"))
        if (is.null(ch)) check(any(good$signals == 99), paste0(lab, "the corrupt sample is read"))
        for (cw in c(TRUE, FALSE)) {
          r <- catch(read_record("hrbad", channels = ch, highres = TRUE, checksum_warning = cw))
          expect_equal(r$value$signals, good$signals, paste0(lab, "all samples, warning ", cw))
          expect_equal(r$warnings, if (cw) sub("ck:", "hrbad:", CKSUM_MSG) else character(0),
                       paste0(lab, "one warning or none, ", cw))
          check(identical(r$value$checksum_ok, FALSE), paste0(lab, "checksum_ok FALSE, ", cw))
        }
      }
      # sampto before the last frame: no checksum verified, all the
      # requested samples
      to <- (cs$nf - 1) * ispfmax
      good <- read_record("hrgood", highres = TRUE, sampto = to)
      r <- catch(read_record("hrbad", highres = TRUE, sampto = to))
      check(length(r$warnings) == 0L && identical(r$value$signals, good$signals) &&
              nrow(good$signals) == to && identical(r$value$checksum_ok, TRUE),
            paste0(lab, "sampto before the last frame"))
      # low resolution: unchanged (one vector per frame, every frame)
      good <- read_record("hrgood")
      r <- catch(read_record("hrbad"))
      check(identical(r$value$signals, good$signals) && nrow(good$signals) == cs$nf &&
              length(r$warnings) == 1L && identical(r$value$checksum_ok, FALSE),
            paste0(lab, "low resolution"))
    }
  }

  # ---- read_header: the record header; base_time_ms and base_date in
  # read_record and read_header
  hdr <- function(name, line1, extra = character(0)) {
    writeLines(c(line1, paste0(name, ".dat 16 100/mV 16 0 0 0 0 s0"), extra), paste0(name, ".hea"))
    writeBin(raw(20), paste0(name, ".dat"))
  }
  hdr("bt1", "bt1 1 250 10 14:00:03.500 21/06/2024", c("#first", "#second"))
  hdr("bt2", "bt2 1 250 10 14:00:03")
  hdr("bt3", "bt3 1 250 10")
  hdr("bt4", "bt4 1 250/1000(-5)")
  hdr("bt5", "bt5 1")
  hdr("bt6", "bt6 1 250 10 0:00:00 01/01/1582")
  for (rd in c("record", "header")) {
    get_ <- function(name) if (rd == "record") read_record(name) else read_header(name)
    h <- get_("bt1")
    expect_equal(h$base_time, "[14:00:03 21/06/2024]", paste(rd, "base_time"))
    check(identical(h$base_time_ms, 50403500), paste(rd, "base_time_ms 14:00:03.500"))
    check(identical(h$base_date, c(2024L, 6L, 21L)), paste(rd, "base_date"))
    expect_equal(h$comments, c("first", "second"), paste(rd, "comments"))
    h <- get_("bt2")
    check(identical(h$base_time_ms, 50403000) && is.null(h$base_date) &&
            "base_date" %in% names(h), paste(rd, "time without a date"))
    h <- get_("bt3")
    check(is.null(h$base_time) && is.null(h$base_time_ms) && is.null(h$base_date) &&
            all(c("base_time", "base_time_ms", "base_date") %in% names(h)),
          paste(rd, "no base time"))
    h <- get_("bt6")                 # (a date before the Gregorian calendar)
    check(identical(h$base_time_ms, 0) && identical(h$base_date, c(1582L, 1L, 1L)),
          paste(rd, "base_date 1582"))
  }
  h <- read_header("bt1")
  check(inherits(h, "wfdbx_header") && is.list(h), "read_header: class wfdbx_header")
  expect_equal(names(h), c("name", "fs", "counter_freq", "base_counter", "nsamples", "nsig",
                           "siginfo", "base_time", "base_time_ms", "base_date", "comments"),
               "read_header: fields")
  check(h$name == "bt1" && h$fs == 250 && h$counter_freq == 250 && h$base_counter == 0 &&
          h$nsamples == 10 && h$nsig == 1 && length(h$siginfo) == 1 &&
          h$siginfo[[1]]$desc == "s0", "read_header: values")
  h <- read_header("bt4")
  check(h$fs == 250 && h$counter_freq == 1000 && h$base_counter == -5 && h$nsamples == 0,
        "read_header: counter frequency, base counter, no length")
  h <- read_header("bt5")
  check(h$fs == 0 && h$counter_freq == 0 && is.null(h$base_time), "read_header: no frequency")
  check(read_header("bt5", legacy = TRUE)$fs == 250, "read_header legacy: 250 Hz")
  h <- read_header("100s")
  check(h$nsig == 2 && h$nsamples == 21600 && h$fs == 360 &&
          identical(h$comments, read_record("100s", sampto = 1)$comments),
        "read_header 100s")
  # the C-style datstr and the base_date conversion agree
  for (jd in c(1, 2299160, 2299161, 2460483, 2488070)) {
    ymd <- .julian_ymd(jd)
    expect_equal(datstr(jd), sprintf(" %02d/%02d/%d", ymd[3], ymd[2], ymd[1]),
                 paste("datstr / .julian_ymd", jd))
  }

  # ---- an output signal file is never a signal file of the open input
  # record (the files are compared, not their names); legacy mode: no check
  fmt16 <- rf("fmt16.dat")
  fmt212 <- rf("fmt212.dat")
  spec16 <- function(fname) lapply(0:2, function(i)
    siginfo(fname = fname, desc = sprintf("s%d", i), units = "mV", gain = 100, group = 0,
            fmt = 16, adcres = 12))
  hard <- file.link("fmt16.dat", "ahard16.dat")
  cases <- list(c("fmt16", "fmt16.dat"), c("fmt16", "./fmt16.dat"), c("skew", "fmt16.dat"),
                c("vlay", "fmt16.dat"), c("vlay", "fmt212.dat"))
  if (hard) cases <- c(cases, list(c("fmt16", "ahard16.dat")))
  wfdbquiet()
  for (cs in cases) {
    wfdbquit()
    lab <- paste("alias:", cs[1L], cs[2L])
    expect_equal(isigopen(cs[1L], 3)$nsig, 3, paste(lab, "isigopen"))
    setsampfreq(250)
    expect_equal(osigfopen(spec16(cs[2L]), 3), -3, paste(lab, "refused"))
    expect_equal(wfdberror(), sprintf("osigfopen: output file %s is also an input file\n", cs[2L]),
                 paste(lab, "message"))
    expect_equal(getvec()$stat, 3, paste(lab, "the input is still readable"))
  }
  wfdbquit()
  expect_equal(isigopen("fmt16", 3)$nsig, 3, "alias: osigopen isigopen")
  expect_equal(osigopen("fmt16", 3)$nsig, -3, "alias: osigopen refused")
  expect_equal(wfdberror(), "osigopen: output file fmt16.dat is also an input file\n",
               "alias: osigopen message")
  wfdbquit()
  check(identical(rf("fmt16.dat"), fmt16) && identical(rf("fmt212.dat"), fmt212),
        "alias: the inputs are intact")
  # not an input file: another file, a file that does not exist yet
  for (fname in c("fmt8.dat", "new.dat")) {
    isigopen("vlay", 3)
    setsampfreq(250)
    expect_equal(osigfopen(spec16(fname), 3), 3, paste("alias: not an input file", fname))
    wfdbquit()
  }
  setsampfreq(250)
  expect_equal(osigfopen(spec16("fmt8.dat"), 3), 3, "alias: no input record open")
  wfdbquit()
  # legacy mode: the original behavior (the file is created, truncated)
  wfdbx_set_legacy(TRUE)
  isigopen("fmt16", 3)
  setsampfreq(250)
  expect_equal(osigfopen(spec16("fmt16.dat"), 3), 3, "alias: legacy, no check")
  wfdbquit()
  wfdbx_set_legacy(FALSE)
  expect_equal(file.size("fmt16.dat"), 0, "alias: legacy truncates")
  writeBin(fmt16, "fmt16.dat")
  wfdbverbose()

  # ---- record names (WFDB-x): outside legacy mode, only the last component
  # of a record name is checked when a header is written, and the names in a
  # header are relative to its directory
  x <- cbind(c(1, 2, 3, -4), c(5, 6, -7, 8))
  hdr_lines <- function(f) strsplit(rawToChar(rf(f)), "\r\n", fixed = TRUE)[[1L]]
  write_record("my.data/rec", x, 250, gains = 200, adcres = 16, units = "mV")
  check(file.exists("my.data/rec.hea") && file.exists("my.data/rec.dat"), "dotdir: files")
  h <- hdr_lines("my.data/rec.hea")
  check(startsWith(h[1L], "rec 2 250") && startsWith(h[2L], "rec.dat 16"),
        "dotdir: names relative to the header")
  r <- read_record("my.data/rec")
  expect_equal(unname(r$signals), unname(x), "dotdir: read back")
  absd <- file.path(getwd(), "abs.dir", "sub")
  write_record(file.path(absd, "rec"), x, 250, gains = 200, adcres = 16, units = "mV")
  h <- hdr_lines(file.path(absd, "rec.hea"))
  check(startsWith(h[1L], "rec 2 250") && startsWith(h[2L], "rec.dat 16"),
        "absolute dotted directory: names relative to the header")
  r <- read_record(file.path(absd, "rec"))
  expect_equal(unname(r$signals), unname(x), "absolute dotted directory: read back")
  # a multi-segment record in a dotted directory
  expect_equal(setmsheader("my.data/ms", c("my.data/rec", "my.data/rec")), 0, "dotdir: setmsheader")
  wfdbquit()
  h <- hdr_lines("my.data/ms.hea")
  check(startsWith(h[1L], "ms/2 2 250 8") && h[2L] == "rec 4" && h[3L] == "rec 4",
        "dotdir: segment names relative to the header")
  r <- read_record("my.data/ms")
  expect_equal(unname(r$signals), unname(rbind(x, x)), "dotdir: multi-segment read back")
  # the last component is checked as before
  wfdbquiet()
  expect_error(write_record("rec.1", x, 250, gains = 200, adcres = 16, units = "mV"),
               "rec.1 refused")
  expect_equal(newheader("my.data/rec.1"), -1, "newheader: rec.1 refused")
  expect_equal(wfdberror(), "init: illegal character 46 in record name\n", "rec.1: message")
  expect_equal(newheader("my.data/"), -1, "newheader: empty last component refused")
  expect_equal(wfdberror(), "init: illegal character 0 in record name\n", "empty: message")
  # legacy mode: the whole name is checked, names written unchanged
  wfdbx_set_legacy(TRUE)
  expect_equal(newheader("my.data/rec"), -1, "legacy: my.data/rec refused")
  expect_equal(wfdberror(), "init: illegal character 46 in record name\n", "legacy: message")
  wfdbx_set_legacy(FALSE)
  wfdbverbose()
  write_record("out/rec", x, 250, gains = 200, adcres = 16, units = "mV", legacy = TRUE)
  h <- hdr_lines("out/rec.hea")
  check(startsWith(h[1L], "out/rec 2 250") && startsWith(h[2L], "out/rec.dat 16"),
        "legacy: names unchanged")
  wfdbquit()

  # ---- write errors (python test_write_record_write_error): a signal file
  # or header that cannot be written stops with an error, in both modes,
  # after the library's message, and without an R warning
  if (file.exists("/dev/full")) {
    for (target in c("full.dat", "full.hea")) for (n in c(10, 100000)) for (lg in c(FALSE, TRUE)) {
      lab <- sprintf("write error (%s, n = %d, legacy = %s)", target, n, lg)
      unlink(c("full.dat", "full.hea"))
      file.symlink("/dev/full", target)
      before <- wfdbx_write_errors()
      warned <- FALSE
      wfdbquiet()
      msg <- tryCatch(withCallingHandlers({
        write_record("full", matrix(0, n, 2), 250, gains = 200, adcres = 16, units = "mV",
                     legacy = lg)
        ""
      }, warning = function(w) {
        warned <<- TRUE
        invokeRestart("muffleWarning")
      }), error = function(e) conditionMessage(e))
      wfdbverbose()
      expect_equal(msg, "write error on record full", lab)
      check(wfdbx_write_errors() > before, paste(lab, ": counted"))
      check(startsWith(wfdberror(), "osigclose: write error"), paste(lab, ": message"))
      check(!warned, paste(lab, ": no R warning"))
      check(!wfdbx_get_legacy(), paste(lab, ": legacy mode restored"))
    }
    unlink(c("full.dat", "full.hea"))
  }

  # ---- samps_per_frame checks (python test_write_record_frame_checks): the
  # columns of signals add up to a whole frame, each signal has at least one
  # sample per frame; nothing is written otherwise
  x <- matrix(0:7, 4, 2, byrow = TRUE)
  bad <- list(list(1, "signals has 2 columns, but samps_per_frame adds up to 1"),
              list(3, "signals has 2 columns, but samps_per_frame adds up to 3"),
              list(c(1, 2), "signals has 2 columns, but samps_per_frame adds up to 3"),
              list(c(0, 2), "samps_per_frame must hold integers >= 1"),
              list(c(2, 0), "samps_per_frame must hold integers >= 1"),
              list(c(-1, 3), "samps_per_frame must hold integers >= 1"),
              list(c(1.5, 0.5), "samps_per_frame must hold integers >= 1"),
              list(c(NA, 2), "samps_per_frame must hold integers >= 1"))
  unlink(c("bad.hea", "bad.dat"))
  for (b in bad) for (lg in c(FALSE, TRUE)) {
    msg <- tryCatch({
      write_record("bad", x, 250, gains = 200, adcres = 16, units = "mV",
                   samps_per_frame = b[[1L]], legacy = lg)
      ""
    }, error = function(e) conditionMessage(e))
    lab <- sprintf("frame check spf = %s, legacy = %s", paste(b[[1L]], collapse = ","), lg)
    expect_equal(msg, b[[2L]], lab)
    check(!file.exists("bad.hea") && !file.exists("bad.dat"), paste(lab, ": no files"))
  }
  # (checked before the other arguments)
  msg <- tryCatch(write_record("bad", x, samps_per_frame = 0), error = function(e) conditionMessage(e))
  expect_equal(msg, "samps_per_frame must hold integers >= 1", "frame check first")
  write_record("good", x, 250, gains = 200, adcres = 16, units = "mV", samps_per_frame = 2)
  expect_equal(dim(read_record("good")$signals), c(4L, 1L), "spf 2: one signal")
  write_record("good", x, 250, gains = 200, adcres = 16, units = "mV", samps_per_frame = c(1, 1))
  expect_equal(unname(read_record("good")$signals), unname(x + 0), "spf 1,1: read back")
  wfdbquit()
}
