# signal.R: signal I/O of the WFDB library (port of lib/signal.c): header
# files (including EDF), signal files in all WFDB formats (FLAC formats
# through flac.R), multi-segment and multi-frequency records, time and date
# conversion, unit conversion, info strings.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of lib/signal.c from the WFDB Software Package 10.7.0,
# by George B. Moody. The translation follows the logic and behavior of the
# original code, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency, gain, ADC
# resolution or units (the original assumed 250 Hz, 200 adu/mV, 12 bits or a
# resolution based on the format, and millivolts): a value that the header does
# not give stays unspecified, and the time and amplitude conversions that need
# it, and setifreq, report an error; the signal files and segments named in a
# header are read only from the header's directory (on disk or at its URL),
# never searched for, and a name that leaves that directory is refused; an
# output signal file is never one of the input files of the open record; a
# header written under a path names the record, its signal files and its
# segments relative to its own directory; FLAC signal files are read and
# written with WFDB-x's own codec (flac.R) instead of libFLAC; additions:
# wfdbx_set_legacy, wfdbx_get_legacy, wfdbx_legacy_args, wfdbx_time_needs_freq,
# getframes and putframes; legacy mode (wfdbx_set_legacy) restores the original
# behavior. Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md
# gives the reasons.
#
# Original C code: lib/signal.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by
#   Benjamin Moody, including FLAC support (2020).
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The C library's global (file-scope) state is kept in the environment
# .sig (sig_reset() restores it).  Internal objects (no class attribute, see
# DEVELOPING.md):
#   hsd       list of header signal descriptions: list(info, start, skew)
#   isd, vsd  lists of environments (input signals, "virtual" signals):
#             info (siginfo list), samp, skew, gvindex, gvcount
#   igd       list of environments (input groups = signal files): data,
#             datb, fp, start, bsize, buf (raw), bp (bytes consumed from
#             buf), be (valid bytes in buf), count, seek, initial_skip,
#             stat, flac
#   osd       list of environments (output signals): info, samp, skew
#   ogd       list of environments (output groups): data, datb, fp, start,
#             bsize, buf (raw, preallocated), nb (bytes pending in buf),
#             obuflen, count, seek, force_flush, nrewind, flac
# Signal and group numbers are 0-based (as in C): signal s is isd[[s + 1]].
#
# getframes(n) and putframes(m) are vectorized bulk versions of getvec()
# and putvec() (exactly equivalent to n getvec / nrow(m) putvec calls).

WFDB_INVALID_SAMPLE <- -32768
WFDB_SAMPLE_MIN <- -2147483648
WFDB_SAMPLE_MAX <- 2147483647
WFDB_TIME_MAX <- 2^63     # (WFDB_Time is a 64-bit long; 2^63 - 1 as a double)
WFDB_TIME_MIN <- -2^63
WFDB_MAXUSL <- 50
WFDB_MAXDSL <- 100
WFDB_FMT_LIST <- c(0, 8, 16, 61, 80, 160, 212, 310, 311, 24, 32, 508, 516, 524)
# WFDB-x: WFDB_DEFFREQ, WFDB_DEFGAIN and WFDB_DEFRES remain defined for
# compatibility, but are not used: WFDB-x never assumes a sampling frequency,
# a gain or an ADC resolution (see docs/DIVERGENCES.md).
WFDB_DEFFREQ <- 250
WFDB_DEFGAIN <- 200
WFDB_DEFRES <- 12
WFDB_LOWRES <- 0
WFDB_HIGHRES <- 1
WFDB_GVPAD <- 2
.DEFWFDBGVMODE <- 0
.BUFSIZ <- 8192
.BUFLN <- 4096

.sig <- new.env(parent = emptyenv())

#' Reset the whole state of the signal module (as at program start).
sig_reset <- function() {
  st <- .sig
  st$hsd <- list()
  st$hheader <- NULL
  st$ffreq <- 0
  st$ifreq <- 0
  st$sfreq <- 0
  st$cfreq <- 0
  st$spfmax <- 0
  st$btime <- 0
  st$bdate <- 0
  st$nsamples <- 0
  st$bcount <- 0
  st$prolog_bytes <- 0
  st$segments <- 0
  st$in_msrec <- 0
  # WFDB-x: the directory of the header read last (see .dirname; NULL if
  # unknown: the standard input), and the directory and name of the header
  # of the current multi-segment record (msrec_name is NULL if there is
  # none); user_segments while setmsheader reads the headers it was given
  st$hdr_dir <- NULL
  st$msrec_dir <- NULL
  st$msrec_name <- NULL
  st$user_segments <- FALSE
  # WFDB-x: TRUE while a high-level reader reads (getvec's checksum message
  # is then not printed: the reader warns instead)
  st$cksum_quiet <- FALSE
  st$msbtime <- 0
  st$msbdate <- 0
  st$msnsamples <- 0
  st$segarray <- NULL
  st$segp <- 0
  st$segend <- 0
  st$isd <- list()
  st$igd <- list()
  st$nisig <- 0
  st$nigroup <- 0
  st$ispfmax <- 0
  st$tvector <- numeric(0)
  st$uvector <- numeric(0)
  st$vvector <- numeric(0)
  st$tuvlen <- 0
  st$istime <- 0
  st$ibsize <- 0
  st$skewmax <- 0
  st$dsbuf <- NULL
  st$dsbi <- -1
  st$dsblen <- 0
  st$framelen <- 0
  st$gvmode <- .DEFWFDBGVMODE
  st$gvc <- 0
  st$isedf <- 0
  st$sbuf <- NULL
  st$sample_vflag <- 0
  st$sample_tt <- -1
  st$osd <- list()
  st$ogd <- list()
  st$nosig <- 0
  st$nogroup <- 0
  st$oheader <- NULL
  st$outinfo <- NULL
  st$ostime <- 0
  st$obsize <- 0
  st$pinfo <- NULL
  st$ninfo <- 0
  st$info_i <- 0
  st$need_sigmap <- 0
  st$nvsig <- 0
  st$tspf <- 0
  st$vspfmax <- 0
  st$vsd <- list()
  st$ovec <- NULL
  st$smi <- NULL
  st$mticks <- 0
  st$nticks <- 0
  st$mnticks <- 0
  st$rgvstat <- 0
  st$rgvtime <- 0
  st$gvtime <- 0
  st$gv0 <- NULL
  st$gv1 <- NULL
  st$rgetvec_stat <- 0
  st$gvec <- numeric(0)
  st$date_string <- ""
  st$time_string <- ""
  st$pdays <- -1
  st$bulk_layout <- NULL
  st$legacy <- FALSE
  invisible()
}
sig_reset()

# ---------------------------------------------------------------------------
# WFDB-x: legacy mode.  By default, the library has no built-in signal
# parameters (see docs/DIVERGENCES.md).  In legacy mode (wfdbx_set_legacy(TRUE),
# or --legacy as the first argument of a tool, see wfdbx_legacy_args), it
# behaves exactly as the original WFDB library 10.7.0, with its built-in
# defaults: WFDB_DEFFREQ for a header without a sampling frequency, an ADC
# resolution inferred from the format or WFDB_DEFRES, 1 sample per second in
# the time conversion functions, and WFDB_DEFGAIN (and a baseline of 0 for
# invalid signal numbers) in the unit conversion functions.  It exists for
# compatibility only.

#' Turn legacy mode on (on = TRUE) or off; returns the previous setting.
wfdbx_set_legacy <- function(on) {
  previous <- .sig$legacy
  .sig$legacy <- isTRUE(as.logical(on))
  previous
}

#' Whether legacy mode is on.
wfdbx_get_legacy <- function() .sig$legacy

#' Called by the tools first, with their argument list (argv, the program
#' name first): if the first argument after the program name is "--legacy",
#' it is removed and legacy mode is turned on.  Returns
#' list(argv = the remaining arguments, legacy = whether "--legacy" was found).
wfdbx_legacy_args <- function(argv) {
  if (length(argv) < 2L || !identical(argv[2L], "--legacy"))
    return(list(argv = argv, legacy = FALSE))
  wfdbx_set_legacy(TRUE)
  list(argv = argv[-2L], legacy = TRUE)
}

# ---------------------------------------------------------------------------
# Small helpers

.b <- function(s) as.integer(charToRaw(s))           # byte codes of a string
.bs <- function(b) rawToChar(as.raw(b))               # string of byte codes
.nb <- function(s) if (is.null(s)) 0L else nchar(s, type = "bytes")
.f <- function(fmt, ...) rawToChar(csprintf(fmt, ...))
# first index >= from of byte ch in b (0 if none)
.bfind <- function(b, ch, from = 1L) {
  n <- length(b)
  if (from > n) return(0L)
  k <- match(ch, b[from:n])
  if (is.na(k)) 0L else from + k - 1L
}
# the first n bytes of string s
.btrunc <- function(s, n) {
  if (.nb(s) > n) rawToChar(charToRaw(s)[seq_len(n)]) else s
}
.first_is <- function(s, code) {
  !is.null(s) && nzchar(s) && as.integer(charToRaw(s)[1L]) == code
}
# a C string (character string, raw vector or NULL) as a character string
.cs <- function(x) {
  if (is.null(x) || is.character(x)) x else cstr(x)
}
.isfmt <- function(f) f %in% WFDB_FMT_LIST
.isflacfmt <- function(f) f >= 500 && f <= 532
.invalid_of <- function(fmt) {
  switch(as.character(fmt), "80" = , "508" = -128, "212" = -2048,
         "310" = , "311" = -512, "24" = , "524" = -8388608,
         "32" = -2147483648, -32768)
}

.hsdata <- function() list(info = siginfo(), start = 0, skew = 0)

.isdata <- function(info = siginfo(), skew = 0) {
  e <- new.env(parent = emptyenv())
  e$info <- info
  e$samp <- 0
  e$skew <- skew
  e$gvindex <- 0
  e$gvcount <- 0
  e
}

.igdata <- function() {
  e <- new.env(parent = emptyenv())
  e$data <- 0
  e$datb <- 0
  e$fp <- NULL
  e$start <- 0
  e$bsize <- 0
  e$buf <- raw(0)
  e$bp <- 0
  e$be <- 0
  e$count <- 0
  e$seek <- 0
  e$initial_skip <- 0
  e$stat <- 0
  e$flac <- NULL
  e
}

.ogdata <- function() {
  e <- new.env(parent = emptyenv())
  e$data <- 0
  e$datb <- 0
  e$fp <- NULL
  e$start <- 0
  e$bsize <- 0
  e$buf <- raw(0)
  e$nb <- 0
  e$obuflen <- 0
  e$count <- 0
  e$seek <- 0
  e$force_flush <- 0
  e$nrewind <- 0
  e$flac <- NULL
  e
}

.osdata <- function(info) {
  e <- new.env(parent = emptyenv())
  e$info <- info
  e$samp <- 0
  e$skew <- 0
  e
}

# ---------------------------------------------------------------------------
# Low-level input (r8, r16, ... of signal.c) on an input group ig

.ig_fill <- function(ig) {
  n <- if (ig$bsize > 0) ig$bsize else .sig$ibsize
  b <- if (!is.null(ig$fp)) wf_read(ig$fp, n) else raw(0)
  ig$stat <- length(b)
  if (length(b)) ig$buf <- b
  ig$bp <- 0
  ig$be <- length(b)
}

# r8: a signed byte
.r8 <- function(ig) {
  if (ig$bp >= ig$be) .ig_fill(ig)
  bp <- ig$bp
  buf <- ig$buf
  v <- if (bp < length(buf)) as.integer(buf[bp + 1]) else 0L
  ig$bp <- bp + 1
  if (v > 127L) v - 256 else v
}

.r16 <- function(ig) {
  bp <- ig$bp
  if (bp + 2 <= ig$be) {
    b <- ig$buf
    ig$bp <- bp + 2
    v <- as.integer(b[bp + 1]) + 256 * as.integer(b[bp + 2])
    return(if (v >= 32768) v - 65536 else v)
  }
  lo <- .r8(ig)
  hi <- .r8(ig)
  cint16(hi * 256 + lo %% 256)
}

.r61 <- function(ig) {
  bp <- ig$bp
  if (bp + 2 <= ig$be) {
    b <- ig$buf
    ig$bp <- bp + 2
    v <- 256 * as.integer(b[bp + 1]) + as.integer(b[bp + 2])
    return(if (v >= 32768) v - 65536 else v)
  }
  hi <- .r8(ig)
  lo <- .r8(ig)
  cint16(lo %% 256 + hi * 256)
}

.r24 <- function(ig) {
  bp <- ig$bp
  if (bp + 3 <= ig$be) {
    b <- as.integer(ig$buf[bp + 1:3])
    ig$bp <- bp + 3
    v <- b[1L] + 256 * b[2L] + 65536 * b[3L]
    return(if (v >= 8388608) v - 16777216 else v)
  }
  lw <- .r16(ig)
  h <- .r8(ig)
  cint32(h * 65536 + lw %% 65536)
}

.r32 <- function(ig) {
  bp <- ig$bp
  if (bp + 4 <= ig$be) {
    b <- as.integer(ig$buf[bp + 1:4])
    ig$bp <- bp + 4
    v <- b[1L] + 256 * b[2L] + 65536 * b[3L] + 16777216 * b[4L]
    return(if (v >= 2147483648) v - 4294967296 else v)
  }
  lw <- .r16(ig)
  h <- .r16(ig)
  cint32(h * 65536 + lw %% 65536)
}

.r80 <- function(ig) .r8(ig) %% 256 - 128
.r160 <- function(ig) .r16(ig) %% 65536 - 32768

.r212 <- function(ig) {
  if (ig$count == 0) {
    ig$count <- 1
    v <- .r16(ig)
    ig$data <- v
  } else {
    ig$count <- 0
    v <- ((ig$data %% 65536) %/% 4096) * 256 + .r8(ig) %% 256
  }
  v <- v %% 4096
  if (v >= 2048) v - 4096 else v
}

.r310 <- function(ig) {
  c <- ig$count
  if (c == 0) {
    ig$count <- 1
    ig$data <- .r16(ig)
    v <- floor(ig$data / 2)
  } else if (c == 1) {
    ig$count <- 2
    ig$datb <- .r16(ig)
    v <- floor(ig$datb / 2)
  } else {
    ig$count <- 0
    v <- (ig$data %% 65536) %/% 2048 + ((ig$datb %% 65536) %/% 2048) * 32
  }
  v <- v %% 1024
  if (v >= 512) v - 1024 else v
}

.r311 <- function(ig) {
  c <- ig$count
  if (c == 0) {
    ig$count <- 1
    v <- .r16(ig)
    ig$data <- v
  } else if (c == 1) {
    ig$count <- 2
    ig$datb <- .r8(ig) %% 256
    v <- (ig$data %% 65536) %/% 1024 + (ig$datb %% 16) * 64
  } else {
    ig$count <- 0
    ig$datb <- ig$datb + .r8(ig) * 256
    v <- floor(ig$datb / 16)
  }
  v <- v %% 1024
  if (v >= 512) v - 1024 else v
}

# ---------------------------------------------------------------------------
# Low-level output on an output group og: bytes are collected in og$buf
# (preallocated, og$nb pending bytes) and written in blocks of og$obuflen
# bytes, as signal.c does.

.og_put <- function(og, b) {
  n <- length(b)
  if (n == 0L) return(invisible())
  len <- og$obuflen
  if (len < 1) len <- 1
  pos <- 0L
  while (pos < n) {
    nb <- og$nb
    if (nb == 0 && n - pos >= len) {
      # whole blocks: written directly
      k <- ((n - pos) %/% len) * len
      if (!is.null(og$fp))
        wf_write(og$fp, if (k == n) b else if (pos == 0) readBin(b, "raw", k) else b[pos + seq_len(k)])
      pos <- pos + k
      next
    }
    k <- min(len - nb, n - pos)
    buf <- og$buf
    og$buf <- NULL
    if (length(buf) < len) buf <- c(buf[seq_len(nb)], raw(len - nb))
    buf[nb + seq_len(k)] <- b[pos + seq_len(k)]
    og$buf <- buf
    pos <- pos + k
    nb <- nb + k
    if (nb >= len) {
      if (!is.null(og$fp)) wf_write(og$fp, buf[seq_len(nb)])
      nb <- 0
    }
    og$nb <- nb
  }
  invisible()
}

.w16b <- function(v) {
  v <- v %% 65536
  as.raw(c(v %% 256, v %/% 256))
}

# Bit-packed formats: .p212(og, v) etc. update the packing state of og and
# return the bytes completed by sample v (possibly none).
.p212 <- function(og, v) {
  if (og$count == 0) {
    og$count <- 1
    og$data <- v %% 4096
    raw(0)
  } else {
    og$count <- 0
    og$data <- og$data + ((v %% 4096) %/% 256) * 4096
    c(.w16b(og$data), as.raw(v %% 256))
  }
}
.w212 <- function(og, v) .og_put(og, .p212(og, v))

.f212 <- function(og) {
  if (og$count == 1) {
    .og_put(og, .w16b(og$data))
    og$nrewind <- 2
  }
}

.p310 <- function(og, v) {
  c <- og$count
  if (c == 0) {
    og$count <- 1
    og$data <- (v %% 1024) * 2
    raw(0)
  } else if (c == 1) {
    og$count <- 2
    og$datb <- (v %% 1024) * 2
    raw(0)
  } else {
    og$count <- 0
    og$data <- og$data + (v %% 32) * 2048
    og$datb <- og$datb + ((v %% 1024) %/% 32) * 2048
    c(.w16b(og$data), .w16b(og$datb))
  }
}
.w310 <- function(og, v) .og_put(og, .p310(og, v))

.f310 <- function(og) {
  if (og$count == 0) return(invisible())
  if (og$count == 1) {
    .og_put(og, .w16b(og$data))
    og$nrewind <- 2
  } else {
    .og_put(og, c(.w16b(og$data), .w16b(og$datb)))
    og$nrewind <- 4
  }
}

.p311 <- function(og, v) {
  c <- og$count
  if (c == 0) {
    og$count <- 1
    og$data <- v %% 1024
    raw(0)
  } else if (c == 1) {
    og$count <- 2
    og$data <- og$data + (v %% 64) * 1024
    og$datb <- floor(v / 64) %% 16
    .w16b(og$data)
  } else {
    og$count <- 0
    og$datb <- og$datb + (v %% 1024) * 16
    .w16b(og$datb)
  }
}
.w311 <- function(og, v) .og_put(og, .p311(og, v))

.f311 <- function(og) {
  if (og$count == 0) return(invisible())
  if (og$count == 1) {
    .og_put(og, .w16b(og$data))
  } else {
    .og_put(og, .w16b(og$datb))
  }
  og$nrewind <- 2
}

# ---------------------------------------------------------------------------
# Variable-layout multi-segment records (signal maps).  The map is kept as
# vectors (one element per sample of the frame): smi$desc (list), gain,
# scale, offset, sample_offset, baseline, index, spf.

.sigmap_cleanup <- function() {
  st <- .sig
  st$need_sigmap <- 0
  st$nvsig <- 0
  st$tspf <- 0
  st$vspfmax <- 0
  st$ovec <- NULL
  st$smi <- NULL
  st$vsd <- list()
}

.make_vsd <- function() {
  st <- .sig
  if (st$nvsig != st$nisig) {
    wfdb_error("make_vsd: oops! nvsig = %d, nisig = %d\n", st$nvsig, st$nisig)
    return(-1)
  }
  st$vsd <- lapply(st$isd[seq_len(st$nvsig)], function(is) .isdata(is$info, is$skew))
  st$nvsig
}

