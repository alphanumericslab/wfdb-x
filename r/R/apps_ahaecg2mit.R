# apps_ahaecg2mit.R: ahaecg2mit -- convert AHA DB files (from the AHA DVD)
# to WFDB format.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of convert/ahaecg2mit.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in signal parameters: the new options -F
# FREQ, -G GAIN, -R BITS and -U UNITS give the sampling frequency, gain, ADC
# resolution and units, and are required (-U unless the gain is 0; the original
# assumed those of the AHA database: 250 Hz, 400 adu/mV, 12 bits and
# millivolts); the options precede the input files, in any order; the
# short-format part of a long-format file (skipped by -s) is located from -F;
# --legacy, as the first argument, restores the original behavior. Each change
# is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
#
# Original C program: convert/ahaecg2mit.c, WFDB Software Package 10.7.0.
#   By George B. Moody (2008); revised 2017 by Benjamin Moody. The C source has
#   no copyright or license notice.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# Each input file is read whole and decoded with vector operations: the
# samples and annotations of the binary (.ecg) format, and for the text
# (.txt) format the successive calls of readtxtdata(), including the
# emulation of its 16-byte line buffer (see docs/KNOWN_C_BEHAVIORS.md).

app_ahaecg2mit <- function(args = character(0)) {
  app_run(.ahaecg2mit_main, c("ahaecg2mit", args))
}

# A long-format AHA record begins with 145 minutes that are not part of the
# short-format (35-minute) record (-s skips them; wfdb-x: their length in
# samples is computed from -F, where the C program assumed 250 Hz).
.AHA_SKIP_MINUTES <- 145
.AHA_ECG_RECLEN <- 5L          # bytes per sample in .ecg files
.AHA_TXT_BUFLEN <- 16L         # line buffer of readtxtdata()

.ahaecg2mit_main <- function(argv) {
  argc <- length(argv)
  legacy <- wfdbx_get_legacy()
  if (argc < 2L || argv[2L] == "-h") {
    if (legacy) {                           # wfdb-x: the usage of the C program
      ceprintf("usage: %s [-s] RECORD.XXX [RECORD.XXX]...\n", argv[1L])
    } else {
      ceprintf("usage: %s [-s] -F FREQ -G GAIN -R BITS -U UNITS RECORD.XXX [RECORD.XXX]...\n",
               argv[1L])
    }
    ceprintf("%s", paste0(
      " where RECORD.XXX is the name of the AHA DVD input file to be converted\n",
      " ('RECORD' is one of the 4-digit AHA DB record names, and 'XXX' may be either\n",
      " 'ecg' or 'txt', depending on the version of the AHA DVD.)\n",
      " Output files are RECORD.hea (text), RECORD.atr (binary), RECORD.dat (binary).\n",
      " Two or more input files may be converted in a single run.\n",
      " Use -s to make short-format (35-minute) records from long-format (2.5 hour)\n",
      " input files.  When using -s, the second digit in the output record name is\n",
      " incremented by 2.\n"))
    if (!legacy) {
      ceprintf("%s", paste0(
        " -F, -G, -R and -U give the sampling frequency (Hz), gain (adu per physical\n",
        " unit), ADC resolution (bits) and units of the signals; for the AHA DVD\n",
        " files, use -F 250 -G 400 -R 12 -U mV.\n"))
    }
    cexit(1)
  }
  # wfdb-x: options (-s and the signal parameters -F, -G, -R and -U) precede
  # the input files, in any order; the C program assumed the parameters of
  # the AHA database (250 Hz, 400 adu/mV, 12 bits, millivolts).
  pname <- argv[1L]
  sflag <- FALSE
  Ffreq <- 0
  Ggain <- NULL
  Rres <- 0
  Uunits <- NULL
  opt <- function() if (i <= argc) argv[i] else NULL
  i <- 2L
  if (legacy) {
    # wfdb-x: in legacy mode, the option of the C program (-s only, as the
    # first argument), and the parameters of the AHA database that it set
    # (250 Hz, 400 adu/mV, 12 bits, millivolts).
    if (argv[2L] == "-s") {
      sflag <- TRUE
      i <- 3L
    }
    Ffreq <- 250
    Ggain <- 400
    Rres <- 12
    Uunits <- "mV"
  } else while (i <= argc && grepl("^-[sFGRU]$", argv[i], useBytes = TRUE)) {
    c <- substr(argv[i], 2L, 2L)
    if (c == "s") {
      sflag <- TRUE                         # produce short-format (35-minute) records
    } else if (c == "F") {
      i <- i + 1L
      Ffreq <- .app_Fopt(pname, opt())
    } else if (c == "G") {
      i <- i + 1L
      Ggain <- .app_Gopt(pname, opt())
    } else if (c == "R") {
      i <- i + 1L
      Rres <- .app_Ropt(pname, opt())
    } else {
      i <- i + 1L
      Uunits <- .app_Uopt(pname, opt())
    }
    i <- i + 1L
  }
  .app_require_params(pname, Ffreq, Ggain, Rres, Uunits)
  par <- list(freq = Ffreq, gain = Ggain, res = Rres, units = Uunits)
  nskip <- trunc(.AHA_SKIP_MINUTES * 60 * Ffreq)   # samples skipped by -s
  while (i <= argc) {
    name <- charToRaw(argv[i])
    n <- length(name)
    ext <- rawToChar(name[max(1L, n - 3L):n])
    if (ext %in% c(".ecg", ".ECG")) {
      binary <- TRUE
    } else if (ext %in% c(".txt", ".TXT")) {
      binary <- FALSE
    } else {
      ceprintf("%s: ignoring '%s'\n", argv[1L], argv[i])
      i <- i + 1L
      next
    }
    if (file.access(argv[i], 4L) != 0L || dir.exists(argv[i])) {
      # (sic: argv[1], which the loop may have modified, not the file)
      ceprintf("%s: can't open '%s'\n", argv[1L], argv[2L])
      i <- i + 1L
      next
    }
    data <- readBin(argv[i], "raw", file.size(argv[i]))
    stem <- name[seq_len(n - 4L)]
    argv[i] <- rawToChar(stem)            # (*p = '\0' strips the extension)
    ns <- length(stem)
    record <- stem[seq_len(min(ns, 4L)) + max(ns - 4L, 0L)]   # (its last 4 characters)
    r <- if (binary) {
      .aha_readbin(data, if (sflag) nskip * .AHA_ECG_RECLEN else 0)
    } else {
      .aha_readtxt(data, if (sflag) nskip else 0)
    }
    # (a record name shorter than 2 characters is left unchanged)
    if (sflag && length(record) > 1L) record[2L] <- as.raw((as.integer(record[2L]) + 2L) %% 256L)
    .aha_process(rawToChar(record), r$v, r$a, par)
    i <- i + 1L
  }
  0
}

