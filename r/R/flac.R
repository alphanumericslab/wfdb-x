# flac.R: FLAC-compressed signal files (formats 508, 516 and 524), without
# external libraries: the FLAC support that the C WFDB library obtains from
# libFLAC (the flac_* functions of lib/signal.c).
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of the FLAC support of lib/signal.c (the code that
# connects FLAC to the signal functions) from the WFDB Software Package 10.7.0,
# by Benjamin Moody (2020). The translation follows the logic and behavior of
# the original code, but it is new code, not the original C code. Its FLAC
# codec is wfdb-x's own implementation of the FLAC format; it has no
# counterpart in the original package, which uses libFLAC.
#
# Changes from the original: FLAC streams are decoded and encoded by wfdb-x's
# own codec instead of libFLAC; the files written decode to the same samples,
# but their bytes differ from libFLAC's. Each change is marked "wfdb-x:" in the
# code; docs/DIVERGENCES.md gives the reasons.
#
# Original C code: lib/signal.c (FLAC support), WFDB Software Package 10.7.0.
#   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by
#   Benjamin Moody, including FLAC support (2020).
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# * A complete FLAC decoder (all subframe types, stereo decorrelation,
#   wasted bits, variable block sizes, CRC verification, and MD5 checking
#   when WFDB_FLAC_CHECK_MD5 is set), used to read signals.  Rice codes are
#   decoded with vector operations (pointer doubling over the positions of
#   the one bits), as in the MATLAB/Octave port.
# * A lossless FLAC encoder, used to write signals, whose output is
#   byte-identical to that of the Python implementation of wfdb-x (fixed
#   predictors of order 0 to 4, Rice partitions; libFLAC reads it back
#   with identical sample values).
# * MD5 (RFC 1321) in R, with exact 32-bit arithmetic on 16-bit halves
#   (md5_raw); large inputs use tools::md5sum, the same algorithm in base
#   R's compiled code.
#
# The glue functions take the input and output signal groups of signal.R
# (environments): see "FLAC signal groups" in DEVELOPING.md.

.FLAC_MAX_CHANNELS <- 8      # (FLAC__MAX_CHANNELS of libFLAC)
.FLAC_BLOCKSIZE <- 4096      # samples per channel in each encoded frame

# ---------------------------------------------------------------------------
# CRC-8 (polynomial 0x07) and CRC-16 (polynomial 0x8005) of FLAC frames

.flac_tables <- local({
  t8 <- integer(256)
  t16 <- integer(256)
  for (i in 0:255) {
    x <- i
    for (k in 1:8) x <- if (x >= 128L) bitwXor((2L * x) %% 256L, 7L) else (2L * x) %% 256L
    t8[i + 1L] <- x
    x <- i * 256L
    for (k in 1:8) x <- if (x >= 32768L) bitwXor((2L * x) %% 65536L, 32773L) else (2L * x) %% 65536L
    t16[i + 1L] <- x
  }
  list(t8 = t8, t16 = t16)
})

.flac_crc8 <- function(b) {
  t8 <- .flac_tables$t8
  c <- 0L
  for (x in as.integer(b)) c <- t8[bitwXor(c, x) + 1L]
  c
}

# CRC-16 of the bytes b.  The CRC (initial value 0) is linear:
# crc(A B) = S(crc(A)) xor crc(B), where S shifts a CRC through as many
# zero bytes as B has; the CRCs of blocks of 1, 2, 4, ... bytes are
# combined pairwise with vector operations (leading zero bytes do not
# change the CRC).
.flac_crc16 <- function(b) {
  t16 <- .flac_tables$t16
  d <- as.integer(b)
  n <- length(d)
  if (n == 0L) return(0L)
  m <- 2L^ceiling(log2(n))
  x <- t16[c(integer(m - n), d) + 1L]
  H <- t16                      # S_1(h << 8) = t16[h]
  Lo <- (0:255) * 256L          # S_1(l) = l << 8
  while (length(x) > 1L) {
    a <- x[c(TRUE, FALSE)]
    bb <- x[c(FALSE, TRUE)]
    x <- bitwXor(bitwXor(H[a %/% 256L + 1L], Lo[a %% 256L + 1L]), bb)
    H2 <- bitwXor(H[H %/% 256L + 1L], Lo[H %% 256L + 1L])
    Lo <- bitwXor(H[Lo %/% 256L + 1L], Lo[Lo %% 256L + 1L])
    H <- H2
  }
  x
}

# ---------------------------------------------------------------------------
# MD5

.md5_K <- floor(abs(sin(1:64)) * 2^32)
.md5_S <- c(rep(c(7L, 12L, 17L, 22L), 4), rep(c(5L, 9L, 14L, 20L), 4),
            rep(c(4L, 11L, 16L, 23L), 4), rep(c(6L, 10L, 15L, 21L), 4))
.md5_G <- c(0:15, (5L * (16:31) + 1L) %% 16L, (3L * (32:47) + 5L) %% 16L,
            (7L * (48:63)) %% 16L) + 1L

#' The MD5 digest (16 raw bytes) of the bytes x (raw), computed in R: the
#' 32-bit words are held as pairs of 16-bit integers (exact bitwise
#' operations, additions modulo 2^32 with carries, rotations).
md5_raw <- function(x) {
  n <- length(x)
  npad <- (55 - n) %% 64
  bitlen <- 8 * n
  lenb <- as.raw(floor(bitlen / 256^(0:7)) %% 256)
  w <- matrix(as.integer(c(x, as.raw(0x80), raw(npad), lenb)), 4L)
  XL <- w[1L, ] + 256L * w[2L, ]
  XH <- w[3L, ] + 256L * w[4L, ]
  KH <- as.integer(.md5_K %/% 65536)
  KL <- as.integer(.md5_K %% 65536)
  S <- .md5_S
  G <- .md5_G
  ah <- 0x6745L; al <- 0x2301L
  bh <- 0xefcdL; bl <- 0xab89L
  ch <- 0x98baL; cl <- 0xdcfeL
  dh <- 0x1032L; dl <- 0x5476L
  M <- 65535L
  for (blk in seq_len(length(XL) %/% 16L)) {
    o <- (blk - 1L) * 16L
    xl <- XL[o + 1:16]
    xh <- XH[o + 1:16]
    Ah <- ah; Al <- al; Bh <- bh; Bl <- bl; Ch <- ch; Cl <- cl; Dh <- dh; Dl <- dl
    for (i in 1:64) {
      if (i <= 16L) {
        Fh <- bitwOr(bitwAnd(Bh, Ch), bitwAnd(bitwXor(Bh, M), Dh))
        Fl <- bitwOr(bitwAnd(Bl, Cl), bitwAnd(bitwXor(Bl, M), Dl))
      } else if (i <= 32L) {
        Fh <- bitwOr(bitwAnd(Dh, Bh), bitwAnd(bitwXor(Dh, M), Ch))
        Fl <- bitwOr(bitwAnd(Dl, Bl), bitwAnd(bitwXor(Dl, M), Cl))
      } else if (i <= 48L) {
        Fh <- bitwXor(bitwXor(Bh, Ch), Dh)
        Fl <- bitwXor(bitwXor(Bl, Cl), Dl)
      } else {
        Fh <- bitwXor(Ch, bitwOr(Bh, bitwXor(Dh, M)))
        Fl <- bitwXor(Cl, bitwOr(Bl, bitwXor(Dl, M)))
      }
      g <- G[i]
      l <- Al + Fl + KL[i] + xl[g]
      h <- (Ah + Fh + KH[i] + xh[g] + l %/% 65536L) %% 65536L
      l <- l %% 65536L
      s <- S[i]
      if (s >= 16L) {
        t <- h
        h <- l
        l <- t
        s <- s - 16L
      }
      if (s > 0L) {
        nh <- bitwAnd(bitwOr(bitwShiftL(h, s), bitwShiftR(l, 16L - s)), M)
        l <- bitwAnd(bitwOr(bitwShiftL(l, s), bitwShiftR(h, 16L - s)), M)
        h <- nh
      }
      Ah <- Dh; Al <- Dl
      Dh <- Ch; Dl <- Cl
      Ch <- Bh; Cl <- Bl
      l <- Bl + l
      Bh <- (Bh + h + l %/% 65536L) %% 65536L
      Bl <- l %% 65536L
    }
    l <- al + Al; ah <- (ah + Ah + l %/% 65536L) %% 65536L; al <- l %% 65536L
    l <- bl + Bl; bh <- (bh + Bh + l %/% 65536L) %% 65536L; bl <- l %% 65536L
    l <- cl + Cl; ch <- (ch + Ch + l %/% 65536L) %% 65536L; cl <- l %% 65536L
    l <- dl + Dl; dh <- (dh + Dh + l %/% 65536L) %% 65536L; dl <- l %% 65536L
  }
  v <- c(al, ah, bl, bh, cl, ch, dl, dh)
  as.raw(rbind(v %% 256L, v %/% 256L))
}

# MD5 digest of x (raw): md5_raw, or for large inputs tools::md5sum (the
# same digest, computed by base R's compiled code).
.flac_md5 <- function(x) {
  if (length(x) >= 4096L) {                 # (large: 4 KiB or more)
    d <- tryCatch({
      f <- tempfile("wfdbx_md5_")
      on.exit(unlink(f))
      writeBin(x, f)
      h <- unname(tools::md5sum(f))
      as.raw(strtoi(substring(h, seq(1L, 31L, 2L), seq(2L, 32L, 2L)), 16L))
    }, error = function(e) NULL)
    if (length(d) == 16L) return(d)
  }
  md5_raw(x)
}

# ---------------------------------------------------------------------------
# Decoder

.flac_err <- function(status) {
  stop(structure(class = c("wfdbx_flac", "error", "condition"),
                 list(message = paste("FLAC decoding error:", status), call = NULL,
                      status = status)))
}

# Bits of bytes (integer 0/1, most significant bit first).
.flac_bits <- function(b) {
  m <- matrix(as.integer(rawToBits(as.raw(b))), 8L)
  as.vector(m[8:1, , drop = FALSE])
}

# A bit reader over a window of the data: environment with B (bits), p
# (bits consumed) and atend (TRUE if the window reaches the end of the
# data).  Reading beyond the window raises 'eof' at the end of the data,
# or 'window' (the caller retries with a larger window).
.flac_overrun <- function(br) {
  if (br$atend) .flac_err("eof")
  .flac_err("window")
}

.flac_rd <- function(br, n) {
  if (n <= 0) return(0)
  p <- br$p
  if (p + n > length(br$B)) .flac_overrun(br)
  br$p <- p + n
  sum(br$B[(p + 1):(p + n)] * 2^((n - 1):0))
}

.flac_rds <- function(br, n) {
  v <- .flac_rd(br, n)
  if (n > 0 && v >= 2^(n - 1)) v - 2^n else v
}

# cnt values of n bits (signed).
.flac_rdvec <- function(br, cnt, n) {
  if (n <= 0 || cnt <= 0) return(numeric(max(cnt, 0)))
  p <- br$p
  if (p + cnt * n > length(br$B)) .flac_overrun(br)
  M <- matrix(br$B[(p + 1):(p + cnt * n)], n)
  v <- colSums(M * 2^((n - 1):0))
  br$p <- p + cnt * n
  v - (v >= 2^(n - 1)) * 2^n
}

.flac_unary <- function(br) {
  p <- br$p
  L <- length(br$B)
  k <- if (p < L) match(1L, br$B[(p + 1):L]) else NA
  if (is.na(k)) .flac_overrun(br)
  br$p <- p + k
  k - 1
}

# n Rice codes with parameter k (unary quotient, then k bits): the folded
# values.
.flac_rice <- function(br, n, k) {
  if (n <= 0) return(numeric(0))
  B <- br$B
  p0 <- br$p
  NB <- length(B)
  win <- n * (k + 4) + 256
  repeat {
    e <- min(NB, p0 + win)
    seg <- if (e > p0) B[(p0 + 1):e] else integer(0)
    O <- which(seg == 1L)                 # positions of the ones
    full <- e == NB
    if (k == 0) {
      if (length(O) >= n) {
        T <- O[seq_len(n)]
        br$p <- p0 + T[n]
        return(T - c(0L, T[-n]) - 1)
      }
    } else {
      M <- length(O)
      if (M > 0L) {
        len <- length(seg)
        cnt <- c(0L, cumsum(seg))         # cnt[q]: ones before position q
        q <- O + 1L + k                   # start of the next code
        J <- rep.int(M + 1L, M + 1L)
        ok <- q <= len
        J[which(ok)] <- cnt[q[ok]] + 1L
        J[J > M] <- M + 1L
        # the n codes: idx[i] = J^(i-1)(1), by pointer doubling
        idx <- rep.int(1L, n)
        ii <- 0:(n - 1L)
        Jp <- J
        b <- 1L
        while (b <= n - 1L) {
          sel <- bitwAnd(ii, b) != 0L
          idx[sel] <- Jp[idx[sel]]
          Jp <- Jp[Jp]
          b <- b * 2L
        }
        if (all(idx <= M) && O[idx[n]] + k <= len) {
          T <- O[idx]
          st <- c(1L, T[-n] + 1L + k)
          low <- numeric(n)
          for (j in seq_len(k)) low <- 2 * low + seg[T + j]
          br$p <- p0 + T[n] + k
          return((T - st) * 2^k + low)
        }
      }
    }
    if (full) .flac_overrun(br)
    win <- 4 * win
  }
}

.flac_residual <- function(br, blocksize, order) {
  method <- .flac_rd(br, 2)
  if (method > 1) .flac_err("unparseable")
  pbits <- if (method == 0) 4 else 5
  esc <- if (method == 0) 15 else 31
  porder <- .flac_rd(br, 4)
  nparts <- 2^porder
  if (blocksize %% nparts) .flac_err("unparseable")
  psize <- blocksize / nparts
  if (porder > 0 && psize < order) .flac_err("unparseable")
  out <- vector("list", nparts)
  for (part in seq_len(nparts)) {
    n <- if (part == 1L) psize - order else psize
    k <- .flac_rd(br, pbits)
    if (k == esc) {
      nb <- .flac_rd(br, 5)
      out[[part]] <- if (n > 0) .flac_rdvec(br, n, nb) else numeric(0)
    } else {
      u <- .flac_rice(br, n, k)
      v <- floor(u / 2)
      odd <- u - 2 * v == 1
      v[odd] <- -v[odd] - 1
      out[[part]] <- v
    }
  }
  unlist(out, use.names = FALSE)
}

.flac_subframe <- function(br, blocksize, bps) {
  if (.flac_rd(br, 1)) .flac_err("unparseable")
  t <- .flac_rd(br, 6)
  wasted <- 0
  if (.flac_rd(br, 1)) {
    wasted <- .flac_unary(br) + 1
    bps <- bps - wasted
  }
  if (t == 0) {
    s <- rep(.flac_rds(br, bps), blocksize)
  } else if (t == 1) {
    s <- .flac_rdvec(br, blocksize, bps)
  } else if (t >= 8 && t <= 12) {
    order <- t - 8
    w <- .flac_rdvec(br, order, bps)
    r <- .flac_residual(br, blocksize, order)
    if (order == 0) {
      s <- r
    } else if (length(r) == 0L) {
      s <- w
    } else {
      # order-fold cumulative sums of the residuals, starting from the
      # differences of the warm-up samples
      d <- w
      last <- numeric(order)
      for (m in 0:(order - 1)) {
        last[m + 1] <- d[length(d)]
        d <- diff(d)
      }
      x <- r
      for (m in (order - 1):0) x <- last[m + 1] + cumsum(x)
      s <- c(w, x)
    }
  } else if (t >= 32) {
    order <- t - 31
    w <- .flac_rdvec(br, order, bps)
    prec <- .flac_rd(br, 4) + 1
    if (prec == 16) .flac_err("unparseable")
    shift <- .flac_rds(br, 5)
    coefs <- .flac_rdvec(br, order, prec)
    r <- .flac_residual(br, blocksize, order)
    if (shift < 0) .flac_err("unparseable")
    s <- .flac_lpc_restore(w, r, rev(coefs), shift)
  } else {
    .flac_err("unparseable")
  }
  if (wasted) s <- s * 2^wasted
  s
}

# s[i] = r[i - order] + floor(sum(c * s[i-order .. i-1]) / 2^shift)
.flac_lpc_restore <- function(w, r, c, shift) {
  order <- length(w)
  n <- order + length(r)
  s <- c(w, numeric(length(r)))
  d <- 2^shift
  if (length(r)) {
    for (i in (order + 1L):n) s[i] <- r[i - order] + floor(sum(c * s[(i - order):(i - 1L)]) / d)
  }
  s
}

.FLAC_BS <- c(192, 576, 1152, 2304, 4608, 0, 0, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768)
.FLAC_BPS <- c(8, 12, NA, 16, 20, 24, 32)

# Decode the frame at byte offset pos (0-based) of data (integer codes),
# reading a window of W bytes: list(chans (matrix, one row per channel),
# bps, newpos).
.flac_frame <- function(data, pos, si_bps, W) {
  L <- length(data)
  # (the frame sync code: 0xFFF8, or 0xFFF9 for variable block sizes)
  if (pos + 2 > L || data[pos + 1L] != 255L || bitwAnd(data[pos + 2L], 254L) != 248L)
    .flac_err("sync")
  e <- min(L, pos + W)
  br <- new.env(parent = emptyenv())
  br$atend <- e == L
  br$B <- .flac_bits(data[(pos + 1):e])
  br$p <- 0
  .flac_rd(br, 16)
  bsc <- .flac_rd(br, 4)
  src <- .flac_rd(br, 4)
  chc <- .flac_rd(br, 4)
  ssc <- .flac_rd(br, 3)
  if (.flac_rd(br, 1)) .flac_err("header")
  # UTF-8 coded frame or sample number: the leading byte gives the number
  # of continuation bytes (10xxxxxx)
  x <- .flac_rd(br, 8)
  if (x >= 128) {
    nx <- if (x >= 192 && x < 224) 1 else if (x >= 224 && x < 240) 2 else
      if (x >= 240 && x < 248) 3 else if (x >= 248 && x < 252) 4 else
        if (x >= 252 && x < 254) 5 else if (x == 254) 6 else .flac_err("header")
    for (k in seq_len(nx)) {
      y <- .flac_rd(br, 8)
      if (y < 128 || y >= 192) .flac_err("header")
    }
  }
  blocksize <- if (bsc == 0) .flac_err("header") else if (bsc == 6) .flac_rd(br, 8) + 1 else
    if (bsc == 7) .flac_rd(br, 16) + 1 else .FLAC_BS[bsc]
  if (src == 12) {
    .flac_rd(br, 8)
  } else if (src == 13 || src == 14) {
    .flac_rd(br, 16)
  } else if (src == 15) {
    .flac_err("header")
  }
  bps <- if (ssc == 0) si_bps else if (ssc == 3) .flac_err("header") else .FLAC_BPS[ssc]
  hend <- br$p / 8
  crc <- .flac_rd(br, 8)
  if (.flac_crc8(data[(pos + 1):(pos + hend)]) != crc) .flac_err("header")
  if (chc < 8) {
    nch <- chc + 1
    chans <- matrix(0, nch, blocksize)
    for (c in seq_len(nch)) chans[c, ] <- .flac_subframe(br, blocksize, bps)
  } else if (chc == 8) {                  # left/side
    a <- .flac_subframe(br, blocksize, bps)
    sd <- .flac_subframe(br, blocksize, bps + 1)
    chans <- rbind(a, a - sd, deparse.level = 0)
  } else if (chc == 9) {                  # side/right
    sd <- .flac_subframe(br, blocksize, bps + 1)
    b <- .flac_subframe(br, blocksize, bps)
    chans <- rbind(sd + b, b, deparse.level = 0)
  } else if (chc == 10) {                 # mid/side
    m <- .flac_subframe(br, blocksize, bps)
    sd <- .flac_subframe(br, blocksize, bps + 1)
    m <- 2 * m + sd %% 2
    chans <- rbind(floor((m + sd) / 2), floor((m - sd) / 2), deparse.level = 0)
  } else {
    .flac_err("header")
  }
  br$p <- 8 * ceiling(br$p / 8)
  fend <- br$p / 8
  crc <- .flac_rd(br, 16)
  if (.flac_crc16(data[(pos + 1):(pos + fend)]) != crc) .flac_err("crc")
  list(chans = chans, bps = bps, newpos = pos + br$p / 8)
}

#' Decode a complete FLAC stream (raw): list(chans (matrix, one row per
#' channel), bps (bits per sample from STREAMINFO), md5 (the 16-byte MD5
#' signature of STREAMINFO)).  With nsig and datb, also checks (as the
#' WFDB library does) that each frame has nsig channels and at most datb
#' bits per sample.  Errors are conditions of class "wfdbx_flac" whose
#' field status is "meta", "sync", "header", "crc", "unparseable", "eof"
#' or "wfdb".
flac_decode <- function(data, nsig = NULL, datb = NULL) {
  d <- as.integer(data)
  L <- length(d)
  if (L < 4L || !identical(d[1:4], c(102L, 76L, 97L, 67L))) .flac_err("meta")   # "fLaC"
  pos <- 4
  si_bps <- 0
  si_ch <- 0
  md5 <- raw(16)
  repeat {
    if (pos + 4 > L) .flac_err("meta")
    hb <- d[pos + 1]
    ln <- sum(d[(pos + 2):(pos + 4)] * c(65536, 256, 1))
    if (pos + 4 + ln > L) .flac_err("meta")
    if (hb %% 128L == 0L) {
      if (ln < 34) .flac_err("meta")
      x <- d[pos + 17] * 256 + d[pos + 18]          # bits 96..111 of STREAMINFO
      si_ch <- (x %/% 512) %% 8 + 1
      si_bps <- (x %/% 16) %% 32 + 1
      md5 <- as.raw(d[(pos + 23):(pos + 38)])
    }
    pos <- pos + 4 + ln
    if (hb >= 128L) break
  }
  frames <- list()
  block_ends <- numeric(0)
  W <- 4096
  while (pos < L) {
    fr <- tryCatch(.flac_frame(d, pos, si_bps, W), wfdbx_flac = function(e) e)
    if (inherits(fr, "wfdbx_flac")) {
      if (fr$status == "window") {
        W <- 4 * W
        next
      }
      if (fr$status == "sync" && !any(d[(pos + 1):L] != 0L)) break
      stop(fr)
    }
    if (!is.null(nsig) && nrow(fr$chans) != nsig) {
      wfdb_error("getvec: wrong number of signals in FLAC signal file\n")
      .flac_err("wfdb")
    }
    if (!is.null(datb) && fr$bps > datb) {
      wfdb_error("getvec: wrong sample resolution in FLAC signal file\n")
      .flac_err("wfdb")
    }
    frames[[length(frames) + 1L]] <- fr$chans
    block_ends <- c(block_ends, ncol(fr$chans))
    W <- max(1024, 2 * (fr$newpos - pos) + 64)   # (window for the next frame)
    pos <- fr$newpos
  }
  nch <- max(si_ch, 1)
  if (length(frames) == 0L) {
    chans <- matrix(0, nch, 0)
  } else {
    m <- min(vapply(frames, nrow, 1L))
    nch <- min(nch, m)                # (channels paired as in the Python decoder)
    chans <- do.call(cbind, lapply(frames, function(f) f[seq_len(nch), , drop = FALSE]))
  }
  # (block_ends: the end of each frame (FLAC block), in samples per channel)
  list(chans = chans, bps = si_bps, md5 = md5, block_ends = cumsum(block_ends))
}

# Bytes of the interleaved samples (as libFLAC computes the MD5 signature):
# for each sample time, each channel, nb little-endian bytes.
.flac_sample_bytes <- function(v, nb) {
  v <- v %% 2^(8 * nb)
  as.raw(floor(rep(v, each = nb) / 256^(0:(nb - 1))) %% 256)
}

# Decode the whole stream of an input group (once).
.flac_ensure <- function(ig) {
  fi <- ig$flac
  if (fi$decoded) return(fi)
  fi$decoded <- TRUE
  r <- tryCatch({
    res <- flac_decode(wf_readall(ig$fp), fi$nsig, fi$datb)
    fi$md5 <- res$md5
    fi$block_ends <- res$block_ends
    arr <- res$chans
    n <- ncol(arr)
    if (n == 0L) arr <- matrix(0, fi$nsig, 0)
    if (fi$md5_check && n) fi$decoded_md5 <- .flac_md5(.flac_sample_bytes(as.vector(arr),
                                                                          (res$bps + 7) %/% 8))
    fi$arr <- arr
    fi$total <- n
    .flac_pack(fi, 0)
    NULL
  }, wfdbx_flac = function(e) e$status)
  if (!is.null(r)) {
    msg <- switch(r,
                  sync = "getvec: unable to decode FLAC (lost sync)\n",
                  header = "getvec: unable to decode FLAC (invalid header)\n",
                  crc = "getvec: unable to decode FLAC (CRC mismatch)\n",
                  unparseable = "getvec: unable to decode FLAC (unsupported format)\n",
                  eof = "getvec: unable to decode FLAC\n",
                  meta = "getvec: unexpected FLAC decoding error\n",
                  NULL)
    if (!is.null(msg)) wfdb_error(msg)
    fi$error <- r
    fi$samples <- numeric(0)
  }
  fi
}

# The samples from sample number base (per signal) onward in WFDB frame
# order (for each frame: spf samples of each signal in turn), as the C
# library reads them after a seek to that sample.
.flac_pack <- function(fi, base) {
  spf <- fi$spf
  nch <- nrow(fi$arr)
  nfr <- (fi$total - base) %/% spf
  fi$leftover <- (fi$total - base) - nfr * spf
  if (nfr > 0) {
    X <- fi$arr[, base + seq_len(nfr * spf), drop = FALSE]
    Y <- array(t(X), c(spf, nfr, nch))
    fi$samples <- as.vector(aperm(Y, c(1L, 3L, 2L)))
  } else {
    fi$samples <- numeric(0)
  }
  fi$pos <- 0
  fi$base <- base
  invisible()
}

# The end of the FLAC block that contains sample n - 1 (n > 0): the number
# of samples (per channel) decoded once sample n - 1 is.
.flac_block_end <- function(fi, n) {
  k <- which(fi$block_ends >= n)
  if (length(k)) fi$block_ends[k[1L]] else fi$total
}

# Decoding a block after a failed seek (ig$stat < 0): iflac_samples()
# aborts the decoder, and flac_getsamp() reports the error.
.flac_abort <- function(ig) {
  ig$flac$aborted <- TRUE
  if (ig$stat != -2) {
    wfdb_error("getvec: unexpected FLAC decoding error\n")
    ig$stat <- -2
  }
  0
}

#' Prepare to read a FLAC signal group (flac_isopen in signal.c).  ig: the
#' input group (fields fp, start, stat, count, flac); hs: list of the
#' header data of its ns signals (hs[[i]]$info$fmt, hs[[i]]$info$spf).
#' Returns 0, or -1 after an error message.
flac_isopen <- function(ig, hs, ns) {
  if (ns > .FLAC_MAX_CHANNELS) {
    wfdb_error("isigopen: cannot store %u signals in a single FLAC file\n", ns)
    return(-1)
  }
  for (i in seq_len(ns)[-1L]) {
    if (hs[[i]]$info$spf != hs[[1L]]$info$spf) {
      wfdb_error("isigopen: every signal in a FLAC file must have\n  the same sampling frequency\n")
      return(-1)
    }
  }
  fi <- new.env(parent = emptyenv())
  fi$nsig <- ns
  fi$datb <- hs[[1L]]$info$fmt - 500
  fi$spf <- hs[[1L]]$info$spf
  fi$decoded <- FALSE
  fi$error <- NULL
  fi$arr <- NULL
  fi$total <- 0
  fi$samples <- numeric(0)
  fi$pos <- 0
  fi$leftover <- 0
  fi$md5_check <- nzchar(Sys.getenv("WFDB_FLAC_CHECK_MD5"))
  fi$md5 <- NULL
  fi$decoded_md5 <- NULL
  fi$seeked <- FALSE
  # State of the libFLAC decoder of the C library, which decodes one FLAC
  # block at a time: the end of each block (in samples per channel), the end
  # of the blocks decoded so far, the sample from which fi$samples starts,
  # whether the buffered samples were discarded by a failed seek, and
  # whether decoding was aborted (after a failed seek, iflac_samples()
  # aborts the decoding of the next block, and libFLAC then refuses to
  # seek).
  fi$block_ends <- numeric(0)
  fi$dec_end <- 0
  fi$base <- 0
  fi$discarded <- FALSE
  fi$aborted <- FALSE
  ig$flac <- fi
  ig$count <- 0
  0
}

#' The next sample of a FLAC input group, in frame order.  At the end of
#' the data, 0 is returned and ig$stat set to 0 (the first time, a warning
#' gives the number of samples left over that do not fill a frame); after
#' a decoding error, 0 is returned and ig$stat is -2.
flac_getsamp <- function(ig) {
  fi <- ig$flac
  if (!fi$decoded) .flac_ensure(ig)
  if (!is.null(fi$error)) {
    ig$stat <- -2
    return(0)
  }
  if (fi$aborted) return(0)    # (the decoder does nothing; ig$stat is negative)
  p <- fi$pos
  if (p < length(fi$samples)) {
    # The frame of the next sample must have been decoded.
    need <- fi$base + (p %/% (fi$nsig * fi$spf) + 1) * fi$spf
    if (fi$discarded || need > fi$dec_end) {
      if (ig$stat < 0) return(if (fi$dec_end < fi$total) .flac_abort(ig) else 0)
      fi$dec_end <- .flac_block_end(fi, need)
    }
    fi$pos <- p + 1
    return(fi$samples[p + 1])
  }
  if (fi$discarded && fi$dec_end < fi$total) return(.flac_abort(ig))
  if (ig$stat < 0) return(0)
  fi$dec_end <- fi$total
  if (fi$leftover) {
    wfdb_error("getvec: warning: %d samples left over at end of file\n", fi$leftover)
    fi$leftover <- 0
  }
  ig$stat <- 0
  0
}

#' The number of samples of a FLAC input group that remain to be read
#' (decoding the stream first if needed), or -1 after a decoding error.
flac_navail <- function(ig) {
  fi <- ig$flac
  if (!fi$decoded) .flac_ensure(ig)
  if (!is.null(fi$error)) return(-1)
  if (fi$aborted || fi$discarded || ig$stat < 0) return(-1)   # (after a failed seek)
  length(fi$samples) - fi$pos
}

#' Exactly the effect of n calls of flac_getsamp(ig) (n = Inf: all the
#' remaining samples, without the reads past the end): list(v = the
#' samples returned, st = the value of ig$stat after each call).
flac_getsamps <- function(ig, n) {
  fi <- ig$flac
  if (!fi$decoded) .flac_ensure(ig)
  if (!is.null(fi$error)) {
    if (is.infinite(n)) n <- 0
    if (n > 0) ig$stat <- -2
    return(list(v = numeric(n), st = rep(-2, n)))
  }
  if (fi$aborted || fi$discarded || ig$stat < 0) {
    # (after a failed seek: one sample at a time)
    if (is.infinite(n)) n <- max(length(fi$samples) - fi$pos, 0)
    v <- numeric(n)
    st <- numeric(n)
    for (k in seq_len(n)) {
      v[k] <- flac_getsamp(ig)
      st[k] <- ig$stat
    }
    return(list(v = v, st = st))
  }
  p <- fi$pos
  avail <- length(fi$samples) - p
  if (is.infinite(n)) n <- avail
  k <- min(n, avail)
  v <- numeric(n)
  st <- numeric(n)
  if (k > 0) {
    v[seq_len(k)] <- fi$samples[p + seq_len(k)]
    st[seq_len(k)] <- ig$stat
    # the blocks decoded for the frame of the last sample read
    need <- fi$base + ((p + k - 1) %/% (fi$nsig * fi$spf) + 1) * fi$spf
    if (need > fi$dec_end) fi$dec_end <- .flac_block_end(fi, need)
  }
  fi$pos <- p + k
  if (k < n) {
    fi$dec_end <- fi$total
    if (fi$leftover) {
      wfdb_error("getvec: warning: %d samples left over at end of file\n", fi$leftover)
      fi$leftover <- 0
    }
    ig$stat <- 0
  }
  list(v = v, st = st)
}

#' Seek a FLAC input group to frame t (counted from ig$start samples into
#' the stream).  Returns ig$stat (1), or -1 if t is out of range or the
#' stream cannot be decoded.
flac_isseek <- function(ig, t) {
  fi <- .flac_ensure(ig)
  ig$stat <- 1
  ig$count <- 0
  fi$seeked <- TRUE
  if (!is.null(fi$error)) {
    ig$stat <- -1
    return(-1)
  }
  tt <- t * fi$spf + ig$start
  if (fi$aborted || tt > fi$total || tt < 0) {
    # (libFLAC refuses to seek once decoding was aborted, or past the end
    # of the stream; the buffered samples are discarded anyway)
    fi$discarded <- TRUE
    ig$stat <- -1
    return(-1)
  }
  .flac_pack(fi, tt)
  fi$discarded <- FALSE
  # The seek decodes the block that contains sample tt - 1 (sample 0 if tt
  # is 0): libFLAC seeks to it, and the first sample is skipped.
  fi$dec_end <- .flac_block_end(fi, max(tt, 1))
  ig$stat
}

#' Finish reading a FLAC input group: with WFDB_FLAC_CHECK_MD5 set (when
#' the group was opened), if the whole stream was decoded without seeking,
#' the MD5 signature of the samples is checked against STREAMINFO.
#' Returns 0, or -1 after "isigclose: warning: incorrect MD5 hash".
flac_isclose <- function(ig) {
  fi <- ig$flac
  if (!is.null(fi) && fi$md5_check && !is.null(fi$md5) && !is.null(fi$decoded_md5) &&
      !fi$seeked && any(fi$md5 != as.raw(0L)) && !identical(fi$md5, fi$decoded_md5)) {
    wfdb_error("isigclose: warning: incorrect MD5 hash in FLAC input\n")
    return(-1)
  }
  0
}

# ---------------------------------------------------------------------------
# Encoder

# Bytes of bit fields (value v[i] on w[i] bits, most significant bit
# first; values >= 0), padded with zeros to a whole number of bytes.
.flac_packbits <- function(v, w) {
  k <- w > 0
  v <- v[k]
  w <- w[k]
  T <- sum(w)
  nb <- ceiling(T / 8)
  bits <- integer(8 * nb)
  if (T > 0) {
    ends <- cumsum(w)
    bits[ends[v == 1]] <- 1L              # (all unary codes)
    gen <- which(v > 1)
    if (length(gen)) {
      maxw <- max(w[gen])
      for (j in 0:(maxw - 1)) {
        sel <- gen[w[gen] > j]
        bits[ends[sel] - j] <- as.integer(floor(v[sel] / 2^j) %% 2)
      }
    }
  }
  packBits(as.vector(matrix(bits, 8L)[8:1, , drop = FALSE]), "raw")
}

# The UTF-8 coding of the frame number v (byte values): with n continuation
# bytes (6 bits each), the leading byte lead[n] holds the remaining bits.
.flac_utf8 <- function(v) {
  if (v < 128) return(v)
  lead <- c(192, 224, 240, 248, 252, 254)
  mx <- 2^(5 * (1:6) + 6) - 1               # largest value coded in n + 1 bytes
  for (n in 1:6) {
    if (v <= mx[n]) {
      b <- numeric(n + 1)
      for (k in (n + 1):2) {
        b[k] <- 128 + v %% 64
        v <- v %/% 64
      }
      b[1] <- lead[n] + v
      return(b)
    }
  }
  stop("FLAC frame number too large")
}

# The partition order and Rice parameters (near the mean of the folded
# residuals u) of least cost: list(cost, porder, params).
.flac_best_partition <- function(u, order, n, maxk) {
  best <- Inf
  bporder <- 0
  bparams <- 0
  for (porder in 0:6) {
    nparts <- 2^porder
    if (n %% nparts) break
    psize <- n / nparts
    if (porder > 0 && psize <= order) break
    U <- matrix(c(numeric(order), u), psize, nparts)
    cnt <- rep(psize, nparts)
    cnt[1] <- psize - order
    sums <- colSums(U)
    params <- numeric(nparts)
    nz <- cnt > 0
    mean <- numeric(nparts)
    mean[nz] <- floor(sums[nz] / cnt[nz])
    k0 <- numeric(nparts)
    pos <- mean > 0
    if (any(pos)) {
      e <- floor(log2(mean[pos])) + 1     # bit length
      e <- e - (2^(e - 1) > mean[pos]) + (2^e <= mean[pos])
      k0[pos] <- e - 1
    }
    lo <- pmin(pmax(k0 - 1, 0), maxk)
    hi <- pmin(k0 + 2, maxk)
    bc <- rep(Inf, nparts)
    for (d in 0:3) {
      k <- lo + d
      ok <- k <= hi & nz
      if (!any(ok)) next
      c <- colSums(floor(U[, ok, drop = FALSE] / rep(2^k[ok], each = psize))) + cnt[ok] * (k[ok] + 1)
      cc <- rep(Inf, nparts)
      cc[ok] <- c
      better <- cc < bc
      bc[better] <- cc[better]
      params[better] <- k[better]
    }
    cost <- 6 + 4 * nparts + sum(bc[nz])
    if (cost < best) {
      best <- cost
      bporder <- porder
      bparams <- params
    }
  }
  list(cost = best, porder = bporder, params = bparams)
}

# The bit fields (values, widths) of the subframe of the samples x.
.flac_enc_subframe <- function(x, bps) {
  n <- length(x)
  mb <- 2^bps
  if (all(x == x[1L])) return(list(v = c(0, 0, 0, x[1L] %% mb), w = c(1, 6, 1, bps)))
  maxk <- 30
  bestcost <- Inf
  for (order in 0:min(4, n - 1)) {
    r <- if (order == 0) x else diff(x, differences = order)
    u <- 2 * abs(r) - (r < 0)             # folded residuals
    bp <- .flac_best_partition(u, order, n, maxk)
    cost <- order * bps + 2 + bp$cost
    if (cost < bestcost) {
      bestcost <- cost
      border <- order
      bu <- u
      bbp <- bp
    }
  }
  if (bestcost >= n * bps)                # verbatim
    return(list(v = c(0, 1, 0, x %% mb), w = c(1, 6, 1, rep(bps, n))))
  order <- border
  u <- bu
  porder <- bbp$porder
  params <- bbp$params
  method <- if (max(params) < 15) 0 else 1
  pbits <- if (method == 0) 4 else 5
  nparts <- 2^porder
  psize <- n / nparts
  V <- c(0, 8 + order, 0, x[seq_len(order)] %% mb, method, porder)
  Wd <- c(1, 6, 1, rep(bps, order), 2, 4)
  # partitions: parameter, then the codes (q zeros and a one, then k bits)
  cnt <- rep(psize, nparts)
  cnt[1] <- psize - order
  m <- length(u)
  kk <- rep(params, cnt)                  # parameter of each residual
  q <- floor(u / 2^kk)
  low <- u - q * 2^kk
  nf <- nparts + 2 * m
  PV <- numeric(nf)
  PW <- numeric(nf)
  start <- cumsum(c(0, cnt[-nparts]))     # residuals before each partition
  ppos <- start * 2 + (0:(nparts - 1)) + 1  # field index of each parameter
  PV[ppos] <- params
  PW[ppos] <- pbits
  part <- rep(seq_len(nparts), cnt)
  ridx <- seq_len(m)
  fpos <- ppos[part] + 2 * (ridx - start[part]) - 1   # field of the unary code
  PV[fpos] <- 1
  PW[fpos] <- q + 1
  PV[fpos + 1] <- low
  PW[fpos + 1] <- kk
  list(v = c(V, PV), w = c(Wd, PW))
}

# One FLAC frame (raw) holding the samples block (one row per channel).
.flac_encode_frame <- function(block, bps, frame_no) {
  nch <- nrow(block)
  n <- ncol(block)
  bsc <- if (n == 4096) 12 else if (n <= 256) 6 else 7
  ssc <- if (bps == 8) 1 else if (bps == 16) 4 else if (bps == 24) 6 else 0
  # sync code, block size and sample rate codes (11: none), channels and
  # sample size codes, frame number
  head <- c(255, 248, bsc * 16 + 11, (nch - 1) * 16 + ssc * 2, .flac_utf8(frame_no))
  if (bsc == 6) {
    head <- c(head, n - 1)
  } else if (bsc == 7) {
    head <- c(head, (n - 1) %/% 256, (n - 1) %% 256)
  }
  head <- as.raw(head)
  head <- c(head, as.raw(.flac_crc8(head)))
  V <- vector("list", nch)
  Wd <- vector("list", nch)
  for (c in seq_len(nch)) {
    f <- .flac_enc_subframe(block[c, ], bps)
    V[[c]] <- f$v
    Wd[[c]] <- f$w
  }
  frame <- c(head, .flac_packbits(unlist(V), unlist(Wd)))
  c16 <- .flac_crc16(frame)
  c(frame, as.raw(c(c16 %/% 256L, c16 %% 256L)))
}

# The FLAC stream of the samples v (WFDB frame order) of ns signals with
# spf samples per frame, written by flac_putsamps (scalar = FALSE) or
# flac_putsamp (scalar = TRUE).
.flac_encode_stream <- function(v, ns, spf, bps, scalar = FALSE) {
  og <- new.env(parent = emptyenv())
  og$fp <- NULL
  si <- replicate(ns, list(spf = spf, fmt = 500 + bps), simplify = FALSE)
  flac_osinit(og, si, ns)
  og$flac$out <- list()
  flac_osopen(og)
  if (scalar) {
    for (x in v) flac_putsamp(x, 500 + bps, og)
  } else {
    flac_putsamps(v, 500 + bps, og)
  }
  fo <- og$flac
  flac_osclose(og)
  b <- unlist(fo$out, use.names = FALSE)
  # (STREAMINFO completed by flac_osclose)
  b[9:42] <- fo$streaminfo
  b
}

.flac_streaminfo <- function(fo, total, md5) {
  bytes <- .flac_packbits(c(.FLAC_BLOCKSIZE, .FLAC_BLOCKSIZE, if (is.null(fo$minfs)) 0 else fo$minfs,
                            fo$maxfs, 96000, fo$nsig - 1, fo$bps - 1, total %/% 2^32, total %% 2^32),
                          c(16, 16, 24, 24, 20, 3, 5, 4, 32))
  c(bytes, md5)
}

.flac_write <- function(og, b) {
  if (!is.null(og$fp)) {
    wf_write(og$fp, b)
  } else if (!is.null(og$flac$out)) {
    og$flac$out[[length(og$flac$out) + 1L]] <- b
  }
}

#' Prepare to write a FLAC signal group (flac_osinit): og is the output
#' group (fields fp, bsize, buf, flac), si the list of the siginfo() of its
#' ns signals.  Returns 0, or -1 after an error message.
flac_osinit <- function(og, si, ns) {
  if (ns > .FLAC_MAX_CHANNELS) {
    wfdb_error("osigfopen: cannot store %u signals in a single FLAC file\n", ns)
    return(-1)
  }
  for (i in seq_len(ns)[-1L]) {
    if (si[[i]]$spf != si[[1L]]$spf) {
      wfdb_error("osigfopen: every signal in a FLAC file must have\n  the same sampling frequency\n")
      return(-1)
    }
  }
  fo <- new.env(parent = emptyenv())
  fo$nsig <- ns
  fo$bps <- si[[1L]]$fmt - 500
  fo$spf <- si[[1L]]$spf
  fo$cbuf <- matrix(0, ns, 0)             # samples per channel not yet encoded
  fo$pend <- numeric(0)                   # samples of the current frame
  fo$frame_no <- 0
  fo$total <- 0
  fo$minfs <- NULL
  fo$maxfs <- 0
  fo$md5data <- list()
  fo$header_pos <- 0
  og$flac <- fo
  og$bsize <- ns * si[[1L]]$spf * 4
  0
}

#' Write the stream header of a FLAC output group (flac_osopen): the
#' stream marker, a STREAMINFO block (completed by flac_osclose) and a
#' VORBIS_COMMENT block (vendor "wfdb-x").  Returns 0.
flac_osopen <- function(og) {
  fo <- og$flac
  vendor <- charToRaw("wfdb-x")
  nv <- length(vendor)
  vc <- c(as.raw(floor(nv / 256^(0:3)) %% 256), vendor, raw(4))
  nvc <- length(vc)
  hdr <- c(charToRaw("fLaC"), as.raw(c(0, 0, 0, 34)),
           .flac_streaminfo(fo, 2^36 - 1, raw(16)),
           as.raw(c(132, nvc %/% 65536, (nvc %/% 256) %% 256, nvc %% 256)), vc)
  fo$header_pos <- if (!is.null(og$fp)) wf_tell(og$fp) else 0
  .flac_write(og, hdr)
  0
}

# Encode and write the first n buffered samples of each signal.
.flac_writeblock <- function(og, n) {
  fo <- og$flac
  block <- fo$cbuf[, seq_len(n), drop = FALSE]
  fo$cbuf <- fo$cbuf[, -seq_len(n), drop = FALSE]
  fo$md5data[[length(fo$md5data) + 1L]] <- .flac_sample_bytes(as.vector(block), (fo$bps + 7) %/% 8)
  frame <- .flac_encode_frame(block, fo$bps, fo$frame_no)
  .flac_write(og, frame)
  fo$frame_no <- fo$frame_no + 1
  fo$total <- fo$total + n
  fs <- length(frame)
  fo$minfs <- if (is.null(fo$minfs)) fs else min(fo$minfs, fs)
  fo$maxfs <- max(fo$maxfs, fs)
  invisible()
}

.flac_wrap <- function(v, fmt) {
  if (fmt == 508) (v + 128) %% 256 - 128 else if (fmt == 516) (v + 32768) %% 65536 - 32768 else
    if (fmt == 524) (v + 8388608) %% 16777216 - 8388608 else v
}

#' Append the samples v (in WFDB frame order) to a FLAC output group:
#' exactly the effect of flac_putsamp(v[k], fmt, og) for each k.
#' Returns 0.
flac_putsamps <- function(v, fmt, og) {
  fo <- og$flac
  s <- c(fo$pend, .flac_wrap(as.numeric(v), fmt))
  fl <- fo$nsig * fo$spf
  nfr <- length(s) %/% fl
  if (nfr > 0) {
    X <- array(s[seq_len(nfr * fl)], c(fo$spf, fo$nsig, nfr))
    X <- matrix(aperm(X, c(2L, 1L, 3L)), fo$nsig)
    fo$cbuf <- cbind(fo$cbuf, X, deparse.level = 0)
    while (ncol(fo$cbuf) >= .FLAC_BLOCKSIZE) .flac_writeblock(og, .FLAC_BLOCKSIZE)
    s <- s[-seq_len(nfr * fl)]
  }
  fo$pend <- s
  0
}

#' Append a sample to a FLAC output group (flac_putsamp).  Returns 0.
flac_putsamp <- function(v, fmt, og) {
  fo <- og$flac
  p <- c(fo$pend, .flac_wrap(v, fmt))
  if (length(p) == fo$nsig * fo$spf) {
    fo$pend <- numeric(0)
    flac_putsamps(p, fmt, og)
  } else {
    fo$pend <- p
  }
  0
}

#' Finish writing a FLAC output group (flac_osclose): encode the remaining
#' samples (an incomplete last frame is discarded), rewrite STREAMINFO
#' (sample count, frame sizes and MD5 signature) if og$fp can seek, and set
#' og$flac to NULL and og$buf to raw(0) (the caller then closes og$fp).
#' Returns 0.
flac_osclose <- function(og) {
  fo <- og$flac
  while (ncol(fo$cbuf) > 0L) .flac_writeblock(og, min(ncol(fo$cbuf), .FLAC_BLOCKSIZE))
  si <- .flac_streaminfo(fo, fo$total, .flac_md5(unlist(fo$md5data, use.names = FALSE)))
  fo$streaminfo <- si
  if (!is.null(og$fp) && wf_seek(og$fp, fo$header_pos + 8, 0) == 0) {
    wf_write(og$fp, si)
    wf_seek(og$fp, 0, 2)
  }
  og$flac <- NULL
  og$buf <- raw(0)
  0
}
