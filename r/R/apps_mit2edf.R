# apps_mit2edf.R: mit2edf -- convert MIT format header and signal files to
# an EDF (European Data Format) file.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of convert/mit2edf.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency, gain or ADC
# resolution: the record must give the sampling frequency, and the gain and ADC
# resolution of every signal (the original assumed 250 Hz and 200 adu/mV, and
# guessed the resolution from the storage format); unspecified units are
# written as "nd" (the original wrote "mV"); --legacy, as the first argument,
# restores the original behavior. Each change is marked "wfdb-x:" in the code;
# docs/DIVERGENCES.md gives the reasons.
#
# Original C program: convert/mit2edf.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2002-2014 George B. Moody; revised 2020 by Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The frames are read in bulk (.getframes_full, the equivalent of the C
# program's getframe calls) and the data blocks written with writeBin.

app_mit2edf <- function(args = character(0)) {
  app_run(.mit2edf_main, c("mit2edf", args))
}

.mit2edf_help <- function(pname) {
  ceprintf("usage: %s -r RECORD [OPTIONS ...]\n", pname)
  h <- c("where RECORD is the name of the input record, and OPTIONS may include:",
         " -h          print this usage summary",
         " -o EDFILE   write the specified European Data Format file (default:",
         "              RECORD.edf)",
         " -p          write the output as an EDF+ file",
         " -v          select verbose mode",
         "This program reads MIT-format signal and header files and writes an EDF",
         "file containing the same data.")
  for (s in h) ceprintf("%s\n", s)
}

# wfdb-x: legacy mode (original behavior): the ADC resolution guessed from
# the signal file format.
.mit2edf_adcres <- function(fmt) {
  if (fmt %in% c(524, 24)) return(24)
  if (fmt == 32) return(32)
  if (fmt %in% c(508, 80)) return(8)
  if (fmt == 212) return(12)
  if (fmt %in% c(310, 311)) return(10)
  if (fmt %in% c(516, 16, 61, 160)) return(16)
  if (fmt >= 100 && fmt %% 100 > 0 && fmt %% 100 <= 32) return(fmt %% 100)
  16
}

# n frames read as the C program's getframe calls do: one row per frame,
# rows of WFDB_INVALID_SAMPLE for the frames that getframe could not read.
# After a failure, the following frames are read again only while that can
# have a visible effect (a later segment, signals with samples left to
# count, groups not at their end); otherwise they are all invalid.
.mit2edf_frames <- function(n, tspf) {
  V <- matrix(WFDB_INVALID_SAMPLE, n, tspf)
  got <- 0
  while (got < n) {
    r <- .getframes_full(n - got)
    m <- nrow(r$v)
    if (m > 0) V[got + seq_len(m), ] <- r$v
    got <- got + m
    if (got >= n) break
    got <- got + 1                          # (the frame that failed)
    if (.mit2edf_at_end()) break
  }
  V
}

.mit2edf_at_end <- function() {
  st <- .sig
  if (st$in_msrec) return(FALSE)
  for (ig in st$igd[seq_len(st$nigroup)]) if (ig$stat > 0) return(FALSE)
  for (is in st$isd[seq_len(st$nisig)]) if (is$info$nsamp > 0) return(FALSE)
  TRUE
}

