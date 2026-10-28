# flac.R: FLAC-compressed signal files (formats 508, 516 and 524), without
# external libraries: the FLAC support that the C WFDB library obtains from
# libFLAC (the flac_* functions of lib/signal.c).
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of the FLAC support of lib/signal.c (the code that
# connects FLAC to the signal functions) from the WFDB Software Package 10.7.0,
# by Benjamin Moody (2020). The translation follows the logic and behavior of
# the original code, but it is new code, not the original C code. Its FLAC
# decoder is an R translation of the stream decoder of libFLAC 1.4.3
# (src/libFLAC/stream_decoder.c and bitreader.c, and the restore functions of
# fixed.c and lpc.c), made so that damaged files are decoded, resynchronized
# and reported exactly as by the C library, which uses libFLAC. Its FLAC
# encoder is WFDB-x's own implementation of the FLAC format; it has no
# counterpart in the original package. WFDB-x needs no external library at
# run time.
#
# Changes from the original: FLAC streams are decoded by the translation of
# libFLAC's stream decoder and encoded by WFDB-x's own encoder instead of by
# libFLAC; the files written decode to the same samples, but their bytes
# differ from libFLAC's. Each change is marked "WFDB-x:" in the
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
# libFLAC is distributed under the following license, which applies to the
# parts of this file translated from it (the FLAC decoder):
#
# Copyright (C) 2000-2009  Josh Coalson
# Copyright (C) 2011-2023  Xiph.Org Foundation
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#
# - Redistributions of source code must retain the above copyright
# notice, this list of conditions and the following disclaimer.
#
# - Redistributions in binary form must reproduce the above copyright
# notice, this list of conditions and the following disclaimer in the
# documentation and/or other materials provided with the distribution.
#
# - Neither the name of the Xiph.org Foundation nor the names of its
# contributors may be used to endorse or promote products derived from
# this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
# LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
# A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE FOUNDATION OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
# LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# * A complete FLAC decoder (all subframe types, stereo decorrelation,
#   wasted bits, variable block sizes, CRC verification, and MD5 checking
#   when WFDB_FLAC_CHECK_MD5 is set), used to read signals.  It follows
#   libFLAC's stream decoder step by step, as the Python decoder does, so
#   that damaged streams give the C library's results.  Rice codes are
#   decoded with vector operations (pointer doubling over the positions of
#   the one bits), as in the MATLAB/Octave port.
# * A lossless FLAC encoder, used to write signals, whose output is
#   byte-identical to that of the Python implementation of WFDB-x (fixed
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
#
# The decoder follows libFLAC's stream decoder (version 1.4.3) step by step,
# as the Python implementation of WFDB-x does: its states, its search for
# frame sync codes, its error statuses and the point at which it reports
# each one, its recovery after a damaged frame, and its binary search when
# seeking.  The C library's results on damaged files depend on all of
# these.  libFLAC reads its input through a buffer of .FLAC_CAPACITY bytes;
# the buffer is modelled as far as its contents affect the results (the
# end-of-file flag, and the return to the last frame sync code after a
# damaged frame).  Subframes are decoded with vector operations (Rice codes
# by pointer doubling over the positions of the one bits); the buffer
# refills that libFLAC makes while reading them are reproduced from the
# positions of the codes (.fd_feed).

# Decoder states (FLAC__StreamDecoderState)
.FLAC_SEARCH_FOR_METADATA <- 0
.FLAC_READ_METADATA <- 1
.FLAC_SEARCH_FOR_FRAME_SYNC <- 2
.FLAC_READ_FRAME <- 3
.FLAC_END_OF_STREAM <- 4
.FLAC_ABORTED <- 5
.FLAC_SEEK_ERROR <- 6
.FLAC_MEMORY_ALLOCATION_ERROR <- 7

.FLAC_CAPACITY <- 8192   # bytes in the input buffer of libFLAC's bit reader

# Block sizes given by the block size codes 1 to 15 of a frame header
# (codes 6 and 7 are handled separately), sample sizes given by the sample
# size codes 1 to 7 (code 3 is handled separately), and sample rates given
# by the sample rate codes 1 to 11.
.FLAC_BS <- c(192, 576, 1152, 2304, 4608, 0, 0, 256, 512, 1024, 2048, 4096, 8192, 16384, 32768)
.FLAC_BPS <- c(8, 12, 0, 16, 20, 24, 32)
.FLAC_RATE <- c(88200, 176400, 192000, 8000, 16000, 22050, 24000, 32000, 44100, 48000, 96000)

.flac_err <- function(status) {
  stop(structure(class = c("wfdbx_flac", "error", "condition"),
                 list(message = paste("FLAC decoding error:", status), call = NULL,
                      status = status)))
}

# The bit reader could not get the bits it needs; dec$state says why (as
# libFLAC's read callback leaves it).
.flac_noinput <- function() {
  stop(structure(class = c("wfdbx_flac_noinput", "error", "condition"),
                 list(message = "FLAC: no input", call = NULL)))
}

# Evaluate expr; TRUE if the bit reader ran out of input meanwhile.
.fd_noinput <- function(expr) {
  tryCatch({
    expr
    FALSE
  }, wfdbx_flac_noinput = function(e) TRUE)
}

# Bits of bytes (integer 0/1, most significant bit first).
.flac_bits <- function(b) {
  m <- matrix(as.integer(rawToBits(as.raw(b))), 8L)
  as.vector(m[8:1, , drop = FALSE])
}

.flac_wrap32 <- function(x) {
  x <- x %% 4294967296
  x - (x >= 2147483648) * 4294967296
}

# libFLAC's stream decoder, reading the bytes data (raw).  on_error(status)
# is called for each error that libFLAC reports to its error callback;
# on_write(chans) for each block of decoded samples (a list with one vector
# per channel), and returns FALSE to abort decoding.
.flac_decoder <- function(data, seekable, on_error, on_write, md5_checking) {
  dec <- new.env(parent = emptyenv())
  dec$raw <- data
  dec$data <- as.integer(data)
  dec$nbytes <- length(data)
  dec$seekable <- seekable
  dec$on_error <- on_error
  dec$on_write <- on_write
  # Bit reader: the buffer holds bytes bstart to bend - 1 of the file (bend
  # is the file position), and pos is the position (in bits) of the next
  # bit to be read.  fsloc is the location of the last frame sync code
  # seen, while it remains in the buffer (NA: none).
  dec$bstart <- 0
  dec$bend <- 0
  dec$end <- 0
  dec$pos <- 0
  dec$fsloc <- NA
  dec$feof <- FALSE
  dec$state <- .FLAC_SEARCH_FOR_METADATA
  dec$cached <- NA           # a byte read ahead while looking for sync
  dec$warmup <- 0            # the second byte of the frame sync code
  dec$has_stream_info <- FALSE
  dec$min_blocksize <- 0
  dec$max_blocksize <- 0
  dec$min_framesize <- 0
  dec$max_framesize <- 0
  dec$si_rate <- 0
  dec$si_channels <- 0
  dec$si_bps <- 0
  dec$total_samples <- 0
  dec$si_md5 <- raw(16)
  # (the seek table: one row per point, columns sample, offset, nsamples,
  # placeholder)
  dec$seek_table <- NULL
  dec$fixed_block_size <- 0
  dec$next_fixed_block_size <- 0
  dec$samples_decoded <- 0
  dec$last_seen_framesync <- 0
  # the last frame passed to on_write: c(sample number, block size, sample
  # rate, channels, bits per sample), or NULL
  dec$last_frame <- NULL
  dec$channels <- 0          # (of the last frame decoded)
  dec$bps <- 0
  dec$is_seeking <- FALSE
  dec$target_sample <- 0
  dec$unparseable_frame_count <- 0
  dec$first_frame_offset <- 0
  dec$do_md5_checking <- md5_checking
  dec$md5data <- list()
  dec$f_blocksize <- 0
  dec$f_rate <- 0
  dec$f_channels <- 0
  dec$f_assign <- 0
  dec$f_bps <- 0
  dec$f_sample <- 0
  dec
}

# -- bit reader

# Read more input into the buffer (bitreader_read_from_client_,
# read_callback_ and the C library's iflac_read), the reader being at bit
# dec$pos.
.fd_fill <- function(dec) {
  consumed <- (dec$pos - dec$bstart * 8) %/% 64        # whole 8-byte words
  if (consumed > 0) {
    dec$fsloc <- NA
    dec$bstart <- dec$bstart + consumed * 8
  }
  request <- .FLAC_CAPACITY - (dec$bend - dec$bstart)
  if (request <= 0) .flac_noinput()
  if (dec$feof) {
    dec$state <- .FLAC_END_OF_STREAM
    .flac_noinput()
  }
  if (dec$is_seeking && dec$unparseable_frame_count > 20) {
    dec$state <- .FLAC_ABORTED
    .flac_noinput()
  }
  got <- min(request, dec$nbytes - dec$bend)
  if (got < request) dec$feof <- TRUE
  if (got <= 0) {
    dec$state <- .FLAC_END_OF_STREAM
    .flac_noinput()
  }
  dec$bend <- dec$bend + got
  dec$end <- dec$bend * 8
}

# The refills of a sequence of reads: read j needs the bits before bit
# need[j] (non-decreasing), and a refill for it is made with the reader at
# fpos[j] (NA: at the end of the buffer, as when counting zero bits).
.fd_feed <- function(dec, need, fpos) {
  L <- length(need)
  if (!L || need[L] <= dec$end) return(invisible())
  j <- findInterval(dec$end, need) + 1L
  while (j <= L) {
    while (need[j] > dec$end) {
      dec$pos <- if (is.na(fpos[j])) dec$end else fpos[j]
      .fd_fill(dec)
    }
    j <- findInterval(dec$end, need) + 1L
  }
  invisible()
}

# The value of the n bits at bit p of the bytes d (unsigned; exact up to
# 2^53).
.fd_val <- function(d, p, n) {
  if (n > 32) return(.fd_val(d, p, n - 32) * 4294967296 + .fd_val(d, p + n - 32, 32))
  b0 <- p %/% 8
  e <- p + n
  b1 <- (e + 7) %/% 8
  v <- sum(d[(b0 + 1):b1] * 256^((b1 - b0 - 1):0))
  (v %/% 2^(b1 * 8 - e)) %% 2^n
}

.fd_read <- function(dec, n) {
  p <- dec$pos
  e <- p + n
  while (e > dec$end) .fd_fill(dec)
  dec$pos <- e
  .fd_val(dec$data, p, n)
}

# n bits as one read (n a multiple of 8): their bytes.
.fd_read_bytes <- function(dec, n) {
  p <- dec$pos
  e <- p + n
  while (e > dec$end) .fd_fill(dec)
  dec$pos <- e
  vapply(seq_len(n %/% 8) - 1, function(k) .fd_val(dec$data, p + 8 * k, 8), 0)
}

.fd_read_signed <- function(dec, n) {
  v <- .fd_read(dec, n)
  if (v >= 2^(n - 1)) v - 2^n else v
}

# The bits (integer 0/1) from bit p on: nbits of them, or fewer at the end
# of the data.
.fd_bitwin <- function(dec, p, nbits) {
  b0 <- p %/% 8
  b1 <- min(dec$nbytes, (p + nbits + 7) %/% 8)
  if (b1 <= b0) return(integer(0))
  B <- .flac_bits(dec$raw[(b0 + 1):b1])
  off <- p - b0 * 8
  n <- min(nbits, length(B) - off)
  if (off || n < length(B)) B[off + seq_len(n)] else B
}

# cnt signed values of nb bits each (read_signed, cnt times).
.fd_read_signed_vec <- function(dec, cnt, nb) {
  if (cnt <= 0) return(numeric(0))
  p <- dec$pos
  starts <- p + (seq_len(cnt) - 1) * nb
  .fd_feed(dec, starts + nb, starts)
  M <- matrix(.fd_bitwin(dec, p, cnt * nb), nb)
  v <- colSums(M * 2^((nb - 1):0))
  dec$pos <- p + cnt * nb
  v - (v >= 2^(nb - 1)) * 2^nb
}

# Count zero bits up to (and consume) the next one bit.
.fd_unary <- function(dec) {
  d <- dec$data
  p <- dec$pos
  n <- 0
  repeat {
    eb <- dec$end %/% 8
    bi <- p %/% 8
    if (bi < eb) {
      byte <- (d[bi + 1] * 2^(p %% 8)) %% 256
      if (byte) {
        z <- 7 - floor(log2(byte))
        dec$pos <- p + z + 1
        return(n + z)
      }
      n <- n + 8 - p %% 8
      bi <- bi + 1
      nz <- eb
      if (bi < eb) {
        k <- which(d[(bi + 1):eb] != 0L)
        if (length(k)) nz <- bi + k[1L] - 1
      }
      n <- n + (nz - bi) * 8
      p <- nz * 8
      if (nz < eb) next
    }
    dec$pos <- p
    .fd_fill(dec)
  }
}

.fd_skip_bytes <- function(dec, n) {
  target <- dec$pos + 8 * n
  repeat {
    dec$pos <- min(target, dec$end)
    if (dec$pos >= target) return(invisible())
    .fd_fill(dec)
  }
}

# Empty the buffer (FLAC__bitreader_clear).
.fd_clear <- function(dec) {
  dec$bstart <- dec$bend
  dec$pos <- dec$end <- dec$bend * 8
  dec$fsloc <- NA
}

# Move the file position (the C library's iflac_seek).
.fd_seek_file <- function(dec, pos) {
  if (!dec$seekable) return(FALSE)
  dec$bend <- pos
  dec$end <- pos * 8
  dec$feof <- FALSE
  TRUE
}

# FLAC__stream_decoder_get_decode_position: the position in the file of
# the next byte to be decoded (NA if it is not known).
.fd_decode_position <- function(dec) {
  if (!dec$seekable || dec$pos %% 8) NA else dec$pos %/% 8
}

# send_error_to_client_
.fd_error <- function(dec, status) {
  if (!dec$is_seeking) {
    dec$on_error(status)
  } else if (status == "unparseable") {
    dec$unparseable_frame_count <- dec$unparseable_frame_count + 1
  }
}

# -- stream

# FLAC__stream_decoder_process_single
.fd_process_single <- function(dec) {
  repeat {
    st <- dec$state
    if (st == .FLAC_SEARCH_FOR_METADATA) {
      if (!.fd_find_metadata(dec)) return(FALSE)
    } else if (st == .FLAC_READ_METADATA) {
      return(.fd_read_metadata(dec))
    } else if (st == .FLAC_SEARCH_FOR_FRAME_SYNC) {
      if (!.fd_frame_sync(dec)) return(TRUE)
    } else if (st == .FLAC_READ_FRAME) {
      r <- .fd_read_frame(dec)
      if (!r[1L]) return(FALSE)
      if (r[2L]) return(TRUE)
    } else if (st == .FLAC_END_OF_STREAM || st == .FLAC_ABORTED) {
      return(TRUE)
    } else {
      return(FALSE)
    }
  }
}

.fd_process_until_end_of_metadata <- function(dec) {
  repeat {
    st <- dec$state
    if (st == .FLAC_SEARCH_FOR_METADATA) {
      if (!.fd_find_metadata(dec)) return(FALSE)
    } else if (st == .FLAC_READ_METADATA) {
      if (!.fd_read_metadata(dec)) return(FALSE)
    } else if (st %in% c(.FLAC_SEARCH_FOR_FRAME_SYNC, .FLAC_READ_FRAME,
                         .FLAC_END_OF_STREAM, .FLAC_ABORTED)) {
      return(TRUE)
    } else {
      return(FALSE)
    }
  }
}

.FLAC_MAGIC <- c(102, 76, 97, 67)       # "fLaC"
.FLAC_ID3 <- c(73, 68, 51)              # "ID3"

# Look for the stream marker "fLaC", skipping an ID3v2 tag.
.fd_find_metadata <- function(dec) {
  i <- 0
  id3 <- 0
  first <- TRUE
  found <- NA
  noinput <- .fd_noinput({
    while (i < 4) {
      if (!is.na(dec$cached)) {
        x <- dec$cached
        dec$cached <- NA
      } else {
        x <- .fd_read(dec, 8)
      }
      if (x == .FLAC_MAGIC[i + 1]) {
        first <- TRUE
        i <- i + 1
        id3 <- 0
        next
      }
      if (id3 >= 3) {
        found <- FALSE
        break
      }
      if (x == .FLAC_ID3[id3 + 1]) {
        id3 <- id3 + 1
        i <- 0
        if (id3 == 3) {
          .fd_read(dec, 24)                 # version and flags
          skip <- 0
          for (k in 1:4) skip <- skip * 128 + .fd_read(dec, 8) %% 128
          .fd_skip_bytes(dec, skip)
        }
        next
      }
      id3 <- 0
      if (x == 255) {
        x <- .fd_read(dec, 8)
        if (x == 255) {
          dec$cached <- x
        } else if (x %/% 2 == 124) {
          dec$warmup <- x
          dec$state <- .FLAC_READ_FRAME
          found <- TRUE
          break
        }
      }
      i <- 0
      if (first) {
        .fd_error(dec, "sync")
        first <- FALSE
      }
    }
  })
  if (noinput) return(FALSE)
  if (!is.na(found)) return(found)
  dec$state <- .FLAC_READ_METADATA
  TRUE
}

# Read one metadata block.  Only STREAMINFO and SEEKTABLE are examined;
# libFLAC skips the others (as the C library does not ask for them).
.fd_read_metadata <- function(dec) {
  ok <- TRUE
  is_last <- 0
  noinput <- .fd_noinput({
    is_last <- .fd_read(dec, 1)
    typ <- .fd_read(dec, 7)
    len <- .fd_read(dec, 24)
    if (typ == 0) {                   # STREAMINFO
      dec$min_blocksize <- .fd_read(dec, 16)
      dec$max_blocksize <- .fd_read(dec, 16)
      dec$min_framesize <- .fd_read(dec, 24)
      dec$max_framesize <- .fd_read(dec, 24)
      dec$si_rate <- .fd_read(dec, 20)
      dec$si_channels <- .fd_read(dec, 3) + 1
      dec$si_bps <- .fd_read(dec, 5) + 1
      dec$total_samples <- .fd_read(dec, 36)
      dec$si_md5 <- as.raw(.fd_read_bytes(dec, 128))
      if (len < 34) {
        ok <- FALSE
      } else {
        .fd_skip_bytes(dec, len - 34)
        dec$has_stream_info <- TRUE
        if (!any(dec$si_md5 != as.raw(0L))) dec$do_md5_checking <- FALSE
      }
    } else if (typ == 3) {            # SEEKTABLE
      dec$seek_table <- NULL
      if (len > 0) {
        if (len %% 18) {
          ok <- FALSE
        } else {
          np <- len %/% 18
          tab <- matrix(0, np, 4L)
          for (k in seq_len(np)) {
            b <- .fd_read_bytes(dec, 64)
            tab[k, 1L] <- sum(b * 256^(7:0))
            tab[k, 4L] <- all(b == 255)              # (a placeholder)
            tab[k, 2L] <- sum(.fd_read_bytes(dec, 64) * 256^(7:0))
            tab[k, 3L] <- .fd_read(dec, 16)
          }
          dec$seek_table <- tab
        }
      }
    } else {
      if (typ == 2) {                 # APPLICATION: an identifier first
        .fd_read(dec, 32)
        if (len < 4) {
          dec$state <- .FLAC_MEMORY_ALLOCATION_ERROR
          ok <- FALSE
        }
        len <- len - 4
      }
      if (ok) .fd_skip_bytes(dec, len)
    }
  })
  if (noinput || !ok) return(FALSE)
  if (is_last) {
    p <- .fd_decode_position(dec)
    dec$first_frame_offset <- if (!is.na(p)) p else 0
    dec$state <- .FLAC_SEARCH_FOR_FRAME_SYNC
  }
  TRUE
}

# Look for the next frame sync code.
.fd_frame_sync <- function(dec) {
  data <- dec$data
  first <- TRUE
  found <- FALSE
  .fd_noinput({
    if (dec$pos %% 8) .fd_read(dec, 8 - dec$pos %% 8)
    repeat {
      if (!is.na(dec$cached)) {
        x <- dec$cached
        dec$cached <- NA
      } else {
        # (skip quickly to the next 0xFF byte in the buffer)
        p <- dec$pos %/% 8
        if (p >= dec$bend) {
          .fd_fill(dec)
          next
        }
        k <- which(data[(p + 1):dec$bend] == 255L)
        q <- if (length(k)) p + k[1L] - 1 else -1
        if (q != p) {
          if (first) {
            .fd_error(dec, "sync")
            first <- FALSE
          }
          if (q < 0) {
            dec$pos <- dec$end
            .fd_fill(dec)
            next
          }
          dec$pos <- q * 8
        }
        x <- .fd_read(dec, 8)
      }
      if (x == 255) {
        x <- .fd_read(dec, 8)
        if (x == 255) {
          dec$cached <- x
        } else if (x %/% 2 == 124) {
          dec$warmup <- x
          dec$state <- .FLAC_READ_FRAME
          dec$fsloc <- dec$pos %/% 8 - dec$bstart
          p <- .fd_decode_position(dec)
          dec$last_seen_framesync <- if (!is.na(p)) p else 0
          found <- TRUE
          break
        }
      }
      if (first) {
        .fd_error(dec, "sync")
        first <- FALSE
      }
    }
  })
  found
}

# -- frames

# Read one frame; returns c(ok, got_a_frame).
.fd_read_frame <- function(dec) {
  start <- dec$pos %/% 8 - 2          # (the frame sync code)
  hdr <- NA
  if (.fd_noinput(hdr <- .fd_read_frame_header(dec)) || !hdr) return(c(FALSE, FALSE))
  if (dec$state == .FLAC_SEARCH_FOR_FRAME_SYNC) return(c(TRUE, FALSE))
  nch <- dec$f_channels
  bs <- dec$f_blocksize
  assign <- dec$f_assign
  chans <- list()
  for (ch in seq_len(nch) - 1) {
    bps <- dec$f_bps
    if ((assign == 8 && ch == 1) || (assign == 9 && ch == 0) || (assign == 10 && ch == 1))
      bps <- bps + 1                  # the side channel
    out <- NULL
    if (.fd_noinput(out <- .fd_read_subframe(dec, bps, bs))) {
      if (dec$state == .FLAC_END_OF_STREAM) break
      return(c(FALSE, FALSE))
    }
    if (dec$state != .FLAC_READ_FRAME) break
    chans[[length(chans) + 1L]] <- out
  }
  if (dec$state != .FLAC_END_OF_STREAM) {
    # zero padding to the end of the byte
    if (.fd_noinput({
      if (dec$pos %% 8 && .fd_read(dec, 8 - dec$pos %% 8)) {
        .fd_error(dec, "sync")
        dec$state <- .FLAC_SEARCH_FOR_FRAME_SYNC
      }
    })) return(c(FALSE, FALSE))
  }
  if (dec$state == .FLAC_READ_FRAME) {
    fend <- dec$pos %/% 8
    crc <- if (fend > start) .flac_crc16(dec$data[(start + 1):fend]) else 0L
    x <- NA
    if (.fd_noinput(x <- .fd_read(dec, 16)) && dec$state != .FLAC_END_OF_STREAM)
      return(c(FALSE, FALSE))
    if (dec$state == .FLAC_READ_FRAME) {
      if (identical(as.numeric(crc), x)) {
        chans <- .fd_undo_channel_coding(dec, chans, assign)
        if (is.null(chans)) {
          .fd_error(dec, "crc")
          dec$state <- .FLAC_SEARCH_FOR_FRAME_SYNC
        }
      } else {
        .fd_error(dec, "crc")
        dec$state <- .FLAC_SEARCH_FOR_FRAME_SYNC
      }
    }
  }
  sn <- dec$f_sample
  if (!is.null(dec$last_frame) && dec$state == .FLAC_READ_FRAME && !dec$is_seeking) {
    if (!.fd_pad_missing_samples(dec, sn)) return(c(FALSE, FALSE))
  }
  if (dec$state == .FLAC_SEARCH_FOR_FRAME_SYNC || dec$state == .FLAC_END_OF_STREAM) {
    # a damaged frame: go back to just after its sync code
    if (!is.na(dec$fsloc)) {
      dec$pos <- (dec$bstart + dec$fsloc + 1) * 8
    } else {
      dec$pos <- dec$bstart * 8
      if (dec$last_seen_framesync) {
        if (!.fd_seek_file(dec, dec$last_seen_framesync)) {
          dec$state <- .FLAC_SEEK_ERROR
          return(c(FALSE, FALSE))
        }
        .fd_clear(dec)
      }
    }
    dec$state <- .FLAC_SEARCH_FOR_FRAME_SYNC
    return(c(TRUE, FALSE))
  }
  if (dec$next_fixed_block_size) dec$fixed_block_size <- dec$next_fixed_block_size
  dec$channels <- nch
  dec$bps <- dec$f_bps
  dec$samples_decoded <- sn + bs
  if (!.fd_write(dec, sn, bs, dec$f_rate, nch, dec$f_bps, chans)) {
    dec$state <- .FLAC_ABORTED
    return(c(FALSE, FALSE))
  }
  dec$state <- .FLAC_SEARCH_FOR_FRAME_SYNC
  c(TRUE, TRUE)
}

.fd_bad_header <- function(dec, back = NA) {
  if (!is.na(back)) dec$cached <- back
  .fd_error(dec, "header")
  dec$state <- .FLAC_SEARCH_FOR_FRAME_SYNC
  TRUE
}

# A frame or sample number: list(v, raw) (v NA if its coding is invalid).
.fd_read_utf8 <- function(dec, wide) {
  x <- .fd_read(dec, 8)
  raw <- x
  if (x < 128) return(list(v = x, raw = raw))
  # (as in libFLAC, bit 0x40 of the first byte is not examined)
  if (!bitwAnd(x, 32)) {
    v <- x %% 32
    n <- 1
  } else if (!bitwAnd(x, 16)) {
    v <- x %% 16
    n <- 2
  } else if (!bitwAnd(x, 8)) {
    v <- x %% 8
    n <- 3
  } else if (!bitwAnd(x, 4)) {
    v <- x %% 4
    n <- 4
  } else if (!bitwAnd(x, 2)) {
    v <- x %% 2
    n <- 5
  } else if (wide && !bitwAnd(x, 1)) {
    v <- 0
    n <- 6
  } else {
    return(list(v = NA, raw = raw))
  }
  for (k in seq_len(n)) {
    x <- .fd_read(dec, 8)
    raw <- c(raw, x)
    if (x %/% 64 != 2) return(list(v = NA, raw = raw))
    v <- v * 64 + x %% 64
  }
  list(v = v, raw = raw)
}

.fd_read_frame_header <- function(dec) {
  raw <- c(255, dec$warmup)
  unparseable <- dec$warmup %% 4 >= 2
  for (k in 1:2) {
    x <- .fd_read(dec, 8)
    # (a sync code cannot occur in a frame header)
    if (x == 255) return(.fd_bad_header(dec, x))
    raw <- c(raw, x)
  }
  bsc <- raw[3L] %/% 16
  blocksize_hint <- 0
  if (bsc == 0) {
    unparseable <- TRUE
  } else if (bsc == 6 || bsc == 7) {
    blocksize_hint <- bsc
  } else {
    dec$f_blocksize <- .FLAC_BS[bsc]
  }
  src <- raw[3L] %% 16
  rate_hint <- 0
  if (src == 0) {
    if (dec$has_stream_info) dec$f_rate <- dec$si_rate else unparseable <- TRUE
  } else if (src <= 11) {
    dec$f_rate <- .FLAC_RATE[src]
  } else if (src <= 14) {
    rate_hint <- src
  } else {
    return(.fd_bad_header(dec))
  }
  x <- raw[4L] %/% 16
  if (x >= 8) {
    dec$f_channels <- 2
    if (x %% 8 <= 2) dec$f_assign <- x else unparseable <- TRUE
  } else {
    dec$f_channels <- x + 1
    dec$f_assign <- 0
  }
  ssc <- (raw[4L] %% 16) %/% 2
  if (ssc == 0) {
    if (dec$has_stream_info) dec$f_bps <- dec$si_bps else unparseable <- TRUE
  } else if (ssc == 3) {
    unparseable <- TRUE
  } else {
    dec$f_bps <- .FLAC_BPS[ssc]
  }
  if (raw[4L] %% 2) unparseable <- TRUE
  is_sample <- raw[2L] %% 2 == 1 || (dec$has_stream_info && dec$min_blocksize != dec$max_blocksize)
  u <- .fd_read_utf8(dec, is_sample)      # (a sample number, or a frame number)
  raw <- c(raw, u$raw)
  if (is.na(u$v)) return(.fd_bad_header(dec, raw[length(raw)]))
  number <- u$v
  if (blocksize_hint) {
    x <- .fd_read(dec, 8)
    raw <- c(raw, x)
    if (blocksize_hint == 7) {
      y <- .fd_read(dec, 8)
      raw <- c(raw, y)
      x <- x * 256 + y
    }
    dec$f_blocksize <- x + 1
    if (dec$f_blocksize > 65535) return(.fd_bad_header(dec, raw[length(raw)]))
  }
  if (rate_hint) {
    x <- .fd_read(dec, 8)
    raw <- c(raw, x)
    if (rate_hint != 12) {
      y <- .fd_read(dec, 8)
      raw <- c(raw, y)
      x <- x * 256 + y
    }
    dec$f_rate <- if (rate_hint == 12) x * 1000 else if (rate_hint == 13) x else x * 10
  }
  crc <- .fd_read(dec, 8)
  if (.flac_crc8(raw) != crc) return(.fd_bad_header(dec))
  dec$next_fixed_block_size <- 0
  if (!is_sample) {
    if (dec$fixed_block_size) {
      number <- number * dec$fixed_block_size
    } else if (dec$has_stream_info) {
      if (dec$min_blocksize == dec$max_blocksize) {
        number <- number * dec$min_blocksize
        dec$next_fixed_block_size <- dec$max_blocksize
      } else {
        unparseable <- TRUE
      }
    } else if (number == 0) {
      dec$next_fixed_block_size <- dec$f_blocksize
    } else {
      number <- number * dec$f_blocksize
    }
  }
  dec$f_sample <- number
  if (unparseable) {
    .fd_error(dec, "unparseable")
    dec$state <- .FLAC_SEARCH_FOR_FRAME_SYNC
  }
  TRUE
}

.fd_lost_sync <- function(dec) {
  .fd_error(dec, "sync")
  dec$state <- .FLAC_SEARCH_FOR_FRAME_SYNC
  NULL
}

.fd_unparseable <- function(dec) {
  .fd_error(dec, "unparseable")
  dec$state <- .FLAC_SEARCH_FOR_FRAME_SYNC
  NULL
}

# Read one subframe; returns its samples (NULL after an error, which leaves
# the state changed).
.fd_read_subframe <- function(dec, bps, bs) {
  x <- .fd_read(dec, 8)
  wasted <- 0
  if (x %% 2) {
    wasted <- .fd_unary(dec) + 1
    if (wasted >= bps) return(.fd_lost_sync(dec))
    bps <- bps - wasted
  }
  x <- x - x %% 2
  if (x >= 128) return(.fd_lost_sync(dec))
  if (x == 0) {                               # CONSTANT
    out <- rep(.fd_read_signed(dec, bps), bs)
  } else if (x == 2) {                        # VERBATIM
    out <- .fd_read_signed_vec(dec, bs, bps)
  } else if (x < 16) {
    return(.fd_unparseable(dec))
  } else if (x <= 24) {                       # FIXED
    order <- (x %/% 2) %% 8
    if (bs <= order) return(.fd_lost_sync(dec))
    out <- .fd_read_fixed(dec, bps, bs, order)
  } else if (x < 64) {
    return(.fd_unparseable(dec))
  } else {                                    # LPC
    order <- (x %/% 2) %% 32 + 1
    if (bs <= order) return(.fd_lost_sync(dec))
    out <- .fd_read_lpc(dec, bps, bs, order)
  }
  if (is.null(out)) return(NULL)
  if (wasted) out <- out * 2^wasted
  out
}

# The entropy coding method and partition order, then the residual (NULL
# after an error).
.fd_read_coding <- function(dec, bs, order) {
  method <- .fd_read(dec, 2)
  if (method > 1) return(.fd_unparseable(dec))
  porder <- .fd_read(dec, 4)
  if (bs %/% 2^porder < order || bs %% 2^porder) return(.fd_lost_sync(dec))
  .fd_read_residual(dec, bs, order, porder, method)
}

.fd_read_fixed <- function(dec, bps, bs, order) {
  w <- .fd_read_signed_vec(dec, order, bps)
  r <- .fd_read_coding(dec, bs, order)
  if (is.null(r)) return(NULL)
  if (order == 0) return(r)
  if (!length(r)) return(w)
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
  c(w, x)
}

.fd_read_lpc <- function(dec, bps, bs, order) {
  w <- .fd_read_signed_vec(dec, order, bps)
  prec <- .fd_read(dec, 4)           # coefficient precision - 1
  if (prec == 15) return(.fd_lost_sync(dec))
  prec <- prec + 1
  shift <- .fd_read_signed(dec, 5)
  if (shift < 0) return(.fd_lost_sync(dec))
  coefs <- .fd_read_signed_vec(dec, order, prec)
  r <- .fd_read_coding(dec, bs, order)
  if (is.null(r)) return(NULL)
  .flac_lpc_restore(w, r, rev(coefs), shift)
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

# n Rice codes with parameter k (unary quotient, then k bits) from the
# current position: the folded values, or NULL (lost sync) if a quotient is
# too large for 32 bits.
.fd_rice <- function(dec, n, k) {
  p0 <- dec$pos
  fileend <- dec$nbytes * 8
  win <- n * (k + 4) + 256
  repeat {
    seg <- .fd_bitwin(dec, p0, win)
    len <- length(seg)
    full <- p0 + len >= fileend
    O <- which(seg == 1L)                 # positions of the ones
    M <- length(O)
    T <- NULL                             # the one bit of each code
    if (k == 0) {
      if (M >= n || full) T <- O[seq_len(min(M, n))]
    } else if (M > 0L) {
      cnt <- c(0L, cumsum(seg))           # cnt[q]: ones before position q
      q <- O + 1L + k                     # start of the next code
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
      } else if (full) {
        # (the end of the data: the codes before it)
        m <- sum(idx <= M)
        T <- O[idx[seq_len(m)]]
      }
    } else if (full) {
      T <- integer(0)
    }
    if (!is.null(T)) break
    win <- 4 * win
  }
  m <- length(T)
  st <- if (m) c(1L, T[-m] + 1L + k) else integer(0)
  qv <- T - st                            # the quotients
  # The refills while reading: each code's quotient (counting zero bits),
  # then its k bits.
  bad <- if (k > 0 && m) which(qv > 4294967295 %/% 2^k) else integer(0)
  mm <- if (length(bad)) bad[1L] else m
  if (k > 0) {
    need <- as.vector(rbind(p0 + T[seq_len(mm)], p0 + T[seq_len(mm)] + k))
    fpos <- as.vector(rbind(NA, p0 + T[seq_len(mm)]))
    if (length(bad)) {
      need <- need[-length(need)]
      fpos <- fpos[-length(fpos)]
    }
  } else {
    need <- p0 + T
    fpos <- rep(NA, m)
  }
  if (!length(bad) && m < n) {          # (a code cut short by the end of the data)
    need <- c(need, max(need, fileend + 1))
    fpos <- c(fpos, NA)
  }
  .fd_feed(dec, need, fpos)
  if (length(bad)) {
    # (libFLAC rejects a quotient too large for 32 bits; its position is
    # then that of the start of the partition)
    dec$pos <- p0
    return(.fd_lost_sync(dec))
  }
  dec$pos <- p0 + T[n] + k
  if (k == 0) return(qv)
  low <- numeric(n)
  for (j in seq_len(k)) low <- 2 * low + seg[T + j]
  qv * 2^k + low
}

.fd_read_residual <- function(dec, bs, order, porder, method) {
  # Rice parameters have 4 bits (method 0) or 5 bits (method 1); the
  # all-ones parameter is an escape code for unencoded residuals.
  pbits <- if (method == 0) 4 else 5
  esc <- if (method == 0) 15 else 31
  psize <- bs %/% 2^porder
  np <- 2^porder
  out <- vector("list", np)
  for (part in seq_len(np)) {
    n <- if (part == 1L) psize - order else psize
    k <- .fd_read(dec, pbits)
    if (k == esc) {
      nb <- .fd_read(dec, 5)         # bits per unencoded residual
      out[[part]] <- if (nb == 0) numeric(n) else .fd_read_signed_vec(dec, n, nb)
    } else if (n > 0) {
      u <- .fd_rice(dec, n, k)
      if (is.null(u)) return(NULL)
      v <- u %/% 2
      odd <- u %% 2 == 1
      v[odd] <- -v[odd] - 1
      out[[part]] <- v
    }
  }
  unlist(out, use.names = FALSE) %||% numeric(0)
}

# Restore left and right channels from side channels, and check that the
# samples fit the sample size (NULL if they do not).
.fd_undo_channel_coding <- function(dec, chans, assign) {
  if (assign == 8) {                  # left/side
    chans <- list(chans[[1L]], chans[[1L]] - chans[[2L]])
  } else if (assign == 9) {           # side/right
    chans <- list(chans[[1L]] + chans[[2L]], chans[[2L]])
  } else if (assign == 10) {          # mid/side
    sd <- chans[[2L]]
    m <- 2 * chans[[1L]] + sd %% 2
    chans <- list(floor((m + sd) / 2), floor((m - sd) / 2))
  }
  lo <- -2^(dec$f_bps - 1)
  hi <- -lo - 1
  out <- function(c) any(!is.finite(c) | c < lo | c > hi)
  for (i in seq_along(chans)) {
    if (out(chans[[i]])) {
      chans[[i]] <- .flac_wrap32(chans[[i]])
      if (out(chans[[i]])) return(NULL)
    }
  }
  chans
}

# Fill a gap between the previous frame and this one with silence, as
# libFLAC does for missing frames (FALSE if decoding is aborted).
.fd_pad_missing_samples <- function(dec, sn) {
  lf <- dec$last_frame
  lsn <- lf[1L]
  lbs <- lf[2L]
  lrate <- lf[3L]
  lch <- lf[4L]
  lbps <- lf[5L]
  if (lsn + lbs >= sn) return(TRUE)
  need <- (sn - (lsn + lbs)) %% 4294967296
  if (lrate != dec$f_rate || lch != dec$f_channels || lbps != dec$f_bps || lbs < 16)
    return(TRUE)
  need <- min(need, (5 * lrate) %% 4294967296, 50 * lbs)
  while (need) {
    lsn <- lsn + lbs
    if (need < lbs) lbs <- need
    need <- need - lbs
    dec$samples_decoded <- lsn + lbs
    if (!.fd_write(dec, lsn, lbs, lrate, lch, lbps, rep(list(numeric(lbs)), lch))) {
      dec$state <- .FLAC_ABORTED
      return(FALSE)
    }
  }
  TRUE
}

# write_audio_frame_to_client_
.fd_write <- function(dec, sn, bs, rate, nch, bps, chans) {
  dec$last_frame <- c(sn, bs, rate, nch, bps)
  if (dec$is_seeking) {
    target <- dec$target_sample
    if (sn <= target && target < sn + bs) {    # the target frame
      delta <- target - sn
      dec$is_seeking <- FALSE
      if (delta) {
        chans <- lapply(chans, function(c) c[-seq_len(delta)])
        dec$last_frame <- c(sn + delta, bs - delta, rate, nch, bps)
      }
      return(dec$on_write(chans))
    }
    return(TRUE)
  }
  if (!dec$has_stream_info) dec$do_md5_checking <- FALSE
  if (dec$do_md5_checking) {
    dec$md5data[[length(dec$md5data) + 1L]] <-
      .flac_sample_bytes(as.vector(do.call(rbind, chans)), (bps + 7) %/% 8)
  }
  dec$on_write(chans)
}

# -- seeking

# FLAC__stream_decoder_flush
.fd_flush <- function(dec) {
  dec$samples_decoded <- 0
  dec$do_md5_checking <- FALSE
  dec$last_seen_framesync <- 0
  dec$last_frame <- NULL
  .fd_clear(dec)
  dec$state <- .FLAC_SEARCH_FOR_FRAME_SYNC
}

# FLAC__stream_decoder_seek_absolute
.fd_seek_absolute <- function(dec, sample) {
  if (!(dec$state %in% c(.FLAC_SEARCH_FOR_METADATA, .FLAC_READ_METADATA,
                         .FLAC_SEARCH_FOR_FRAME_SYNC, .FLAC_READ_FRAME,
                         .FLAC_END_OF_STREAM))) return(FALSE)
  total <- if (dec$has_stream_info) dec$total_samples else 0
  if (total > 0 && sample >= total) return(FALSE)
  dec$is_seeking <- TRUE
  dec$do_md5_checking <- FALSE
  if (!dec$seekable) {                # (the length is not known)
    dec$is_seeking <- FALSE
    return(FALSE)
  }
  dec$feof <- FALSE                   # (finding the length seeks)
  if (dec$state %in% c(.FLAC_SEARCH_FOR_METADATA, .FLAC_READ_METADATA)) {
    if (!.fd_process_until_end_of_metadata(dec)) {
      dec$is_seeking <- FALSE
      return(FALSE)
    }
    total <- if (dec$has_stream_info) dec$total_samples else 0
    if (total > 0 && sample >= total) {
      dec$is_seeking <- FALSE
      return(FALSE)
    }
  }
  ok <- .fd_seek_to_absolute_sample(dec, dec$nbytes, sample)
  dec$is_seeking <- FALSE
  ok
}

# seek_to_absolute_sample_: a binary search for the frame that holds the
# target sample.
.fd_seek_to_absolute_sample <- function(dec, stream_length, target) {
  u32 <- 4294967296
  total <- if (dec$has_stream_info) dec$total_samples else 0
  channels <- if (dec$channels) dec$channels else dec$si_channels
  bps <- if (dec$bps) dec$bps else dec$si_bps
  if (dec$max_framesize > 0) {
    approx <- (dec$max_framesize + dec$min_framesize) %/% 2 + 1
  } else if (dec$min_blocksize == dec$max_blocksize && dec$min_blocksize > 0) {
    approx <- ((dec$min_blocksize * channels * bps) %% u32) %/% 8 + 64
  } else {
    approx <- ((4096 * channels * bps) %% u32) %/% 8 + 64
  }
  approx <- approx %% u32
  lower <- dec$first_frame_offset
  lower_sample <- 0
  upper <- stream_length
  upper_sample <- if (total > 0) total else target
  if (dec$state == .FLAC_SEARCH_FOR_FRAME_SYNC && dec$samples_decoded) {
    p <- .fd_decode_position(dec)
    if (target < dec$samples_decoded) {
      if (!is.na(p)) {
        upper <- p
        upper_sample <- dec$samples_decoded
      }
    } else if (!is.na(p)) {
      lower <- p
      lower_sample <- dec$samples_decoded
    }
  }
  tab <- dec$seek_table
  if (!is.null(tab) && nrow(tab)) {
    new_lower <- lower
    new_upper <- upper
    new_lower_sample <- lower_sample
    new_upper_sample <- upper_sample
    usable <- tab[, 4L] == 0 & tab[, 3L] > 0 & (total <= 0 | tab[, 1L] < total)
    below <- which(usable & tab[, 1L] <= target)
    if (length(below)) {
      b <- below[length(below)]
      new_lower <- dec$first_frame_offset + tab[b, 2L]
      new_lower_sample <- tab[b, 1L]
    }
    above <- which(usable & tab[, 1L] > target)
    if (length(above)) {
      a <- above[1L]
      new_upper <- dec$first_frame_offset + tab[a, 2L]
      new_upper_sample <- tab[a, 1L]
    }
    if (new_upper >= new_lower) {
      lower <- new_lower
      upper <- new_upper
      lower_sample <- new_lower_sample
      upper_sample <- new_upper_sample
    }
  }
  if (upper_sample == lower_sample) upper_sample <- upper_sample + 1
  dec$target_sample <- target
  first_seek <- TRUE
  from_lower <- FALSE
  repeat {
    if (dec$state %in% c(.FLAC_MEMORY_ALLOCATION_ERROR, .FLAC_ABORTED)) return(FALSE)
    if (lower_sample >= upper_sample || lower > upper || upper >= 2^63 - 1) {
      dec$state <- .FLAC_SEEK_ERROR
      return(FALSE)
    }
    if (from_lower) {
      pos <- lower
    } else {
      pos <- lower + trunc(((target - lower_sample) %% 2^64) /
                             ((upper_sample - lower_sample) %% 2^64) * (upper - lower)) - approx
    }
    if (pos >= upper) pos <- upper - 1
    if (pos < lower) pos <- lower
    if (!.fd_seek_file(dec, pos)) {
      dec$state <- .FLAC_SEEK_ERROR
      return(FALSE)
    }
    .fd_flush(dec)
    dec$unparseable_frame_count <- 0
    if (!.fd_process_single(dec) || dec$state == .FLAC_ABORTED || dec$samples_decoded == 0) {
      # no frame could be decoded
      if (dec$state != .FLAC_ABORTED && dec$feof && !from_lower) {
        from_lower <- TRUE
        next
      }
      dec$state <- .FLAC_SEEK_ERROR
      return(FALSE)
    }
    from_lower <- FALSE
    if (!dec$is_seeking) break
    this_sample <- dec$last_frame[1L]
    this_bs <- dec$last_frame[2L]
    if (this_sample + this_bs >= upper_sample && !first_seek) {
      if (pos == lower) {
        dec$state <- .FLAC_SEEK_ERROR
        return(FALSE)
      }
      approx <- if (approx) (approx * 2) %% u32 else 16
      next
    }
    first_seek <- FALSE
    if (this_sample < lower_sample) {
      dec$state <- .FLAC_SEEK_ERROR
      return(FALSE)
    }
    p <- .fd_decode_position(dec)
    if (is.na(p)) {
      dec$state <- .FLAC_SEEK_ERROR
      return(FALSE)
    }
    if (target < this_sample) {
      upper_sample <- this_sample + this_bs
      upper <- p
      approx <- .fd_approx(upper - pos)
    } else {
      lower_sample <- this_sample + this_bs
      lower <- p
      approx <- .fd_approx(lower - pos)
    }
  }
  TRUE
}

# The estimate of the bytes per frame after a step of the binary search:
# ((x mod 2^64) * 2 / 3 + 16) mod 2^32, x being a difference of file
# positions (a 64-bit unsigned value in libFLAC).
.fd_approx <- function(x) {
  if (x >= 0) return(((2 * x) %/% 3 + 16) %% 4294967296)
  # (2^65 = 3 * 0xAAAAAAAAAAAAAAAA + 2)
  (2863311530 + floor((2 + 2 * x) / 3) + 16) %% 4294967296
}

# FLAC__stream_decoder_finish: FALSE if the MD5 signature does not match the
# samples decoded.
.fd_finish <- function(dec) {
  if (dec$do_md5_checking)
    return(identical(.flac_md5(unlist(dec$md5data, use.names = FALSE)), dec$si_md5))
  TRUE
}

#' Decode a complete FLAC stream (raw): list(chans (matrix, one row per
#' channel), bps (bits per sample from STREAMINFO), md5 (the 16-byte MD5
#' signature of STREAMINFO)).  Errors are conditions of class "wfdbx_flac"
#' whose field status is "sync", "header", "crc", "unparseable" or "meta".
flac_decode <- function(data) {
  blocks <- list()
  nch <- NA
  on_error <- function(status) .flac_err(status)
  on_write <- function(fr) {
    if (is.na(nch)) nch <<- length(fr)
    if (length(fr) != nch) .flac_err("unparseable")
    blocks[[length(blocks) + 1L]] <<- do.call(rbind, fr)
    TRUE
  }
  dec <- .flac_decoder(as.raw(data), TRUE, on_error, on_write, FALSE)
  while (dec$state != .FLAC_END_OF_STREAM) {
    if (!.fd_process_single(dec)) .flac_err("meta")
  }
  chans <- if (length(blocks)) do.call(cbind, blocks) else matrix(0, max(dec$si_channels, 1), 0)
  list(chans = unname(chans), bps = dec$si_bps, md5 = dec$si_md5)
}

# Bytes of the interleaved samples (as libFLAC computes the MD5 signature):
# for each sample time, each channel, nb little-endian bytes.
.flac_sample_bytes <- function(v, nb) {
  v <- v %% 2^(8 * nb)
  as.raw(floor(rep(v, each = nb) / 256^(0:(nb - 1))) %% 256)
}

.FLAC_MESSAGES <- c(sync = "getvec: unable to decode FLAC (lost sync)\n",
                    header = "getvec: unable to decode FLAC (invalid header)\n",
                    crc = "getvec: unable to decode FLAC (CRC mismatch)\n",
                    unparseable = "getvec: unable to decode FLAC (unsupported format)\n")

# The decoder of a FLAC signal group (created when the file is first read).
.flac_dec <- function(ig) {
  fi <- ig$flac
  if (is.null(fi$dec)) {
    on_error <- function(status) {
      msg <- .FLAC_MESSAGES[status]
      wfdb_error(if (is.na(msg)) "getvec: unable to decode FLAC\n" else msg)
      ig$stat <- -2
    }
    on_write <- function(chans) .flac_samples(ig, chans)
    fi$dec <- .flac_decoder(wf_readall(ig$fp), isTRUE(ig$seek != 0), on_error, on_write,
                            fi$md5_check)
  }
  fi$dec
}

# Store a block of decoded samples (iflac_samples), in WFDB frame order (for
# each frame: spf samples of each signal in turn): FALSE to abort decoding.
.flac_samples <- function(ig, chans) {
  fi <- ig$flac
  if (length(chans) != fi$nsig) {
    wfdb_error("getvec: wrong number of signals in FLAC signal file\n")
    ig$stat <- -2
  }
  if (fi$dec$f_bps > fi$datb) {
    wfdb_error("getvec: wrong sample resolution in FLAC signal file\n")
    ig$stat <- -2
  }
  if (ig$stat < 0) return(FALSE)
  n <- if (length(chans)) length(chans[[1L]]) else 0
  if (fi$skip > n) {
    fi$skip <- fi$skip - n
    return(TRUE)
  }
  if (fi$skip) {
    chans <- lapply(chans, function(c) c[-seq_len(fi$skip)])
    fi$skip <- 0
  }
  if (fi$pos) {
    ns <- length(fi$samples)
    fi$samples <- if (fi$pos < ns) fi$samples[(fi$pos + 1):ns] else numeric(0)
    fi$pos <- 0
  }
  spf <- fi$spf
  if (!is.null(fi$partial)) {
    chans <- Map(c, fi$partial, chans)
    fi$partial <- NULL
  }
  n <- if (length(chans)) length(chans[[1L]]) else 0
  nfr <- n %/% spf
  if (nfr > 0) {
    X <- do.call(rbind, lapply(chans, function(c) c[seq_len(nfr * spf)]))
    new <- if (spf == 1) as.vector(X) else
      as.vector(aperm(array(t(X), c(spf, nfr, nrow(X))), c(1L, 3L, 2L)))
    fi$samples <- c(fi$samples, new)
  }
  if (n > nfr * spf) fi$partial <- lapply(chans, function(c) c[(nfr * spf + 1):n])
  TRUE
}

#' Prepare to read a FLAC signal group (flac_isopen in signal.c).  ig: the
#' input group (fields fp, seek, start, stat, count, flac); hs: list of the
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
  # State of a FLAC signal group: libFLAC's decoder, and the samples it has
  # decoded, in frame order, as the C library's iflac_samples() stores them
  fi <- new.env(parent = emptyenv())
  fi$nsig <- ns
  fi$datb <- hs[[1L]]$info$fmt - 500   # resolution of the group (8, 16 or 24)
  fi$spf <- hs[[1L]]$info$spf
  fi$dec <- NULL
  fi$samples <- numeric(0)             # complete frames, in frame order
  fi$pos <- 0                          # index of the next sample to be returned
  fi$partial <- NULL                   # an incomplete frame: one vector per signal
  fi$skip <- 0                         # samples to discard after a seek
  fi$md5_check <- nzchar(Sys.getenv("WFDB_FLAC_CHECK_MD5"))
  ig$flac <- fi
  ig$count <- 0
  0
}

