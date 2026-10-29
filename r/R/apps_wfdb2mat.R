# apps_wfdb2mat.R: wfdb2mat -- convert (all or part of) a WFDB record to a
# MATLAB/Octave .mat file.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of convert/wfdb2mat.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency, gain or units: the
# record must give the sampling frequency (the original assumed 250 Hz),
# uncalibrated signals stay uncalibrated in the output header (the original
# wrote 200 adu/mV), and unspecified units are written as "nd" (the original
# wrote "mV"); --legacy, as the first argument, restores the original behavior.
# Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the
# reasons.
#
# Original C program: convert/wfdb2mat.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2009-2013 George B. Moody; revised 2014-2021 by
#   Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The samples are read with getframes() and written with putframes(), a
# block at a time (the same output as the C program's getvec/putvec loop,
# including the vector of the getvec call that fails at the end of the
# record, which C writes too).

app_wfdb2mat <- function(args = character(0)) {
  app_run(.wfdb2mat_main, c("wfdb2mat", args))
}

.wfdb2mat_help <- function(pname) {
  ceprintf("usage: %s -r RECORD [OPTIONS ...]\n", pname)
  h <- c("where RECORD is the name of the input record, and OPTIONS may include:",
         " -f TIME     begin at specified time",
         " -h          print this usage summary",
         " -H          read multifrequency signals in high resolution mode",
         " -l INTERVAL truncate output after the specified time interval (hh:mm:ss)",
         " -s SIGNAL   [SIGNAL ...]  convert only the specified signal(s)",
         " -S SIGNAL   search for a valid sample of the specified SIGNAL at or after",
         "\t\tthe time specified with -f, and begin converting then",
         " -t TIME     stop at specified time",
         "Outputs are written to the current directory as RECORD.mat and RECORDm.hea.")
  for (s in h) ceprintf("%s\n", s)
}

# The 192-byte prolog of a MATLAB "version 5" .mat file holding one matrix
# named "val" (nrow x ncol elements of type sub4type, nbytesofdata bytes,
# the whole matrix element nbytesmaster bytes).
.wfdb2mat_prolog <- function(nrow, ncol, sub4type, nbytesofdata, nbytesmaster) {
  MAT_HEADER_TEXT_BYTES <- 124              # descriptive text field
  miMATRIX <- 14; miUINT32 <- 6; miINT32 <- 5; miINT8 <- 1
  mxDOUBLE_CLASS <- 6
  le32 <- function(x) {
    x <- x %% 4294967296
    as.raw(c(x %% 256, (x %/% 256) %% 256, (x %/% 65536) %% 256, (x %/% 16777216) %% 256))
  }
  text <- c(charToRaw("MATLAB 5.0"), raw(MAT_HEADER_TEXT_BYTES - 10))
  c(text,
    as.raw(c(0x00, 0x01)), charToRaw("IM"),      # version, endian indicator
    le32(miMATRIX), le32(nbytesmaster),
    le32(miUINT32), le32(8), le32(mxDOUBLE_CLASS), le32(0),   # array flags
    le32(miINT32), le32(8), le32(nrow), le32(ncol),           # dimensions
    le32(miINT8), le32(3), charToRaw("val"), raw(5),          # array name
    le32(sub4type), le32(nbytesofdata))                       # data tag
}

