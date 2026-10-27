# apps_mit2wav.R: mit2wav -- convert a WFDB record to a .wav file.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of convert/mit2wav.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency: the record must
# give it (the original assumed 250 Hz); --legacy, as the first argument,
# restores the original behavior. Each change is marked "wfdb-x:" in the code;
# docs/DIVERGENCES.md gives the reasons.
#
# Original C program: convert/mit2wav.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2003-2010 George B. Moody; revised 2018 by Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The samples are read with getframes() and written with putframes(), a
# block at a time (the same output as the C program's getvec/putvec loop).

app_mit2wav <- function(args = character(0)) {
  app_run(.mit2wav_main, c("mit2wav", args))
}

.mit2wav_help <- function(pname) {
  ceprintf("usage: %s -o FILE.wav -r RECORD [ OPTIONS ... ]\n", pname)
  h <- c("where FILE.wav is the name of the wav-format output signal file,",
         "RECORD is the record name, and OPTIONS may include:",
         " -h         print this usage summary",
         " -n NEWREC  create a header file for the output signal file, so it",
         "             may be read as record NEWREC")
  for (s in h) ceprintf("%s\n", s)
}

# Little-endian unsigned 16- and 32-bit fields (values taken modulo 2^16,
# 2^32).
.le16 <- function(x) as.raw(c(x %% 256, (x %/% 256) %% 256))
.le32 <- function(x) {
  x <- x %% 4294967296
  as.raw(c(x %% 256, (x %/% 256) %% 256, (x %/% 65536) %% 256, (x %/% 16777216) %% 256))
}

.mit2wav_main <- function(argv) {
  WAV_HEADER_BYTES <- 44                    # RIFF, fmt and data chunk headers
  RIFF_SIZE_OFFSET <- 36                    # header bytes counted in the RIFF size
  PCM_FMT_LEN <- 16                         # length of a PCM format chunk
  WAVE_FORMAT_PCM <- 1
  WAV_BITS <- 16                            # bits per output sample
  CHUNK <- 65536                            # sample vectors read at a time
  pname <- argv[1L]
  argc <- length(argv)
  arg <- function(i) argv[i + 1L]          # C argv[i]
  nrec <- NULL
  ofname <- NULL
  record <- NULL
  i <- 1
  while (i < argc) {
    a <- arg(i)
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "h") {
        .mit2wav_help(pname)
        cexit(1)
      } else if (c == "n") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: new record name must follow -n\n", pname)
          cexit(1)
        }
        nrec <- arg(i)
      } else if (c == "o") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: name of wav-format output file must follow -o\n", pname)
          cexit(1)
        }
        ofname <- arg(i)
        if (nchar(ofname, type = "bytes") < 5 || !endsWith(ofname, ".wav")) {
          ceprintf("%s: name of output file must end in '.wav'\n", pname)
          cexit(1)
        }
      } else if (c == "r") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: record name must follow -r\n", pname)
          cexit(1)
        }
        record <- arg(i)
      } else {
        ceprintf("%s: unrecognized option %s\n", pname, a)
        cexit(1)
      }
    } else {
      ceprintf("%s: unrecognized argument %s\n", pname, a)
      cexit(1)
    }
    i <- i + 1
  }
  if (is.null(ofname) || is.null(record)) {
    .mit2wav_help(pname)
    cexit(1)
  }
  if (!is.null(nrec) && record == nrec) {
    ceprintf("%s: names of input and output records must not be identical\n", pname)
    cexit(1)
  }
  nsig <- isigopen(record, 0)$nsig
  if (nsig <= 0) cexit(2)
  r <- isigopen(record, nsig)
  nsig <- r$nsig
  s <- r$si
  if (nsig <= 0) cexit(3)
  if (!wfdbx_get_legacy() && sampfreq(NULL) <= 0)  # wfdb-x: no default frequency
                                                   # (except in legacy mode)
    .app_nofreq(pname, record, 3)
  if (!is.null(nrec) && newheader(nrec) < 0) cexit(3)
  bitspersample <- 0
  offset <- shift <- numeric(nsig)
  for (k in seq_len(nsig)) {
    si <- s[[k]]
    if (si$adcres > bitspersample) bitspersample <- si$adcres
    offset[k] <- si$adczero
    si$adczero <- 0
    shift[k] <- WAV_BITS - si$adcres
    si$adcres <- WAV_BITS
    mag <- if (shift[k] >= 0) cint32(2^shift[k]) else 0
    si$gain <- si$gain * mag
    si$baseline <- cint32((si$baseline - offset[k]) * mag)
    si$fname <- ofname
    si$group <- 0
    si$fmt <- 16
    si$spf <- 1
    s[[k]] <- si
  }
  nsamp <- strtim("e")
  sps <- strtim("1")
  framelen <- nsig * 2
  if (osigfopen(s, nsig) < nsig) cexit(4)
  for (k in seq_len(nsig)) wfdbsetstart(k - 1, WAV_HEADER_BYTES)
  hdr <- c(charToRaw("RIFF"), .le32(nsamp * framelen + RIFF_SIZE_OFFSET),
           charToRaw("WAVEfmt "), .le32(PCM_FMT_LEN), .le16(WAVE_FORMAT_PCM),
           .le16(nsig), .le32(sps), .le32(sps * framelen), .le16(framelen),
           .le16(bitspersample), charToRaw("data"), .le32(nsamp * framelen))
  # (x - offset) << shift, or >> -shift for a negative shift
  scale <- 2^shift
  repeat {
    g <- getframes(CHUNK, nsig)      # (getvec(x) == nsig)
    x <- g$v
    if (nrow(x) > 0) {
      y <- sweep(x, 2L, offset)
      y <- sweep(y, 2L, scale, "*")
      y <- cint32(floor(y))
      dim(y) <- dim(x)
      if (putframes(y) != nsig) break
    }
    if (g$stat != nsig || nrow(x) < CHUNK) break
  }
  setsampfreq(sampfreq(NULL))
  if (!is.null(nrec)) newheader(nrec)
  wfdbquit()
  # Prepend the wav header to the signal file (the C program does this with
  # a temporary file and the 'mv', 'cat' and 'rm' commands).
  data <- tryCatch(readBin(ofname, "raw", file.size(ofname)), error = function(e) raw(0))
  writeBin(c(hdr, data), ofname)
  0
}