#' The next sample of a FLAC input group, in frame order (flac_getsamp).
#' At the end of the data, 0 is returned and ig$stat set to 0 (the first
#' time, a warning gives the number of samples left over that do not fill a
#' frame); after a decoding error, 0 is returned and ig$stat is -2.
flac_getsamp <- function(ig) {
  fi <- ig$flac
  p <- fi$pos
  if (p < length(fi$samples)) {
    fi$pos <- p + 1
    return(fi$samples[p + 1])
  }
  dec <- .flac_dec(ig)
  while (fi$pos >= length(fi$samples)) {
    oldcount <- if (!is.null(fi$partial)) length(fi$partial[[1L]]) else 0
    if (!.fd_process_single(dec)) {
      if (ig$stat != -2) {
        wfdb_error("getvec: unexpected FLAC decoding error\n")
        ig$stat <- -2
      }
      return(0)
    }
    if (ig$stat <= 0) return(0)
    count <- if (!is.null(fi$partial)) length(fi$partial[[1L]]) else 0
    if (fi$pos >= length(fi$samples) && count == oldcount) {
      st <- dec$state
      if (st == .FLAC_END_OF_STREAM) {
        if (count)
          wfdb_error("getvec: warning: %d samples left over at end of file\n", count)
        fi$partial <- NULL
        ig$stat <- 0
        return(0)
      }
      if (!(st %in% c(.FLAC_SEARCH_FOR_METADATA, .FLAC_READ_METADATA,
                      .FLAC_SEARCH_FOR_FRAME_SYNC))) {
        wfdb_error("getvec: unknown FLAC decoding state\n")
        ig$stat <- -2
        return(0)
      }
    }
  }
  p <- fi$pos
  fi$pos <- p + 1
  fi$samples[p + 1]
}