.sigmap_init <- function(first_segment) {
  st <- .sig
  if (st$in_msrec && first_segment && !is.null(st$segarray) &&
      st$segarray[[1L]]$nsamp == 0) {
    st$need_sigmap <- 1
    st$nvsig <- st$nisig
    st$vspfmax <- st$ispfmax
    spf <- vapply(st$isd, function(is) is$info$spf, 0)
    st$tspf <- sum(spf)
    rep_i <- rep(seq_along(spf), spf)
    st$smi <- list(
      desc = lapply(st$isd, function(is) is$info$desc)[rep_i],
      gain = vapply(st$isd, function(is) is$info$gain, 0)[rep_i],
      baseline = vapply(st$isd, function(is) is$info$baseline, 0)[rep_i],
      spf = spf[rep_i],
      scale = numeric(st$tspf), offset = numeric(st$tspf),
      sample_offset = numeric(st$tspf), index = numeric(st$tspf))
    st$ovec <- numeric(st$tspf)
    return(.make_vsd())
  } else if (st$need_sigmap) {
    smi <- st$smi
    tspf <- st$tspf
    smi$index <- numeric(tspf)
    smi$scale <- numeric(tspf)
    smi$offset <- numeric(tspf)
    smi$sample_offset <- rep(WFDB_INVALID_SAMPLE, tspf)
    st$ispfmax <- st$vspfmax
    if (st$isd[[1L]]$info$fmt == 0 && st$nisig == 1) {
      st$smi <- smi
      return(0)
    }
    segname <- st$segarray[[st$segp + 1]]$recname
    j <- 0
    for (i in seq_len(st$nisig)) {
      isi <- st$isd[[i]]$info
      s <- 0
      while (s < tspf) {
        if (identical(smi$desc[[s + 1]], isi$desc)) {
          kmax <- smi$spf[s + 1]
          if (kmax != isi$spf) {
            wfdb_error("sigmap_init: unexpected spf for signal %d in segment %s\n",
                       i - 1, segname)
            if (kmax > isi$spf) kmax <- isi$spf
          }
          for (k in seq_len(kmax) - 1) {
            p <- s + k + 1
            smi$index[p] <- j + k
            sc <- smi$gain[p] / isi$gain
            smi$scale[p] <- sc
            if (isTRUE(sc < 1)) {
              wfdb_error("sigmap_init: loss of precision in signal %d in segment %s\n",
                         i - 1, segname)
            }
            off <- smi$baseline[p] - sc * isi$baseline + 0.5
            f <- isi$fmt
            # (the range of the samples of format f)
            if (f %in% c(508, 80)) {
              ivmin <- -128; ivmax <- 127
            } else if (f %in% c(310, 311)) {
              ivmin <- -512; ivmax <- 511
            } else if (f == 212) {
              ivmin <- -2048; ivmax <- 2047
            } else if (f %in% c(16, 61, 516, 160)) {
              ivmin <- -32768; ivmax <- 32767
            } else if (f %in% c(524, 24)) {
              ivmin <- -8388608; ivmax <- 8388607
            } else {
              ivmin <- WFDB_SAMPLE_MIN; ivmax <- WFDB_SAMPLE_MAX
            }
            ovmin <- ivmin * sc + off
            ovmax <- ivmax * sc + off
            if (isTRUE(ovmin < ovmax && ovmin >= WFDB_SAMPLE_MIN + 1 &&
                       ovmax <= WFDB_SAMPLE_MAX &&
                       ovmax - ovmin + 1 < WFDB_SAMPLE_MAX)) {
              so <- trunc(ovmin - 1)
              smi$sample_offset[p] <- so
              off <- off - so
            } else {
              smi$sample_offset[p] <- 0
            }
            smi$offset[p] <- off
          }
          break
        }
        s <- s + smi$spf[s + 1]
      }
      j <- j + isi$spf
    }
    st$smi <- smi
    if (j > tspf) {
      wfdb_error("sigmap_init: frame size too large in segment %s\n", segname)
      return(-1)
    }
  } else if (st$in_msrec && !first_segment && st$framelen == 0) {
    st$ispfmax <- st$vspfmax
    segname <- st$segarray[[st$segp + 1]]$recname
    if (st$nisig > st$nvsig) {
      wfdb_error("sigmap_init: wrong number of signals in segment %s\n", segname)
      return(-1)
    }
    for (i in seq_len(st$nisig)) {
      if (st$isd[[i]]$info$spf != st$vsd[[i]]$info$spf) {
        wfdb_error("sigmap_init: wrong spf for signal %d in segment %s\n", i - 1, segname)
        return(-1)
      }
    }
  } else {
    st$nvsig <- st$nisig
    st$vspfmax <- st$ispfmax
    st$tspf <- sum(vapply(st$isd, function(is) is$info$spf, 0))
    return(.make_vsd())
  }
  0
}

# sigmap(): the virtual frame from the raw frame ivec (vectorized).
.sigmap <- function(ivec) {
  smi <- .sig$smi
  x <- ivec[smi$index + 1]
  v <- x * smi$scale + smi$offset
  so <- smi$sample_offset
  out <- numeric(length(x))
  inv <- x == WFDB_INVALID_SAMPLE
  a <- !inv & so != 0
  if (any(a)) out[a] <- cint32(trunc(v[a]) + so[a])
  b <- !inv & so == 0
  if (any(b)) {
    vb <- v[b]
    r <- rep(WFDB_SAMPLE_MIN, length(vb))
    pos <- !is.na(vb) & vb >= 0
    r[pos] <- ifelse(vb[pos] <= WFDB_SAMPLE_MAX, trunc(vb[pos]), WFDB_SAMPLE_MAX)
    neg <- !is.na(vb) & vb < 0 & vb >= WFDB_SAMPLE_MIN
    r[neg] <- floor(vb[neg])
    out[b] <- r
  }
  out[inv] <- WFDB_INVALID_SAMPLE
  out
}

# ---------------------------------------------------------------------------
# Header parsing

# Read a header line as byte codes (up to a NUL); NULL at end of file.
.hline <- function(f) {
  l <- wf_getline(f)
  if (length(l) == 0L) NULL else cbytes(l)
}

.read_edf_str <- function(f, size) {
  b <- wf_read(f, size)
  if (length(b) != size) return("")
  b <- cbytes(b)
  n <- length(b)
  while (n > 0L && b[n] == 32L) n <- n - 1L
  .bs(b[seq_len(n)])
}

# sscanf(s, "%d%*c%d%*c%d"): up to n ints (NA where missing).
.scan_ints <- function(s, n) {
  b <- cbytes(s)
  out <- rep(NA_real_, n)
  pos <- 1
  for (k in seq_len(n)) {
    r <- strtol(b, 10, pos)
    if (r[2L] == pos) break
    out[k] <- cint32(r[1L])
    pos <- r[2L]
    if (k < n) {
      if (pos > length(b)) break
      pos <- pos + 1
    }
  }
  out
}

.na0 <- function(x) if (is.na(x)) 0 else x

.edfparse <- function(ifile) {
  st <- .sig
  edf_fname <- .wfdb_io$wfdb_filename
  magic <- wf_read(ifile, 8L)
  if (length(magic) == 8L && identical(magic, charToRaw("0       "))) {
    fmt <- 16
  } else if (length(magic) == 8L && identical(magic[2:8], charToRaw("BIOSEMI"))) {
    fmt <- 24
  } else {
    wfdb_error("init: '%s' is not EDF or EDF+\n", edf_fname)
    return(-2)
  }
  .read_edf_str(ifile, 80)
  .read_edf_str(ifile, 80)
  d <- .scan_ints(.read_edf_str(ifile, 8), 3)
  day <- .na0(d[1L])
  month <- .na0(d[2L])
  year <- .na0(d[3L]) + 1900
  if (year < 1985) year <- year + 100     # (two-digit years: 1985 to 2084)
  h <- .scan_ints(.read_edf_str(ifile, 8), 3)
  hour <- .na0(h[1L])
  minute <- .na0(h[2L])
  second <- .na0(h[3L])
  offset <- .na0(.scan_ints(.read_edf_str(ifile, 8), 1))
  .read_edf_str(ifile, 44)
  nframes <- strtol(.read_edf_str(ifile, 8))[1L]
  if (nframes < 0) nframes <- 0
  st$nsamples <- nframes
  spr <- strtod(.read_edf_str(ifile, 8))[1L]
  if (spr <= 0) spr <- 1
  nsig <- .na0(.scan_ints(cstr(wf_read(ifile, 4L)), 1))
  if (nsig < 1 || (nsig + 1) * 256 != offset) {
    wfdb_error("init: '%s' is not EDF or EDF+\n", edf_fname)
    return(-2)
  }
  hsd <- st$hsd
  while (length(hsd) < nsig) hsd[[length(hsd) + 1L]] <- .hsdata()
  # strip any path info from the EDF file name
  fb <- .b(edf_fname)
  p <- length(fb) - 4L
  base <- 0L
  p <- p - 1L
  while (p > 0L) {
    if (fb[p + 1L] == 47L) {
      base <- p + 1L
      break
    }
    p <- p - 1L
  }
  fname <- .bs(fb[seq_len(length(fb) - base) + base])
  for (s in seq_len(nsig)) {
    h <- hsd[[s]]
    h$start <- offset
    h$skew <- 0
    h$info["fname"] <- list(fname)
    h$info$group <- 0
    h$info$bsize <- 0
    h$info$cksum <- 0
    h$info$fmt <- fmt
    h$info$nsamp <- nframes
    h$info["desc"] <- list(.read_edf_str(ifile, 16))
    hsd[[s]] <- h
  }
  for (s in seq_len(nsig)) .read_edf_str(ifile, 80)
  for (s in seq_len(nsig)) hsd[[s]]$info["units"] <- list(.read_edf_str(ifile, 8))
  pmin <- numeric(nsig)
  pmax <- numeric(nsig)
  dmin <- numeric(nsig)
  dmax <- numeric(nsig)
  for (s in seq_len(nsig)) pmin[s] <- strtod(.read_edf_str(ifile, 8))[1L]
  for (s in seq_len(nsig)) pmax[s] <- strtod(.read_edf_str(ifile, 8))[1L]
  for (s in seq_len(nsig)) dmin[s] <- strtol(.read_edf_str(ifile, 8))[1L]
  for (s in seq_len(nsig)) {
    dmax[s] <- strtol(.read_edf_str(ifile, 8))[1L]
    info <- hsd[[s]]$info
    info$initval <- info$adczero <- cint32(cdiv(dmax[s] + 1 + dmin[s], 2))
    adcrange <- dmax[s] - dmin[s]
    i <- 0
    while (adcrange > 0) {
      adcrange <- cdiv(adcrange, 2)
      i <- i + 1
    }
    info$adcres <- i
    if (pmax[s] != pmin[s]) {
      info$gain <- (dmax[s] - dmin[s]) / (pmax[s] - pmin[s])
      baseline <- dmax[s] - pmax[s] * info$gain
      info$baseline <- if (baseline >= 0) trunc(baseline + 0.5) else trunc(baseline - 0.5)
    } else {
      info$gain <- 0
      info$baseline <- 0
    }
    hsd[[s]]$info <- info
  }
  for (s in seq_len(nsig)) .read_edf_str(ifile, 80)
  for (s in seq_len(nsig)) {
    n <- .na0(.scan_ints(.read_edf_str(ifile, 8), 1))
    hsd[[s]]$info$spf <- n
    if (n > st$spfmax) st$spfmax <- n
  }
  st$hsd <- hsd
  wf_close(ifile)
  st$hheader <- NULL
  st$ffreq <- 1 / spr
  st$cfreq <- st$ffreq
  st$sfreq <- st$ffreq * st$spfmax
  if (getafreq() == 0) setafreq(st$sfreq)
  st$gvmode <- as.numeric(bitwOr(st$gvmode, WFDB_HIGHRES))
  setbasetime(.f("%02d:%02d:%02d %02d/%02d/%04d", hour, minute, second, day, month, year))
  st$isedf <- 1
  nsig
}

# Open the header (of type s: "hea", or NULL for a file name) of a record,
# or of a segment named in the header of the current multi-segment record
# (WFDB-x: in that header's directory), and note its directory.
.open_header <- function(s, record) {
  st <- .sig
  if (wfdbx_get_legacy()) return(wfdb_open(s, record, WFDB_READ))
  if (!st$in_msrec) st$msrec_dir <- st$msrec_name <- NULL
  f <- if (st$in_msrec && !is.null(st$msrec_name) && !st$user_segments)
    .open_in(st$msrec_dir, s, record, st$msrec_name) else wfdb_open(s, record, WFDB_READ)
  st$hdr_dir <- if (!is.null(f) && !f$is_std) .dirname(.wfdb_io$wfdb_filename) else NULL
  f
}

.readheader <- function(record) {
  st <- .sig
  sep <- " \t\n\r"
  if (!is.null(st$hheader)) {
    wf_close(st$hheader)
    st$hheader <- NULL
  }
  st$spfmax <- 1
  st$sfreq <- st$ffreq
  st$isedf <- 0
  if (identical(record, "~")) {
    if (st$in_msrec && length(st$vsd)) {
      nsamp <- st$segarray[[st$segp + 1]]$nsamp
      info <- siginfo(desc = "~", spf = 1, fmt = 0, nsamp = nsamp)
      st$nsamples <- nsamp
      st$hsd <- list(list(info = info, start = 0, skew = 0))
      return(1)
    }
    return(0)
  }
  rb <- .b(record)
  n <- length(rb)
  q <- n
  while (q > 1L && !(rb[q] %in% c(46L, 47L, 58L, 92L))) q <- q - 1L
  if (n >= 1L && rb[q] == 46L) {
    st$hheader <- .open_header(NULL, record)
    if (is.null(st$hheader)) {
      wfdb_error("init: can't open %s\n", record)
      return(-1)
    }
    ext <- if (q < n) rb[(q + 1L):n] else integer(0)
    if (!identical(ext, .b("hea"))) return(.edfparse(st$hheader))
  } else {
    st$hheader <- .open_header("hea", record)
    if (is.null(st$hheader)) {
      wfdb_error("init: can't open header for record %s\n", record)
      return(-1)
    }
  }
  hh <- st$hheader
  line <- .hline(hh)
  if (is.null(line)) {
    wfdb_error("init: record %s header is empty\n", record)
    return(-2)
  }
  if (length(line) >= 5L && identical(line[1:5], .b("#wfdb"))) {
    vals <- numeric(0)
    pos <- 6
    for (k in 1:3) {
      r <- strtol(line, 10, pos)
      if (r[2L] == pos) break
      vals <- c(vals, r[1L])
      pos <- r[2L]
      if (k < 3) {
        if (!(pos <= length(line) && line[pos] == 46L)) break
        pos <- pos + 1
      }
    }
    i <- length(vals)
    major <- if (i > 0) vals[1L] else 0
    minor <- if (i > 1) vals[2L] else 0
    release <- if (i > 2) vals[3L] else 0
    if ((i > 0 && major > WFDB_MAJOR) ||
        (i > 1 && major == WFDB_MAJOR && minor > WFDB_MINOR) ||
        (i > 2 && major == WFDB_MAJOR && minor == WFDB_MINOR && release > WFDB_RELEASE)) {
      wfdb_error(paste0("init: reading record %s requires WFDB library ",
                        "version %d.%d.%d or later\n",
                        "  (the most recent version is always available from ",
                        "http://physionet.org)\n"),
                 record, major, minor, release)
      return(-1)
    }
  }
  tok <- strtok_new(line)
  p <- strtok_next(tok, sep)
  while (is.null(p) || .first_is(p, 35L)) {
    line <- .hline(hh)
    if (is.null(line)) {
      wfdb_error("init: can't find record name in record %s header\n", record)
      return(-2)
    }
    tok <- strtok_new(line)
    p <- strtok_next(tok, sep)
  }
  pb <- .b(p)
  slash <- .bfind(pb, 47L, 2L)
  if (slash >= 2L) {
    if (st$in_msrec) {
      wfdb_error("init: record %s cannot be nested in another multi-segment record\n",
                 record)
      return(-2)
    }
    st$segments <- cint32(strtol(pb, 10, slash + 1)[1L])
    pb <- pb[seq_len(slash - 1L)]
    p <- .bs(pb)
  }
  lp <- length(pb)
  if (hh$type == WFDB_LOCAL && !hh$is_std &&
      !(n >= lp && identical(rb[seq_len(lp)], pb))) {
    sidx <- n - 1L                # (0-based)
    q2 <- sidx
    while (sidx != 0L) {
      if (rb[sidx + 1L] %in% c(47L, 92L, 58L)) break
      sidx <- sidx - 1L
    }
    if (q2 > sidx && (0L > sidx || !identical(pb, rb[seq_len(n - sidx - 1L) + sidx + 1L]))) {
      wfdb_error("init: record name in record %s header is incorrect\n", record)
      return(-2)
    }
  }
  p <- strtok_next(tok, sep)
  if (is.null(p)) {
    wfdb_error("init: obsolete format in record %s header\n", record)
    return(-2)
  }
  nsig <- cuint32(strtol(p)[1L])
  p <- strtok_next(tok, sep)
  if (!is.null(p)) {
    f <- strtod(p)[1L]
    if (f <= 0) {
      wfdb_error("init: sampling frequency in record %s header is incorrect\n", record)
      return(-2)
    }
    if (st$ffreq > 0 && f != st$ffreq) {
      wfdb_error("warning (init):\n")
      wfdb_error(" record %s sampling frequency differs", record)
      wfdb_error(" from that of previously opened record\n")
    } else {
      st$ffreq <- f
    }
  } else if (st$legacy && st$ffreq == 0) {
    st$ffreq <- WFDB_DEFFREQ
  }
  # WFDB-x: if the header does not specify the sampling frequency (and the
  # caller has not set one with setsampfreq), it remains unspecified (0); the C
  # library assumed WFDB_DEFFREQ (250 Hz), as legacy mode does.
  st$sfreq <- st$ffreq
  st$cfreq <- 0
  st$bcount <- 0
  if (!is.null(p)) {
    pb <- .b(p)
    k <- .bfind(pb, 47L)
    if (k > 0L) {
      st$cfreq <- strtod(pb, k + 1)[1L]
      k2 <- .bfind(pb, 40L, k + 1L)
      if (k2 > 0L) st$bcount <- strtod(pb, k2 + 1)[1L]
    }
  }
  if (st$cfreq <= 0) st$cfreq <- st$ffreq
  p <- strtok_next(tok, sep)
  if (!is.null(p)) {
    ns <- strtol(p)[1L]
    if (ns < 0) {
      wfdb_error("init: number of samples in record %s header is incorrect\n", record)
      return(-2)
    }
    if (st$nsamples == 0) {
      st$nsamples <- ns
    } else if (ns > 0 && ns != st$nsamples && !st$in_msrec) {
      wfdb_error("warning (init):\n")
      wfdb_error(" record %s duration differs", record)
      wfdb_error(" from that of previously opened record\n")
      if (st$nsamples > ns) st$nsamples <- ns
    }
  } else {
    ns <- 0
  }
  p <- strtok_next(tok, "\n\r")
  if (!is.null(p) && st$btime == 0 && setbasetime(p) < 0) return(-2)
  # master header of a multi-segment record
  if (st$segments && !st$in_msrec) {
    if (!wfdbx_get_legacy()) {        # WFDB-x: the segments are next to it
      st$msrec_dir <- st$hdr_dir
      st$msrec_name <- record
    }
    st$msbtime <- st$btime
    st$msbdate <- st$bdate
    st$msnsamples <- st$nsamples
    segarray <- vector("list", max(st$segments, 0))
    ns <- 0
    fail <- function() {
      st$segarray <- NULL
      st$segments <- 0
      -2
    }
    for (i in seq_len(max(st$segments, 0))) {
      repeat {
        line <- .hline(hh)
        if (is.null(line)) {
          wfdb_error("init: unexpected EOF in header file for record %s\n", record)
          return(fail())
        }
        tok <- strtok_new(line)
        p <- strtok_next(tok, sep)
        if (!is.null(p) && !.first_is(p, 35L)) break
      }
      if (.first_is(p, 43L)) {
        wfdb_error("init: `%s' is not a valid segment name in record %s\n", p, record)
        return(fail())
      }
      if (.nb(p) > WFDB_MAXRNL) {
        wfdb_error("init: `%s' is too long for a segment name in record %s\n", p, record)
        return(fail())
      }
      seg <- seginfo(recname = p)
      p <- strtok_next(tok, sep)
      if (!is.null(p)) seg$nsamp <- strtol(p)[1L]
      if (is.null(p) || seg$nsamp < 0) {
        wfdb_error("init: length must be specified for segment %s in record %s\n",
                   seg$recname, record)
        return(fail())
      }
      seg$samp0 <- ns
      ns <- ns + seg$nsamp
      segarray[[i]] <- seg
    }
    st$segarray <- segarray
    st$segend <- length(segarray) - 1
    st$segp <- 0
    if (st$msnsamples == 0) {
      st$msnsamples <- ns
    } else if (ns != st$msnsamples) {
      wfdb_error("warning (init): in record %s, stated record length (%d)\n",
                 record, st$msnsamples)
      wfdb_error(" does not match sum of segment lengths (%d)\n", ns)
    }
    return(0)
  }
  hsd <- st$hsd
  on.exit(st$hsd <- hsd)
  while (length(hsd) < nsig) hsd[[length(hsd) + 1L]] <- .hsdata()
  s <- 0
  while (s < nsig) {
    hs <- hsd[[s + 1]]
    hp <- if (s) hsd[[s]] else NULL
    repeat {
      line <- .hline(hh)
      if (is.null(line)) {
        wfdb_error("init: unexpected EOF in header file for record %s\n", record)
        return(-2)
      }
      tok <- strtok_new(line)
      p <- strtok_next(tok, sep)
      if (!is.null(p) && !.first_is(p, 35L)) break
    }
    info <- hs$info
    if (s == 0 || !identical(p, hp$info$fname)) {
      info$group <- if (s == 0) 0 else hp$info$group + 1
      info["fname"] <- list(p)
    } else {
      info$group <- hp$info$group
      info["fname"] <- list(hp$info$fname)
    }
    p <- strtok_next(tok, sep)
    if (!is.null(p)) info$fmt <- cint32(strtol(p)[1L])
    if (is.null(p) || !.isfmt(info$fmt)) {
      hs$info <- info
      hsd[[s + 1]] <- hs
      wfdb_error("init: illegal format for signal %d, record %s\n", s, record)
      return(-2)
    }
    info$spf <- 1
    hs$skew <- 0
    hs$start <- 0
    pb <- .b(p)
    np <- length(pb)
    k <- 0L                         # (0-based index into p)
    # the optional "xSPF", ":SKEW" and "+START" suffixes
    repeat {
      k <- k + 1L
      if (k >= np) break
      if (pb[k + 1L] == 120L) {          # 'x'
        k <- k + 1L
        if (k < np) {
          info$spf <- cint32(strtol(pb, 10, k + 1L)[1L])
          if (info$spf < 1) info$spf <- 1
        }
      }
      if (k < np && pb[k + 1L] == 58L) {  # ':'
        k <- k + 1L
        if (k < np) {
          hs$skew <- cint32(strtol(pb, 10, k + 1L)[1L])
          if (hs$skew < 0) hs$skew <- 0
        }
      }
      if (k < np && pb[k + 1L] == 43L) {  # '+'
        k <- k + 1L
        if (k < np) {
          hs$start <- strtol(pb, 10, k + 1L)[1L]
          if (hs$start < 0) hs$start <- 0
        }
      }
      if (k >= np) break
    }
    if (info$spf > st$spfmax) st$spfmax <- info$spf
    hs$skew <- trunc(hs$skew / info$spf + 0.5)
    p <- strtok_next(tok, sep)
    info$gain <- if (!is.null(p)) strtod(p)[1L] else 0
    nobaseline <- TRUE
    units <- NULL
    if (!is.null(p)) {
      pb <- .b(p)
      np <- length(pb)
      k <- 0L
      while (k < np && !(pb[k + 1L] %in% c(40L, 47L))) k <- k + 1L
      if (k < np && pb[k + 1L] == 40L) {
        k <- k + 1L
        info$baseline <- cint32(strtol(pb, 10, k + 1L)[1L])
        nobaseline <- FALSE
      }
      while (k < np) {
        c <- pb[k + 1L]
        k <- k + 1L
        if (c == 47L && k < np) break
      }
      if (k < np) units <- .bs(pb[(k + 1L):min(np, k + WFDB_MAXUSL)])
    }
    info["units"] <- list(units)
    p <- strtok_next(tok, sep)
    if (!is.null(p)) {
      i <- cint32(strtol(p)[1L])
    } else if (st$legacy) {
      # WFDB-x: legacy mode (original behavior): inferred from the format, or
      # WFDB_DEFRES
      i <- switch(as.character(info$fmt), "80" = 8, "160" = 16, "212" = 12,
                  "310" = 10, "311" = 10, WFDB_DEFRES)
    } else {
      # WFDB-x: a missing ADC resolution is unspecified (0); the C library
      # inferred it from the format or assumed WFDB_DEFRES (12 bits).
      i <- 0
    }
    info$adcres <- i
    p <- strtok_next(tok, sep)
    info$adczero <- if (!is.null(p)) cint32(strtol(p)[1L]) else 0
    if (nobaseline) info$baseline <- info$adczero
    p <- strtok_next(tok, sep)
    info$initval <- if (!is.null(p)) cint32(strtol(p)[1L]) else info$adczero
    p <- strtok_next(tok, sep)
    if (!is.null(p)) {
      info$cksum <- cint32(strtol(p)[1L])
      info$nsamp <- ns
    } else {
      info$cksum <- 0
      info$nsamp <- 0
    }
    p <- strtok_next(tok, sep)
    info$bsize <- if (!is.null(p)) cint32(strtol(p)[1L]) else 0
    hs$info <- info
    hsd[[s + 1]] <- hs
    if (s && (info$group == hp$info$group &&
              (info$fmt != hp$info$fmt || info$bsize != hp$info$bsize))) {
      wfdb_error("init: error in specification of signal %d or %d\n", s - 1, s)
      return(-2)
    }
    p <- strtok_next(tok, "\n\r")
    if (!is.null(p)) {
      info["desc"] <- list(.btrunc(p, WFDB_MAXDSL))
    } else {
      info["desc"] <- list(.f("record %s, signal %d", record, s))
    }
    hs$info <- info
    hsd[[s + 1]] <- hs
    s <- s + 1
  }
  setgvmode(st$gvmode)
  s
}

