# highlevel.R: convenience functions for reading and writing WFDB records
# (read_record, read_header, write_record), built on the C-compatible API
# (isigopen, getframes, putframes, ...), so they read and write exactly
# what the WFDB library and tools do.  (read_annotations and
# write_annotations are in highlevel_annot.R.)
#
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV, 12
# bits and millivolts), because a silently assumed value corrupts every result
# derived from it. See docs/DIVERGENCES.md. The original behavior remains
# available with --legacy (see docs/DIVERGENCES.md).
#
# Legacy mode (wfdb-x): with legacy = TRUE, each function behaves as in the
# original package (the default gain of 200 adu/mV and ADC resolution based
# on the format in write_record, 250 Hz for a header without a frequency, a
# gain of 200 for uncalibrated signals in physical units, ...), with the
# library's legacy mode (wfdbx_set_legacy) on for the duration of the call.
# With legacy = FALSE (the default), the current setting (off, unless
# wfdbx_set_legacy turned it on) applies.  It is kept for compatibility only:
# the values it assumes are exactly the silent defaults this project removed,
# so results produced with it carry the same risks.
#
# Design decision (Reza Sameni, after a code review, Oct 2026): the writers
# (write_record, write_annotations) take a dir argument (the files are
# created in that directory, and the record opens from there under its plain
# name).
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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

# The dir argument of the writers (wfdb-x): with a directory (not NULL or
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

#' The siginfo lists of the signals of a record (no signals are opened).
#' legacy: see read_record.
read_header <- function(record, legacy = FALSE) .hl_legacy(legacy, {
  wfdbquit()
  n <- isigopen(record, 0)$nsig
  if (n < 0) {
    wfdbquit()
    stop("can't read header for record ", record)
  }
  si <- isigopen(record, -n)$si
  wfdbquit()
  si
})