# Write record `record`: the samples v (two columns) and the annotations a,
# with the signal parameters par (freq, gain, res, units: -F, -G, -R, -U).
.aha_process <- function(record, v, a, par) {
  setsampfreq(par$freq)                     # wfdb-x: -F (the C program set 250 Hz)
  si <- lapply(c("ECG0", "ECG1"), function(desc) {
    siginfo(fname = paste0(record, ".dat"), desc = desc, units = par$units,
            gain = par$gain, fmt = 212, adcres = par$res, spf = 0)
  })
  if (osigfopen(si, 2) != 2 || annopen(record, list(anninfo("atr", WFDB_WRITE)), 1) < 0) {
    wfdbquit()
    return(invisible())
  }
  if (nrow(v) > 0L) putframes(v)
  if (length(a$time)) .putann_bulk(0, a)
  newheader(record)
  wfdbquit()
  ceprintf("wrote %s.atr, %s.dat, and %s.hea\n", record, record, record)
}

# Annotations at times `time` with the AHA codes `code` (byte values).
.aha_annots <- function(time, code) {
  list(time = time, anntyp = ammap(cint8(code)), subtyp = -(code == utf8ToInt("U")))
}

# readbindata(): 5-byte records (two little-endian 16-bit samples, and an
# AHA code or '.'), from byte `off` of the file.
.aha_readbin <- function(data, off) {
  b <- as.integer(data)
  if (off > 0) b <- b[-seq_len(min(off, length(b)))]
  nr <- length(b) %/% .AHA_ECG_RECLEN
  R <- matrix(b[seq_len(.AHA_ECG_RECLEN * nr)], .AHA_ECG_RECLEN)
  v <- cbind(R[1L, ] + 256 * R[2L, ], R[3L, ] + 256 * R[4L, ])
  k <- which(R[5L, ] != utf8ToInt("."))
  # t starts at -1 and is incremented after each sample is written
  list(v = v, a = .aha_annots(k - 2, R[5L, k]))
}

