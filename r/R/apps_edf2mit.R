# apps_edf2mit.R: edf2mit -- convert an EDF (European Data Format) file to
# MIT format header and signal files.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of convert/edf2mit.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: none, apart from the language and the --legacy
# option (as the first argument, it restores the original behavior).
#
# Original C program: convert/edf2mit.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1996-2004 George B. Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The input file is read whole; the data records are decoded with vector
# operations and written with putframes() (the same output as the C
# program's putvec() calls, including its handling of a truncated last
# data record).  The header fields are read through an emulation of the C
# program's reusable 81-byte buffer (see docs/KNOWN_C_BEHAVIORS.md).

app_edf2mit <- function(args = character(0)) {
  app_run(.edf2mit_main, c("edf2mit", args))
}

.edf2mit_help <- function(pname) {
  ceprintf("usage: %s [OPTIONS ...]\n", pname)
  h <- c("where OPTIONS may include:",
         " -b          input is in big-endian byte order (default: little-endian)",
         " -h          print this usage summary",
         " -i EDFILE   read the specified European Data Format file",
         " -r RECORD   create the specified RECORD (default: input file name without",
         "              suffix)",
         " -s SIGNAL [SIGNAL ...]  copy only the specified signal(s) (use signal",
         "              numbers, beginning with zero;  default: copy all signals)",
         " -v          print debugging output",
         "This program reads an EDF file and creates MIT-format signal and header",
         "files containing the same data.")
  for (s in h) ceprintf("%s\n", s)
}

# gcd() of edf2mit.c: the greatest common divisor of two sampling
# frequencies, within a tolerance of 0.1% of the smaller one.
.edf2mit_gcd <- function(x, y) {
  tol <- 0.001 * (if (x > y) y else x)
  repeat {
    if (x > y && x - y > tol) {
      x <- x - y
    } else if (y > x && y - x > tol) {
      y <- y - x
    } else {
      return(x)
    }
  }
}

# The default record name: the input file name up to its first '.', with
# characters other than letters and digits replaced by '_', truncated to
# WFDB_MAXRNL characters (see docs/KNOWN_C_BEHAVIORS.md).
.edf2mit_recname <- function(fname) {
  b <- charToRaw(fname)
  b <- b[seq_len(min(length(b), WFDB_MAXRNL))]
  dot <- match(as.raw(0x2e), b)
  if (!is.na(dot)) b <- b[seq_len(dot - 1L)]
  alnum <- (b >= as.raw(0x30) & b <= as.raw(0x39)) |
    (b >= as.raw(0x41) & b <= as.raw(0x5a)) | (b >= as.raw(0x61) & b <= as.raw(0x7a))
  b[!alnum] <- as.raw(0x5f)
  rawToChar(b)
}

