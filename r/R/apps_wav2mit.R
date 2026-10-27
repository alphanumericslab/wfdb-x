# apps_wav2mit.R: wav2mit -- create a header file for a .wav file, so that
# it can be read as a WFDB record.
#
# This file is part of wfdb-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of convert/wav2mit.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in gain or units: the new options -G GAIN
# (required) and -U UNITS (required unless the gain is 0) give them (the
# original wrote 12.5 adu/mV for 8-bit and 6400 adu/mV for 16-bit files, in
# millivolts); --legacy, as the first argument, restores the original behavior.
# Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the
# reasons.
#
# Original C program: convert/wav2mit.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2003-2004 George B. Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

app_wav2mit <- function(args = character(0)) {
  app_run(.wav2mit_main, c("wav2mit", args))
}

.wav2mit_help <- function(pname) {
  ceprintf("usage: %s -i FILE.wav -r RECORD [ OPTIONS ... ]\n", pname)
  h <- c("where FILE.wav is the name of the wav-format input signal file,",
         "and OPTIONS may include:",
         " -G GAIN    gain in adu per physical unit (required; 0: uncalibrated)",
         " -h         print this usage summary",
         " -r RECORD  create RECORD.hea (default: FILE.hea)",
         " -U UNITS   physical units (required unless the gain is 0)")
  h <- .app_help_text(h, h[c(3L, 6L)])    # (-G, -U)
  for (s in h) ceprintf("%s\n", s)
}

.wav2mit_main <- function(argv) {
  WAV_HEADER_BYTES <- 44                    # RIFF, fmt and data chunk headers
  RIFF_CHUNK_OVERHEAD <- 8                  # chunk ID and length fields
  PCM_FMT_LEN <- 16                         # length of a PCM format chunk
  WAVE_FORMAT_PCM <- 1
  pname <- argv[1L]
  argc <- length(argv)
  arg <- function(i) argv[i + 1L]          # C argv[i]
  ifname <- NULL
  record <- NULL
  Ggain <- NULL                             # wfdb-x: -G and -U
  Uunits <- NULL
  legacy <- wfdbx_get_legacy()
  i <- 1
  while (i < argc) {
    a <- arg(i)
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "G" && !legacy) {            # gain in adu per physical unit (wfdb-x)
        i <- i + 1
        Ggain <- .app_Gopt(pname, if (i < argc) arg(i) else NULL)
      } else if (c == "U" && !legacy) {     # physical units (wfdb-x)
        i <- i + 1
        Uunits <- .app_Uopt(pname, if (i < argc) arg(i) else NULL)
      } else if (c == "h") {
        .wav2mit_help(pname)
        cexit(1)
      } else if (c == "i") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: name of wav-format input file must follow -i\n", pname)
          cexit(1)
        }
        ifname <- arg(i)
        if (nchar(ifname, type = "bytes") < 5 || !endsWith(ifname, ".wav")) {
          ceprintf("%s: name of input file must end in '.wav'\n", pname)
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
  if (is.null(ifname)) {
    .wav2mit_help(pname)
    cexit(1)
  }
  # wfdb-x: the gain and units must be given explicitly; the C program wrote
  # 12.5 adu/mV for 8-bit and 6400 adu/mV for 16-bit files, with no units
  # (millivolts).  (The sampling frequency and the resolution are those
  # given in the file.)  Legacy mode: as in the C program.
  if (!legacy) .app_require_params(pname, gain = Ggain, units = Uunits)
  if (is.null(record)) {
    # (see docs/KNOWN_C_BEHAVIORS.md)
    b <- charToRaw(ifname)
    record <- rawToChar(b[seq_len(length(b) - 4L)])
  }
  data <- if (file.exists(ifname) && !dir.exists(ifname))
    tryCatch(readBin(ifname, "raw", WAV_HEADER_BYTES), error = function(e) NULL) else NULL
  if (is.null(data)) {
    ceprintf("%s: can't open %s\n", pname, ifname)
    cexit(2)
  }
  flen <- file.size(ifname)
  pos <- 0
  rd <- function(n) {                       # fread of n bytes
    m <- min(n, length(data) - pos)
    b <- if (m > 0) data[pos + seq_len(m)] else raw(0)
    pos <<- pos + max(m, 0)
    b
  }
  tag_is <- function(s) identical(rd(4L), charToRaw(s))
  in16 <- function() {
    b <- as.integer(rd(2L))
    if (length(b) < 2L) return(-1)
    cint16(b[1L] + 256 * b[2L])
  }
  in32 <- function() {
    b <- as.integer(rd(4L))
    if (length(b) < 4L) return(-1)
    sum(b * c(1, 256, 65536, 16777216))
  }
  if (!tag_is("RIFF")) {
    ceprintf("%s: %s is not a .wav-format file\n", pname, ifname)
    cexit(3)
  }
  ln <- in32() + RIFF_CHUNK_OVERHEAD
  if (ln != flen) {
    ceprintf("%s: header chunk of %s has incorrect length (%d, should be %d)\n",
             pname, ifname, ln, flen)
    cexit(3)
  }
  if (!tag_is("WAVE")) {
    ceprintf("%s: %s is not a .wav-format file\n", pname, ifname)
    cexit(3)
  }
  if (!tag_is("fmt ")) {
    ceprintf("%s: format chunk missing or corrupt in %s\n", pname, ifname)
    cexit(3)
  }
  ln <- in32()
  tag <- in16()
  if (ln != PCM_FMT_LEN || tag != WAVE_FORMAT_PCM) {
    ceprintf("%s: unsupported format %d in %s\n", pname, tag, ifname)
    cexit(3)
  }
  nsig <- in16()
  sps <- in32()
  in32()                                    # (bytes per second)
  framelen <- in16()
  bitspersample <- in16()
  if (bitspersample <= 8) {
    wres <- 8
    if (legacy) Ggain <- 12.5        # wfdb-x: the C program's gain
  } else if (bitspersample <= 16) {
    wres <- 16
    if (legacy) Ggain <- 6400        # wfdb-x: the C program's gain
  } else {
    ceprintf("%s: unsupported resolution (%d bits/sample) in %s\n",
             pname, bitspersample, ifname)
    cexit(3)
  }
  if (framelen != nsig * wres %/% 8) {
    ceprintf("%s: format chunk of %s has incorrect frame length\n", pname, ifname)
    cexit(3)
  }
  if (!tag_is("data")) {
    ceprintf("%s: data chunk missing or corrupt in %s\n", pname, ifname)
    cexit(3)
  }
  ln <- in32()
  wnsamp <- if (framelen != 0) ln %/% framelen else 0
  adczero <- if (wres == 16) 0 else 128
  s <- vector("list", max(nsig, 0))
  for (k in seq_len(max(nsig, 0))) {
    s[[k]] <- siginfo(fname = ifname, units = Uunits, gain = Ggain, initval = 0, group = 0,
                      fmt = if (wres == 16) 16 else 80, spf = 1, bsize = 0,
                      adcres = wres, adczero = adczero, baseline = adczero,
                      nsamp = wnsamp, cksum = 0)
    wfdbsetstart(k - 1, WAV_HEADER_BYTES)
  }
  setsampfreq(sps)
  if (setheader(record, s, nsig)) cexit(4)
  wfdbquit()
  0
}