#' The number of samples of a FLAC input group that flac_getsamp returns
#' without decoding more of the stream (-1 after an error or a failed
#' seek).
flac_navail <- function(ig) {
  if (ig$stat < 0) return(-1)
  fi <- ig$flac
  length(fi$samples) - fi$pos
}

#' Exactly the effect of n calls of flac_getsamp(ig) (n = Inf: all the
#' remaining samples, without the reads past the end): list(v = the
#' samples returned, st = the value of ig$stat after each call).
flac_getsamps <- function(ig, n) {
  fi <- ig$flac
  if (is.infinite(n)) {
    v <- list()
    repeat {
      p <- fi$pos
      ns <- length(fi$samples)
      if (p < ns) {
        v[[length(v) + 1L]] <- fi$samples[(p + 1):ns]
        fi$pos <- ns
      }
      if (ig$stat <= 0) break
      x <- flac_getsamp(ig)
      if (ig$stat <= 0) break
      v[[length(v) + 1L]] <- x
    }
    v <- unlist(v, use.names = FALSE) %||% numeric(0)
    return(list(v = v, st = rep(ig$stat, length(v))))
  }
  p <- fi$pos
  k <- min(n, max(length(fi$samples) - p, 0))
  v <- numeric(n)
  st <- numeric(n)
  if (k > 0) {
    v[seq_len(k)] <- fi$samples[p + seq_len(k)]
    st[seq_len(k)] <- ig$stat
    fi$pos <- p + k
  }
  for (j in seq_len(n - k) + k) {
    v[j] <- flac_getsamp(ig)
    st[j] <- ig$stat
  }
  list(v = v, st = st)
}