.hsdfree <- function() .sig$hsd <- list()

# ---------------------------------------------------------------------------
# Opening and closing signals

.isigclose <- function() {
  st <- .sig
  if (!is.null(st$sbuf) && !st$in_msrec) {
    st$sbuf <- NULL
    st$sample_vflag <- 0
  }
  st$isd <- list()
  st$nisig <- 0
  st$framelen <- 0
  for (ig in st$igd) {
    if (!is.null(ig$flac)) flac_isclose(ig)
    if (!is.null(ig$fp)) wf_close(ig$fp)
  }
  st$igd <- list()
  st$nigroup <- 0
  st$bulk_layout <- NULL
  st$istime <- 0
  st$gvc <- 1
  st$ispfmax <- 1
  if (!is.null(st$hheader)) {
    wf_close(st$hheader)
    st$hheader <- NULL
  }
  if (st$nosig == 0 && length(st$hsd)) .hsdfree()
  invisible()
}

.osigclose <- function() {
  st <- .sig
  stat <- 0
  for (og in st$ogd[seq_len(st$nogroup)]) og$force_flush <- 1
  .wfdb_osflush()
  st$osd <- list()
  st$nosig <- 0
  g <- length(st$ogd)
  for (og in rev(st$ogd)) {
    g <- g - 1
    if (!is.null(og$fp)) {
      flac <- !is.null(og$flac)
      if (flac) {
        flac_osclose(og)
        og$nb <- 0
      }
      if (og$bsize && !flac && og$nb < og$obuflen) {
        buf <- og$buf
        if (length(buf) < og$obuflen) buf <- c(buf, raw(og$obuflen - length(buf)))
        buf[(og$nb + 1):og$obuflen] <- as.raw(0L)
        og$buf <- buf
        og$nb <- og$obuflen
      }
      if (og$nb > 0) {
        wf_write(og$fp, og$buf[seq_len(og$nb)])
        og$nb <- 0
      }
      if (og$fp$is_std) wf_flush(og$fp)
      errflag <- wf_ferror(og$fp)
      if (!og$fp$is_std) {
        if (wf_close(og$fp) != 0) errflag <- TRUE
        og$fp <- NULL
      }
      if (errflag) {
        wfdb_error("osigclose: write error in signal group %d\n", g)
        stat <- -4
      }
    }
  }
  st$ogd <- list()
  st$nogroup <- 0
  st$ostime <- 0
  if (!is.null(st$oheader)) {
    errflag <- wf_ferror(st$oheader)
    if (wf_close(st$oheader) != 0) errflag <- TRUE
    if (errflag) {
      wfdb_error("osigclose: write error in header file\n")
      stat <- -4
    }
    if (identical(st$outinfo, st$oheader)) st$outinfo <- NULL
    st$oheader <- NULL
  }
  if (st$nisig == 0 && length(st$hsd)) .hsdfree()
  stat
}

# ---------------------------------------------------------------------------
# Input positioning

# Skip nb bytes of input group ig through its buffer (as nb calls of r8).
.ig_skip <- function(ig, nb) {
  while (nb > 0 && ig$stat > 0) {
    if (ig$bp >= ig$be) {
      .ig_fill(ig)
      if (ig$stat <= 0) {
        ig$bp <- ig$bp + 1
        nb <- nb - 1
        break
      }
    }
    k <- min(nb, ig$be - ig$bp)
    ig$bp <- ig$bp + k
    nb <- nb - k
  }
  nb
}

.isgsetframe <- function(g, t) {
  st <- .sig
  trem <- 0
  d <- 1
  # (C reads igd[g] even if g is not a signal group number: undefined
  # behavior, here the group number is then reported as incorrect)
  if (st$nigroup < 2 && st$istime == t && st$gvc == st$ispfmax &&
      g >= 0 && g < length(st$igd) && st$igd[[g + 1]]$start == 0) return(0)
  s <- 0
  while (s < st$nisig && g != st$isd[[s + 1]]$info$group) s <- s + 1
  if (s == st$nisig) {
    wfdb_error("isgsettime: incorrect signal group number %d\n", g)
    return(-2)
  }
  if (st$in_msrec) {
    if (t >= st$msnsamples) {
      wfdb_error("isigsettime: improper seek on signal group %d\n", g)
      return(-1)
    }
    tseg <- st$segp
    seg <- st$segarray
    while (t < seg[[tseg + 1]]$samp0) tseg <- tseg - 1
    while (t >= seg[[tseg + 1]]$samp0 + seg[[tseg + 1]]$nsamp && tseg < st$segend)
      tseg <- tseg + 1
    if (st$segp != tseg) {
      st$segp <- tseg
      if (.isigopen(seg[[tseg + 1]]$recname, st$nvsig)$nsig <= 0) {
        wfdb_error("isigsettime: can't open segment %s\n", seg[[tseg + 1]]$recname)
        return(-1)
      }
      for (h in seq_len(max(st$nigroup - 1, 0))) {
        i <- .isgsetframe(h, t)
        if (i) return(i)
      }
      if (g == 0) return(.isgsetframe(0, t))
      return(0)
    }
    t <- t - seg[[st$segp + 1]]$samp0
  }
  ig <- st$igd[[g + 1]]
  ig$initial_skip <- 0
  n <- 0
  nn <- 0
  while (s + n < st$nisig && st$isd[[s + n + 1]]$info$group == g) {
    nn <- nn + st$isd[[s + n + 1]]$info$spf
    n <- n + 1
  }
  clear_nsamp <- function(n) {
    while (n) {
      n <- n - 1
      st$isd[[s + n + 1]]$info$nsamp <- 0
    }
  }
  msamp0 <- function() if (st$in_msrec) st$segarray[[st$segp + 1]]$samp0 else 0
  fmt <- st$isd[[s + 1]]$info$fmt
  if (fmt == 0) {
    if (t < st$nsamples) {
      st$gvc <- st$ispfmax
      if (s == 0) st$istime <- t + msamp0()
      st$isd[[s + 1]]$info$nsamp <- st$nsamples - t
      ig$stat <- 1
      return(0)
    } else {
      if (s == 0) st$istime <- if (st$in_msrec) st$msnsamples else st$nsamples
      st$isd[[s + 1]]$info$nsamp <- 0
      return(-1)
    }
  } else if (fmt %in% c(508, 516, 524)) {
    if (flac_isseek(ig, t) < 0) {
      wfdb_error("isigsettime: improper seek on signal group %d\n", g)
      return(-1)
    }
    st$gvc <- st$ispfmax
    if (s == 0) st$istime <- t + msamp0()
    clear_nsamp(n)
    return(0)
  } else if (fmt %in% c(16, 61, 160)) {
    if (nn > UINT_MAX %/% 2) {
      wfdb_error("isigsettime: overflow in signal group %d\n", g)
      return(-1)
    }
    b <- 2 * nn
  } else if (fmt == 212) {
    if (nn > UINT_MAX %/% 3) {
      wfdb_error("isigsettime: overflow in signal group %d\n", g)
      return(-1)
    }
    ig$count <- 0
    if (nn %% 2 == 1 && t %% 2 == 1) {
      if (st$in_msrec) t <- t + st$segarray[[st$segp + 1]]$samp0
      i <- .isgsetframe(g, t - 1)
      if (i) return(i)
      for (j in seq_len(nn)) .r212(ig)
      st$istime <- st$istime + 1
      n <- 0
      while (s + n < st$nisig && st$isd[[s + n + 1]]$info$group == g) {
        st$isd[[s + n + 1]]$info$nsamp <- 0
        n <- n + 1
      }
      return(0)
    }
    b <- 3 * nn
    d <- 2
  } else if (fmt %in% c(310, 311)) {
    if (nn > UINT_MAX %/% 4) {
      wfdb_error("isigsettime: overflow in signal group %d\n", g)
      return(-1)
    }
    ig$count <- 0
    trem <- cmod(t, 3)
    if (nn %% 3 != 0 && trem != 0) {
      if (st$in_msrec) t <- t + st$segarray[[st$segp + 1]]$samp0
      i <- .isgsetframe(g, t - trem)
      if (i) return(i)
      rd <- if (fmt == 310) .r310 else .r311
      for (j in seq_len(nn * trem)) rd(ig)
      st$istime <- st$istime + trem
      n <- 0
      while (s + n < st$nisig && st$isd[[s + n + 1]]$info$group == g) {
        st$isd[[s + n + 1]]$info$nsamp <- 0
        n <- n + 1
      }
      return(0)
    }
    b <- 4 * nn
    d <- 3
  } else if (fmt == 24) {
    if (nn > UINT_MAX %/% 3) {
      wfdb_error("isigsettime: overflow in signal group %d\n", g)
      return(-1)
    }
    b <- 3 * nn
  } else if (fmt == 32) {
    if (nn > UINT_MAX %/% 4) {
      wfdb_error("isigsettime: overflow in signal group %d\n", g)
      return(-1)
    }
    b <- 4 * nn
  } else {
    b <- nn
  }
  if (b == 0 || t > cdiv(LONG_MAX, b) || cdiv(t * b, d) > (LONG_MAX - ig$start)) {
    wfdb_error("isigsettime: improper seek on signal group %d\n", g)
    return(-1)
  }
  if (ig$seek) {
    nb <- cdiv(t * b, d) + ig$start
    i <- if (ig$bsize != 0) ig$bsize else st$ibsize
    tt <- cdiv(nb, i)
    if (is.null(ig$fp) || wf_seek(ig$fp, tt * i, 0) != 0) {
      wfdb_error("isigsettime: improper seek on signal group %d\n", g)
      return(-1)
    }
    nb <- cmod(nb, i)
  } else {
    t0 <- st$istime - cdiv(ig$bp, b)
    t1 <- t0 + cdiv(ig$be, b)
    if (t < t0) {
      if (wf_seek(ig$fp, 0, 0) != 0) {
        wfdb_error("isigsettime: improper seek on signal group %d\n", g)
        return(-1)
      }
      nb <- cdiv(t * b, d) + ig$start
    } else if (t < t1) {
      ig$bp <- cdiv((t - t0) * b, d)
      return(0)
    } else {
      nb <- cdiv((t - t1) * b, d)
    }
    while (nb > ig$bsize && !wf_feof(ig$fp)) nb <- nb - length(wf_read(ig$fp, ig$bsize))
  }
  ig$bp <- 0
  ig$be <- 0
  ig$stat <- 1
  .ig_skip(ig, nb)
  if (ig$stat <= 0) return(-1)
  st$gvc <- st$ispfmax
  if (s == 0) st$istime <- t + msamp0()
  clear_nsamp(n)
  0
}

# getskewedframe(): read one frame (without deskewing).  vec: the frame
# vector to fill (its other elements are kept).  Returns list(stat, v).
.getskewedframe <- function(vec = NULL) {
  st <- .sig
  stat <- st$nisig
  if (stat == 0) return(list(stat = if (st$nvsig > 0) -1 else 0, v = vec))
  nisig <- st$nisig
  isd <- st$isd
  igd <- st$igd
  if (st$istime == 0) {
    for (is in isd) is$samp <- is$info$initval
  }
  g <- st$nigroup
  while (g) {
    g <- g - 1
    if (igd[[g + 1]]$initial_skip)
      .isgsetframe(g, if (st$in_msrec) st$segarray[[st$segp + 1]]$samp0 else 0)
  }
  tspf <- st$tspf
  need_sigmap <- st$need_sigmap
  if (length(vec) < tspf) vec <- c(vec, numeric(tspf - length(vec)))
  w <- if (need_sigmap) st$ovec else vec
  if (length(w) < st$framelen) w <- c(w, numeric(st$framelen - length(w)))
  vi <- 0
  pad <- bitwAnd(st$gvmode, WFDB_GVPAD) != 0
  for (s in seq_len(nisig) - 1) {
    is <- isd[[s + 1]]
    info <- is$info
    ig <- igd[[info$group + 1]]
    fmt <- info$fmt
    cks <- info$cksum
    inval <- .invalid_of(fmt)
    for (c in seq_len(info$spf)) {
      vi <- vi + 1
      if (fmt == 0) {
        v <- if (pad) is$samp else WFDB_INVALID_SAMPLE
        w[vi] <- v
        if (info$nsamp == 0) ig$stat <- -1
      } else if (fmt == 8) {
        v <- cint32(is$samp + .r8(ig))
        is$samp <- v
        w[vi] <- v
      } else {
        v <- switch(as.character(fmt),
                    "16" = .r16(ig), "212" = .r212(ig), "61" = .r61(ig),
                    "80" = .r80(ig), "160" = .r160(ig), "310" = .r310(ig),
                    "311" = .r311(ig), "24" = .r24(ig), "32" = .r32(ig),
                    flac_getsamp(ig))
        if (v == inval) {
          w[vi] <- if (pad) is$samp else WFDB_INVALID_SAMPLE
        } else {
          w[vi] <- v
          is$samp <- v
        }
      }
      if (ig$stat <= 0) {
        ig$count <- 0
        if (ig$stat == -2) {
          stat <- -3
        } else if (info$nsamp > 0) {
          wfdb_error("getvec: unexpected EOF in signal %d\n", s)
          stat <- -3
        } else if (st$in_msrec && !is.null(st$segarray) && st$segp < st$segend) {
          st$segp <- st$segp + 1
          if (.isigopen(st$segarray[[st$segp + 1]]$recname, st$nvsig)$nsig <= 0) {
            wfdb_error("getvec: error opening segment %s\n",
                       st$segarray[[st$segp + 1]]$recname)
            return(list(stat = -3, v = if (need_sigmap) vec else w))
          } else {
            st$istime <- st$segarray[[st$segp + 1]]$samp0
            return(.getskewedframe(vec))
          }
        } else {
          stat <- -1
        }
      }
      cks <- cks - v
    }
    info$cksum <- cint32(cks)
    if (info$nsamp >= 0) {
      info$nsamp <- info$nsamp - 1
      if (info$nsamp == 0 && (info$cksum %% 65536) != 0 && !st$in_msrec &&
          !st$isedf && fmt != 0) {
        # WFDB-x: not printed during a high-level read (which warns
        # instead), but recorded for wfdberror
        pr <- .wfdb_io$error_print
        if (st$cksum_quiet) .wfdb_io$error_print <- FALSE
        wfdb_error("getvec: checksum error in signal %d\n", s)
        .wfdb_io$error_print <- pr
        stat <- -4
      }
    }
    is$info <- info
  }
  if (need_sigmap) {
    st$ovec <- w
    vec[seq_len(tspf)] <- .sigmap(w)
  } else {
    vec <- w
    if (st$framelen < tspf) vec[(st$framelen + 1):tspf] <- WFDB_INVALID_SAMPLE
  }
  list(stat = stat, v = vec)
}

.meansamp <- function(sv, n) {
  sv <- sv[seq_len(n)]
  if (any(sv == WFDB_INVALID_SAMPLE)) return(WFDB_INVALID_SAMPLE)
  total <- n %/% 2 + sum(sv)
  neg <- if (total < 0) 1 else 0
  if (bitwAnd(n, n - 1) != 0) return(cdiv(total + neg, n) - neg)
  repeat {
    n <- n %/% 2
    if (n == 0) break
    total <- cdiv(total - (if (total < 0) 1 else 0), 2)
  }
  total
}

# getframe() with deskewing.  Returns list(stat, v).
.getframe <- function(vector) {
  st <- .sig
  stat <- -1
  if (!is.null(st$dsbuf)) {
    tspf <- st$tspf
    dsbuf <- st$dsbuf
    st$dsbuf <- NULL
    if (st$dsbi < 0) {
      i <- 0
      while (i < st$dsblen) {
        r <- .getskewedframe(dsbuf[i + seq_len(tspf)])
        stat <- r$stat
        if (length(r$v) >= tspf) dsbuf[i + seq_len(tspf)] <- r$v[seq_len(tspf)]
        if (stat < 0) break
        i <- i + tspf
      }
      st$dsbi <- 0
    } else {
      r <- .getskewedframe(dsbuf[st$dsbi + seq_len(tspf)])
      stat <- r$stat
      if (length(r$v) >= tspf) dsbuf[st$dsbi + seq_len(tspf)] <- r$v[seq_len(tspf)]
      st$dsbi <- st$dsbi + tspf
      if (st$dsbi >= st$dsblen) st$dsbi <- 0
    }
    st$dsbuf <- dsbuf
    j <- 0
    for (vs in st$vsd[seq_len(st$nvsig)]) {
      i <- j + st$dsbi + vs$skew * tspf
      if (i >= st$dsblen) i <- i %% st$dsblen
      k <- vs$info$spf
      vector[j + seq_len(k)] <- dsbuf[i + seq_len(k)]
      j <- j + k
    }
  } else {
    r <- .getskewedframe(vector)
    stat <- r$stat
    if (!is.null(r$v)) vector <- r$v
  }
  st$istime <- st$istime + 1
  list(stat = stat, v = vector)
}

