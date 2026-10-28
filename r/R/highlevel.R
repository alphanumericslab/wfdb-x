# highlevel.R: convenience functions for reading and writing WFDB records
# (read_record, read_header, write_record), built on the C-compatible API
# (isigopen, getframes, putframes, ...), so they read and write exactly
# what the WFDB library and tools do.  (read_annotations and
# write_annotations are in highlevel_annot.R.)
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# Legacy mode (WFDB-x): with legacy = TRUE, each function behaves as in the
# original package (the default gain of 200 adu/mV and ADC resolution based
# on the format in write_record, 250 Hz for a header without a frequency, a
# gain of 200 for uncalibrated signals in physical units, ...), with the
# library's legacy mode (wfdbx_set_legacy) on for the duration of the call.
# With legacy = FALSE (the default), the current setting (off, unless
# wfdbx_set_legacy turned it on) applies.  It is kept for compatibility only:
# the values it assumes are exactly the silent defaults this project removed,
# so results produced with it carry the same risks.
#
# The functions have no built-in sampling frequency, gain, ADC resolution or
# units: values that the record or the caller does not give are never assumed.
# The writers (write_record, write_annotations) take a dir argument (the files
# are created in that directory, and the record opens from there under its
# plain name). Files are found by explicit names (the input directory, the
# output directory, or a full path or URL), not by a search of the WFDB path,
# and URLs are opened only if asked for (network = TRUE): the readers take
# input_dir and network, the writers dir. A checksum error (getvec status -4:
# the samples are complete, their sum does not match the header's checksums)
# is not an error of read_record but a warning (checksum_warning = FALSE:
# none); the data are returned. docs/DIVERGENCES.md gives the reasons.

# A time argument: a sample number, or a WFDB time string (absolute times
# give their magnitude, as in rdsamp).
.hl_time <- function(t) {
  if (is.null(t)) return(NULL)
  if (is.character(t)) {
    x <- strtim(t)
    return(if (x < 0) -x else x)
  }
  as.numeric(t)
}

# Evaluate expr with the library's legacy mode on if legacy is TRUE (the
# previous setting is restored afterwards, also on errors), or with the
# current setting otherwise: the legacy argument of the high-level functions.
.hl_legacy <- function(legacy, expr) {
  if (!isTRUE(legacy)) return(expr)
  old <- wfdbx_set_legacy(TRUE)
  on.exit(wfdbx_set_legacy(old))
  expr
}

# The dir argument of the writers (WFDB-x): with a directory (not NULL or
# ""), check record and dir, and set the library's output directory
# (wfdbx_set_output_dir) for the duration of the call that evaluates expr
# (the previous one is restored afterwards, also on errors).  The record is
# then named without the directory, so that it can be opened from that
# directory under its plain name.
.hl_output_dir <- function(record, dir, expr) {
  if (is.null(dir) || !nzchar(dir)) return(expr)
  .hl_check_output_dir(record, dir)
  old <- wfdbx_set_output_dir(dir)
  on.exit(wfdbx_set_output_dir(old))
  expr
}

.hl_check_output_dir <- function(record, dir) {
  if (grepl("/", record, fixed = TRUE) ||
      (.Platform$OS.type == "windows" && grepl("\\", record, fixed = TRUE)))
    stop("record name must not contain a directory when dir is given")
  if (!dir.exists(dir)) stop("directory ", dir, " does not exist")
  invisible()
}

# The input_dir and network arguments of the readers (WFDB-x): if given (not
# NULL), the library's input directory (wfdbx_set_input_dir) and network
# permission (wfdbx_set_network) are set for the duration of the call that
# evaluates expr, and the previous values are restored afterwards (also on
# errors).
.hl_input <- function(input_dir, network, expr) {
  if (!is.null(input_dir)) {
    prev_dir <- wfdbx_set_input_dir(input_dir)
    on.exit(wfdbx_set_input_dir(prev_dir), add = TRUE)
  }
  if (!is.null(network)) {
    prev_net <- wfdbx_set_network(network)
    on.exit(wfdbx_set_network(prev_net), add = TRUE, after = FALSE)
  }
  expr
}