#' Seek a FLAC input group to frame t (counted from ig$start samples into
#' the stream; flac_isseek).  Returns ig$stat (1), or -1 if the seek fails.
flac_isseek <- function(ig, t) {
  fi <- ig$flac
  dec <- .flac_dec(ig)
  if (dec$state == .FLAC_SEEK_ERROR) .fd_flush(dec)
  fi$samples <- numeric(0)
  fi$pos <- 0
  fi$partial <- NULL
  ig$stat <- 1
  ig$count <- 0
  fi$skip <- 0
  # (seeking to the sample before the target, then discarding it, allows a
  # seek to the end of the stream)
  tt <- t * fi$spf + ig$start
  if (tt != 0) {
    tt <- tt - 1
    fi$skip <- 1
  }
  if (!.fd_seek_absolute(dec, tt)) ig$stat <- -1
  ig$stat
}

#' Finish reading a FLAC input group (flac_isclose): with
#' WFDB_FLAC_CHECK_MD5 set (when the group was opened), the MD5 signature
#' of the samples decoded is checked against STREAMINFO.  Returns 0, or -1
#' after "isigclose: warning: incorrect MD5 hash".
flac_isclose <- function(ig) {
  fi <- ig$flac
  if (is.null(fi)) return(0)
  dec <- fi$dec
  if (is.null(dec)) {
    # (nothing was read: libFLAC compares the signature of no samples with
    # that of a STREAMINFO block it has not read)
    if (fi$md5_check) {
      wfdb_error("isigclose: warning: incorrect MD5 hash in FLAC input\n")
      return(-1)
    }
    return(0)
  }
  if (!.fd_finish(dec)) {
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