.wfdb2mat_main <- function(argv) {
  MAT8 <- 2; MAT16 <- 3; MAT32 <- 5         # MATLAB data types (miUINT8, ...)
  MAT_PROLOG_BYTES <- 192
  MAT_MAX_BYTES <- 2147483648               # 2 GB limit of .mat files
  MAT_ALIGN <- 8                            # data elements are 8-byte aligned
  MAT_TAGS_BYTES <- 56                      # matrix element bytes besides the data
  INITIAL_LENGTH_GUESS <- 16 * 1024         # (for records of unknown length)
  FMT80_OFFSET <- 128                       # (format 80 samples are offset)
  CHUNK <- 65536                            # sample vectors read at a time
  pname <- argv[1L]
  argc <- length(argv)
  arg <- function(i) argv[i + 1L]          # C argv[i]
  record <- NULL
  search <- NULL
  highres <- 0
  nosig <- 0
  isiglist <- 0
  from <- 0; maxl <- 0; to <- 0
  i <- 1
  while (i < argc) {
    a <- arg(i)
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "f") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: time must follow -f\n", pname)
          cexit(1)
        }
        from <- i
      } else if (c == "h") {
        .wfdb2mat_help(pname)
        cexit(0)
      } else if (c == "H") {
        highres <- 1
      } else if (c == "l") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: max output length must follow -l\n", pname)
          cexit(1)
        }
        maxl <- i
      } else if (c == "r") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: record name must follow -r\n", pname)
          cexit(1)
        }
        record <- arg(i)
      } else if (c == "s") {
        isiglist <- i + 1
        while (i + 1 < argc && !startsWith(arg(i + 1), "-")) {
          i <- i + 1
          nosig <- nosig + 1
        }
        if (nosig == 0) {
          ceprintf("%s: signal list must follow -s\n", pname)
          cexit(1)
        }
      } else if (c == "S") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: signal name or number must follow -S\n", pname)
          cexit(1)
        }
        search <- arg(i)
      } else if (c == "t") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: time must follow -t\n", pname)
          cexit(1)
        }
        to <- i
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
  if (is.null(record)) {
    .wfdb2mat_help(pname)
    cexit(1)
  }
  nisig <- isigopen(record, 0)$nsig
  if (nisig <= 0) cexit(2)
  r <- isigopen(record, nisig)
  nisig <- r$nsig
  si <- r$si
  if (nisig <= 0) cexit(2)
  # WFDB-x: uncalibrated signals remain uncalibrated in the output (the C
  # program assumed 200 adu/mV), and the output header needs the sampling
  # frequency (the C program assumed 250 Hz).  Legacy mode: as in the C
  # program.
  legacy <- wfdbx_get_legacy()
  if (legacy) for (k in seq_len(nisig)) if (si[[k]]$gain == 0) si[[k]]$gain <- WFDB_DEFGAIN
  if (highres) setgvmode(WFDB_HIGHRES)
  freq <- sampfreq(NULL)
  if (isTRUE(freq <= 0) && !legacy) .app_nofreq(pname, record, 2)
  if (from > 0) from <- abs(strtim(arg(from)))
  if (isigsettime(from) < 0) cexit(2)
  if (to > 0) to <- abs(strtim(arg(to)))
  if (nosig) {
    sig <- numeric(nosig)
    for (k in seq_len(nosig)) {
      s <- findsig(arg(isiglist + k - 1))
      if (s < 0) {
        ceprintf("%s: can't read signal '%s'\n", pname, arg(isiglist + k - 1))
        cexit(2)
      }
      sig[k] <- s
    }
  } else {
    nosig <- nisig
    sig <- seq_len(nosig) - 1
  }
  if (!is.null(search)) {
    s <- findsig(search)
    if (s >= 0) from <- tnextvec(s, from)
    if (s < 0 || from < 0) {
      ceprintf("%s: can't read signal '%s'\n", pname, search)
      cexit(2)
    }
  }
  if (maxl > 0) maxl <- abs(strtim(arg(maxl)))
  if (maxl && (to == 0 || to > from + maxl)) to <- from + maxl
  t <- strtim("e")
  if (t == 0) {
    # The length of the record is unknown: find it by binary search.
    wfdbquiet()
    lower <- 0
    upper <- LONG_MAX
    t <- INITIAL_LENGTH_GUESS
    while (lower < upper) {
      if (isigsettime(t) >= 0 && getvec()$stat > 0) {
        lower <- t + 1
      } else {
        upper <- t
      }
      if (upper == LONG_MAX && t < LONG_MAX %/% 2) {
        t <- t * 2
      } else {
        t <- lower + (upper - lower) %/% 2
      }
    }
    wfdbverbose()
    if (isigsettime(from) < 0) cexit(2)
  }
  if (to == 0 || to > t) to <- t
  if (to <= from) {
    wfdbquit()
    ceprintf("%s: no output\n", pname)
    ceprintf(" Use the -f and -t options to specify time limits\n(or type '%s -h' for help)\n",
             pname)
    cexit(1)
  }

  # The output record name: the input record name without its directory
  # part (and without a final '/'), with '.' replaced by '_', and 'm'
  # appended.
  rb <- charToRaw(record)
  sfname <- if (length(rb) && rb[length(rb)] == as.raw(0x2f)) 1L else 0L
  p <- length(rb) - 1L                      # (0-based, as in C)
  repeat {
    p <- p - 1L
    if (!(p > 0L)) break
    if (rb[p + 1L] == as.raw(0x2f)) {
      p <- p + 1L
      break
    }
  }
  if (p < 0L) p <- 0L
  base <- rb[seq_along(rb) > p]
  base <- base[seq_len(length(base) - sfname)]
  base[base == as.raw(0x2e)] <- as.raw(0x5f)
  orec <- paste0(rawToChar(base), "m")
  matname <- paste0(orec, ".mat")

  # bytes per sample: enough for the ADC resolution (or format) of every
  # output signal
  nbytes <- 1
  for (k in seq_len(nosig)) {
    s <- si[[sig[k] + 1]]
    if (s$adcres > 0) {
      if (s$adcres > 16) {
        nbytes <- 4
      } else if (s$adcres > 8 && nbytes < 2) {
        nbytes <- 2
      }
    } else {
      if (s$fmt %in% c(24, 32)) {
        nbytes <- 4
      } else if (s$fmt != 80 && nbytes < 2) {
        nbytes <- 2
      }
    }
  }
  if (nbytes == 1) {
    sub4type <- MAT8
    wfdbtype <- 80
  } else if (nbytes == 2) {
    sub4type <- MAT16
    wfdbtype <- 16
  } else {
    sub4type <- MAT32
    wfdbtype <- 32
  }
  adczero <- vapply(si, function(s) s$adczero, 0)[sig + 1]
  so <- vector("list", nosig)
  for (k in seq_len(nosig)) {
    o <- si[[sig[k] + 1]]
    o$fname <- matname
    o$group <- 0
    o$spf <- 1
    o$fmt <- wfdbtype
    o$adczero <- 0
    o$baseline <- o$baseline - adczero[k]
    if (is.null(o$units)) {
      o$units <- if (legacy) "mV" else "nd"   # WFDB-x: not assumed to be mV (but in legacy mode)
    } else if (!nzchar(o$units)) {
      o$units <- "nd"
    }
    so[[k]] <- o
  }
  max_length <- MAT_MAX_BYTES %/% nbytes %/% nosig
  if (to - from > max_length) {
    ceprintf("%s: cannot write mat file - data size exceeds 2GB limit\n", pname)
    cexit(1)
  }
  nbytesofdata <- nbytes * nosig * (to - from)
  lremain <- nbytesofdata %% MAT_ALIGN
  if (lremain == 0) {
    nbytesmaster <- nbytesofdata + MAT_TAGS_BYTES
  } else {
    nbytesmaster <- nbytesofdata + MAT_TAGS_BYTES + MAT_ALIGN - lremain
    for (k in seq_len(nosig)) so[[k]]$bsize <- MAT_ALIGN
  }
  if (osigfopen(so, nosig) != nosig) {
    wfdbquit()
    cexit(1)
  }
  wfdbputprolog(.wfdb2mat_prolog(nosig, to - from, sub4type, nbytesofdata, nbytesmaster),
                MAT_PROLOG_BYTES, 0)

  # The samples (as the C loop: t = from; while (t < to && stat >= 0) {
  # stat = getvec(vi); putvec(vi - adczero); t++; })
  t <- from
  repeat {
    g <- getframes(min(CHUNK, to - t))
    x <- g$v
    if (g$stat < 0) {
      # (the vector of the getvec call that failed is written too)
      x <- rbind(x, .sig$gvec[seq_len(ncol(x))])
    }
    if (nrow(x) > 0) {
      y <- cint32(sweep(x[, sig + 1, drop = FALSE], 2L, adczero))
      dim(y) <- c(nrow(x), nosig)
      if (putframes(y) != nosig) break
      t <- t + nrow(x)
    }
    if (g$stat < 0 || t >= to) break
  }
  if (t != to) {
    ceprintf("%s (warning): final %d columns are invalid\n", pname, to - t)
    while (t < to) {
      n <- min(CHUNK, to - t)
      putframes(matrix(WFDB_INVALID_SAMPLE, n, nosig))
      t <- t + n
    }
  }
  setsampfreq(freq)
  p <- mstimstr(-from)
  if (startsWith(p, "[")) setbasetime(substring(p, 2L))
  newheader(orec)
  repeat {
    p <- getinfo(NULL)
    if (is.null(p)) break
    putinfo(p)
  }
  putinfo(.f("Creator: %s", pname))
  p <- .f("Source: record %s", record)
  q <- sub("^ +", "", mstimstr(0))
  if (from != 0 || startsWith(q, "[")) p <- paste0(p, "  Start: ", q)
  putinfo(p)
  offset <- if (wfdbtype == 80) FMT80_OFFSET else 0
  one <- to == from + 1
  cprintf("%s\n", p)
  cprintf("val has %d row%s (signal%s) and %d column%s (sample%s/signal)\n",
          nosig, if (nosig == 1) "" else "s", if (nosig == 1) "" else "s",
          to - from, if (one) "" else "s", if (one) "" else "s")
  cprintf("Duration: %s\n", timstr(to - from))
  cprintf("Sampling frequency: %.12g Hz  Sampling interval: %.10g sec\n", freq, 1 / freq)
  cprintf("Row\tSignal\tGain\tBase\tUnits\n")
  for (k in seq_len(nosig)) {
    cprintf("%d\t%s\t%.12g\t%d\t%s\n", k, so[[k]]$desc, so[[k]]$gain,
            so[[k]]$baseline + offset, so[[k]]$units)
  }
  cprintf("\nTo convert from raw units to the physical units shown\nabove, call the 'rdmat.m' function from the wfdb-matlab\ntoolbox: https://physionet.org/physiotools/matlab/wfdb-app-matlab/\n")
  wfdbquit()
  0
}