.rgetvec <- function(vector) {
  st <- .sig
  if (st$ispfmax < 2) return(.getframe(vector))
  if (bitwAnd(st$gvmode, WFDB_HIGHRES) != WFDB_HIGHRES) {
    r <- .getframe(st$tvector)
    st$tvector <- r$v
    stat <- st$rgetvec_stat <- r$stat
    tv <- r$v
    tp <- 0
    for (s in seq_len(st$nvsig)) {
      sf <- st$vsd[[s]]$info$spf
      vector[s] <- .meansamp(tv[tp + seq_len(sf)], sf)
      tp <- tp + sf
    }
  } else {
    if (st$gvc >= st$ispfmax) {
      r <- .getframe(st$tvector)
      st$tvector <- r$v
      st$rgetvec_stat <- r$stat
      st$gvc <- 0
    }
    stat <- st$rgetvec_stat
    tv <- st$tvector
    tp <- 0
    gvc <- st$gvc
    ispfmax <- st$ispfmax
    for (s in seq_len(st$nvsig)) {
      vs <- st$vsd[[s]]
      sf <- vs$info$spf
      if (gvc == 0) {
        vs$gvindex <- 0
        vs$gvcount <- -ispfmax
      } else {
        vs$gvcount <- vs$gvcount + sf
        if (vs$gvcount >= 0) {
          vs$gvindex <- vs$gvindex + 1
          vs$gvcount <- vs$gvcount - ispfmax
        }
      }
      vector[s] <- tv[tp + vs$gvindex + 1]
      tp <- tp + sf
    }
    st$gvc <- gvc + 1
  }
  list(stat = stat, v = vector)
}

# ---------------------------------------------------------------------------
# Public functions: opening signals

#' Open input signals of a record.  r <- isigopen(record, nsig): if nsig is
#' <= 0, no signals are opened, r$nsig is the number of signals in the
#' record and r$si the siginfo lists of up to -nsig of them; otherwise up
#' to nsig signals are opened, and r$nsig is the number of signals opened
#' (negative values: errors, as in C) and r$si their siginfo lists.
isigopen <- function(record, nsig = 0) .isigopen(record, nsig, TRUE)

.isigopen <- function(record, nsig, want_si = FALSE) {
  st <- .sig
  first_segment <- 0
  if (.first_is(record, 43L)) {
    record <- rawToChar(charToRaw(record)[-1L])
  } else {
    .isigclose()
  }
  record <- wfdb_striphea(record)
  if (!st$in_msrec) wfdb_setirec(record)
  navail <- .readheader(record)
  if (navail <= 0) {
    if (navail == 0 && st$segments) {
      st$in_msrec <- 1
      first_segment <- 1
      if (length(st$segarray)) {
        navail <- .readheader(st$segarray[[st$segp + 1]]$recname)
        if (navail >= 0) {
          if (st$msbtime == 0) st$msbtime <- st$btime
          if (st$msbdate == 0) st$msbdate <- st$bdate
        }
      }
      if (nsig <= 0) st$in_msrec <- 0
    }
    if (navail == 0 && nsig) wfdb_error("isigopen: record %s has no signals\n", record)
    if (navail <= 0) return(list(nsig = navail, si = list()))
  }
  if (nsig <= 0) {
    nsig <- -nsig
    if (navail < nsig) nsig <- navail
    si <- if (want_si) lapply(st$hsd[seq_len(nsig)], function(h) h$info) else list()
    st$in_msrec <- 0
    return(list(nsig = navail, si = si))
  }
  if (nsig > navail) nsig <- navail
  if (st$ibsize <= 0) st$ibsize <- .BUFSIZ
  nisig0 <- st$nisig
  nigroup0 <- st$nigroup
  new_isd <- list()
  new_igd <- list()
  si <- 0
  s <- 0
  hsd <- st$hsd
  while (si < navail && s < nsig) {
    hs <- hsd[[si + 1]]
    sj <- si + 1
    while (sj < navail && hsd[[sj + 1]]$info$group == hs$info$group) sj <- sj + 1
    if (sj - si > nsig - s) {
      si <- sj
      next
    }
    ig <- .igdata()
    if (hs$info$bsize < 0) {
      hs$info$bsize <- -hs$info$bsize
      hsd[[si + 1]]$info$bsize <- hs$info$bsize
      ig$bsize <- hs$info$bsize
      ig$seek <- 0
    } else {
      ig$bsize <- hs$info$bsize
      if (ig$bsize == 0) ig$bsize <- st$ibsize
      ig$seek <- 1
    }
    if (hs$info$fmt == 0) {
      ig$fp <- NULL
    } else {
      # WFDB-x: in the directory of the header
      ig$fp <- if (wfdbx_get_legacy()) wfdb_open(hs$info$fname, NULL, WFDB_READ) else
        .open_in(st$hdr_dir, NULL, hs$info$fname, record)
      if (is.null(ig$fp)) {
        si <- sj
        next
      }
    }
    if (.isflacfmt(hs$info$fmt)) {
      if (flac_isopen(ig, hsd[(si + 1):sj], sj - si) < 0) {
        wf_close(ig$fp)
        si <- sj
        next
      }
    }
    ig$bp <- 0
    ig$be <- 0
    ig$start <- hs$start
    ig$initial_skip <- if (ig$start > 0) 1 else 0
    ig$stat <- 1
    gnum <- nigroup0 + length(new_igd)
    while (si < sj && s < nsig) {
      info <- hs$info
      info$group <- gnum
      new_isd[[length(new_isd) + 1L]] <- .isdata(info, hs$skew)
      s <- s + 1
      si <- si + 1
      if (si < sj) hs <- hsd[[si + 1]]
    }
    new_igd[[length(new_igd) + 1L]] <- ig
    si <- sj
  }
  st$hsd <- hsd
  if (s == 0 && nsig) {
    wfdb_error("isigopen: none of the signals for record %s is readable\n", record)
  }
  spflimit <- INT_MAX - st$framelen
  for (is in new_isd) {
    spflimit <- spflimit - is$info$spf
    if (spflimit < 0) {
      wfdb_error("isigopen: total frame size too large in record %s\n", record)
      .isigclose()
      return(list(nsig = -3, si = list()))
    }
  }
  st$isd <- c(st$isd[seq_len(nisig0)], new_isd)
  st$igd <- c(st$igd[seq_len(nigroup0)], new_igd)
  st$bulk_layout <- NULL
  for (is in new_isd) {
    is$samp <- is$info$initval
    if (st$ispfmax < is$info$spf) st$ispfmax <- is$info$spf
    if (st$skewmax < is$skew) st$skewmax <- is$skew
  }
  sio <- if (want_si) lapply(new_isd, function(is) is$info) else list()
  st$nisig <- st$nisig + s
  st$nigroup <- st$nigroup + length(new_igd)
  if (.sigmap_init(first_segment) < 0) {
    .isigclose()
    return(list(nsig = -3, si = list()))
  }
  st$spfmax <- st$ispfmax
  setgvmode(st$gvmode)
  st$gvc <- st$ispfmax
  st$framelen <- 0
  for (is in st$isd[seq_len(st$nisig)]) st$framelen <- st$framelen + is$info$spf
  if (st$tspf > st$tuvlen) {
    st$tvector <- numeric(st$tspf)
    st$uvector <- numeric(st$tspf)
    st$vvector <- numeric(st$tspf)
    st$tuvlen <- st$tspf
  }
  if (length(st$gvec) < max(st$tspf, st$nvsig)) st$gvec <- numeric(max(st$tspf, st$nvsig))
  if (st$skewmax != 0 && (!st$in_msrec || is.null(st$dsbuf))) {
    if (st$tspf > INT_MAX %/% (st$skewmax + 1)) {
      wfdb_error("isigopen: maximum skew too large in record %s\n", record)
      .isigclose()
      return(list(nsig = -3, si = list()))
    }
    st$dsbi <- -1
    st$dsblen <- st$tspf * (st$skewmax + 1)
    st$dsbuf <- numeric(st$dsblen)
  }
  list(nsig = s, si = sio)
}

# WFDB-x: an output signal file is never one of the input files.  In normal
# mode, .openosig refuses to create (and so to truncate) an output signal
# file that is the same file as a signal file of the open input record: a
# signal file open for input, or a signal file of any segment of the open
# multi-segment record (read from the segment's header; segments are opened
# later, as they are reached).  "The same file" is decided by the files, not
# by their names.  Base R has no device and inode numbers (file.info() does
# not report them), so: the same path once links and relative components
# are resolved (normalizePath; case-insensitive on MS-Windows), or else, on
# POSIX systems, for files of equal size and modification time only (other
# hard links of the same file), the device and inode numbers given by the
# stat program (GNU "stat -L -c", or BSD "stat -L -f").  Decided by Reza
# Sameni, Oct 2026: e.g., "xform -i vlay -o fmt16", fmt16 being a segment of
# vlay, truncated fmt16.dat while reading it, with a platform-dependent
# result and the input destroyed.  Legacy mode: no check (the original
# behavior).  The behavior is that of the other implementations (device and
# inode numbers).

# The identity of an existing local file: list(path (normalized), size,
# mtime), or NULL if it does not exist (or is a directory).
.file_key <- function(path) {
  if (is.null(path) || !file.exists(path) || dir.exists(path)) return(NULL)
  fi <- file.info(path, extra_cols = FALSE)
  np <- normalizePath(path, winslash = "/", mustWork = FALSE)
  if (.Platform$OS.type == "windows") np <- tolower(np)
  list(path = path, norm = np, size = fi$size, mtime = as.numeric(fi$mtime))
}

# Device and inode numbers of a file ("dev:ino"), from the stat program, or
# NA.
.file_inode <- function(path) {
  for (fmt in list(c("-L", "-c", "%d:%i"), c("-L", "-f", "%d:%i"))) {
    r <- tryCatch(suppressWarnings(system2("stat", c(fmt, shell_quote(path)), stdout = TRUE,
                                           stderr = FALSE)),
                  error = function(e) character(0))
    if (length(r) == 1L && grepl("^[0-9]+:[0-9]+$", r)) return(r)
  }
  NA_character_
}

.same_file <- function(a, b) {
  if (is.null(a) || is.null(b)) return(FALSE)
  if (identical(a$norm, b$norm)) return(TRUE)
  if (.Platform$OS.type == "windows" || !identical(a$size, b$size) ||
      !identical(a$mtime, b$mtime)) return(FALSE)
  ia <- .file_inode(a$path)
  !is.na(ia) && identical(ia, .file_inode(b$path))
}

# The identity (.file_key) of the open local WFDB_FILE f (not a standard
# stream, not a remote file), or NULL.
.open_file_key <- function(f) {
  if (is.null(f) || f$type != WFDB_LOCAL || f$is_std || is.null(f$con)) return(NULL)
  .file_key(f$name)
}

# TRUE if one of the signal files named in the header of segment seg (of the
# open multi-segment record) is the file of key k.  The header and the
# signal files are located as isigopen locates them in normal mode; one
# that cannot be found (or is at a URL) is not k.  No message.
.segment_has_file <- function(seg, k) {
  st <- .sig
  if (identical(seg, "~") || !.in_header_dir(seg) ||
      (!is.null(st$msrec_dir) && .is_url(st$msrec_dir))) return(FALSE)
  hf <- if (!is.null(st$msrec_name)) .open_in(st$msrec_dir, "hea", seg, st$msrec_name) else
    wfdb_open("hea", seg, WFDB_READ)
  if (is.null(hf)) return(FALSE)
  on.exit(wf_close(hf))
  d <- if (hf$type == WFDB_LOCAL && !hf$is_std) .dirname(.wfdb_io$wfdb_filename) else NULL
  nsig <- -1
  repeat {
    line <- wf_getline(hf)
    if (length(line) == 0L) break
    tok <- strsplit(rawToChar(line[line != as.raw(0L)]), "[ \t\n\r]+", useBytes = TRUE)[[1L]]
    tok <- tok[nzchar(tok)]
    if (length(tok) == 0L || startsWith(tok[1L], "#")) next
    if (nsig < 0) {                       # the record line
      if (grepl("/", tok[1L], fixed = TRUE) || length(tok) < 2L) break
      nsig <- strtol(tok[2L])[1L]
      if (nsig <= 0) break
      next
    }
    nsig <- nsig - 1                      # a signal line: file name, format, ...
    name <- tok[1L]
    if (length(tok) >= 2L && strtol(tok[2L])[1L] != 0 && name != "-" &&
        .in_header_dir(name) && !is.null(d) && !.is_url(d)) {
      sf <- .open_in(d, NULL, name, seg)
      if (!is.null(sf)) {
        found <- .same_file(.open_file_key(sf), k)
        wf_close(sf)
        if (found) return(TRUE)
      }
    }
    if (nsig == 0) break
  }
  FALSE
}

# TRUE if the output signal file fname (as named in an output signal
# specification, created by wfdb_open(fname, NULL, WFDB_WRITE)) exists and
# is one of the signal files of the open input record (see above).
.is_input_file <- function(fname) {
  st <- .sig
  k <- .file_key(.output_file(fname))
  if (is.null(k)) return(FALSE)        # it does not exist: not an input file
  for (g in seq_len(min(st$nigroup, length(st$igd))))
    if (.same_file(.open_file_key(st$igd[[g]]$fp), k)) return(TRUE)
  if (st$in_msrec && length(st$segarray)) {
    for (sg in st$segarray[seq_len(st$segend + 1)])
      if (.segment_has_file(sg$recname, k)) return(TRUE)
  }
  FALSE
}

.openosig <- function(func, si_in, nsig, want_si = FALSE) {
  st <- .sig
  if (st$obsize <= 0) st$obsize <- .BUFSIZ
  ga <- st$nogroup
  while (length(st$ogd) < st$nogroup + si_in[[nsig]]$group + 1)
    st$ogd[[length(st$ogd) + 1L]] <- .ogdata()
  op <- NULL
  si_out <- list()
  for (s in seq_len(nsig) - 1) {
    sin <- si_in[[s + 1]]
    info <- sin
    if (info$spf < 1) info$spf <- 1
    info$cksum <- 0
    info$nsamp <- 0
    info$group <- info$group + ga
    os <- .osdata(info)
    st$osd[[length(st$osd) + 1L]] <- os
    st$nosig <- st$nosig + 1
    if (want_si) si_out[[length(si_out) + 1L]] <- os$info
    if (s == 0 || os$info$group != op$info$group) {
      og <- st$ogd[[os$info$group + 1]]
      og$bsize <- os$info$bsize
      if (.isflacfmt(os$info$fmt)) {
        ns <- 1
        while (s + ns < nsig && si_in[[s + ns + 1]]$group == sin$group) ns <- ns + 1
        if (flac_osinit(og, si_in[(s + 1):(s + ns)], ns) < 0) {
          .osigclose()
          return(list(stat = -3, si = si_out))
        }
      }
      og$obuflen <- if (og$bsize) og$bsize else st$obsize
      og$buf <- raw(0)
      og$nb <- 0
      if (os$info$fmt == 0) {
        if (is.null(os$info$fname) || identical(os$info$fname, "~")) {
          og$fp <- NULL
        } else {
          os$info$fmt <- 16
        }
      }
      if (os$info$fmt != 0) {
        # WFDB-x: never an input file (see .is_input_file)
        if (!wfdbx_get_legacy() && .is_input_file(os$info$fname)) {
          wfdb_error("%s: output file %s is also an input file\n", func, os$info$fname)
          .osigclose()
          return(list(stat = -3, si = si_out))
        }
        og$fp <- wfdb_open(os$info$fname, NULL, WFDB_WRITE)
        if (is.null(og$fp)) {
          wfdb_error("%s: can't open %s\n", func, os$info$fname)
          .osigclose()
          return(list(stat = -3, si = si_out))
        }
      }
      if (.isflacfmt(os$info$fmt)) {
        if (flac_osopen(og) < 0) {
          .osigclose()
          return(list(stat = -3, si = si_out))
        }
      }
      st$nogroup <- st$nogroup + 1
    } else {
      if (os$info$fmt != op$info$fmt || os$info$bsize != op$info$bsize) {
        wfdb_error("%s: error in specification of signal %d or %d\n", func, s - 1, s)
        return(list(stat = -2, si = si_out))
      }
    }
    op <- os
  }
  list(stat = nsig, si = si_out)
}

#' Open output signals as specified by the header of an existing record.
#' Returns list(nsig = status or number of signals, si = their siginfo).
osigopen <- function(record, nsig) {
  if (.first_is(record, 43L)) {
    record <- rawToChar(charToRaw(record)[-1L])
  } else {
    .osigclose()
  }
  record <- wfdb_striphea(record)
  n <- .readheader(record)
  if (n < 0) return(list(nsig = n, si = list()))
  if (n < nsig) {
    wfdb_error("osigopen: record %s has fewer signals than needed\n", record)
    return(list(nsig = -3, si = list()))
  }
  hsi <- lapply(.sig$hsd[seq_len(nsig)], function(h) h$info)
  r <- .openosig("osigopen", hsi, nsig, TRUE)
  list(nsig = r$stat, si = r$si)
}

# Normalize a siginfo list given by a caller (strings as character).
.norm_si <- function(si) {
  base <- siginfo()
  for (nm in names(si)) base[nm] <- list(si[[nm]])
  for (nm in c("fname", "desc", "units")) base[nm] <- list(.cs(base[[nm]]))
  base
}

#' Open output signals as specified by a list of siginfo lists (siarray);
#' returns the number of signals opened, or a negative error code.
osigfopen <- function(siarray, nsig = length(siarray)) {
  st <- .sig
  stat <- .osigclose()
  if (!length(siarray) || nsig == 0) return(stat)
  if (st$obsize <= 0) st$obsize <- .BUFSIZ
  siarray <- lapply(siarray[seq_len(nsig)], .norm_si)
  for (s in seq_len(nsig) - 1) {
    si <- siarray[[s + 1]]
    # (200: the limit on the length of the names, as in C)
    if (.nb(si$fname) + .nb(si$desc) > 200 || si$bsize < 0 || !.isfmt(si$fmt)) {
      wfdb_error("osigfopen: error in specification of signal %d\n", s)
      return(-2)
    }
    if (s) prev <- siarray[[s]]
    if (!((s == 0 && si$group == 0) ||
          (s && si$group == prev$group && identical(si$fname, prev$fname)) ||
          (s && si$group == prev$group + 1 && !identical(si$fname, prev$fname)))) {
      wfdb_error("osigfopen: incorrect file name or group for signal %d\n", s)
      return(-2)
    }
  }
  .openosig("osigfopen", siarray, nsig)$stat
}

#' The number of the input signal named (or numbered) p, or -1.
findsig <- function(p) {
  st <- .sig
  p <- as.character(p)
  b <- .b(p)
  if (all(b >= 48L & b <= 57L)) {
    s <- cint32(strtol(b)[1L])
    if (s < st$nisig || s < st$nvsig) return(s)
  }
  lst <- if (st$need_sigmap) st$vsd[seq_len(st$nvsig)] else st$isd[seq_len(st$nisig)]
  for (s in seq_along(lst)) {
    q <- lst[[s]]$info$desc
    if (!is.null(q) && identical(q, p)) return(s - 1)
  }
  -1
}

#' The number of samples per signal returned by getvec per frame.
getspf <- function() {
  st <- .sig
  if (st$sfreq != st$ffreq) trunc(st$sfreq / st$ffreq + 0.5) else 1
}

#' Set the getvec mode (WFDB_LOWRES, WFDB_HIGHRES, WFDB_GVPAD; < 0: from
#' $WFDBGVMODE).
setgvmode <- function(mode) {
  st <- .sig
  if (mode < 0) {
    p <- cgetenv("WFDBGVMODE")
    mode <- if (!is.null(p)) cint32(strtol(p)[1L]) else .DEFWFDBGVMODE
  }
  st$gvmode <- as.numeric(bitwAnd(mode, bitwOr(WFDB_HIGHRES, WFDB_GVPAD)))
  if (bitwAnd(mode, WFDB_HIGHRES) == WFDB_HIGHRES) {
    if (st$spfmax == 0) st$spfmax <- 1
    st$sfreq <- st$ffreq * st$spfmax
  } else {
    st$sfreq <- st$ffreq
  }
  invisible()
}

getgvmode <- function() .sig$gvmode

#' Set the sampling frequency at which getvec returns samples.
setifreq <- function(f) {
  st <- .sig
  g <- st$sfreq
  if (g <= 0) {
    st$ifreq <- 0
    if (st$nisig > 0 && !st$legacy)   # WFDB-x: the frequency is unspecified
      wfdb_error("setifreq: sampling frequency is not specified\n")
    else
      wfdb_error("setifreq: no open input record\n")
    return(-1)
  }
  if (f > 0) {
    n <- max(st$nvsig, 1)
    st$gv0 <- numeric(max(n, st$tspf))
    st$gv1 <- numeric(max(n, st$tspf))
    st$ifreq <- f
    setafreq(f)
    repeat {
      error <- f - g
      if (!(error > 0.005 || error < -0.005)) break
      if (f > g) f <- f - g else g <- g - f
    }
    st$mticks <- trunc(st$sfreq / f + 0.5)
    st$nticks <- trunc(st$ifreq / f + 0.5)
    st$mnticks <- st$mticks * st$nticks
    st$gvtime <- 0
    r <- .rgetvec(st$gv0)
    st$gv0 <- r$v
    r <- .rgetvec(st$gv1)
    st$gv1 <- r$v
    st$rgvstat <- r$stat
    st$rgvtime <- st$nticks
    return(0)
  }
  st$ifreq <- 0
  wfdb_error("setifreq: improper frequency %g (must be > 0)\n", f)
  -1
}

getifreq <- function() {
  st <- .sig
  if (st$ifreq > 0) st$ifreq else st$sfreq
}

