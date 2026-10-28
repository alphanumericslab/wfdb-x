# Tests of the FLAC codec (flac.R): decoding of the FLAC records of
# tests/data (digests of the samples from the Python implementation), the
# encoder (output identical to the Python encoder's), MD5 (RFC 1321 test
# suite), CRCs, and the signal-group glue functions.
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

hex <- function(b) paste(sprintf("%02x", as.integer(b)), collapse = "")

# --- MD5 (RFC 1321, appendix A.5) and CRCs
md5s <- function(s) hex(md5_raw(charToRaw(s)))
expect_equal(md5s(""), "d41d8cd98f00b204e9800998ecf8427e", "md5 ''")
expect_equal(md5s("a"), "0cc175b9c0f1b6a831c399e269772661", "md5 a")
expect_equal(md5s("abc"), "900150983cd24fb0d6963f7d28e17f72", "md5 abc")
expect_equal(md5s("message digest"), "f96b697d7cb7938d525a2f31aaf161d0", "md5 message digest")
expect_equal(md5s("abcdefghijklmnopqrstuvwxyz"), "c3fcd3d76192e4007dfb496cca67e13b", "md5 a-z")
expect_equal(md5s("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"),
             "d174ab98d277d9f5a5611c2c9f419d9f", "md5 alnum")
expect_equal(md5s(strrep("1234567890", 8)), "57edf4a22be3c955ac49da2e2107b67a", "md5 80 digits")
expect_equal(hex(md5_raw(as.raw(rep(97, 55)))), "ef1772b6dff9a122358552954ad0df65", "md5 55 bytes")
expect_equal(hex(md5_raw(as.raw(rep(98, 56)))), "b9d955696c7654cd20086bec31670b11", "md5 56 bytes")
expect_equal(hex(md5_raw(as.raw(rep(99, 64)))), "bcd5708ed79b18f0f0aaa27fd0056d86", "md5 64 bytes")
x <- as.raw(rep(0:255, 3))
expect_equal(hex(md5_raw(x)), "e6899eaaf06fd702f3ed3f988eb19362", "md5 768 bytes")
x <- as.raw((seq_len(10000) * 7919) %% 256)
expect_equal(.flac_md5(x), md5_raw(x), "md5: tools::md5sum path = md5_raw")
crc16_ref <- function(b) {
  t16 <- .flac_tables$t16
  c <- 0L
  for (v in as.integer(b)) c <- bitwXor((c * 256L) %% 65536L, t16[bitwXor(c %/% 256L, v) + 1L])
  c
}
for (n in c(1, 2, 3, 63, 64, 65, 1000)) {
  b <- as.raw((seq_len(n) * 131 + 7) %% 256)
  expect_equal(.flac_crc16(b), crc16_ref(b), paste("crc16 of", n, "bytes"))
}
expect_equal(.flac_crc8(charToRaw("123456789")), 0xF4L, "crc8 check value")

# --- encoder: identical to the Python encoder (sizes and MD5 of the output)
enc <- function(v, ns, spf, bps, scalar = FALSE) {
  b <- .flac_encode_stream(v, ns, spf, bps, scalar)
  paste(length(b), hex(md5_raw(b)))
}
inter <- function(...) as.vector(rbind(...))
i <- 0:4999
expect_equal(enc(((i * 37) %% 201) - 100, 1, 1, 8), "5080 bad22cbfa10147365c4b49a0f77bdb3b", "encode v1")
i <- 0:8999
c1 <- trunc(1000 * sin(i / 20))
c2 <- ((i * 7919) %% 60001) - 30000
expect_equal(enc(inter(c1, c2), 2, 1, 16), "20881 cd7914067d4d0779390be0fa8e09cdc8", "encode v2")
i <- 0:299
expect_equal(enc(inter(rep(7, 300), ((i * 104729) %% 16000001) - 8000000, i * 1000), 3, 1, 24),
             "361 d53e4f3838807bc4a35b1b45a9e2f7a3", "encode v3")
i <- 0:4099
expect_equal(enc((((i * 13) %% 5) - 2) * 5000, 1, 1, 16), "7871 419ebf902e757d104894e89a6fd8b60e",
             "encode v4")
i <- 0:69
expect_equal(enc(trunc(50000 * sin(i / 7)), 1, 1, 24), "135 9a22f44e9eec03180e4180dc63403fb5", "encode v5")
k <- 0:3000
v6 <- ((k * 31) %% 2001) - 1000
expect_equal(enc(v6, 2, 2, 16), "3592 2bf85303d50cbdb430620afdcbbccb23", "encode v6 (spf 2)")
expect_equal(enc(v6, 2, 2, 16, scalar = TRUE), "3592 2bf85303d50cbdb430620afdcbbccb23",
             "encode v6 with flac_putsamp")
k <- 0:499
expect_equal(enc(((k * 31) %% 2001) - 1000 + 70000, 1, 1, 16), "565 fe0247275c81779b9f5108dec6d26fec",
             "encode v7 (wrapped values)")
# round trip (the incomplete last frame of v6 is discarded)
d <- flac_decode(.flac_encode_stream(v6, 2, 2, 16))
X <- matrix(aperm(array(v6[1:3000], c(2, 2, 750)), c(2, 1, 3)), 2)
expect_equal(d$chans, X, "decode(encode(v6))")
expect_equal(d$bps, 16, "decoded bps")