#' Read the signals of a record into a matrix.
#'
#' Returns a list: name, fs (sampling frequency of the returned samples; 0
#' if the header does not specify it),
#' signals (matrix, one row per sample and one column per signal: ADC units,
#' invalid samples WFDB_INVALID_SAMPLE; or physical units with physical =
#' TRUE, invalid samples NA), siginfo (list of siginfo lists), names,
#' units (NULL elements: unspecified), gains, baselines, base_time (e.g.
#' "[08:45:00 01/01/2001]", or NULL; "" if fs is 0), sampfrom, comments (info
#' strings).
#'
#' channels: signal numbers (0-based, as in WFDB) or names (default: all);
#' sampfrom, sampto: sample numbers or time strings (sampto exclusive;
#' default: the end of the record); highres: WFDB_HIGHRES mode for
#' multi-frequency records; pad: WFDB_GVPAD mode (invalid samples replaced
#' by the previous valid sample).
#'
#' wfdb-x: no built-in sampling frequency, gain, ADC resolution or units
#' (see docs/DIVERGENCES.md): a time string that needs the sampling
#' frequency (wfdbx_time_needs_freq) is an error for a record whose header
#' does not specify it, and so is physical = TRUE for a selected signal that
#' is uncalibrated (gain 0).  An unspecified ADC resolution is reported as 0
#' (siginfo adcres) and unspecified units as NULL (never as millivolts).
#'
#' legacy: if TRUE, behave as the original package (250 Hz for a header
#' without a frequency, a gain of 200 for uncalibrated signals in physical
#' units, an ADC resolution based on the format), with the library's legacy
#' mode on for the duration of the call.  Kept for compatibility only: the
#' values it assumes are exactly the silent defaults this project removed.
read_record <- function(record, channels = NULL, sampfrom = 0, sampto = NULL,
                        physical = FALSE, highres = FALSE, pad = FALSE,
                        legacy = FALSE) .hl_legacy(legacy, {
  legacy <- wfdbx_get_legacy()
  wfdbquit()
  nsig <- isigopen(record, 0)$nsig
  if (nsig <= 0) {
    wfdbquit()
    stop("can't read record ", record)
  }
  r <- isigopen(record, nsig)
  nsig <- r$nsig
  si <- r$si
  if (nsig <= 0) {
    wfdbquit()
    stop("can't open signals of record ", record)
  }
  setgvmode(bitwOr(if (highres) WFDB_HIGHRES else WFDB_LOWRES, if (pad) WFDB_GVPAD else 0))
  fs <- sampfreq(NULL)
  # wfdb-x: no default sampling frequency (C, legacy mode: 250 Hz)
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
    cols <- vapply(as.list(channels), function(c) {
      k <- if (is.character(c)) findsig(c) else as.numeric(c)
      if (k < 0 || k >= nsig) {
        wfdbquit()
        stop("record ", record, " has no signal ", c)
      }
      k
    }, 0)
  }
  # wfdb-x: no default gain (C, legacy mode: 200 adu/mV for uncalibrated
  # signals)
  if (physical && !legacy) {
    for (k in cols) {
      if (si[[k + 1]]$gain == 0) {
        wfdbquit()
        stop("signal ", k, " of record ", record, " is uncalibrated")
      }
    }
  }
  # base_time is NULL if the header gives none (wfdb-x: always the case
  # without a sampling frequency; timstr is then not called)
  base_time <- NULL
  if (fs > 0 || legacy) {
    base_time <- timstr(0)
    if (!startsWith(base_time, "[")) base_time <- NULL
  }
  if (isigsettime(from) < 0) {
    wfdbquit()
    stop("can't seek to sample ", from, " of record ", record)
  }
  n <- if (is.null(to)) Inf else max(to - from, 0)
  data <- getframes(n)$v
  data <- data[, cols + 1, drop = FALSE]
  sel <- si[cols + 1]
  comments <- character(0)
  c <- getinfo(record)
  while (!is.null(c)) {
    comments <- c(comments, c)
    c <- getinfo(NULL)
  }
  if (physical) {
    # (legacy mode: the default gain for uncalibrated signals)
    g <- vapply(sel, function(s) if (s$gain == 0 && legacy) WFDB_DEFGAIN else s$gain, 0)
    b <- vapply(sel, function(s) s$baseline, 0)
    out <- sweep(sweep(data, 2L, b), 2L, g, "/")
    out[data == WFDB_INVALID_SAMPLE] <- NA
    data <- out
  }
  rec <- list(name = record, fs = fs, signals = data, siginfo = sel,
              names = vapply(sel, function(s) s$desc %||% "", ""),
              units = lapply(sel, function(s) s$units),
              gains = vapply(sel, function(s) s$gain, 0),
              baselines = vapply(sel, function(s) s$baseline, 0),
              base_time = base_time, sampfrom = from, comments = comments)
  wfdbquit()
  rec
})

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
#' "mV".  (wfdb-x: there is no default frequency, gain, ADC resolution or
#' units; see docs/DIVERGENCES.md.)  Scalar arguments apply to all signals;
#' vectors (or lists, for units and names) give per-signal values.
#' samps_per_frame (per signal) writes a multi-frequency record:
#' then signals has sum(samps_per_frame) columns, frame by frame.
#' comments: info strings added to the header.
#'
#' dir: if given, the directory (which must exist) in which the files are
#' created; the header then names the record and its signal file without
#' the directory, so that the record opens from that directory under its
#' plain name (record must not contain a directory).  (wfdb-x)
#'
#' legacy: if TRUE, behave as the original package (default gains of 200
#' adu/mV, ADC resolutions based on the format, no units required), with the
#' library's legacy mode on for the duration of the call.  Kept for
#' compatibility only: the values it assumes are exactly the silent defaults
#' this project removed.
write_record <- function(record, signals, fs, fmt = 16, gains, baselines = NULL,
                         adczeros = 0, adcres = NULL, units = NULL, names = NULL,
                         base_time = NULL, comments = NULL, physical = FALSE,
                         samps_per_frame = NULL, dir = NULL,
                         legacy = FALSE) .hl_legacy(legacy, .hl_output_dir(record, dir, {
  legacy <- wfdbx_get_legacy()
  # wfdb-x: no default sampling frequency, gain, ADC resolution or units
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
  x <- signals
  if (is.null(dim(x))) x <- matrix(x, ncol = 1L)
  x <- matrix(as.numeric(x), nrow(x), ncol(x))
  if (is.null(samps_per_frame)) {
    nsig <- ncol(x)
    spf <- rep(1, nsig)
  } else {
    spf <- as.numeric(samps_per_frame)
    nsig <- length(spf)
    if (ncol(x) != sum(spf))
      stop("signals must have sum(samps_per_frame) = ", sum(spf), " columns")
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
  if (legacy) {          # wfdb-x: legacy mode (original behavior)
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
  invisible()
}))