.edf2mit_main <- function(argv) {
  FIELD_BUFSIZE <- 81L      # size of the C program's header field buffer
  EDF_MAGIC <- "0       "   # version field of an EDF header
  SP <- as.raw(0x20)
  pname <- argv[1L]
  argc <- length(argv)
  arg <- function(i) argv[i + 1L]          # C argv[i]
  record <- ""
  big_endian <- 0
  vflag <- 0
  siglist <- numeric(0)
  data <- NULL                              # the whole input file
  iname <- NULL                             # its name, as given
  i <- 1
  while (i < argc) {
    a <- arg(i)
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "b") {
        big_endian <- 1
      } else if (c == "h") {
        .edf2mit_help(pname)
        cexit(0)
      } else if (c == "i") {
        i <- i + 1
        if (i < argc) {
          fn <- arg(i)
          iname <- fn
          if (fn == "-") {
            data <- stdin_bytes()
          } else {
            data <- if (!file.exists(fn)) NULL else if (dir.exists(fn)) raw(0) else
              tryCatch(readBin(fn, "raw", file.size(fn)), error = function(e) NULL)
            if (is.null(data)) {
              ceprintf("%s: can't read %s\n", pname, fn)
              cexit(1)
            }
            if (record == "") record <- .edf2mit_recname(fn)
          }
        }
      } else if (c == "r") {
        i <- i + 1
        if (i < argc) {
          b <- charToRaw(arg(i))
          record <- rawToChar(b[seq_len(min(length(b), WFDB_MAXRNL))])
        } else {
          ceprintf("%s: record name must follow -r\n", pname)
          cexit(1)
        }
      } else if (c == "s") {
        j <- 0
        while (i + j + 1 < argc && !startsWith(arg(i + j + 1), "-")) j <- j + 1
        if (j == 0) {
          ceprintf("%s: signal list must follow -s\n", pname)
          cexit(1)
        }
        siglist <- c(siglist, vapply(arg(i + seq_len(j)), atoi, 0, USE.NAMES = FALSE))
        i <- i + j
      } else if (c == "v") {
        vflag <- 1
      }
    }
    i <- i + 1
  }
  if (is.null(data)) {
    .edf2mit_help(pname)
    cexit(1)
  }
  if (record == "" || newheader(record) < 0) {
    ceprintf("\n")
    .edf2mit_help(pname)
    ceprintf("\nRun %s again, specifying a valid name for the output record,\n", argv[1L])
    ceprintf("using the -r option as described above.\n\n")
    ceprintf("  Valid record names may include letters, digits, and underscores only.\n")
    cexit(1)
  }
  hea_file <- wfdbfile(NULL, NULL)          # (the header newheader created)
  # WFDB-x: the 256-byte fixed part of the EDF header is read at once.  If
  # the input file is shorter (C takes the missing fields from uninitialized
  # memory; see KNOWN_C_BEHAVIORS.md), and its first 8 bytes are not those
  # of another format, the program stops, and no output file remains.
  if (length(data) < 256 &&
      (length(data) < 8 || identical(data[1:8], charToRaw(EDF_MAGIC)))) {
    wfdbquit()
    if (!is.null(hea_file)) unlink(hea_file)
    ceprintf("%s: incomplete EDF header in %s\n", pname, iname)
    cexit(2)
  }

  # fread() from the input file
  pos <- 0
  fread <- function(n) {
    m <- min(n, length(data) - pos)
    if (m <= 0) return(raw(0))
    b <- data[pos + seq_len(m)]
    pos <<- pos + m
    b
  }
  # The header field buffer: read n bytes into it, set buf[n] to a space,
  # and clear the trailing spaces from buf[trim] down (0-based indices, as
  # in C).  Returns the index of the last byte left (-1 if none).
  buf <- raw(FIELD_BUFSIZE)
  field <- function(n, trim = n) {
    b <- fread(n)
    buf[seq_along(b)] <<- b
    if (n < FIELD_BUFSIZE) buf[n + 1L] <<- SP
    j <- trim
    while (j >= 0 && buf[j + 1L] == SP) {
      buf[j + 1L] <<- as.raw(0L)
      j <- j - 1
    }
    j
  }
  fstr <- function() cstr(buf)
  show <- function(fmt, ...) if (vflag) cprintf(fmt, ...)

  b <- fread(8)
  buf[seq_along(b)] <- b
  if (!identical(buf[1:8], charToRaw(EDF_MAGIC))) {
    ceprintf("%s: input does not appear to be EDF -- no conversion attempted.\n", pname)
    cexit(2)
  }
  buf[9L] <- SP
  j <- 8
  while (j >= 0 && buf[j + 1L] == SP) {
    buf[j + 1L] <- as.raw(0L)
    j <- j - 1
  }
  show("EDF version number: '%s'\n", fstr())
  field(80)
  show("Patient ID: '%s'\n", fstr())
  field(80)
  show("Recording ID: '%s'\n", fstr())
  field(8)
  show("Recording date: '%s'\n", fstr())
  ints3 <- function() {
    r <- csscanf(fstr(), "%d%*c%d%*c%d")
    v <- vapply(r$v, function(x) cint32(x), 0)
    c(v, numeric(3 - length(v)))
  }
  d <- ints3()
  day <- d[1L]; month <- d[2L]; year <- d[3L]
  if (year < 1970) year <- year + 1900
  if (year < 1970) year <- year + 100     # (two-digit years: 1970 to 2069)
  field(8)
  show("Recording time: '%s'\n", fstr())
  d <- ints3()
  hour <- d[1L]; minute <- d[2L]; second <- d[3L]
  field(8)
  show("Number of bytes in header record: '%s'\n", fstr())
  if (field(44) > 0) show("Free space: '%s'\n", fstr())
  field(8)
  show("Number of data records: '%s'\n", fstr())
  field(8)
  show("Duration of each data record in seconds: '%s'\n", fstr())
  r <- csscanf(fstr(), "%lf")
  spr <- if (r$n == 1) r$v[[1L]] else 0
  if (spr <= 0) spr <- 1
  field(4)
  show("Number of signals: '%s'\n", fstr())
  r <- csscanf(fstr(), "%d")
  nsig <- if (r$n == 1) cint32(r$v[[1L]]) else 0
  if (nsig < 1) cexit(1)
  si <- replicate(nsig, siginfo(gain = 0, spf = 0), simplify = FALSE)
  spb <- numeric(nsig)
  sigdmax <- sigdmin <- sigpmax <- sigpmin <- sampfreq <- numeric(nsig)
  if (!length(siglist)) {
    siglist <- seq_len(nsig) - 1
  } else {
    for (s in siglist) {
      if (s < 0 || s >= nsig) {
        ceprintf("%s: invalid signal number, %d, in signal list\n", pname, s)
        cexit(1)
      }
    }
  }
  nosig <- length(siglist)
  for (k in seq_len(nsig)) {
    field(16, 15)                         # (see docs/KNOWN_C_BEHAVIORS.md)
    show("Signal %d label: '%s'\n", k - 1, fstr())
    si[[k]]$desc <- fstr()
  }
  for (k in seq_len(nsig)) {
    if (field(80) > 0) show("Signal %d transducer type: '%s'\n", k - 1, fstr())
  }
  for (k in seq_len(nsig)) {
    field(8)
    show("Signal %d physical dimension: '%s'\n", k - 1, fstr())
    si[[k]]$units <- fstr()
  }
  numfields <- function(label, conv, x) {
    for (k in seq_len(nsig)) {
      field(8)
      show("Signal %d %s: '%s'\n", k - 1, label, fstr())
      r <- csscanf(fstr(), conv)
      if (r$n == 1) x[k] <- r$v[[1L]]
    }
    x
  }
  sigpmin <- numfields("physical minimum", "%lf", sigpmin)
  sigpmax <- numfields("physical maximum", "%lf", sigpmax)
  sigdmin <- numfields("digital minimum", "%ld", sigdmin)
  sigdmax <- numfields("digital maximum", "%ld", sigdmax)
  for (k in seq_len(nsig)) {
    if (sigpmax[k] == sigpmin[k]) {
      ceprintf("gain for signal %d is undefined\n", k - 1)
      next
    }
    si[[k]]$adczero <- cint32(cdiv(sigdmax[k] + 1 + sigdmin[k], 2))
    adcrange <- sigdmax[k] - sigdmin[k]
    si[[k]]$gain <- adcrange / (sigpmax[k] - sigpmin[k])
    j <- 0
    while (adcrange > 1) {
      adcrange <- cdiv(adcrange, 2)
      j <- j + 1
    }
    si[[k]]$adcres <- j
    si[[k]]$baseline <- d2i(sigdmax[k] - sigpmax[k] * si[[k]]$gain + 1)
  }
  for (k in seq_len(nsig)) {
    if (field(80) > 0) show("Signal %d filtering information: '%s'\n", k - 1, fstr())
  }
  for (k in seq_len(nsig)) {
    field(8)
    show("Signal %d number of samples per record: '%s'\n", k - 1, fstr())
    r <- csscanf(fstr(), "%lf")
    if (r$n == 1) sampfreq[k] <- r$v[[1L]]
    r <- csscanf(fstr(), "%d")
    if (r$n == 1) spb[k] <- cint32(r$v[[1L]])
    sampfreq[k] <- sampfreq[k] / spr
  }
  for (k in seq_len(nsig)) {
    if (field(32) > 0) show("Signal %d free space: '%s'\n", k - 1, fstr())
  }

  sl <- siglist + 1                        # (1-based signal indices)
  sps <- sampfreq[sl[1L]]
  for (k in seq_len(nosig)[-1L]) {
    if (sampfreq[sl[k]] != sps) sps <- .edf2mit_gcd(sps, sampfreq[sl[k]])
  }
  setsampfreq(sps)
  setbasetime(.f("%02d:%02d:%02d %02d/%02d/%04d", hour, minute, second, day, month, year))
  fname <- paste0(record, ".dat")
  so <- vector("list", nosig)
  for (k in seq_len(nosig)) {
    s <- sl[k]
    si[[s]]$fname <- fname
    si[[s]]$fmt <- 16
    si[[s]]$spf <- d2i(sampfreq[s] / sps + 0.5)
    so[[k]] <- si[[s]]
  }
  ospf <- vapply(so, function(s) s$spf, 0)
  fpb <- cdiv(spb[sl[1L]], si[[sl[1L]]]$spf)
  show("\nOUTPUT:\nBase sampling frequency: %g Hz\n", sps)
  for (k in seq_len(nosig)) {
    j <- ospf[k]
    show(" Signal %d samples per second: %g (%d sample%s per frame)\n",
         k - 1, sampfreq[sl[k]], j, if (j > 1) "s" else "")
  }
  osigfopen(so, nosig)
  .edf2mit_copy(data[seq_along(data) > pos], pmax(spb, 0), sl, ospf, fpb, big_endian)
  newheader(record)
  wfdbquit()
  0
}