data <- if (nzchar(.rdir)) file.path(dirname(dirname(.rdir)), "tests", "data") else ""
if (!nzchar(data) || !dir.exists(data)) {
  cat("(tests/data not found: FLAC decoding tests skipped)\n")
} else {
  # --- decoding (MD5 of the samples, as 32-bit little-endian integers in
  # time order, from the Python decoder)
  ref <- list(flac8 = c(2, 5000, 8, "505da209b1473fbc46a21feb7833b00d"),
              flac16 = c(3, 9000, 16, "c7031b07326efeaf5de0938839eccfd4"),
              flac24 = c(1, 4500, 24, "009556de1b80833f7f1d21d99c817729"),
              flacmf = c(2, 8642, 16, "76ee297c139a1538a9fd7f43d5398659"))
  for (f in names(ref)) {
    raw <- readBin(file.path(data, paste0(f, ".dat")), "raw", 1e7)
    r <- flac_decode(raw)
    got <- c(dim(r$chans), r$bps, hex(md5_raw(.flac_sample_bytes(as.vector(r$chans), 4))))
    expect_equal(got, ref[[f]], paste("decode", f))
    expect_equal(.flac_md5(.flac_sample_bytes(as.vector(r$chans), (r$bps + 7) %/% 8)), r$md5,
                 paste("STREAMINFO MD5 of", f))
  }

  # --- the signal-group interface
  old <- getwd()
  td <- tempfile("wfdbx-flac")
  dir.create(td)
  file.copy(file.path(data, c("flac16.dat", "flacmf.dat")), td)
  setwd(td)
  on.exit({
    setwd(old)
    unlink(td, recursive = TRUE)
    wfdbio_reset()
  }, add = TRUE)
  mkig <- function(file, ns, fmt, spf) {
    ig <- new.env()
    ig$fp <- wfdb_fopen(file, "rb")
    ig$start <- 0
    ig$seek <- 1
    ig$stat <- 1
    ig$count <- 0
    hs <- replicate(ns, list(info = siginfo(fmt = fmt, spf = spf)), simplify = FALSE)
    list(ig = ig, st = flac_isopen(ig, hs, ns))
  }
  r <- flac_decode(readBin("flac16.dat", "raw", 1e7))
  o <- mkig("flac16.dat", 3, 516, 1)
  expect_equal(o$st, 0, "flac_isopen")
  ig <- o$ig
  v <- c(flac_getsamp(ig), flac_getsamp(ig), flac_getsamp(ig), flac_getsamp(ig))
  expect_equal(v, as.vector(r$chans)[1:4], "flac_getsamp: frame order")
  g <- flac_getsamps(ig, 5)
  expect_equal(g$v, as.vector(r$chans)[5:9], "flac_getsamps")
  expect_equal(g$st, rep(1, 5), "flac_getsamps status")
  g <- flac_getsamps(ig, Inf)
  expect_equal(g$v, as.vector(r$chans)[-(1:9)], "flac_getsamps(Inf)")
  expect_equal(c(flac_getsamp(ig), ig$stat), c(0, 0), "flac_getsamp at the end")
  expect_equal(flac_isseek(ig, 8000), 1, "flac_isseek")
  g <- flac_getsamps(ig, 3002)
  expect_equal(g$v, c(as.vector(r$chans[, 8001:9000]), 0, 0), "after flac_isseek")
  expect_equal(g$st, c(rep(1, 3000), 0, 0), "status at the end")
  wfdbquiet()
  expect_equal(flac_isseek(ig, 9001), -1, "flac_isseek out of range")
  wfdbverbose()
  expect_equal(flac_isclose(ig), 0, "flac_isclose")
  wf_close(ig$fp)
  # spf 2: frames of 2 samples of each signal
  r <- flac_decode(readBin("flacmf.dat", "raw", 1e7))
  o <- mkig("flacmf.dat", 2, 516, 2)
  g <- flac_getsamps(o$ig, 8)
  expect_equal(g$v, c(r$chans[1, 1:2], r$chans[2, 1:2], r$chans[1, 3:4], r$chans[2, 3:4]),
               "frame order with spf 2")
  wf_close(o$ig$fp)
  # decoding errors
  b <- readBin("flac16.dat", "raw", 1e7)
  b[2000] <- xor(b[2000], as.raw(1))
  writeBin(b, "bad.dat")
  o <- mkig("bad.dat", 3, 516, 1)
  wfdbquiet()
  expect_equal(flac_getsamp(o$ig), 0, "corrupt stream: 0")
  wfdbverbose()
  expect_equal(o$ig$stat, -2, "corrupt stream: stat -2")
  check(grepl("unable to decode FLAC", wfdberror()), "corrupt stream: message")
  wf_close(o$ig$fp)
  wfdbquiet()
  o <- mkig("flac16.dat", 9, 516, 1)
  expect_equal(o$st, -1, "flac_isopen: too many signals")
  wf_close(o$ig$fp)
  wfdbverbose()
  # writing through an output group (seekable file: STREAMINFO rewritten)
  og <- new.env()
  og$fp <- wfdb_fopen("out.dat", "wb")
  og$buf <- raw(0)
  si <- replicate(2, siginfo(fmt = 516, spf = 2), simplify = FALSE)
  expect_equal(flac_osinit(og, si, 2), 0, "flac_osinit")
  expect_equal(og$bsize, 16, "bsize")
  flac_osopen(og)
  flac_putsamps(v6[1:1000], 516, og)
  for (x in v6[1001:3001]) flac_putsamp(x, 516, og)
  flac_osclose(og)
  wf_close(og$fp)
  expect_equal(readBin("out.dat", "raw", 1e6), .flac_encode_stream(v6, 2, 2, 16), "file output")
  check(is.null(og$flac) && identical(og$buf, raw(0)), "flac_osclose resets the group")
}