# readtxtdata(), called repeatedly (after nskip calls with -s) until it
# returns 0.  Each call reads up to 16 characters, up to a CR, LF or EOF (a
# byte 255 reads as EOF), into a buffer that keeps the bytes of earlier
# lines and is not NUL-terminated (bytes beyond it read as NUL), then
# scans it with sscanf(buf, "%d,%d,\"%c", ...).
.aha_readtxt <- function(data, nskip) {
  BL <- .AHA_TXT_BUFLEN
  b <- as.integer(data)
  nb <- length(b)
  # the calls: q full calls (16 characters) per segment, then one more
  term <- c(which(b == 13L | b == 10L | b == 255L), nb + 1L)   # CR, LF, (char) EOF
  S <- c(1L, term[-length(term)] + 1L)          # segment starts
  L <- term - S                                  # characters in each segment
  q <- L %/% BL
  K <- sum(q + 1L)
  seg <- rep.int(seq_along(term), q + 1L)
  first <- cumsum(c(1L, q[-length(q)] + 1L))
  r <- seq_len(K) - first[seg]                   # index of a call in its segment
  st <- S[seg] + BL * r                          # first character read
  last <- r == q[seg]
  m <- rep.int(BL, K)                            # characters stored
  m[last] <- L[seg[last]] - BL * q[seg[last]]
  # the last character read (c), and whether the call returns at EOF
  cend <- integer(K)
  full <- !last
  cend[full] <- b[st[full] + BL - 1L]
  tl <- term[seg[last]]
  atend <- tl > nb
  cl <- integer(length(tl))
  cl[!atend] <- b[tl[!atend]]
  cend[last] <- cl
  eofc <- logical(K)
  eofc[last] <- atend | cl == 255L
  # the results of sscanf: n and the values assigned
  nres <- integer(K)
  v0 <- numeric(K)
  v1 <- numeric(K)
  cc <- integer(K)
  done <- logical(K)
  # Fast path: the characters stored by the call are converted completely,
  # so the rest of the buffer does not matter.  (NUL ends the string in C:
  # it is mapped to \001, which the pattern does not accept for %c; calls
  # with a real \001 there take the slow path.)
  bm <- data
  bm[bm == as.raw(0L)] <- as.raw(1L)
  strs <- substring(rawToChar(bm), st, st + m - 1L)
  mt <- regexpr("^[ \t\x0b\x0c]*([+-]?[0-9]{1,9}),[ \t\x0b\x0c]*([+-]?[0-9]{1,9}),\"[^\x01]",
                strs, perl = TRUE, useBytes = TRUE)
  ok <- which(mt > 0L & !eofc)
  if (length(ok)) {
    cs <- attr(mt, "capture.start")[ok, , drop = FALSE]
    cn <- attr(mt, "capture.length")[ok, , drop = FALSE]
    so <- strs[ok]
    nres[ok] <- 3L
    v0[ok] <- as.numeric(substring(so, cs[, 1L], cs[, 1L] + cn[, 1L] - 1L))
    v1[ok] <- as.numeric(substring(so, cs[, 2L], cs[, 2L] + cn[, 2L] - 1L))
    cc[ok] <- b[st[ok] + attr(mt, "match.length")[ok] - 1L]
    done[ok] <- TRUE
  }
  # A call that stores nothing leaves the buffer as the previous call did.
  z <- which(m == 0L & !eofc)
  z <- z[z > 1L]
  z <- z[done[z - 1L] & !eofc[z - 1L]]
  nres[z] <- nres[z - 1L]
  v0[z] <- v0[z - 1L]
  v1[z] <- v1[z - 1L]
  cc[z] <- cc[z - 1L]
  done[z] <- TRUE
  # Slow path: build the buffer and scan it.
  slow <- which(!done & !eofc)
  bufs <- vector("list", K)
  if (length(slow)) {
    buf <- matrix(0L, length(slow), BL)
    idx <- seq_len(K)
    for (j in seq_len(BL)) {
      kk <- cummax(idx * (m >= j))[slow]       # the last call that wrote byte j
      has <- kk > 0L
      buf[has, j] <- b[st[kk[has]] + j - 1L]
    }
    for (k in seq_along(slow)) {
      s <- as.raw(buf[k, ])
      bufs[[slow[k]]] <- s
      sc <- csscanf(s, "%d,%d,\"%c")
      nres[slow[k]] <- sc$n
      if (length(sc$v) >= 1L) v0[slow[k]] <- sc$v[[1L]]
      if (length(sc$v) >= 2L) v1[slow[k]] <- sc$v[[2L]]
      if (length(sc$v) >= 3L) cc[slow[k]] <- as.integer(charToRaw(sc$v[[3L]]))
    }
  }
  # v[0] and v[1] keep their values when they are not assigned.
  idx <- seq_len(K)
  a0 <- cummax(idx * (nres >= 1L & !eofc))
  a1 <- cummax(idx * (nres >= 2L & !eofc))
  V0 <- numeric(K)
  V1 <- numeric(K)
  V0[a0 > 0L] <- v0[a0[a0 > 0L]]
  V1[a1 > 0L] <- v1[a1[a1 > 0L]]
  err <- !eofc & nres < 3L
  # the calls of the -s skip, then those of the conversion, up to the first
  # that returns 0
  k0 <- min(nskip, K)
  k1 <- k0 + match(TRUE, (err | eofc)[seq_len(K - k0) + k0])
  if (is.na(k1)) k1 <- K + 1L
  for (k in which(err[seq_len(min(k1, K))])) {
    ceprintf("Error: improperly formatted input!\n")
    ceprintf(" n = %d, buf = |%s|, v[0] = %d, v[1] = %d, c = |%c|\n",
             nres[k], bufs[[k]], V0[k], V1[k], cend[k])
  }
  ks <- seq_len(max(k1 - k0 - 1L, 0L)) + k0
  c <- cc[ks]
  an <- which(c != utf8ToInt("\""))
  # t starts at -1 and is incremented before each sample is written
  list(v = cbind(V0[ks], V1[ks]), a = .aha_annots(an - 1, c[an]))
}