# getvec() on a vector: list(stat, v).
.getvec <- function(vector) {
  st <- .sig
  if (st$ifreq == 0 || st$ifreq == st$sfreq) return(.rgetvec(vector))
  if (st$rgvtime > st$mnticks) {
    st$rgvtime <- st$rgvtime - st$mnticks
    st$gvtime <- st$gvtime - st$mnticks
  }
  nsig <- max(st$nvsig, st$nisig)
  gv0 <- st$gv0
  gv1 <- st$gv1
  while (st$gvtime > st$rgvtime) {
    gv0[seq_len(nsig)] <- gv1[seq_len(nsig)]
    r <- .rgetvec(gv1)
    gv1 <- r$v
    st$rgvstat <- r$stat
    st$rgvtime <- st$rgvtime + st$nticks
  }
  nt <- st$nticks
  gm <- cmod(st$gvtime, nt)
  i <- seq_len(nsig)
  if (length(vector) < nsig) vector <- c(vector, numeric(nsig - length(vector)))
  vector[i] <- cint32(gv0[i] + cdiv(gm * (gv1[i] - gv0[i]), nt))
  gv0[i] <- gv1[i]
  st$gv0 <- gv0
  st$gv1 <- gv1
  st$gvtime <- st$gvtime + st$mticks
  list(stat = st$rgvstat, v = vector)
}

#' Read a sample from each input signal: list(stat, v), stat as in C (the
#' number of signals, 0 or -1 at the end, < -1 on errors), v the sample
#' vector.
getvec <- function() {
  st <- .sig
  r <- .getvec(st$gvec)
  st$gvec <- r$v
  nsig <- max(st$nvsig, st$nisig)
  list(stat = r$stat, v = r$v[seq_len(nsig)])
}

#' Read a complete frame (all samples of every signal): list(stat, v).
getframe <- function() {
  st <- .sig
  r <- .getframe(st$gvec)
  st$gvec <- r$v
  list(stat = r$stat, v = r$v[seq_len(st$tspf)])
}

#' Write a sample to each output signal (a frame: spf samples of each signal
#' with spf > 1).  Returns the number of output signals, 0 if a format 8
#' difference was clipped, or -1 on a write error.
putvec <- function(vector) {
  st <- .sig
  stat <- st$nosig
  vi <- 0
  for (s in seq_len(st$nosig) - 1) {
    os <- st$osd[[s + 1]]
    info <- os$info
    og <- st$ogd[[info$group + 1]]
    fmt <- info$fmt
    if (info$nsamp == 0) info$initval <- os$samp <- vector[vi + 1]
    info$nsamp <- info$nsamp + 1
    cks <- info$cksum
    for (c in seq_len(info$spf)) {
      vi <- vi + 1
      samp <- vector[vi]
      if (samp == WFDB_INVALID_SAMPLE) samp <- .invalid_of(fmt)
      if (fmt == 0) {
        os$samp <- samp
      } else if (fmt == 8) {
        # (a first difference, clipped to a signed byte)
        dif <- cint32(samp - os$samp)
        if (dif < -128) {
          dif <- -128
          stat <- 0
        } else if (dif > 127) {
          dif <- 127
          stat <- 0
        }
        os$samp <- cint32(os$samp + dif)
        .og_put(og, as.raw(dif %% 256))
      } else {
        switch(as.character(fmt),
               "212" = .w212(og, samp),
               "16" = .og_put(og, .w16b(samp)),
               "61" = .og_put(og, rev(.w16b(samp))),
               "80" = .og_put(og, as.raw((samp %% 256 + 128) %% 256)),
               "160" = .og_put(og, .w16b(samp %% 65536 + 32768)),
               "310" = .w310(og, samp),
               "311" = .w311(og, samp),
               "24" = .og_put(og, as.raw(c(samp %% 256, (samp %/% 256) %% 256,
                                         (samp %/% 65536) %% 256))),
               "32" = .og_put(og, as.raw(c(samp %% 256, (samp %/% 256) %% 256,
                                         (samp %/% 65536) %% 256,
                                         (samp %/% 16777216) %% 256))),
               {
                 if (flac_putsamp(samp, fmt, og) < 0) stat <- -1
               })
        os$samp <- samp
      }
      if (!is.null(og$fp) && wf_ferror(og$fp)) {
        wfdb_error("putvec: write error in signal %d\n", s)
        stat <- -1
      } else {
        cks <- cks + os$samp
      }
    }
    info$cksum <- cint32(cks)
    os$info <- info
  }
  st$ostime <- st$ostime + 1
  stat
}

#' Skip to sample number t in each input signal.
isigsettime <- function(t) {
  st <- .sig
  stat <- 0
  if (st$nisig == 0) return(0)
  if (st$ifreq <= 0) {
    if (!bitwAnd(st$gvmode, WFDB_HIGHRES) || st$ispfmax < 2) {
      curtime <- st$istime
    } else {
      curtime <- (st$istime - 1) * st$ispfmax + st$gvc
    }
    if (t == curtime) return(0)
  }
  for (g in seq_len(max(st$nigroup - 1, 0))) {
    stat <- isgsettime(g, t)
    if (stat < 0) break
  }
  if (stat == 0) stat <- isgsettime(0, t)
  stat
}

#' Skip to sample number t in input signal group g.
isgsettime <- function(g, t) {
  st <- .sig
  trem <- 0
  if (t < 0) {
    if (t < -WFDB_TIME_MAX) {
      wfdb_error("isigsettime: improper seek on signal group %d\n", g)
      return(-1)
    }
    t <- -t
  }
  if (st$ifreq > 0) {
    tt <- t * st$sfreq / st$ifreq
    if (tt > WFDB_TIME_MAX) {
      wfdb_error("isigsettime: improper seek on signal group %d\n", g)
      return(-1)
    }
    t <- trunc(tt)
  }
  if (bitwAnd(st$gvmode, WFDB_HIGHRES)) {
    trem <- cmod(t, st$ispfmax)
    t <- cdiv(t, st$ispfmax)
  }
  st$dsbi <- -1
  stat <- .isgsetframe(g, t)
  if (stat == 0 && g == 0) {
    while (trem > 0) {
      trem <- trem - 1
      r <- .rgetvec(st$uvector)
      st$uvector <- r$v
      if (r$stat < 0) {
        wfdb_error("isigsettime: improper seek on signal group %d\n", g)
        return(-1)
      }
    }
    if (st$ifreq > 0 && st$ifreq != st$sfreq) {
      st$gvtime <- 0
      r <- .rgetvec(st$gv0)
      st$gv0 <- r$v
      r <- .rgetvec(st$gv1)
      st$gv1 <- r$v
      st$rgvstat <- r$stat
      st$rgvtime <- st$nticks
    }
  }
  stat
}

#' The time of the next valid sample of signal s at or after t (-1 if
#' none, or an error status).
tnextvec <- function(s, t) {
  st <- .sig
  stat <- 0
  if (st$in_msrec && st$need_sigmap) {
    if (s >= st$nvsig) {
      wfdb_error("nextvect: illegal signal number %d\n", s)
      return(-1)
    }
    if (t != st$istime && isigsettime(t) < 0) return(-1)
    while (stat >= 0) {
      p <- st$vsd[[s + 1]]$info$desc
      seg <- st$segarray[[st$segp + 1]]
      tf <- seg$samp0 + seg$nsamp
      ss <- 0
      while (ss < st$nisig) {
        q <- st$isd[[ss + 1]]$info$desc
        if (!is.null(q) && identical(p, q)) break
        ss <- ss + 1
      }
      if (ss < st$nisig) {
        while (t <= tf) {
          r <- .getvec(st$vvector)
          st$vvector <- r$v
          stat <- r$stat
          if (stat <= 0) break
          if (r$v[s + 1] != WFDB_INVALID_SAMPLE) {
            isigsettime(t)
            return(t)
          }
          t <- t + 1
        }
        if (stat < 0) return(-1)
      }
      if (t != tf) {
        t <- tf
        stat <- isigsettime(t)
      }
    }
  } else {
    if (t != st$istime && isigsettime(t) < 0) return(-1)
    if (s >= st$nisig) {
      wfdb_error("nextvect: illegal signal number %d\n", s)
      return(-1)
    }
    repeat {
      r <- .getvec(st$vvector)
      st$vvector <- r$v
      stat <- r$stat
      if (stat <= 0) break
      if (r$v[s + 1] != WFDB_INVALID_SAMPLE) {
        isigsettime(t)
        return(t)
      }
      t <- t + 1
    }
  }
  stat
}

setibsize <- function(n) {
  st <- .sig
  if (st$nisig) {
    wfdb_error("setibsize: can't change buffer size after isigopen\n")
    return(-1)
  }
  if (n < 0) {
    wfdb_error("setibsize: illegal buffer size %d\n", n)
    return(-2)
  }
  if (n == 0) n <- .BUFSIZ
  st$ibsize <- n
  n
}

setobsize <- function(n) {
  st <- .sig
  if (st$nosig) {
    wfdb_error("setobsize: can't change buffer size after osig[f]open\n")
    return(-1)
  }
  if (n < 0) {
    wfdb_error("setobsize: illegal buffer size %d\n", n)
    return(-2)
  }
  if (n == 0) n <- .BUFSIZ
  st$obsize <- n
  n
}

# ---------------------------------------------------------------------------
# Header files

#' Create a header file for the open output signals.
newheader <- function(record) {
  st <- .sig
  record <- wfdb_striphea(record)
  osi <- lapply(st$osd[seq_len(st$nosig)], function(os) os$info)
  .setheader(record, osi, st$nosig)$stat
}

# First strtok() token of string s, and s as strtok leaves it (truncated
# at the end of the token).
.strtok_inplace <- function(s, delims) {
  b <- .b(s)
  dl <- .b(delims)
  n <- length(b)
  i <- 1L
  while (i <= n && b[i] %in% dl) i <- i + 1L
  if (i > n) return(list(tok = NULL, s = s))
  j <- i
  while (j <= n && !(b[j] %in% dl)) j <- j + 1L
  list(tok = .bs(b[i:(j - 1L)]), s = .bs(b[seq_len(j - 1L)]))
}

#' Create or rewrite a header file for record, given a list of siginfo
#' lists.  Returns 0 or -1.  (setheader in C modifies the units and desc
#' strings of the caller's siarray, cutting them at their first token;
#' .setheader() returns the modified array as $si.)
# A name as written into the header of record.  WFDB-x: outside legacy
# mode, names are written relative to the header's directory (where the
# reader looks for them): the directory part of record (up to and including
# its last '/') is removed from name when name begins with it.
.hea_name <- function(record, name) {
  if (wfdbx_get_legacy() || is.null(name)) return(name)
  rb <- charToRaw(record)
  k <- which(rb == as.raw(47L))
  if (!length(k)) return(name)
  d <- rb[seq_len(k[length(k)])]
  nb <- charToRaw(name)
  if (length(nb) >= length(d) && identical(nb[seq_along(d)], d))
    rawToChar(nb[-seq_along(d)]) else name
}

setheader <- function(record, siarray, nsig = length(siarray)) {
  .setheader(record, siarray, nsig)$stat
}

.setheader <- function(record, siarray, nsig = length(siarray)) {
  st <- .sig
  if (!is.null(st$oheader)) {
    wf_close(st$oheader)
    if (identical(st$outinfo, st$oheader)) st$outinfo <- NULL
    st$oheader <- NULL
  }
  record <- wfdb_striphea(record)
  if (wfdb_checkname(record, "record")) return(list(stat = -1, si = siarray))
  st$oheader <- wfdb_open("hea", record, WFDB_WRITE)
  if (is.null(st$oheader)) {
    wfdb_error("newheader: can't create header for record %s\n", record)
    return(list(stat = -1, si = siarray))
  }
  out <- list(csprintf("%s %d %.12g", .hea_name(record, record), nsig, st$ffreq))
  if ((st$cfreq > 0 && st$cfreq != st$ffreq) || st$bcount != 0) {
    out[[length(out) + 1L]] <- csprintf("/%.12g", st$cfreq)
    if (st$bcount != 0) out[[length(out) + 1L]] <- csprintf("(%.12g)", st$bcount)
  }
  out[[length(out) + 1L]] <- csprintf(" %d", if (nsig > 0) siarray[[1L]]$nsamp else 0)
  if (st$btime != 0 || st$bdate != 0) {
    if (st$btime == 0) {
      out[[length(out) + 1L]] <- charToRaw(" 0:00")
    } else if (st$btime %% 1000 == 0) {
      out[[length(out) + 1L]] <- csprintf(" %s", .ftimstr(st$btime, 1000))
    } else {
      out[[length(out) + 1L]] <- csprintf(" %s", .fmstimstr(st$btime, 1000))
    }
  }
  if (st$bdate) out[[length(out) + 1L]] <- charToRaw(datstr(st$bdate))
  out[[length(out) + 1L]] <- charToRaw("\r\n")
  for (s in seq_len(nsig) - 1) {
    si <- siarray[[s + 1]]
    out[[length(out) + 1L]] <- csprintf("%s %d", .hea_name(record, .cs(si$fname)), si$fmt)
    if (si$spf > 1) out[[length(out) + 1L]] <- csprintf("x%d", si$spf)
    if (s < length(st$osd) && st$osd[[s + 1]]$skew)
      out[[length(out) + 1L]] <- csprintf(":%d", st$osd[[s + 1]]$skew * si$spf)
    if (length(st$ogd) && s < length(st$osd) &&
        st$ogd[[st$osd[[s + 1]]$info$group + 1]]$start) {
      out[[length(out) + 1L]] <- csprintf("+%d", st$ogd[[st$osd[[s + 1]]$info$group + 1]]$start)
    } else if (st$prolog_bytes) {
      out[[length(out) + 1L]] <- csprintf("+%d", st$prolog_bytes)
    }
    out[[length(out) + 1L]] <- csprintf(" %.12g", si$gain)
    if (si$baseline != si$adczero) out[[length(out) + 1L]] <- csprintf("(%d)", si$baseline)
    units <- .cs(si$units)
    if (!is.null(units) && nzchar(units)) {
      r <- .strtok_inplace(units, " \t\n\r")
      si["units"] <- list(r$s)
      if (!is.null(r$tok)) out[[length(out) + 1L]] <- csprintf("/%s", r$tok)
    }
    out[[length(out) + 1L]] <- csprintf(" %d %d %d %d %d", si$adcres, si$adczero,
                                        si$initval, cint16(si$cksum), si$bsize)
    desc <- .cs(si$desc)
    if (!is.null(desc) && nzchar(desc)) {
      r <- .strtok_inplace(desc, "\n\r")
      si["desc"] <- list(r$s)
      if (!is.null(r$tok)) out[[length(out) + 1L]] <- csprintf(" %s", r$tok)
    }
    out[[length(out) + 1L]] <- charToRaw("\r\n")
    siarray[[s + 1]] <- si
  }
  wf_write(st$oheader, unlist(out, use.names = FALSE))
  st$prolog_bytes <- 0
  wf_flush(st$oheader)
  list(stat = 0, si = siarray)
}

#' The segments of the open multi-segment record (list of seginfo lists).
getseginfo <- function() {
  st <- .sig
  if (is.null(st$segarray)) list() else st$segarray
}

#' Create a header for a multi-segment record from its segment names
#' (character vector).
setmsheader <- function(record, segment_name, nsegments = length(segment_name)) {
  st <- .sig
  msfreq <- 0
  mscfreq <- 0
  msbcount <- 0
  nsig <- 0
  old_in_msrec <- st$in_msrec
  .isigclose()
  if (!is.null(st$oheader)) {
    wf_close(st$oheader)
    if (identical(st$outinfo, st$oheader)) st$outinfo <- NULL
    st$oheader <- NULL
  }
  record <- wfdb_striphea(record)
  if (wfdb_checkname(record, "record")) return(-1)
  if (nsegments < 1) {
    wfdb_error("setmsheader: record must contain at least one segment\n")
    return(-1)
  }
  ns <- numeric(nsegments)
  for (i in seq_len(nsegments)) {
    sn <- segment_name[[i]]
    if (.nb(sn) > WFDB_MAXRNL) {
      wfdb_error("setmsheader: `%s' is too long for a segment name in record %s\n",
                 sn, record)
      return(-2)
    }
    st$in_msrec <- 1
    st$nsamples <- 0
    st$user_segments <- TRUE          # WFDB-x: names given by the caller
    n <- .readheader(sn)
    st$user_segments <- FALSE
    st$in_msrec <- old_in_msrec
    if (n < 0) {
      wfdb_error("setmsheader: can't read segment %s header\n", sn)
      return(-3)
    }
    ns[i] <- st$nsamples
    if (ns[i] <= 0) {
      wfdb_error("setmsheader: length of segment %s must be specified\n", sn)
      return(-4)
    }
    if (i == 1) {
      nsig <- n
      msfreq <- st$ffreq
      mscfreq <- st$cfreq
      msbcount <- st$bcount
      st$msbtime <- st$btime
      st$msbdate <- st$bdate
      st$msnsamples <- ns[i]
    } else {
      if (nsig != n) {
        wfdb_error("setmsheader: incorrect number of signals in segment %s\n", sn)
        return(-4)
      }
      if (msfreq != st$ffreq) {
        wfdb_error("setmsheader: incorrect sampling frequency in segment %s\n", sn)
        return(-4)
      }
      st$msnsamples <- st$msnsamples + ns[i]
    }
  }
  st$oheader <- wfdb_open("hea", record, WFDB_WRITE)
  if (is.null(st$oheader)) {
    wfdb_error("setmsheader: can't create header file for record %s\n", record)
    return(-1)
  }
  out <- list(csprintf("%s/%d %d %.12g", .hea_name(record, record), nsegments, nsig, msfreq))
  if ((mscfreq > 0 && mscfreq != msfreq) || msbcount != 0) {
    out[[length(out) + 1L]] <- csprintf("/%.12g", mscfreq)
    if (msbcount != 0) out[[length(out) + 1L]] <- csprintf("(%.12g)", msbcount)
  }
  out[[length(out) + 1L]] <- csprintf(" %d", st$msnsamples)
  if (st$msbtime != 0 || st$msbdate != 0) {
    if (st$msbtime %% 1000 == 0) {
      out[[length(out) + 1L]] <- csprintf(" %s", .ftimstr(st$msbtime, 1000))
    } else {
      out[[length(out) + 1L]] <- csprintf(" %s", .fmstimstr(st$msbtime, 1000))
    }
  }
  if (st$msbdate) out[[length(out) + 1L]] <- charToRaw(datstr(st$msbdate))
  out[[length(out) + 1L]] <- charToRaw("\r\n")
  for (i in seq_len(nsegments))
    out[[length(out) + 1L]] <- csprintf("%s %d\r\n", .hea_name(record, segment_name[[i]]), ns[i])
  wf_write(st$oheader, unlist(out, use.names = FALSE))
  0
}

#' The skew (in frames) of input signal s.
wfdbgetskew <- function(s) {
  st <- .sig
  if (s < st$nvsig) st$vsd[[s + 1]]$skew else 0
}

wfdbsetiskew <- function(s, skew) {
  st <- .sig
  if (s < st$nvsig && skew >= 0 && st$tspf && skew < st$dsblen %/% st$tspf)
    st$vsd[[s + 1]]$skew <- skew
  invisible()
}

#' Set the skew to be written by setheader for output signal s.
wfdbsetskew <- function(s, skew) {
  st <- .sig
  if (s < st$nosig) st$osd[[s + 1]]$skew <- skew
  invisible()
}

#' The byte offset of sample 0 in the signal file of input signal s.
wfdbgetstart <- function(s) {
  st <- .sig
  if (s < st$nisig) {
    st$igd[[st$vsd[[s + 1]]$info$group + 1]]$start
  } else if (s == 0 && length(st$hsd)) {
    st$hsd[[1L]]$start
  } else {
    0
  }
}

#' Set the byte offset to be written by setheader for output signal s.
wfdbsetstart <- function(s, nbytes) {
  st <- .sig
  if (s < st$nosig) st$ogd[[st$osd[[s + 1]]$info$group + 1]]$start <- nbytes
  st$prolog_bytes <- nbytes
  invisible()
}

#' Write a prolog (raw or character) of size bytes to the signal file of
#' output signal s.
wfdbputprolog <- function(buf, size, s) {
  st <- .sig
  g <- st$osd[[s + 1]]$info$group
  b <- craw(buf)
  n <- wf_write(st$ogd[[g + 1]]$fp, b[seq_len(min(size, length(b)))])
  wfdbsetstart(s, n)
  if (n != size) wfdb_error("wfdbputprolog: only %d of %d bytes written\n", n, size)
  if (n == size) 0 else -1
}

# ---------------------------------------------------------------------------
# Info strings

#' Create (or open for appending) the .info file of a record.
setinfo <- function(record) {
  stat <- .wfdb_oinfoclose()
  if (is.null(record)) return(stat)
  record <- wfdb_striphea(record)
  if (wfdb_checkname(record, "record")) return(-1)
  .sig$outinfo <- wfdb_open("info", record, WFDB_APPEND)
  if (is.null(.sig$outinfo)) {
    wfdb_error("setinfo: can't create info file for record %s\n", record)
    return(-1)
  }
  0
}