.mit2edf_main <- function(argv) {
  EDFMAXBLOCK <- 61440                      # maximum size of an EDF data block
  EDF_FIELD_BYTES <- 256                    # header bytes per signal (and fixed part)
  MONTHS <- c("JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP",
              "OCT", "NOV", "DEC")
  pname <- argv[1L]
  argc <- length(argv)
  arg <- function(i) argv[i + 1L]          # C argv[i]
  ofname <- NULL
  record <- NULL
  edfplusflag <- 0
  vflag <- 0
  i <- 1
  while (i < argc) {
    a <- arg(i)
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "h") {
        .mit2edf_help(pname)
        cexit(0)
      } else if (c == "o") {
        i <- i + 1
        if (i < argc) {
          ofname <- arg(i)
        } else {
          ceprintf("%s: output file name must follow -o\n", pname)
          cexit(1)
        }
      } else if (c == "p") {
        edfplusflag <- 1
      } else if (c == "r") {
        i <- i + 1
        if (i < argc) {
          record <- arg(i)
        } else {
          ceprintf("%s: record name must follow -r\n", pname)
          cexit(1)
        }
      } else if (c == "v") {
        vflag <- 1
      }
    }
    i <- i + 1
  }
  if (is.null(record)) {
    .mit2edf_help(pname)
    cexit(1)
  }
  if (is.null(ofname)) {
    b <- charToRaw(record)
    sl <- which(b == as.raw(0x2f))
    if (length(sl)) b <- b[seq_along(b) > sl[length(sl)]]
    ofname <- paste0(rawToChar(b[seq_len(min(length(b), WFDB_MAXRNL))]), ".edf")
  } else if (edfplusflag) {
    if (!endsWith(ofname, ".edf") && !endsWith(ofname, ".EDF")) {
      ceprintf("%s: '%s' is not a valid EDF+ file name\n", pname, ofname)
      ceprintf(" EDF+ file names must end with '.edf' or '.EDF')\n")
      cexit(1)
    }
  }
  nsig <- isigopen(record, 0)$nsig
  if (nsig <= 0) cexit(2)
  r <- isigopen(record, nsig)
  nsig <- r$nsig
  si <- r$si
  if (nsig <= 0) cexit(3)
  # wfdb-x: an EDF file needs the sampling frequency and the gain of each
  # signal (the C program assumed 250 Hz and 200 adu/mV if the header did
  # not specify them, as legacy mode does).
  legacy <- wfdbx_get_legacy()
  if (!legacy && sampfreq(NULL) <= 0) .app_nofreq(pname, record, 3)
  for (k in seq_len(if (legacy) 0 else nsig)) {
    if (si[[k]]$gain == 0) .app_uncalibrated(pname, k - 1, record, 3)
    # wfdb-x: the EDF digital range needs the ADC resolution (the C program
    # guessed it from the storage format).
    if (si[[k]]$adcres < 1) .app_noadcres(pname, k - 1, record, 3)
  }
  ofile <- .app_fopen(ofname, pname)
  if (is.null(ofile)) {
    ceprintf("%s: can't create %s\n", pname, ofname)
    cexit(4)
  }
  on.exit(.app_fclose(ofile, report = FALSE))
  p <- timstr(0)
  start_date_recorded <- 1
  if (!startsWith(p, "[")) {
    setbasetime(NULL)
    p <- timstr(0)
    start_date_recorded <- 0
  }
  r <- csscanf(p, "[%d:%d:%d %d/%d/%d")
  v <- c(vapply(r$v, cint32, 0), numeric(6))
  hour <- v[1L]; minute <- v[2L]; second <- v[3L]
  day <- v[4L]; month <- v[5L]; year <- v[6L]
  if (r$n != 6) {
    start_date_recorded <- 0
    day <- month <- 1
    year <- 1985
  }
  spfs <- vapply(si, function(s) s$spf, 0)
  samples_per_frame <- sum(spfs)
  frames_per_second <- strtim("1:0") / 60
  frames_per_block <- d2i(10 * frames_per_second + 0.5)
  bytes_per_block <- 2 * samples_per_frame * frames_per_block
  while (bytes_per_block > EDFMAXBLOCK) {
    frames_per_block <- cdiv(frames_per_block, 10)
    bytes_per_block <- samples_per_frame * 2 * frames_per_block
  }
  seconds_per_block <- frames_per_block / frames_per_second
  if (frames_per_block < 1 && bytes_per_block < EDFMAXBLOCK %/% 60) {
    frames_per_block <- strtim("1:0")
    bytes_per_block <- 2 * samples_per_frame * frames_per_block
    seconds_per_block <- 60
  }
  if (bytes_per_block > EDFMAXBLOCK) {
    ceprintf("%s: can't convert record %s to EDF\n", pname, record)
    ceprintf(" EDF blocks cannot be larger than %d bytes, but each input frame requires\n",
             EDFMAXBLOCK)
    ceprintf(" %d bytes.  Use 'snip' to select a subset of the input signals, or use\n 'xform' to reduce the sampling frequency.\n",
             samples_per_frame * 2)
    cexit(5)
  }
  nblocks <- cdiv(strtim("e"), frames_per_block) + 1
  hlen <- (nsig + 1) * EDF_FIELD_BYTES
  header <- rep(as.raw(0x20), hlen)
  if (vflag) {
    cprintf("Converting record %s to %s (%s mode)\n", record, ofname,
            if (edfplusflag == 1) "EDF+" else "EDF")
  }
  dmax <- dmin <- pmax <- pmin <- numeric(nsig)
  for (k in seq_len(nsig)) {
    if (legacy && si[[k]]$adcres < 1) si[[k]]$adcres <- .mit2edf_adcres(si[[k]]$fmt)
    half <- 2^(si[[k]]$adcres - 1)
    dmax[k] <- cint32(si[[k]]$adczero + half - 1)
    dmin[k] <- cint32(si[[k]]$adczero - half)
    pmax[k] <- aduphys(k - 1, dmax[k])
    pmin[k] <- aduphys(k - 1, dmin[k])
  }

  # The header: strings copied at pos (0-based), cut at the end of the
  # header; pos then advances by the field width.
  pos <- 0
  put <- function(text, width = 0) {
    b <- if (is.raw(text)) text else charToRaw(text)
    e <- min(pos + length(b), hlen)
    if (e > pos) header[(pos + 1):e] <<- b[seq_len(e - pos)]
    pos <<- pos + width
  }
  # strncpy(p, s, n): s cut to n bytes, or padded with NULs to n bytes
  strncpy <- function(s, n) {
    b <- charToRaw(s)
    c(b, raw(n))[seq_len(n)]
  }
  # s cut to n bytes
  cut <- function(s, n) {
    b <- charToRaw(s)
    if (length(b) > n) rawToChar(b[seq_len(n)]) else s
  }
  put("0", 8)
  rb <- charToRaw(record)
  if (length(rb) > 80) record <- rawToChar(rb[1:79])
  put(record, 80)
  if (start_date_recorded) {
    buf <- .f("Startdate %02d-%s-%d", day, MONTHS[month], year)
  } else {
    buf <- "Startdate not recorded"
    if (edfplusflag)
      ceprintf("WARNING (%s): EDF+ requires start date (not specified)\n", pname)
  }
  put(buf, 80)
  put(strncpy(.f("%02d.%02d.%02d", day, month, cmod(year, 100)), 8), 8)
  put(strncpy(.f("%02d.%02d.%02d", hour, minute, second), 8), 8)
  put(.f("%d", hlen), 8)
  if (edfplusflag) put("EDF+C")
  pos <- pos + 44
  put(.f("%d", nblocks), 8)
  put(cut(.f("%g", seconds_per_block), 8), 8)
  put(.f("%d", nsig), 4)
  for (k in seq_len(nsig)) {
    si[[k]]$desc <- cut(si[[k]]$desc %||% "", 16)
    put(si[[k]]$desc, 16)
  }
  for (k in seq_len(nsig)) put("transducer type not recorded", 80)
  for (k in seq_len(nsig)) {
    # (wfdb-x: unspecified units are shown as "nd"; C, legacy mode: mV)
    si[[k]]$units <- if (!is.null(si[[k]]$units)) cut(si[[k]]$units, 8) else if (legacy) "mV" else "nd"
    put(si[[k]]$units, 8)
  }
  for (k in seq_len(nsig)) put(.f("%g", pmin[k]), 8)
  for (k in seq_len(nsig)) put(.f("%g", pmax[k]), 8)
  for (k in seq_len(nsig)) put(.f("%d", dmin[k]), 8)
  for (k in seq_len(nsig)) put(.f("%d", dmax[k]), 8)
  for (k in seq_len(nsig)) put("prefiltering not recorded", 80)
  for (k in seq_len(nsig)) put(.f("%d", frames_per_block * spfs[k]), 8)
  .app_fwrite(ofile, header)
  hc <- as.integer(header)
  hc <- hc - 256L * (hc >= 128L)            # (C char: signed)
  for (k in which(hc < 32L | hc > 126L)) {
    ceprintf("WARNING (%s): output contains an invalid character, %d, at byte %d\n",
             pname, hc[k], k - 1)
  }
  blocks_per_minute <- blocks_per_hour <- 0
  if (vflag) {
    cprintf(" Header block size: %d bytes\n", hlen)
    cprintf(" Data block size: %g second%s (%d frame%s or %d bytes)\n",
            seconds_per_block, if (seconds_per_block == 1) "" else "s",
            frames_per_block, if (frames_per_block == 1) "" else "s", bytes_per_block)
    p <- sub("^ +", "", timstr(strtim("e")))
    cprintf(" Recording length: %s (%d data blocks, %d frames, %d bytes)\n",
            p, nblocks, nblocks * frames_per_block, nblocks * bytes_per_block)
    cprintf(" Total length of file to be written: %d bytes\n",
            hlen + nblocks * bytes_per_block)
    blocks_per_minute <- d2i(60 / seconds_per_block)
    blocks_per_hour <- 60 * blocks_per_minute
  }
  # The data blocks: in each, the samples of signal 0 for all the frames of
  # the block, then those of signal 1, ...  (written a group of blocks at a
  # time)
  CHUNK <- 1048576                          # samples per write (about)
  step <- max(1, CHUNK %/% max(1, frames_per_block * samples_per_frame))
  sig_cols <- split(seq_len(samples_per_frame), rep(seq_len(nsig), spfs))
  b0 <- 0
  while (b0 < nblocks && frames_per_block > 0) {
    nb <- min(step, nblocks - b0)
    V <- .mit2edf_frames(nb * frames_per_block, samples_per_frame)
    parts <- lapply(seq_len(nsig), function(k) {
      matrix(t(V[, sig_cols[[k]], drop = FALSE]), spfs[k] * frames_per_block, nb)
    })
    blk <- do.call(rbind, parts)
    .app_fwrite(ofile, as.integer(cint16(blk)), size = 2L, endian = "little")
    b0 <- b0 + nb
  }
  .app_fclose(ofile)            # wfdb-x: reports a write error
  if (vflag) {
    nbs <- seq_len(nblocks)
    dots <- character(nblocks)
    if (blocks_per_minute != 0) dots[nbs %% blocks_per_minute == 0] <- "."
    if (blocks_per_hour != 0) {
      h <- nbs %% blocks_per_hour == 0
      dots[h] <- paste0(dots[h], "\n")
    }
    cout(paste(dots, collapse = ""))
  }
  cout("\n")
  if (edfplusflag) {
    ceprintf(paste0("\nWARNING (%s): EDF+ requires the subject's gender, birthdate, and name, as\n",
                    " well as additional information about the recording that is not usually\n",
                    " available.  This information is not saved in the output file even if\n",
                    " available.  EDF+ also requires the use of standard names for signals and\n",
                    " for physical units;  these requirements are not enforced by this program.\n",
                    " To make the output file fully EDF+ compliant, its header must be edited\n",
                    " manually.\n"), pname)
    if (!any(vapply(si, function(s) identical(s$desc, "EDF-Annotations"), TRUE))) {
      ceprintf("\nWARNING:  The output file does not include EDF annotations, which are\n required for EDF+.\n")
    }
  }
  wfdbquit()
  0
}