# The base time and date of the open record (WFDB-x), as read_record and
# read_header give them: base_time, the text timstr(0) gives (NULL if the
# header gives no base time, or, without legacy mode, no sampling
# frequency: timstr is then not called); base_time_ms, the base time in
# milliseconds after midnight (the library's btime; NULL exactly when
# base_time is NULL); base_date, c(year, month, day) (integer; NULL if the
# header gives no date), converted as datstr() converts it.
.hl_base_fields <- function(fs, legacy) {
  base_time <- NULL
  if (fs > 0 || legacy) {
    base_time <- timstr(0)
    if (!startsWith(base_time, "[")) base_time <- NULL
  }
  st <- .sig
  list(base_time = base_time,
       base_time_ms = if (!is.null(base_time)) as.numeric(st$btime),
       base_date = if (st$bdate != 0) as.integer(.julian_ymd(st$bdate)))
}

# The siginfo lists si with the white space (C isspace) at both ends of
# each description removed.  WFDB-x: the high-level readers give the
# signal names without the spaces that some headers end them with (the
# C-style functions keep them, as C does).
.HL_SPACE <- as.raw(c(32, 9, 10, 11, 12, 13))

.hl_strip <- function(s) {
  b <- charToRaw(s)
  k <- which(!(b %in% .HL_SPACE))
  if (!length(k)) return("")
  if (k[1L] == 1L && k[length(k)] == length(b)) return(s)
  rawToChar(b[k[1L]:k[length(k)]])
}

.hl_strip_desc <- function(si) {
  lapply(si, function(s) {
    if (!is.null(s$desc)) s$desc <- .hl_strip(s$desc)
    s
  })
}

# The info strings of the header of record (getinfo).
.hl_comments <- function(record) {
  comments <- character(0)
  c <- getinfo(record)
  while (!is.null(c)) {
    comments <- c(comments, c)
    c <- getinfo(NULL)
  }
  comments
}

#' Read the header of a record (no signal file is opened).
#'
#' Returns a list of class "wfdbx_header": name (the record name as
#' given), fs (the sampling frequency, as sampfreq() gives it: 0 if the
#' header does not specify it; legacy mode: 250 Hz), counter_freq (as
#' getcfreq() gives it), base_counter (as getbasecount() gives it),
#' nsamples (the number of samples per signal given on the record line of
#' the header; 0 if it gives none), nsig (the number of signals), siginfo
#' (one siginfo list per signal; desc without the white space at either
#' end), base_time, base_time_ms, base_date (as in read_record) and
#' comments (the info strings).
#' input_dir, network, legacy: see read_record.
read_header <- function(record, input_dir = NULL, network = NULL,
                        legacy = FALSE) .hl_legacy(legacy, .hl_input(input_dir, network, {
  legacy <- wfdbx_get_legacy()
  wfdbquit()
  n <- isigopen(record, 0)$nsig
  if (n < 0) {
    wfdbquit()
    stop("can't read header for record ", record)
  }
  si <- .hl_strip_desc(isigopen(record, -n)$si)
  st <- .sig
  fs <- sampfreq(NULL)
  # (a multi-segment record: the length on the record line of its master
  # header)
  nsamples <- if (st$segments) st$msnsamples else st$nsamples
  h <- c(list(name = record, fs = fs, counter_freq = getcfreq(),
              base_counter = getbasecount(), nsamples = nsamples, nsig = n,
              siginfo = si),
         .hl_base_fields(fs, legacy),
         list(comments = .hl_comments(record)))
  wfdbquit()
  structure(h, class = "wfdbx_header")
}))