#' Write an info string (character or raw) to the output header or .info
#' file.
putinfo <- function(s) {
  st <- .sig
  if (is.null(st$outinfo)) {
    if (!is.null(st$oheader)) {
      st$outinfo <- st$oheader
    } else {
      wfdb_error("putinfo: caller has not specified a record name\n")
      return(-1)
    }
  }
  wf_write(st$outinfo, c(charToRaw("#"), craw(s), charToRaw("\r\n")))
  wf_flush(st$outinfo)
  0
}

.strip_info <- function(b) {
  n <- length(b)
  if (n && b[n] == 10L) {
    n <- n - 1L
    if (n && b[n] == 13L) n <- n - 1L
  } else if (n && b[n] == 13L) {
    n <- n - 1L
  }
  b[seq_len(n)]
}

#' The next info string of a record (getinfo(record) starts with the first
#' one, getinfo(NULL) gives the next); NULL when there are no more.
getinfo <- function(record = NULL) {
  st <- .sig
  if (!is.null(record)) wfdb_freeinfo()
  if (is.null(st$pinfo)) {
    if (is.null(record)) {
      record <- wfdb_getirec()
      if (is.null(record)) {
        wfdb_error("getinfo: caller did not specify record name\n")
        return(NULL)
      }
    }
    st$ninfo <- 0
    st$info_i <- 0
    pinfo <- list()
    add <- function(b) pinfo[[length(pinfo) + 1L]] <<- .bs(.strip_info(b)[-1L])
    if (!st$isedf) {
      record <- wfdb_striphea(record)
      ifile <- wfdb_open("hea", record, WFDB_READ)
      if (!is.null(ifile)) {
        # (as in wfdb_getline(), the buffer keeps its previous contents
        # when the end of the file is reached)
        buf <- integer(0)
        repeat {
          line <- .hline(ifile)
          if (is.null(line)) break
          buf <- line
          if (!(length(buf) && buf[1L] == 35L)) break
        }
        repeat {
          line <- .hline(ifile)
          if (is.null(line)) break
          buf <- line
          if (length(buf) && buf[1L] == 35L) break
        }
        while (length(buf)) {
          if (buf[1L] == 35L) add(buf)
          line <- .hline(ifile)
          if (is.null(line)) break
          buf <- line
        }
        wf_close(ifile)
      }
    }
    ifile <- wfdb_open("info", record, WFDB_READ)
    if (!is.null(ifile)) {
      repeat {
        buf <- .hline(ifile)
        if (is.null(buf)) break
        if (length(buf) && buf[1L] == 35L) add(buf)
      }
      wf_close(ifile)
    }
    st$pinfo <- pinfo
    st$ninfo <- length(pinfo)
  }
  if (st$info_i < st$ninfo) {
    st$info_i <- st$info_i + 1
    return(st$pinfo[[st$info_i]])
  }
  NULL
}

# ---------------------------------------------------------------------------
# Sampling frequency, base time, time and date conversion

#' The sampling frequency of a record (NULL: of the open record); negative
#' values are errors.
sampfreq <- function(record = NULL) {
  st <- .sig
  record <- wfdb_striphea(record)
  if (!is.null(record)) {
    wfdb_setirec(record)
    setsampfreq(0)
    n <- .readheader(record)
    if (n < 0) return(n)
  }
  st$sfreq
}

#' Set the sampling frequency.
setsampfreq <- function(freq) {
  st <- .sig
  if (freq >= 0) {
    st$sfreq <- st$ffreq <- freq
    if (st$spfmax == 0) st$spfmax <- 1
    if (bitwAnd(st$gvmode, WFDB_HIGHRES) == WFDB_HIGHRES) st$sfreq <- st$sfreq * st$spfmax
    return(0)
  }
  wfdb_error("setsampfreq: sampling frequency must not be negative\n")
  -1
}

#' Set the base time and date ("hh:mm:ss dd/mm/yyyy"; NULL or "": now).
setbasetime <- function(string) {
  st <- .sig
  st$pdays <- -1
  if (is.null(string) || !nzchar(string)) {
    now <- as.POSIXlt(Sys.time())
    st$date_string <- .f("%02d/%02d/%d", now$mday, now$mon + 1, now$year + 1900)  # (struct tm)
    st$bdate <- strdat(st$date_string)
    st$time_string <- .f("%d:%d:%d", now$hour, now$min, trunc(now$sec))
    st$btime <- .fstrtim(st$time_string, 1000)
    return(0)
  }
  b <- .b(string)
  i <- 1L
  while (i <= length(b) && b[i] == 32L) i <- i + 1L
  b <- b[seq_along(b) >= i]
  k <- .bfind(b, 32L)
  if (k > 0L) {
    tpart <- b[seq_len(k - 1L)]
    dpart <- b[seq_along(b) > k]
  } else {
    tpart <- b
    dpart <- NULL
  }
  st$btime <- .fstrtim(tpart, 1000)
  st$bdate <- if (!is.null(dpart)) strdat(dpart) else 0
  if (st$btime == 0 && st$bdate == 0 && !(length(tpart) && tpart[1L] == 91L)) {
    wfdb_error("setbasetime: incorrect time format, '%s'\n", .bs(b))
    return(-1)
  }
  0
}

.ftimstr <- function(t, f) {
  st <- .sig
  p <- .fmstimstr(t, f)
  k <- regexpr(".", p, fixed = TRUE)
  if (k > 0) p <- substr(p, 1L, k - 1L)
  if (t <= 0 && (st$btime != 0 || st$bdate != 0)) p <- paste0(p, st$date_string, "]")
  p
}

.tfreq <- function() {
  st <- .sig
  # (legacy mode: 1 sample per second, as the C library did)
  if (st$ifreq > 0) st$ifreq else if (st$sfreq > 0) st$sfreq else if (st$legacy) 1 else 0
}

# WFDB-x: the time conversion functions need a sampling frequency; the C
# library used 1 sample per second when none was specified.  Without one,
# timstr and mstimstr report an error and return the time as a sample number
# ("s" followed by the number, a valid strtim argument), and strtim reports an
# error and returns 0 for time strings that need a frequency.
.nofreq_timstr <- function(fn, t) {
  wfdb_error("%s: sampling frequency is not specified\n", fn)
  .f("s%.0f", abs(t))
}

#' Whether strtim needs a sampling frequency to convert a time string (a
#' WFDB-x addition): 0 for sample numbers ("s..."), "e", "i", "o", and
#' counter values ("c...") when no counter frequency is defined; 1 otherwise.
wfdbx_time_needs_freq <- function(string) {
  b <- cbytes(string)
  i <- 1L
  n <- length(b)
  while (i <= n && b[i] %in% c(32L, 9L, 10L, 13L)) i <- i + 1L
  c <- if (i <= n) b[i] else 0L
  if (c %in% c(101L, 105L, 111L, 115L)) return(0L)     # 'e', 'i', 'o', 's'
  if (c == 99L) return(as.integer(.sig$cfreq > 0))      # 'c'
  1L
}

#' Convert a time in sample intervals to a string (hh:mm:ss); negative
#' times (and 0 if the base time is set) give the time of day.
timstr <- function(t) {
  f <- .tfreq()
  if (f <= 0) return(.nofreq_timstr("timstr", t))
  .ftimstr(t, f)
}

.fmstimstr <- function(t, f) {
  st <- .sig
  if (t > 0 || (st$btime == 0 && st$bdate == 0)) {
    if (t < 0) t <- -t
    sec <- trunc(t / f)
    msec <- trunc((t - sec * f) * 1000 / f + 0.5)
    if (msec == 1000) {
      msec <- 0
      sec <- sec + 1
    }
    t <- sec
    seconds <- t %% 60
    t <- t %/% 60
    minutes <- t %% 60
    hours <- t %/% 60
    if (hours > 0) {
      st$time_string <- .f("%2d:%02d:%02d.%03d", hours, minutes, seconds, msec)
    } else {
      st$time_string <- .f("   %2d:%02d.%03d", minutes, seconds, msec)
    }
  } else {
    tms <- st$btime - (t * 1000 / f)
    sec <- trunc(tms / 1000)
    msec <- trunc((tms - sec * 1000) + 0.5)
    if (msec == 1000) {
      msec <- 0
      sec <- sec + 1
    }
    t <- sec
    seconds <- cmod(t, 60)
    t <- cdiv(t, 60)
    minutes <- cmod(t, 60)
    t <- cdiv(t, 60)
    hours <- cmod(t, 24)
    days <- cdiv(t, 24)
    if (days != st$pdays) {
      if (st$bdate > 0) {
        datstr(days + st$bdate)
      } else if (days == 0) {
        st$date_string <- ""
      } else {
        st$date_string <- .f(" %d", days)
      }
      st$pdays <- days
    }
    st$time_string <- .f("[%02d:%02d:%02d.%03d%s]", hours, minutes, seconds, msec,
                         st$date_string)
  }
  st$time_string
}

#' Convert a time in sample intervals to a string with milliseconds.
mstimstr <- function(t) {
  f <- .tfreq()
  if (f <= 0) return(.nofreq_timstr("mstimstr", t))
  .fmstimstr(t, f)
}

getcfreq <- function() {
  st <- .sig
  if (st$cfreq > 0) st$cfreq else st$ffreq
}

setcfreq <- function(freq) {
  .sig$cfreq <- freq
  invisible()
}

getbasecount <- function() .sig$bcount

setbasecount <- function(counter) {
  .sig$bcount <- counter
  invisible()
}

# strtim() with frequency f; string: character or byte codes.
.fstrtim <- function(string, f) {
  st <- .sig
  b <- cbytes(string)
  i <- 1L
  n <- length(b)
  while (i <= n && b[i] %in% c(32L, 9L, 10L, 13L)) i <- i + 1L
  b <- b[seq_along(b) >= i]
  n <- length(b)
  c <- if (n) b[1L] else 0L
  if (c == 99L) {                                   # 'c'
    if (st$cfreq > 0) return(d2l((strtod(b, 2)[1L] - st$bcount) * f / st$cfreq))
    return(strtol(b, 10, 2)[1L])
  }
  if (c == 101L) {                                  # 'e'
    return((if (st$in_msrec) st$msnsamples else st$nsamples) *
             (if (bitwAnd(st$gvmode, WFDB_HIGHRES) == WFDB_HIGHRES) st$spfmax else 1))
  }
  if (c == 102L) return(d2l(strtol(b, 10, 2)[1L] * f / st$ffreq))       # 'f'
  if (c == 105L) {                                  # 'i'
    return(d2l(st$istime * (if (st$ifreq > 0) st$ifreq / st$sfreq else 1) *
                   (if (bitwAnd(st$gvmode, WFDB_HIGHRES) == WFDB_HIGHRES) st$ispfmax else 1)))
  }
  if (c == 111L) return(st$ostime)                  # 'o'
  if (c == 115L) return(strtol(b, 10, 2)[1L])       # 's'
  if (c == 91L) {                                   # '['
    b <- b[-1L]
    q <- .bfind(b, 93L)
    if (q == 0L) return(0)
    p <- .bfind(b, 32L)
    if (p == 0L || p > q) {
      days <- 0
    } else {
      r <- .bfind(b, 47L, p + 1L)
      if (r == 0L || r > q) {
        days <- strtol(b, 10, p + 1L)[1L]
      } else {
        days <- strdat(b[seq_along(b) > p]) - st$bdate
      }
    }
    x <- .fstrtim(b, 1000) - st$btime
    # (a WFDB_Time difference, which wraps around in C)
    if (x < -2^63) x <- x + 2^64 else if (x >= 2^63) x <- x - 2^64
    if (days > 0) x <- x + days * (24 * 60 * 60 * 1000)
    t <- d2l(x * f / 1000 + 0.5)
    return(if (t == -2^63) t else -t)     # (in C, -LONG_MIN is LONG_MIN)
  }
  x <- strtod(b)[1L]
  p <- .bfind(b, 58L)
  if (p == 0L) return(d2l(x * f + 0.5))
  y <- strtod(b, p + 1L)[1L]
  p2 <- .bfind(b, 58L, p + 1L)
  if (p2 == 0L) return(d2l((60 * x + y) * f + 0.5))
  z <- strtod(b, p2 + 1L)[1L]
  d2l((3600 * x + 60 * y + z) * f + 0.5)
}

#' Convert a time string to a time in sample intervals (negative values:
#' absolute times, i.e. times of day).
strtim <- function(string) {
  f <- .tfreq()
  if (f <= 0) {
    if (wfdbx_time_needs_freq(string)) {     # WFDB-x: no default frequency
      wfdb_error("strtim: sampling frequency is not specified\n")
      return(0)
    }
    f <- 1                                   # (not used)
  }
  .fstrtim(string, f) + 0                    # (+ 0: never -0)
}

# datstr() and strdat() use the algorithms of chapter 1 of Numerical
# Recipes (Press, Flannery, Teukolsky and Vetterling), as signal.c does;
# 2299161 is the Julian date of 15 October 1582, the first day of the
# Gregorian calendar.

#' Convert a Julian date to a string (" dd/mm/yyyy").
datstr <- function(date) {
  st <- .sig
  ymd <- .julian_ymd(date)
  st$date_string <- .f(" %02d/%02d/%d", ymd[3L], ymd[2L], ymd[1L])
  st$pdays <- -1
  st$date_string
}

# The calendar date c(year, month, day) of a Julian date, as datstr()
# converts it (WFDB-x: datstr's conversion, shared with the base_date of
# the high-level readers).
.julian_ymd <- function(date) {
  if (date >= 2299161) {                    # Gregorian calendar correction
    gcorr <- trunc(((date - 1867216) - 0.25) / 36524.25)
    date <- date + 1 + gcorr - trunc(0.25 * gcorr)
  }
  date <- date + 1524
  jy <- trunc(6680 + ((date - 2439870) - 122.1) / 365.25)
  jd <- trunc(365 * jy + (0.25 * jy))
  jm <- trunc((date - jd) / 30.6001)
  d <- date - jd - trunc(30.6001 * jm)
  m <- jm - 1
  if (m > 12) m <- m - 12
  y <- jy - 4715
  if (m > 2) y <- y - 1
  if (y <= 0) y <- y - 1
  c(y, m, d)
}

#' Convert a date string (dd/mm/yyyy) to a Julian date (0 if invalid).
strdat <- function(string) {
  b <- cbytes(string)
  mp <- .bfind(b, 47L)
  if (mp == 0L) return(0)
  yp <- .bfind(b, 47L, mp + 1L)
  if (yp == 0L) return(0)
  d <- cint32(strtol(b)[1L])
  if (d < 1 || d > 31) return(0)
  m <- cint32(strtol(b, 10, mp + 1L)[1L])
  if (m < 1 || m > 12) return(0)
  y <- cint32(strtol(b, 10, yp + 1L)[1L])
  if (y == 0) return(0)
  if (m > 2) {
    jy <- y
    jm <- m + 1
  } else {
    jy <- y - 1
    jm <- m + 13
  }
  date <- if (jy > 0) trunc(365.25 * jy) else -trunc(-365.25 * (jy + 0.25))
  date <- date + trunc(30.6001 * jm) + d + 1720995
  if (d + 31 * (m + 12 * y) >= (15 + 31 * (10 + 12 * 1582))) {   # from 15/10/1582
    gcorr <- trunc(0.01 * jy)
    date <- date + 2 - gcorr + trunc(0.25 * gcorr)
  }
  date
}

# ---------------------------------------------------------------------------
# Unit conversion

# WFDB-x: the unit conversion functions need the gain of the signal; the C
# library assumed WFDB_DEFGAIN (200 adu per physical unit) for uncalibrated
# signals (gain 0) and invalid signal numbers (with a baseline of 0), as
# legacy mode does.  Otherwise they report an error and return
# WFDB_INVALID_SAMPLE (aduphys returns NaN).  Returns c(gain, baseline); gain
# 0 means that the conversion is impossible.
.conversion_gain <- function(fn, s) {
  st <- .sig
  if (st$legacy) {         # WFDB-x: legacy mode (original behavior)
    if (s < 0 || s >= st$nvsig) return(c(WFDB_DEFGAIN, 0))
    info <- st$vsd[[s + 1]]$info
    return(c(if (info$gain == 0) WFDB_DEFGAIN else info$gain, info$baseline))
  }
  if (s < 0 || s >= st$nvsig) {        # (WFDB_Signal is unsigned in C)
    wfdb_error("%s: invalid signal number %.0f\n", fn, s %% 2^32)
    return(c(0, 0))
  }
  info <- st$vsd[[s + 1]]$info
  if (info$gain == 0) wfdb_error("%s: signal %.0f is uncalibrated\n", fn, s)
  c(info$gain, info$baseline)
}

#' ADC units to microvolts.
adumuv <- function(s, a) {
  g <- .conversion_gain("adumuv", s)[1L]
  if (g == 0) return(WFDB_INVALID_SAMPLE)
  x <- a * 1000 / g
  if (x >= 0) trunc(x + 0.5) else trunc(x - 0.5)
}

#' Microvolts to ADC units.
muvadu <- function(s, v) {
  g <- .conversion_gain("muvadu", s)[1L]
  if (g == 0) return(WFDB_INVALID_SAMPLE)
  x <- g * v * 0.001
  if (x >= 0) trunc(x + 0.5) else trunc(x - 0.5)
}

#' ADC units to physical units.
aduphys <- function(s, a) {
  gb <- .conversion_gain("aduphys", s)
  if (gb[1L] == 0) return(NaN)
  (a - gb[2L]) / gb[1L]
}

#' Physical units to ADC units.
physadu <- function(s, v) {
  gb <- .conversion_gain("physadu", s)
  if (gb[1L] == 0) return(WFDB_INVALID_SAMPLE)
  v <- v * gb[1L]
  if (v >= 0) cint32(trunc(v + 0.5) + gb[2L]) else cint32(trunc(v - 0.5) + gb[2L])
}

# ---------------------------------------------------------------------------
# sample(): buffered random access

#' The sample of signal s at time t (WFDB_INVALID_SAMPLE if unavailable;
#' see sample_valid()).
sample <- function(s, t) {
  st <- .sig
  nsig <- max(st$nvsig, st$nisig)
  if (is.null(st$sbuf)) {
    st$sbuf <- matrix(0, .BUFLN, max(nsig, 1))
    st$sample_tt <- -1
  }
  if (s < 0 || s >= nsig) {
    st$sample_vflag <- -1
    return(WFDB_INVALID_SAMPLE)
  }
  if (t < 0) t <- 0
  tt <- st$sample_tt
  if (t <= tt - .BUFLN || t > tt + .BUFLN) {
    tt <- t - .BUFLN
    if (tt < 0) tt <- -1
    st$sample_tt <- tt
    if (isigsettime(tt + 1) < 0) {
      st$sample_vflag <- 0
      return(WFDB_INVALID_SAMPLE)
    }
  }
  while (t > tt) {
    tt <- tt + 1
    st$sample_tt <- tt
    row <- tt %% .BUFLN + 1
    sb <- st$sbuf
    r <- .getvec(sb[row, ])
    sb[row, ] <- r$v[seq_len(ncol(sb))]
    st$sbuf <- sb
    if (r$stat < 0) {
      tt <- tt - 1
      st$sample_tt <- tt
      st$sample_vflag <- 0
      return(st$sbuf[tt %% .BUFLN + 1, s + 1])
    }
  }
  v <- st$sbuf[t %% .BUFLN + 1, s + 1]
  st$sample_vflag <- if (v == WFDB_INVALID_SAMPLE) -1 else 1
  v
}

#' wfdb_sample is sample() under a name that does not mask base::sample
#' (the package exports wfdb_sample only).
wfdb_sample <- function(s, t) sample(s, t)

sample_valid <- function() .sig$sample_vflag

# ---------------------------------------------------------------------------
# Private functions used by wfdbquit() and wfdbflush()

.wfdb_sampquit <- function() {
  st <- .sig
  if (!is.null(st$sbuf)) {
    st$sbuf <- NULL
    st$sample_vflag <- 0
  }
}

.wfdb_sigclose <- function() {
  st <- .sig
  .isigclose()
  .osigclose()
  st$btime <- st$bdate <- st$nsamples <- 0
  st$msbtime <- st$msbdate <- st$msnsamples <- 0
  st$sfreq <- st$ifreq <- st$ffreq <- 0
  st$pdays <- -1
  st$segments <- st$in_msrec <- st$skewmax <- 0
  st$hdr_dir <- st$msrec_dir <- st$msrec_name <- NULL    # WFDB-x
  if (!is.null(st$dsbuf)) {
    st$dsbuf <- NULL
    st$dsbi <- -1
  }
  if (!is.null(st$segarray)) {
    st$segarray <- NULL
    st$segp <- st$segend <- 0
  }
  st$gv0 <- st$gv1 <- NULL
  st$tvector <- numeric(0)
  st$uvector <- numeric(0)
  st$vvector <- numeric(0)
  st$tuvlen <- 0
  .sigmap_cleanup()
}