# The data records: each holds spb[k] 16-bit samples of each signal k in
# turn.  As in C, each record is read signal by signal into one buffer per
# signal (a short read at the end of the file leaves the rest of a buffer
# as it was, and the record is used only if the last signal got at least
# one sample); then fpb frames are written, taking spf[j] samples from the
# buffer of signal sl[j] for each output signal j (bytes beyond a buffer
# read as 0).
.edf2mit_copy <- function(data, spb, sl, ospf, fpb, big_endian) {
  CHUNK <- 1048576                          # samples decoded at a time (about)
  nsig <- length(spb)
  bsize <- 2 * spb                          # buffer sizes in bytes
  recsize <- sum(bsize)
  if (recsize == 0 || fpb <= 0 || !length(sl)) return(invisible())
  boff <- c(0, cumsum(bsize))[seq_len(nsig)]  # offsets of the buffers in a record
  nfull <- length(data) %/% recsize
  rest <- length(data) - nfull * recsize
  # bytes of the partial last record that reach each signal's buffer
  got <- pmin(pmax(rest - boff, 0), bsize)
  nrec <- if (spb[nsig] == 0) 0 else nfull + (got[nsig] >= 2)
  # The samples of the records r (record numbers, 1-based) as a matrix:
  # one row per output frame.
  frames <- function(r) {
    cols <- vector("list", length(sl))
    for (j in seq_along(sl)) {
      k <- sl[j]
      n <- fpb * ospf[j]                     # samples taken from each record
      h <- min(2 * n, bsize[k])              # bytes of them within the buffer
      take <- matrix(as.raw(0L), 2 * n, length(r))
      if (h > 0) {
        full <- r <= nfull
        idx <- boff[k] + seq_len(h)
        if (any(full)) take[seq_len(h), full] <- data[outer(idx, (r[full] - 1) * recsize, "+")]
        if (!all(full)) {
          # the partial record: its bytes over those of the previous record
          col <- if (nfull > 0) data[idx + (nfull - 1) * recsize] else raw(h)
          g <- min(got[k], h)
          col[seq_len(g)] <- data[nfull * recsize + boff[k] + seq_len(g)]
          take[seq_len(h), !full] <- col
        }
      }
      b1 <- as.integer(take[seq(1L, by = 2L, length.out = n), , drop = FALSE])
      b2 <- as.integer(take[seq(2L, by = 2L, length.out = n), , drop = FALSE])
      v <- if (big_endian) b2 + 256L * b1 else b1 + 256L * b2
      v <- v - 65536L * (v >= 32768L)
      # (the n samples of a record are fpb frames of ospf[j] samples)
      cols[[j]] <- t(matrix(v, ospf[j], fpb * length(r)))
    }
    do.call(cbind, cols)
  }
  step <- max(1, CHUNK %/% (fpb * sum(ospf)))
  r0 <- 1
  while (r0 <= nrec) {
    r1 <- min(nrec, r0 + step - 1)
    putframes(frames(r0:r1))
    r0 <- r1 + 1
  }
  invisible()
}