#' Read the signals of a record into a matrix.
#'
#' Returns a list: name, fs (sampling frequency of the returned samples; 0
#' if the header does not specify it),
#' signals (matrix, one row per sample and one column per signal: ADC units,
#' invalid samples WFDB_INVALID_SAMPLE; or physical units with physical =
#' TRUE, invalid samples NA), siginfo (list of siginfo lists; desc
#' without the white space at either end), names (the description of each
#' signal, without the white space that a header may put at either end of
#' it), units (NULL elements: unspecified), gains, baselines, base_time (e.g.
#' "[08:45:00 01/01/2001]", or NULL: the header gives no base time, or no
#' sampling frequency), base_time_ms (the base time in milliseconds after
#' midnight, a double, e.g. 50403500 for 14:00:03.500; NULL exactly when
#' base_time is NULL), base_date (c(year, month, day), an integer vector,
#' or NULL if the header gives no date), sampfrom, comments (info strings),
#' checksum_ok (FALSE if the samples were found not to match the checksums
#' in the header, getvec status -4, whether or not checksum_warning is on;
#' TRUE otherwise.  The checksums are verified only when the read reaches
#' the end of the record).
#'
#' channels: signal numbers (0-based, as in WFDB) or names (as in names;
#' default: all);
#' sampfrom, sampto: sample numbers or time strings (sampto exclusive;
#' default: the end of the record); highres: WFDB_HIGHRES mode for
#' multi-frequency records; pad: WFDB_GVPAD mode (invalid samples replaced
#' by the previous valid sample).
#'
#' WFDB-x: no built-in sampling frequency, gain, ADC resolution or units
#' (see docs/DIVERGENCES.md): a time string that needs the sampling
#' frequency (wfdbx_time_needs_freq) is an error for a record whose header
#' does not specify it, and so is physical = TRUE for a selected signal that
#' is uncalibrated (gain 0).  An unspecified ADC resolution is reported as 0
#' (siginfo adcres) and unspecified units as NULL (never as millivolts).
#'
#' Errors: stop() if the record cannot be read, a channel does not exist or
#' sampfrom cannot be reached; also if reading stops with a getvec status
#' below -1 (e.g. -3: a signal file shorter than its header says, or a read
#' or decoding error), with the message "can't read signal data of record
#' REC (getvec status S)", also in legacy mode (reaching the end of the
#' record before sampto is not an error, nor is a checksum error: see
#' checksum_warning).
#'
#' checksum_warning: if TRUE (the default), warn (warning(): "checksum error
#' in record REC: the signal data do not match the checksums in its header")
#' when the samples read to the end of the record do not match the
#' checksums in its header (getvec status -4); the data, every frame
#' included, are returned either way (FALSE: no warning).  WFDB-x; the same
#' in all seven implementations.
#'
#' record: relative to the input directory, or a full path, ~ path or URL
#' (WFDB-x).  input_dir: the input directory for this call (a local
#' directory, a ~ name or a URL; see wfdbx_set_input_dir); default: the
#' current setting.  network: TRUE to allow reading URLs for this call
#' (FALSE to forbid it; see wfdbx_set_network); default: the current
#' setting (by default, not allowed).
#'
#' legacy: if TRUE, behave as the original package (250 Hz for a header
#' without a frequency, a gain of 200 for uncalibrated signals in physical
#' units, an ADC resolution based on the format), with the library's legacy
#' mode on for the duration of the call.  Kept for compatibility only: the
#' values it assumes are exactly the silent defaults this project removed.
read_record <- function(record, channels = NULL, sampfrom = 0, sampto = NULL,
                        physical = FALSE, highres = FALSE, pad = FALSE,
                        input_dir = NULL, network = NULL,
                        legacy = FALSE, checksum_warning = TRUE) .hl_legacy(legacy, .hl_input(input_dir, network, {
  legacy <- wfdbx_get_legacy()
  wfdbquit()
  nsig <- isigopen(record, 0)$nsig
  if (nsig <= 0) {
    wfdbquit()
    stop("can't read record ", record)
  }
  r <- isigopen(record, nsig)
  nsig <- r$nsig
  si <- .hl_strip_desc(r$si)
  if (nsig <= 0) {
    wfdbquit()
    stop("can't open signals of record ", record)
  }
  setgvmode(bitwOr(if (highres) WFDB_HIGHRES else WFDB_LOWRES, if (pad) WFDB_GVPAD else 0))
  fs <- sampfreq(NULL)
  # WFDB-x: no default sampling frequency (C, legacy mode: 250 Hz)
  if (fs <= 0 && !legacy) {
    for (t in list(sampfrom, sampto)) {
      if (is.character(t) && wfdbx_time_needs_freq(t)) {
        wfdbquit()
        stop("sampling frequency of record ", record, " is not specified")
      }
    }
  }
  from <- .hl_time(sampfrom)
  if (is.null(from)) from <- 0
  to <- .hl_time(sampto)
  if (is.null(channels)) {
    cols <- seq_len(nsig) - 1
  } else {
    snames <- vapply(si, function(s) s$desc %||% "", "")
    cols <- vapply(as.list(channels), function(c) {
      # (a name: among the names without white space, then as findsig)
      k <- if (!is.character(c)) as.numeric(c) else {
        j <- match(.hl_strip(c), snames)
        if (is.na(j)) findsig(c) else j - 1
      }
      if (k < 0 || k >= nsig) {
        wfdbquit()
        stop("record ", record, " has no signal ", c)
      }
      k
    }, 0)
  }
  # WFDB-x: no default gain (C, legacy mode: 200 adu/mV for uncalibrated
  # signals)
  if (physical && !legacy) {
    for (k in cols) {
      if (si[[k + 1]]$gain == 0) {
        wfdbquit()
        stop("signal ", k, " of record ", record, " is uncalibrated")
      }
    }
  }
  # base_time is NULL if the header gives none (WFDB-x: always the case
  # without a sampling frequency; timstr is then not called)
  base <- .hl_base_fields(fs, legacy)
  if (isigsettime(from) < 0) {
    wfdbquit()
    stop("can't seek to sample ", from, " of record ", record)
  }
  n <- if (is.null(to)) Inf else max(to - from, 0)
  # (getvec's checksum message is not printed: a warning replaces it)
  .sig$cksum_quiet <- TRUE
  g <- tryCatch(.getframes(n, keep_checksum_frame = TRUE),
                finally = .sig$cksum_quiet <- FALSE)
  # WFDB-x: -4, a checksum error: the frames are complete (the last one
  # included), only their sum does not match the header: a warning, not an
  # error.  Any other status below -1 (e.g. -3, unexpected EOF: a signal
  # file shorter than its header says, or a decoder or I/O error) is an
  # error, not the end of the data (-1).
  if (g$stat == -4) {
    if (isTRUE(checksum_warning))
      warning("checksum error in record ", record,
              ": the signal data do not match the checksums in its header", call. = FALSE)
  } else if (g$stat < -1) {
    wfdbquit()
    stop("can't read signal data of record ", record, " (getvec status ", g$stat, ")")
  }
  checksum_ok <- g$stat != -4
  # (no copy when all the signals are selected, in order)
  data <- if (length(cols) == ncol(g$v) && all(cols == seq_len(ncol(g$v)) - 1)) g$v else
    g$v[, cols + 1, drop = FALSE]
  g <- NULL
  sel <- si[cols + 1]
  comments <- .hl_comments(record)
  if (physical) {
    # (legacy mode: the default gain for uncalibrated signals)
    gn <- vapply(sel, function(s) if (s$gain == 0 && legacy) WFDB_DEFGAIN else s$gain, 0)
    b <- vapply(sel, function(s) s$baseline, 0)
    inv <- if (length(data) && min(data) <= WFDB_INVALID_SAMPLE) which(data == WFDB_INVALID_SAMPLE)
    # (the whole matrix at once if all the signals have the same gain and
    # baseline)
    if (length(gn) && all(gn == gn[1L]) && all(b == b[1L])) {
      data <- (data - b[1L]) / gn[1L]
    } else {
      for (k in seq_along(sel)) data[, k] <- (data[, k] - b[k]) / gn[k]
    }
    if (length(inv)) data[inv] <- NA
  }
  rec <- list(name = record, fs = fs, signals = data, siginfo = sel,
              names = vapply(sel, function(s) s$desc %||% "", ""),
              units = lapply(sel, function(s) s$units),
              gains = vapply(sel, function(s) s$gain, 0),
              baselines = vapply(sel, function(s) s$baseline, 0),
              base_time = base$base_time, base_time_ms = base$base_time_ms,
              base_date = base$base_date, sampfrom = from, comments = comments,
              checksum_ok = checksum_ok)
  wfdbquit()
  rec
}))