.wfdb_osflush <- function() {
  st <- .sig
  if (!length(st$osd) || !length(st$ogd)) return(invisible())
  for (s in seq_len(st$nosig)) {
    os <- st$osd[[s]]
    og <- st$ogd[[os$info$group + 1]]
    if (og$nrewind == 0) {
      if (!og$force_flush && og$seek == 0) {
        if (og$bsize == 0 && !is.null(og$fp) && wf_seek(og$fp, 0, 1) == 0) {
          og$seek <- 1
        } else {
          og$seek <- -1
        }
      }
      if (og$force_flush || og$seek > 0) {
        f <- os$info$fmt
        if (f == 212) .f212(og) else if (f == 310) .f310(og) else if (f == 311) .f311(og)
      }
    }
  }
  for (og in st$ogd[seq_len(st$nogroup)]) {
    if (og$bsize == 0 && og$nb > 0) {
      if (!is.null(og$fp)) wf_write(og$fp, og$buf[seq_len(og$nb)])
      og$nb <- 0
    }
    if (!is.null(og$fp)) {
      wf_flush(og$fp)
      if (!og$force_flush && og$nrewind != 0) {
        wf_seek(og$fp, -og$nrewind, 1)
        og$nrewind <- 0
      }
    }
  }
  invisible()
}

#' Release the info strings read by getinfo(): a later getinfo(NULL) reads
#' them again (from the open input record).
wfdb_freeinfo <- function() {
  st <- .sig
  st$pinfo <- NULL
  st$ninfo <- 0
  st$info_i <- 0
  invisible()
}

.wfdb_oinfoclose <- function() {
  st <- .sig
  stat <- 0
  if (!is.null(st$outinfo) && !identical(st$outinfo, st$oheader)) {
    errflag <- wf_ferror(st$outinfo)
    if (wf_close(st$outinfo) != 0) errflag <- TRUE
    if (errflag) {
      wfdb_error("setinfo: write error in info file\n")
      stat <- -2
    }
  }
  st$outinfo <- NULL
  stat
}

# ---------------------------------------------------------------------------
# Bulk (vectorized) reading: getframes()
#
# .bulk_frames(n) decodes up to n getvec vectors at once with vector
# operations, exactly as n calls of getvec would.  It handles signal files
# of all formats (FLAC through flac_navail() and flac_getsamps()), null
# signals (format 0, of known length), multi-frequency records in
# WFDB_LOWRES and WFDB_HIGHRES modes, WFDB_GVPAD, and the segments of
# multi-segment records (mapped to the layout signals with the signal map
# when the layout varies).  It reads fewer vectors (possibly none) whenever
# a frame needs special handling (end of file or of a segment, a frame at
# which a checksum is verified, a partial bit-packed group, a partial frame
# in WFDB_HIGHRES mode, ...), and returns NULL when the bulk path cannot be
# used at all (skew with several samples per frame or a signal map,
# setifreq resampling, an unskipped prolog, non-seekable input); getframes()
# then uses getvec for the next vector.  With full = TRUE, it decodes up to
# n complete frames instead, as n calls of getframe would (one row per
# frame, tspf columns; used by .getframes_full).  The result is a double
# matrix; with int = TRUE, it may be an integer matrix (of the same values).

.BULK_FMTS <- c(8, 80, 16, 61, 160, 24, 32, 212, 310, 311, 508, 516, 524)
.BULK_MAXFRAMES <- 1048576     # largest block of vectors decoded at once

# The layout of the open input signals, as .bulk_frames needs it: for each
# group g (1-based), its signals sl[[g]], format fmt[g], samples per frame
# nn[g], and the size of its packing unit: nbytes[g] bytes for nsamp[g]
# samples.  `period`: the number of frames after which every bit-packed
# group is at a unit boundary.  The groups of null signals (format 0: no
# file) are in nullg, those with files in fileg (FLAC: flacg).  Computed
# once per set of open signals (cached in .sig$bulk_layout, which is
# cleared whenever .sig$isd or .sig$igd change); NULL if the bulk path
# cannot be used.
.bulk_layout <- function(st) {
  lay <- st$bulk_layout
  if (!is.null(lay)) return(lay$value)
  nisig <- st$nisig
  ng <- st$nigroup
  isd <- st$isd[seq_len(nisig)]
  igd <- st$igd[seq_len(ng)]
  fmts <- spfs <- grp <- numeric(nisig)
  for (s in seq_len(nisig)) {
    info <- isd[[s]]$info
    fmts[s] <- info$fmt
    spfs[s] <- info$spf
    grp[s] <- info$group
  }
  value <- NULL
  if (all(fmts %in% .BULK_FMTS | fmts == 0)) {
    sl <- vector("list", ng)
    fmt <- nn <- nbytes <- nsamp <- numeric(ng)
    period <- 1
    for (g in seq_len(ng)) {
      sg <- which(grp == g - 1)
      if (!length(sg) || any(fmts[sg] != fmts[sg[1L]])) {
        sl <- NULL
        break
      }
      sl[[g]] <- sg
      fmt[g] <- fmts[sg[1L]]
      nn[g] <- sum(spfs[sg])
      # bytes per packing unit, samples per unit
      u <- switch(as.character(fmt[g]), "8" = , "80" = c(1, 1), "16" = , "61" = ,
                  "160" = c(2, 1), "24" = c(3, 1), "32" = c(4, 1), "212" = c(3, 2),
                  "310" = , "311" = c(4, 3), c(1, 1))
      nbytes[g] <- u[1L]
      nsamp[g] <- u[2L]
      if (nsamp[g] == 2 && nn[g] %% 2 && period %% 2) period <- period * 2
      if (nsamp[g] == 3 && nn[g] %% 3 && period %% 3) period <- period * 3
    }
    if (!is.null(sl)) {
      isflac <- fmt %in% c(508, 516, 524)
      isnull <- fmt == 0
      value <- list(isd = isd, igd = igd, spfs = spfs, sl = sl, fmt = fmt,
                    inval = vapply(fmt, .invalid_of, 0), nn = nn, nbytes = nbytes,
                    nsamp = nsamp, isflac = isflac, isnull = isnull, flacg = which(isflac),
                    nullg = which(isnull), fileg = which(!isflac & !isnull),
                    nullsig = which(fmts == 0), period = period)
    }
  }
  st$bulk_layout <- list(value = value)
  value
}

# Decode the samples of n frames of ng samples each, of format fmt, from the
# raw vector data (aligned): a matrix with one row per frame, integer
# (formats 8 and 32: double).  When a frame is one packing unit (format 212
# with 2 samples per frame, 310 and 311 with 3), the units are decoded
# directly as the rows of that matrix; otherwise the samples are decoded in
# order and then arranged in frames.
.decode_frames <- function(fmt, data, n, ng) {
  nsamp <- n * ng
  k <- 1L
  v <- switch(as.character(fmt),
    "16" = readBin(data, "integer", n = nsamp, size = 2L, signed = TRUE, endian = "little"),
    "61" = readBin(data, "integer", n = nsamp, size = 2L, signed = TRUE, endian = "big"),
    "80" = as.integer(readBin(data, "raw", n = nsamp)) - 128L,
    "160" = readBin(data, "integer", n = nsamp, size = 2L, signed = FALSE,
                    endian = "little") - 32768L,
    "8" = readBin(data, "integer", n = nsamp, size = 1L, signed = TRUE),
    "32" = {
      v <- as.numeric(readBin(data, "integer", n = nsamp, size = 4L, endian = "little"))
      v[is.na(v)] <- -2147483648            # (readBin's NA_integer_ is INT_MIN)
      v
    },
    "24" = {
      # each sample as a 32-bit word: its 3 bytes and the sign byte
      b <- readBin(data, "raw", n = 3 * nsamp)
      dim(b) <- c(3L, nsamp)
      readBin(rbind(b, .SIGN8[as.integer(b[3L, ]) + 1L]), "integer", n = nsamp,
              size = 4L, endian = "little")
    },
    "212" = {
      # two 12-bit samples in 3 bytes, the second byte holding the high
      # nibbles: as 16-bit words, the low byte of each sample, then its
      # high nibble with the sign extended (in order, or with 2 samples per
      # frame, all first samples, then all second samples)
      nu <- (nsamp + 1) %/% 2
      b <- if (length(data) == 3 * nu) data else readBin(data, "raw", n = 3 * nu)
      dim(b) <- c(3L, nu)
      h <- as.integer(b[2L, ]) + 1L
      w <- if (ng == 2) c(rbind(b[1L, ], .LO4[h]), rbind(b[3L, ], .HI4[h])) else
        rbind(b[1L, ], .LO4[h], b[3L, ], .HI4[h])
      v <- readBin(w, "integer", n = nsamp, size = 2L, endian = "little")
      if (ng == 2) {
        k <- 2L
        dim(v) <- c(nu, 2L)
      }
      v
    },
    {   # 310, 311: three 10-bit samples in two 16-bit words
      nu <- (nsamp + 2) %/% 3
      w <- readBin(data, "integer", n = 2 * nu, size = 2L, signed = FALSE,
                   endian = "little")
      dim(w) <- c(2L, nu)
      w <- t(w)
      w0 <- w[, 1L]
      w1 <- w[, 2L]
      if (fmt == 310) {
        s0 <- bitwAnd(bitwShiftR(w0, 1L), 1023L)
        s1 <- bitwAnd(bitwShiftR(w1, 1L), 1023L)
        s2 <- bitwOr(bitwShiftR(w0, 11L), bitwShiftL(bitwShiftR(w1, 11L), 5L))
      } else {
        s0 <- bitwAnd(w0, 1023L)
        s1 <- bitwOr(bitwShiftR(w0, 10L), bitwShiftL(bitwAnd(w1, 15L), 6L))
        s2 <- bitwAnd(bitwShiftR(w1, 4L), 1023L)
      }
      if (ng == 3) {
        k <- 3L
        v <- c(s0, s1, s2)
        dim(v) <- c(nu, 3L)
      } else {
        v <- rbind(s0, s1, s2)
        dim(v) <- NULL
        if (length(v) > nsamp) v <- v[seq_len(nsamp)]
      }
      v - bitwShiftL(bitwAnd(v, 512L), 1L)
    })
  if (k > 1L) return(v)
  if (ng > 1) {
    dim(v) <- c(ng, n)
    t(v)
  } else {
    dim(v) <- c(n, 1L)
    v
  }
}

# Byte tables for .decode_frames (indexed by the byte + 1): the sign byte
# of a byte (.SIGN8), and the low (.LO4) and high (.HI4) nibble of a byte
# with its sign extended to 8 bits.
.SIGN8 <- as.raw(ifelse(0:255 >= 128, 255, 0))
.LO4 <- as.raw(bitwAnd(0:255, 15L) + ifelse(bitwAnd(0:255, 8L) > 0, 240L, 0L))
.HI4 <- as.raw(bitwShiftR(0:255, 4L) + ifelse(0:255 >= 128, 240L, 0L))

# meansamp() for each row of the matrix sv (n samples per row).
.meansamp_rows <- function(sv, n) {
  total <- n %/% 2 + rowSums(sv)
  if (bitwAnd(n, n - 1) != 0) {
    neg <- as.numeric(total < 0)
    total <- trunc((total + neg) / n) - neg
  } else {
    total <- floor(total / n)     # (repeated halving, rounding down)
  }
  if (min(sv) <= WFDB_INVALID_SAMPLE) total[rowSums(sv == WFDB_INVALID_SAMPLE) > 0] <- WFDB_INVALID_SAMPLE
  total
}

# Leave the buffer of input group ig as the C library would after reading
# the first `used` bytes of data: the `have` bytes that were left in the
# buffer, followed by blocks of bs bytes read from the file (the last one
# possibly shorter).  The buffer then holds the block of the last byte
# used (its contents are visible at the end of the file, where the readers
# return bytes of the last block read), and the bytes read beyond that
# block are given back to the file.
.bulk_setbuf <- function(ig, data, have, used, bs) {
  nb <- length(data) - have                 # bytes read from the file
  p <- used - have                          # of which used
  keep <- 0                                 # bytes read that C would have read
  if (p <= 0) {
    ig$bp <- ig$bp + used
  } else {
    b0 <- (ceiling(p / bs) - 1) * bs        # start of the block of the last byte used
    keep <- min(b0 + bs, nb)
    ig$buf <- if (have == 0 && b0 == 0 && keep == nb) data else data[have + (b0 + 1):keep]
    ig$bp <- p - b0
    ig$be <- keep - b0
    ig$stat <- ig$be
  }
  if (nb > keep) wf_seek(ig$fp, keep - nb, 1)
  invisible()
}

# sigmap() for each row of raw (the frames of a segment, as getskewedframe
# reads them): the frames of the layout of a variable-layout record (one
# row per frame, tspf columns).
.bulk_sigmap <- function(raw) {
  smi <- .sig$smi
  n <- nrow(raw)
  tspf <- length(smi$index)
  out <- matrix(0, n, tspf)
  for (i in seq_len(tspf)) {
    x <- raw[, smi$index[i] + 1]
    v <- x * smi$scale[i] + smi$offset[i]
    so <- smi$sample_offset[i]
    if (so != 0) {
      r <- trunc(v) + so
      if (anyNA(r) || any(r < WFDB_SAMPLE_MIN | r > WFDB_SAMPLE_MAX)) r <- cint32(r)
    } else {
      r <- rep(WFDB_SAMPLE_MIN, n)
      pos <- !is.na(v) & v >= 0
      r[pos] <- pmin(trunc(v[pos]), WFDB_SAMPLE_MAX)
      neg <- !is.na(v) & v < 0 & v >= WFDB_SAMPLE_MIN
      r[neg] <- floor(v[neg])
    }
    r[x == WFDB_INVALID_SAMPLE] <- WFDB_INVALID_SAMPLE
    out[, i] <- r
  }
  out
}

# The samples of a frame (0-based) that rgetvec gives in WFDB_HIGHRES mode
# for a signal of sf samples per frame, at each of the per steps of a frame
# (its gvindex, as gvcount advances).
.gvindex_steps <- function(sf, per) {
  idx <- numeric(per)
  index <- 0
  count <- -per
  for (k in seq_len(per - 1)) {
    count <- count + sf
    if (count >= 0) {
      index <- index + 1
      count <- count - per
    }
    idx[k + 1] <- index
  }
  idx
}

.bulk_frames <- function(n, full = FALSE, int = FALSE) {
  st <- .sig
  nisig <- st$nisig
  nvsig <- st$nvsig
  need_sigmap <- st$need_sigmap
  if (n <= 0 || nisig == 0 || (if (need_sigmap) nisig > nvsig else nvsig != nisig) ||
      !(st$ifreq == 0 || st$ifreq == st$sfreq)) return(NULL)
  lay <- .bulk_layout(st)
  if (is.null(lay)) return(NULL)
  ispfmax <- st$ispfmax
  # (deskewing: only with one sample per frame and no signal map, once the
  # buffer is primed)
  deskew <- !is.null(st$dsbuf)
  if (deskew && (need_sigmap || ispfmax != 1 || st$dsbi < 0 || st$tspf != nisig))
    return(NULL)
  highres <- !full && ispfmax > 1 && bitwAnd(st$gvmode, WFDB_HIGHRES) == WFDB_HIGHRES
  if (highres && st$gvc < ispfmax) return(NULL)
  isd <- lay$isd
  igd <- lay$igd
  isflac <- lay$isflac
  isnull <- lay$isnull
  for (g in seq_along(igd)) {
    if (isnull[g]) next
    ig <- igd[[g]]
    if (ig$initial_skip || ig$count || (!isflac[g] && (ig$seek != 1 || is.null(ig$fp))))
      return(NULL)
  }
  # (null signals: only of known length)
  for (s in lay$nullsig) {
    if (isd[[s]]$info$nsamp <= 0) return(NULL)
  }
  ncols <- if (full) st$tspf else nvsig
  if (highres) n <- floor(n / ispfmax)
  # (no frame at which a checksum would be verified, or after which a null
  # signal ends)
  for (is in isd) {
    ns <- is$info$nsamp
    if (ns > 0 && n >= ns) n <- ns - 1
  }
  period <- lay$period
  n <- n - n %% period
  if (n <= 0) return(matrix(0, 0, ncols))
  nn <- lay$nn
  # The frames available in each group.  Signal files are read in whole
  # blocks, as the C library's buffer fills do, so that the buffer can be
  # left as C leaves it; FLAC samples are taken only once n is known, so
  # that none is lost when another group has fewer frames.
  # (the bytes of n frames of group g: exact, n being a multiple of period)
  nbytes <- function(g, n) (n * nn[g] * lay$nbytes[g]) %/% lay$nsamp[g]
  bufs <- vector("list", length(igd))
  haves <- bsizes <- numeric(length(igd))
  for (g in lay$fileg) {
    ig <- igd[[g]]
    need <- nbytes(g, n)
    have <- ig$be - ig$bp
    bs <- if (ig$bsize > 0) ig$bsize else st$ibsize
    haves[g] <- have
    bsizes[g] <- bs
    if (have >= need) {
      data <- ig$buf[(ig$bp + 1):(ig$bp + need)]
    } else {
      data <- wf_read(ig$fp, ceiling((need - have) / bs) * bs)
      if (have > 0) data <- c(ig$buf[(ig$bp + 1):ig$be], data)
    }
    bufs[[g]] <- data
    avail <- (length(data) %/% nbytes(g, period)) * period
    if (avail < n) n <- avail
  }
  for (g in lay$flacg) {
    if (n <= 0) break
    avail <- flac_navail(igd[[g]])
    avail <- if (avail < 0) 0 else (avail %/% (period * nn[g])) * period
    if (avail < n) n <- avail
  }
  if (st$istime == 0) {
    for (is in isd) is$samp <- is$info$initval
  }
  pad <- bitwAnd(st$gvmode, WFDB_GVPAD) != 0
  spfs <- lay$spfs
  frames <- vector("list", nisig)
  # (whole: the decoded frames of a single group holding all the signals,
  # none of them invalid, are the result)
  whole_ok <- ispfmax == 1 && !need_sigmap && length(igd) == 1L &&
    !(full && st$framelen < st$tspf)
  whole <- NULL
  for (g in seq_along(igd)) {
    ig <- igd[[g]]
    if (!isflac[g] && !isnull[g])
      .bulk_setbuf(ig, bufs[[g]], haves[g], nbytes(g, n), bsizes[g])
    if (n == 0) next
    fmt <- lay$fmt[g]
    ng <- nn[g]
    inval <- lay$inval[g]
    clean <- FALSE
    if (!isnull[g]) {
      # (one row per frame, one column per sample of a frame)
      if (isflac[g]) {
        raws <- flac_getsamps(ig, n * ng)$v
        dim(raws) <- c(ng, n)
        raws <- t(raws)
      } else {
        raws <- .decode_frames(fmt, bufs[[g]], n, ng)
      }
      # (clean: no invalid sample, and no first differences: the samples
      # are the decoded values)
      clean <- fmt != 8 && (min(raws) > inval || !any(raws == inval))
      if (clean) {
        csum <- colSums(raws)
        last <- as.numeric(raws[n, ])
        if (whole_ok) whole <- raws
      }
    }
    off <- 0
    for (s in lay$sl[[g]]) {
      is <- isd[[s]]
      sf <- spfs[s]
      if (isnull[g]) {
        # (a null signal: its last sample with WFDB_GVPAD, else invalid)
        v <- rep(if (pad) is$samp else WFDB_INVALID_SAMPLE, n * sf)
        cks <- sum(v)
        fr <- v
      } else if (clean) {
        cks <- sum(csum[off + seq_len(sf)])
        is$samp <- last[off + sf]
        fr <- if (!is.null(whole)) NULL else if (ng == 1) raws else
          raws[, off + seq_len(sf), drop = sf == 1]
      } else {
        col <- as.numeric(if (sf == 1) raws[, off + 1] else t(raws[, off + seq_len(sf)]))
        if (fmt == 8) {
          v <- cint32(cumsum(col) + is$samp)  # first differences
          is$samp <- v[length(v)]
          cks <- sum(v)
        } else {
          inv <- col == inval
          cks <- sum(col)
          if (any(inv)) {
            if (pad) {
              # an invalid sample repeats the last valid one
              idx <- seq_along(col)
              idx[inv] <- 0L
              idx <- cummax(idx)
              v <- rep(is$samp, length(col))
              m <- idx > 0
              v[m] <- col[idx[m]]
            } else {
              v <- col
              v[inv] <- WFDB_INVALID_SAMPLE
            }
            valid <- which(!inv)
            if (length(valid)) is$samp <- col[valid[length(valid)]]
          } else {
            v <- col
            is$samp <- col[length(col)]
          }
        }
        fr <- if (sf == 1) v else matrix(v, n, sf, byrow = TRUE)
      }
      if (!is.null(fr) && is.null(dim(fr)) && (ispfmax > 1 || sf > 1)) dim(fr) <- c(n, sf)
      frames[s] <- list(fr)
      info <- is$info
      info$cksum <- cint32(info$cksum - cks)
      if (info$nsamp > 0) {
        info$nsamp <- info$nsamp - n
      } else if (info$nsamp == 0) {
        info$nsamp <- -1
      }
      is$info <- info
      off <- off + sf
    }
  }
  st$istime <- st$istime + n
  if (n == 0) return(matrix(0, 0, ncols))
  if (need_sigmap) {
    # the frames of the layout (getframe), split into its signals
    raw <- do.call(cbind, frames)
    st$ovec <- as.numeric(raw[n, ])
    fr <- .bulk_sigmap(raw)
    if (full || ispfmax == 1) return(fr[, seq_len(ncols), drop = FALSE])
    spfs <- vapply(st$vsd[seq_len(nvsig)], function(vs) vs$info$spf, 0)
    tp <- cumsum(c(0, spfs))
    frames <- lapply(seq_len(nvsig), function(s) fr[, tp[s] + seq_len(spfs[s]), drop = FALSE])
    st$tvector <- fr[n, ]
  } else if (full && (ispfmax > 1 || st$framelen < st$tspf)) {
    fr <- do.call(cbind, frames)
    if (st$framelen < st$tspf)
      fr <- cbind(fr, matrix(WFDB_INVALID_SAMPLE, n, st$tspf - st$framelen))
    if (!int && is.integer(fr)) storage.mode(fr) <- "double"
    return(fr)
  } else if (ispfmax > 1) {
    st$tvector <- as.numeric(unlist(lapply(frames, function(f) f[n, ]), use.names = FALSE))
  }
  if (ispfmax == 1) {
    out <- whole
    if (is.null(out)) {
      out <- unlist(frames, use.names = FALSE)     # (dim<-: no copy)
      dim(out) <- c(n, nisig)
    }
    if (!int && is.integer(out)) storage.mode(out) <- "double"
    if (deskew) {
      # the ring buffer holds raw frames k .. k+L-1 (L = skewmax + 1), the
      # oldest in slot dsbi; output frame k+j takes signal s from raw frame
      # k+j+skew[s]
      L <- st$dsblen / nisig
      ring <- matrix(st$dsbuf, L, nisig, byrow = TRUE)
      a <- rbind(ring[(st$dsbi / nisig + 0:(L - 1)) %% L + 1, , drop = FALSE], out)
      res <- matrix(0, n, nisig)
      for (s in seq_len(nisig)) res[, s] <- a[seq_len(n) + 1 + st$vsd[[s]]$skew, s]
      dsbi <- ((st$dsbi / nisig + n) %% L)
      newring <- matrix(0, L, nisig)
      newring[(dsbi + 0:(L - 1)) %% L + 1, ] <- a[n + seq_len(L), , drop = FALSE]
      st$dsbuf <- as.vector(t(newring))
      st$dsbi <- dsbi * nisig
      out <- res
    }
  } else if (highres) {
    # ispfmax vectors per frame; at step c of a frame, signal s gives the
    # sample of the frame that rgetvec's gvindex/gvcount select
    out <- matrix(0, n * ispfmax, nvsig)
    for (s in seq_len(nvsig)) {
      idx <- .gvindex_steps(spfs[s], ispfmax) + 1
      out[, s] <- as.vector(t(frames[[s]][, idx, drop = FALSE]))
    }
    st$gvc <- ispfmax
    st$rgetvec_stat <- nisig
  } else {
    out <- matrix(0, n, nvsig)
    # (the mean of one sample is that sample)
    for (s in seq_len(nvsig))
      out[, s] <- if (spfs[s] == 1) frames[[s]] else .meansamp_rows(frames[[s]], spfs[s])
    st$rgetvec_stat <- nisig
  }
  out
}

#' Read up to n sample vectors at once (fast): equivalent to calling getvec
#' up to n times, stopping at the first negative status.  Returns list(v =
#' matrix with one row per vector read and one column per signal, stat =
#' the status of the first vector that could not be read, or the number of
#' signals if all n were read).  n may be Inf.  With minstat, it stops
#' instead at the first vector for which getvec returns less than minstat
#' (that vector is not included), as a C loop "while (getvec(v) >= minstat)"
#' does.  (In a variable-layout record, getvec returns a positive value
#' smaller than the number of signals in a segment that lacks some of them.)
getframes <- function(n, minstat = 0) .getframes(n, minstat)

# getframes; with keep_checksum_frame (WFDB-x, for the high-level reader),
# a vector for which getvec returns -4 (a checksum error: the samples are
# valid, their sum does not match the header) is included in the matrix and
# reading continues (in high-resolution mode, getvec returns -4 for each
# of the vectors of the frame at which the checksum is verified); stat is
# then -4 unless reading stops at a status below -1.  (.bulk_frames never
# decodes that frame.)
.getframes <- function(n, minstat = 0, keep_checksum_frame = FALSE) {
  st <- .sig
  nsig <- max(st$nvsig, st$nisig)
  if (nsig == 0 || st$nisig == 0) {
    r <- getvec()
    return(list(v = matrix(0, 0, nsig), stat = r$stat))
  }
  if (n <= 0) return(list(v = matrix(0, 0, nsig), stat = nsig))
  # (blocks of a multiple of 6 frames, so that formats 212, 310 and 311 end
  # each block on a whole packed unit)
  per <- if (st$ispfmax > 1 && bitwAnd(st$gvmode, WFDB_HIGHRES) == WFDB_HIGHRES) st$ispfmax else 1
  maxv <- .BULK_MAXFRAMES - .BULK_MAXFRAMES %% (6 * per)
  # (integer blocks: converted once, by rbind if there are several)
  blk <- .bulk_frames(min(n, maxv), int = TRUE)
  if (!is.null(blk) && nrow(blk) >= n) {
    if (is.integer(blk)) storage.mode(blk) <- "double"
    return(list(v = blk, stat = nsig))
  }
  # Otherwise: blocks decoded by .bulk_frames, and vectors read by getvec
  # (collected in acc) where it declines.
  parts <- list()
  got <- 0
  stat <- nsig
  acc <- NULL
  nrows <- 0
  cksum_err <- FALSE
  repeat {
    if (!is.null(blk) && nrow(blk) > 0) {
      if (nrows > 0) {
        parts[[length(parts) + 1L]] <- acc[seq_len(nrows), , drop = FALSE]
        nrows <- 0
      }
      parts[[length(parts) + 1L]] <- blk
      got <- got + nrow(blk)
    } else {
      r <- .getvec(st$gvec)
      st$gvec <- r$v
      stat <- r$stat
      if (stat == -4 && keep_checksum_frame) {
        cksum_err <- TRUE
      } else if (stat < minstat || stat < 0) {
        break
      }
      if (is.null(acc) || nrows == nrow(acc)) {
        if (nrows > 0) {
          parts[[length(parts) + 1L]] <- acc
          nrows <- 0
        }
        acc <- matrix(0, min(max(64, 2 * nrow(acc) %||% 0), 65536), nsig)
      }
      nrows <- nrows + 1
      acc[nrows, ] <- r$v[seq_len(nsig)]
      got <- got + 1
    }
    if (got >= n) break
    blk <- .bulk_frames(min(n - got, maxv), int = TRUE)
  }
  if (nrows > 0) parts[[length(parts) + 1L]] <- acc[seq_len(nrows), , drop = FALSE]
  v <- if (length(parts) == 1L) parts[[1L]] else if (length(parts)) {
    do.call(rbind, parts)
  } else {
    matrix(0, 0, nsig)
  }
  if (is.integer(v)) storage.mode(v) <- "double"
  if (cksum_err && stat >= -1) stat <- -4
  list(v = v, stat = stat)
}

# Read up to n complete frames at once: equivalent to calling getframe up
# to n times, stopping at the first negative status.  Returns list(v =
# matrix with one row per frame read and tspf columns, stat = the status of
# the first frame that could not be read, or the number of signals if all
# n were read).  n may be Inf.
.getframes_full <- function(n) {
  st <- .sig
  tspf <- st$tspf
  parts <- list()
  got <- 0
  stat <- max(st$nvsig, st$nisig)
  while (got < n) {
    blk <- .bulk_frames(min(n - got, .BULK_MAXFRAMES), full = TRUE)
    if (!is.null(blk) && nrow(blk) > 0) {
      parts[[length(parts) + 1L]] <- blk
      got <- got + nrow(blk)
      next
    }
    r <- getframe()
    stat <- r$stat
    if (stat < 0) break
    parts[[length(parts) + 1L]] <- matrix(r$v, 1L, tspf)
    got <- got + 1
  }
  v <- if (length(parts) == 1L) parts[[1L]] else if (length(parts)) {
    do.call(rbind, parts)
  } else {
    matrix(0, 0, tspf)
  }
  list(v = v, stat = stat)
}

# ---------------------------------------------------------------------------
# Bulk writing: putframes()

# Format 8: the differences written and the samples they represent (as
# successive putvec calls, with slew-rate clipping).
.fmt8_diffs <- function(x, prev) {
  n <- length(x)
  d <- numeric(n)
  osamp <- numeric(n)
  clipped <- FALSE
  i <- 1
  while (i <= n) {
    e <- min(n, i + 4095)                   # (in chunks of 4096 samples)
    dd <- diff(c(prev, x[i:e]))
    bad <- which(dd < -128 | dd > 127)
    if (!length(bad)) {
      d[i:e] <- dd
      osamp[i:e] <- x[i:e]
      prev <- x[e]
      i <- e + 1
      next
    }
    bad <- bad[1L]
    j <- i + bad - 2
    if (j >= i) {
      d[i:j] <- dd[seq_len(bad - 1)]
      osamp[i:j] <- x[i:j]
      prev <- x[j]
    }
    i <- j + 1
    while (i <= n) {
      dif <- cint32(x[i] - prev)
      if (dif < -128) {
        dif <- -128
        clipped <- TRUE
      } else if (dif > 127) {
        dif <- 127
        clipped <- TRUE
      }
      prev <- cint32(prev + dif)
      d[i] <- dif
      osamp[i] <- prev
      i <- i + 1
      if (prev == x[i - 1]) break
    }
  }
  list(d = d %% 256, osamp = osamp, clipped = clipped)
}

# Bytes of the samples v in a byte-aligned format.
.encode_stream <- function(fmt, v) {
  # (16- and 32-bit words are written with writeBin, as signed integers)
  i16 <- function(x) {
    x <- x %% 65536
    as.integer(x - 65536 * (x >= 32768))
  }
  w16 <- function(x, endian = "little") {
    x <- if (isTRUE(min(x) >= -32768) && isTRUE(max(x) <= 32767)) as.integer(x) else i16(x)
    writeBin(x, raw(), size = 2L, endian = endian)
  }
  switch(as.character(fmt),
    "8" = as.raw(v),
    "16" = w16(v),
    "61" = w16(v, "big"),
    "80" = as.raw((v %% 256 + 128) %% 256),
    "160" = w16(v + 32768),
    "24" = {
      x <- v %% 16777216
      as.vector(rbind(matrix(w16(x), 2L), as.raw(x %/% 65536)))
    },
    "32" = {
      # (-2^31 becomes NA_integer_, whose bytes are those of INT_MIN)
      x <- v %% 4294967296
      x <- suppressWarnings(as.integer(x - 4294967296 * (x >= 2147483648)))
      writeBin(x, raw(), size = 4L, endian = "little")
    },
    as.raw(v %% 256))
}

# Bytes of the samples v in a bit-packed format (212, 310, 311), continuing
# from the state of the output group og (as successive putvec calls).
.encode_packed <- function(fmt, v, og) {
  p1 <- switch(as.character(fmt), "212" = .p212, "310" = .p310, .p311)
  # (samples that complete a pending group, and the last partial group, go
  # through the scalar packers, which update og's state)
  pre <- list()
  n <- length(v)
  i <- 1
  while (og$count != 0 && i <= n) {
    pre[[length(pre) + 1L]] <- p1(og, v[i])
    i <- i + 1
  }
  k <- if (fmt == 212) 2 else 3
  ngr <- (n - i + 1) %/% k
  mid <- raw(0)
  if (ngr > 0) {
    w <- matrix(v[i:(i + ngr * k - 1)], k)
    if (fmt == 212) {
      d <- w[1L, ] %% 4096 + ((w[2L, ] %% 4096) %/% 256) * 4096
      m <- rbind(d %% 256, d %/% 256, w[2L, ] %% 256)
    } else if (fmt == 310) {
      d <- (w[1L, ] %% 1024) * 2 + (w[3L, ] %% 32) * 2048
      e <- (w[2L, ] %% 1024) * 2 + ((w[3L, ] %% 1024) %/% 32) * 2048
      m <- rbind(d %% 256, d %/% 256, e %% 256, e %/% 256)
    } else {
      d <- w[1L, ] %% 1024 + (w[2L, ] %% 64) * 1024
      e <- floor(w[2L, ] / 64) %% 16 + (w[3L, ] %% 1024) * 16
      m <- rbind(d %% 256, d %/% 256, e %% 256, e %/% 256)
    }
    mid <- as.raw(as.vector(m))
    i <- i + ngr * k
  }
  post <- list()
  while (i <= n) {
    post[[length(post) + 1L]] <- p1(og, v[i])
    i <- i + 1
  }
  c(unlist(pre, use.names = FALSE), mid, unlist(post, use.names = FALSE))
}

#' Write many frames at once (fast): the rows of matrix m are written to the
#' open output signals with exactly the results of putvec(m[r, ]) for each
#' row r in turn.  Returns the smallest value those putvec calls would have
#' returned.
putframes <- function(m) {
  st <- .sig
  nosig <- st$nosig
  stat <- nosig
  if (is.null(dim(m))) m <- matrix(m, nrow = 1L)
  nrows <- nrow(m)
  if (nrows == 0 || nosig == 0) {
    st$ostime <- st$ostime + nrows
    return(stat)
  }
  if (!is.double(m)) storage.mode(m) <- "double"
  osd <- st$osd
  vi <- 0
  s <- 1
  while (s <= nosig) {
    g <- osd[[s]]$info$group
    s2 <- s
    while (s2 < nosig && osd[[s2 + 1]]$info$group == g) s2 <- s2 + 1
    og <- st$ogd[[g + 1]]
    fmt <- osd[[s]]$info$fmt
    if (fmt == 8) {
      gs <- vector("list", s2 - s + 1)
      for (k in s:s2) {
        os <- osd[[k]]
        info <- os$info
        spf <- info$spf
        x <- t(m[, vi + seq_len(spf), drop = FALSE])   # spf x nrows, time order
        if (info$nsamp == 0) {
          info$initval <- m[1L, vi + 1]
          os$samp <- m[1L, vi + 1]
        }
        vi <- vi + spf
        info$nsamp <- info$nsamp + nrows
        inv <- x == WFDB_INVALID_SAMPLE
        if (any(inv)) x[inv] <- .invalid_of(info$fmt)
        r <- .fmt8_diffs(as.vector(x), os$samp)
        x <- matrix(r$d, spf, nrows)
        if (r$clipped) stat <- min(stat, 0)
        info$cksum <- cint32(info$cksum + sum(r$osamp))
        os$samp <- r$osamp[length(r$osamp)]
        os$info <- info
        gs[[k - s + 1]] <- x
      }
      seq <- if (s2 == s) as.vector(gs[[1L]]) else as.vector(do.call(rbind, gs))
    } else {
      # the columns of the group's signals, frame by frame (invalid samples
      # replaced by the invalid value of each signal's format)
      spfs <- vapply(osd[s:s2], function(os) os$info$spf, 0)
      cols <- vi + seq_len(sum(spfs))
      x <- if (length(cols) == ncol(m) && vi == 0) m else m[, cols, drop = FALSE]
      off <- 0
      for (k in s:s2) {
        ival <- .invalid_of(osd[[k]]$info$fmt)
        ck <- off + seq_len(spfs[k - s + 1])
        off <- off + length(ck)
        if (ival == WFDB_INVALID_SAMPLE) next
        xk <- x[, ck]
        inv <- xk == WFDB_INVALID_SAMPLE
        if (any(inv)) {
          xk[inv] <- ival
          x[, ck] <- xk
        }
      }
      csum <- colSums(x)
      off <- 0
      for (k in s:s2) {
        os <- osd[[k]]
        info <- os$info
        spf <- spfs[k - s + 1]
        if (info$nsamp == 0) {
          info$initval <- m[1L, vi + off + 1]
          os$samp <- m[1L, vi + off + 1]
        }
        info$nsamp <- info$nsamp + nrows
        info$cksum <- cint32(info$cksum + sum(csum[off + seq_len(spf)]))
        os$samp <- x[nrows, off + spf]
        os$info <- info
        off <- off + spf
      }
      vi <- vi + off
      seq <- if (ncol(x) == 1L) x else t(x)
      dim(seq) <- NULL
    }
    bytes <- raw(0)
    if (fmt %in% c(508, 516, 524)) {
      if (flac_putsamps(seq, fmt, og) < 0) stat <- -1
    } else if (fmt %in% c(212, 310, 311)) {
      bytes <- .encode_packed(fmt, seq, og)
    } else if (fmt != 0) {
      bytes <- .encode_stream(fmt, seq)
    }
    if (length(bytes)) {
      .og_put(og, bytes)
      if (!is.null(og$fp) && wf_ferror(og$fp)) {
        for (k in s:s2) wfdb_error("putvec: write error in signal %d\n", k - 1)
        stat <- -1
      }
    }
    s <- s2 + 1
  }
  st$ostime <- st$ostime + nrows
  stat
}

# ---------------------------------------------------------------------------
# Vectorized time strings (for tools printing many times): the results of
# mstimstr()/timstr() with frequency f for each element of t.  The module
# state (time and date strings) is left as the last call would leave it.
# The fields are formatted through tables of their distinct values
# (.cfmt_tab).

# csprintf_v(fmt, x) as a table of the strings of the distinct values of x
# and the index of each element of x in it: list(tab, i).  (With key, x is
# the vector of the key's distinct values, in the order of unique(key), for
# each of which fn(x) gives the string.)
.cfmt_tab <- function(fmt, x, key = x, fn = function(u) csprintf_v(fmt, u)) {
  u <- unique(key)
  list(tab = fn(u), i = match(key, u))
}

# The time strings of t (list(s, d): the strings, and the date string of
# each).  With pieces = TRUE, if all the strings are elapsed times, or all
# absolute times, s is NULL and p gives them as pieces to be pasted: a list
# of tables (.cfmt_tab), of the minutes (with the hours), seconds and
# milliseconds (and, for absolute times, the date and the closing bracket).
.fmstimstr_v0 <- function(t, f, pieces = FALSE) {
  st <- .sig
  n <- length(t)
  out <- character(n)
  dstr <- rep(st$date_string, n)
  if (n == 0L) return(list(s = out, d = dstr))
  el <- t > 0 | (st$btime == 0 & st$bdate == 0)
  pieces <- pieces && (all(el) || !any(el))
  p <- NULL
  if (any(el)) {
    x <- abs(t[el])
    sec <- trunc(x / f)
    msec <- trunc((x - sec * f) * 1000 / f + 0.5)
    k <- msec == 1000
    msec[k] <- 0
    sec[k] <- sec[k] + 1
    seconds <- sec %% 60
    m <- sec %/% 60
    # ("   %2d:%02d.%03d" of minutes, seconds, msec, or "%2d:%02d:%02d.%03d"
    # with the hours)
    p <- list(.cfmt_tab(key = m, fn = function(u) {
      h <- u %/% 60
      ifelse(h > 0, csprintf_v("%2d:%02d:", h, u %% 60), csprintf_v("   %2d:", u %% 60))
    }), .cfmt_tab("%02d.", seconds), .cfmt_tab("%03d", msec))
    if (!pieces) out[el] <- do.call(paste0, lapply(p, function(q) q$tab[q$i]))
  }
  if (any(!el)) {
    tms <- st$btime - (t[!el] * 1000 / f)
    sec <- trunc(tms / 1000)
    msec <- trunc((tms - sec * 1000) + 0.5)
    k <- msec == 1000
    msec[k] <- 0
    sec[k] <- sec[k] + 1
    seconds <- cmod(sec, 60)
    m <- cdiv(sec, 60)
    days <- cdiv(cdiv(m, 60), 24)
    ud <- unique(days)
    ds <- vapply(ud, function(d) {
      if (d == st$pdays) st$date_string else if (st$bdate > 0) datstr(d + st$bdate) else
        if (d == 0) "" else .f(" %d", d)
    }, "")
    di <- match(days, ud)
    dstr[!el] <- ds[di]
    # ("[%02d:%02d:%02d.%03d" of hours, minutes, seconds, msec, the date, "]")
    p <- list(.cfmt_tab(key = m, fn = function(u)
      csprintf_v("[%02d:%02d:", cmod(cdiv(u, 60), 24), cmod(u, 60))),
      .cfmt_tab("%02d.", seconds), .cfmt_tab("%03d", msec), list(tab = ds, i = di),
      list(tab = "]", i = rep(1L, length(di))))
    if (!pieces) out[!el] <- do.call(paste0, lapply(p, function(q) q$tab[q$i]))
  }
  .fmstimstr(t[n], f)       # (the state after the last one)
  if (pieces) list(s = NULL, d = dstr, p = p) else list(s = out, d = dstr)
}

.fmstimstr_v <- function(t, f) .fmstimstr_v0(t, f)$s

.ftimstr_v <- function(t, f) {
  st <- .sig
  r <- .fmstimstr_v0(t, f)
  p <- sub(".", "\001", r$s, fixed = TRUE)
  p <- sub("\001.*$", "", p)
  if (st$btime != 0 || st$bdate != 0) {
    k <- t <= 0
    p[k] <- paste0(p[k], r$d[k], "]")
  }
  p
}