#' Write signals (and a header) as record `record`.
#'
#' signals: a matrix (one row per sample, one column per signal) of ADC
#' units, or of physical units if physical = TRUE (converted with the gains
#' and baselines, rounding as physadu() does; NA becomes an invalid
#' sample).  fs: sampling frequency (required, > 0).  gains (required):
#' ADC units per physical unit; a gain of 0 declares a signal uncalibrated,
#' which is allowed only when the samples are given in ADC units (physical
#' = FALSE).  adcres (required): ADC resolutions in bits (>= 1).  units
#' (required for every signal whose gain is not 0): physical units, e.g.
#' "mV".  (WFDB-x: there is no default frequency, gain, ADC resolution or
#' units; see docs/DIVERGENCES.md.)  Scalar arguments apply to all signals;
#' vectors (or lists, for units and names) give per-signal values.
#' samps_per_frame (per signal) writes a multi-frequency record:
#' then signals has sum(samps_per_frame) columns, frame by frame.
#' comments: info strings added to the header.
#'
#' dir: if given, the directory (which must exist) in which the files are
#' created; the header then names the record and its signal file without
#' the directory, so that the record opens from that directory under its
#' plain name (record must not contain a directory).  (WFDB-x)
#'
#' legacy: if TRUE, behave as the original package (default gains of 200
#' adu/mV, ADC resolutions based on the format, no units required), with the
#' library's legacy mode on for the duration of the call.  Kept for
#' compatibility only: the values it assumes are exactly the silent defaults
#' this project removed.
#'
#' Errors: stop() on invalid arguments (among them, a samps_per_frame value
#' that is not an integer >= 1: "samps_per_frame must hold integers >= 1",
#' or signals whose number of columns is not the sum of samps_per_frame:
#' "signals has N columns, but samps_per_frame adds up to M"; these are
#' checked first, before any file is created), if the signal file or the
#' header cannot be created, or if they cannot be written completely, for
#' example when the disk is full ("write error on record R", after the
#' library's messages).
write_record <- function(record, signals, fs, fmt = 16, gains, baselines = NULL,
                         adczeros = 0, adcres = NULL, units = NULL, names = NULL,
                         base_time = NULL, comments = NULL, physical = FALSE,
                         samps_per_frame = NULL, dir = NULL,
                         legacy = FALSE) .hl_legacy(legacy, .hl_output_dir(record, dir, {
  x <- signals
  if (is.null(dim(x))) x <- matrix(x, ncol = 1L)
  if (!is.double(x) || !is.matrix(x)) x <- matrix(as.numeric(x), nrow(x), ncol(x))
  spf <- if (is.null(samps_per_frame)) rep(1, ncol(x)) else
    suppressWarnings(as.numeric(samps_per_frame))
  nsig <- length(spf)
  # Each frame holds spf[k] >= 1 samples of signal k, and each row of
  # signals is one frame.
  if (anyNA(spf) || any(spf < 1 | spf != trunc(spf)))
    stop("samps_per_frame must hold integers >= 1")
  if (ncol(x) != sum(spf))
    stop(sprintf("signals has %d columns, but samps_per_frame adds up to %.0f", ncol(x), sum(spf)))
  legacy <- wfdbx_get_legacy()
  # WFDB-x: no default sampling frequency, gain, ADC resolution or units
  # (C: 250 Hz, 200 adu/mV, a resolution based on the format, millivolts;
  # legacy mode: as the original package, no checks, default gain 200)
  if (legacy) {
    if (missing(gains)) gains <- WFDB_DEFGAIN
  } else {
    if (missing(fs) || is.null(fs) || length(fs) != 1L || !is.numeric(fs) ||
        is.na(fs) || fs <= 0)
      stop("fs must be specified and > 0")
    if (missing(gains) || is.null(gains) || length(gains) == 0L)
      stop("gains must be specified")
  }
  per <- function(v, default = NULL) {
    if (is.null(v)) return(rep(list(default), nsig))
    if (length(v) == 1L && !is.list(v)) return(rep(list(v), nsig))
    if (length(v) != nsig) stop("expected ", nsig, " values")
    as.list(v)
  }
  fmts <- unlist(per(fmt))
  gains_ <- as.numeric(unlist(per(gains)))
  if (anyNA(gains_)) stop("gains must be specified")
  zeros <- unlist(per(adczeros, 0))
  bases <- per(baselines)
  bases <- vapply(seq_len(nsig), function(k) if (is.null(bases[[k]])) zeros[k] else bases[[k]], 0)
  if (legacy) {          # WFDB-x: legacy mode (original behavior)
    defres <- function(f) {
      switch(as.character(f), "80" = , "508" = 8, "212" = 12, "310" = , "311" = 10,
             "24" = , "524" = 24, "32" = 32, 16)
    }
    res <- per(adcres)
    res <- vapply(seq_len(nsig), function(k) if (is.null(res[[k]])) defres(fmts[k]) else res[[k]], 0)
  } else {
    if (is.null(adcres) || length(adcres) == 0L)
      stop("ADC resolution(s) must be specified")
    res <- per(adcres)
    res <- vapply(res, function(r) {
      r <- suppressWarnings(as.numeric(r))
      if (length(r) != 1L || is.na(r) || r < 1) stop("ADC resolution(s) must be specified")
      trunc(r)
    }, 0)
  }
  units_ <- per(units)
  for (k in seq_len(if (legacy) 0 else nsig)) {
    u <- units_[[k]]
    if (gains_[k] != 0 && (is.null(u) || length(u) != 1L || is.na(u) || !nzchar(u)))
      stop("units must be specified")
  }
  names_ <- per(names)
  if (length(unique(fmts)) > 1L)
    stop("all signals of a record written by write_record must have the same format")
  if (physical) {
    c <- 0
    for (k in seq_len(nsig)) {
      g <- gains_[k]
      if (g == 0) {
        if (!legacy) stop("signal ", k - 1, " is uncalibrated")
        g <- WFDB_DEFGAIN                  # (legacy mode: the default gain)
      }
      for (j in seq_len(spf[k])) {
        c <- c + 1
        v <- x[, c] * g
        r <- ifelse(v >= 0, trunc(v + 0.5), trunc(v - 0.5)) + bases[k]
        r[is.na(v)] <- WFDB_INVALID_SAMPLE
        x[, c] <- r
      }
    }
  }
  si <- lapply(seq_len(nsig), function(k) {
    siginfo(fname = paste0(record, ".dat"),
            desc = if (!is.null(names_[[k]])) as.character(names_[[k]]) else "",
            units = if (!is.null(units_[[k]])) as.character(units_[[k]]) else NULL,
            gain = as.numeric(gains_[k]), initval = 0, group = 0, fmt = fmts[k],
            spf = spf[k], bsize = 0, adcres = res[k], adczero = zeros[k],
            baseline = bases[k])
  })
  wfdbquit()
  errors <- wfdbx_write_errors()
  if (osigfopen(si, nsig) != nsig) {
    wfdbquit()
    stop("can't create signal file for record ", record)
  }
  setsampfreq(as.numeric(fs))
  # (the counter frequency and base count survive wfdbquit, as in C; a new
  # record written here has neither)
  setcfreq(0)
  setbasecount(0)
  if (!is.null(base_time)) setbasetime(base_time)
  putframes(x)
  if (newheader(record) < 0) {
    wfdbquit()
    stop("can't create header for record ", record)
  }
  for (c in comments) putinfo(c)
  wfdbquit()
  if (wfdbx_write_errors() > errors) stop("write error on record ", record)
  invisible()
}))
