# highlevel_annot.R: reading and writing whole annotation files
# (read_annotations, write_annotations), built on the C-compatible API
# (annopen, getann, putann), so that they read and write exactly what the
# WFDB library and the rdann and wrann tools do.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU Lesser General Public License as published by
# the Free Software Foundation, either version 2.1 of the License, or (at
# your option) any later version. See LICENSE.
#
# No sampling frequency is assumed (read_annotations takes an optional fs).
# write_annotations takes a dir argument (the file is created in that
# directory), and an out-of-order file is sorted in this process (see
# annot.R). docs/DIVERGENCES.md gives the reasons.

# A time argument: a sample number, or a time string (strtim; absolute
# times are taken as their magnitude).
.hl_ann_time <- function(t) {
  if (is.null(t)) return(NULL)
  if (is.character(t)) {
    x <- strtim(t)
    return(if (x < 0) -x else x)
  }
  as.numeric(t)
}

# The text of an aux string: its data (as given by the length byte) up to
# the first null; NA for none.
.hl_aux_text <- function(aux) {
  vapply(aux, function(a) {
    if (is.null(a)) return(NA_character_)
    n <- as.integer(a[1L])
    d <- a[seq.int(2L, length.out = min(n, length(a) - 1L))]
    z <- match(as.raw(0L), d)
    if (!is.na(z)) d <- d[seq_len(z - 1L)]
    rawToChar(d)
  }, "", USE.NAMES = FALSE)
}

#' Read an annotation file (as rdann does).
#'
#' Returns a data frame with one row per annotation and the columns
#' sample (the annotation times, in the time resolution of the file),
#' symbol (mnemonics, as annstr gives them), code (annotation type codes),
#' subtype, chan, num and aux (auxiliary strings, NA where absent), and the
#' attributes record, annotator and fs (the time resolution, ticks per
#' second).  sampfrom and sampto (sample numbers or time strings) select
#' the annotations at or after sampfrom and before sampto.  Modification
#' labels at the start of the file are consumed by annopen, as in C.
#'
#' sampfrom and sampto are checked as read_record checks them (see
#' .hl_sample_number), before any file is opened; whatever happens, the
#' annotation file is closed (wfdbquit) before the function returns.
#'
#' Errors: stop() if the annotator cannot be opened, or if reading ends
#' with a getann status other than 0 and -1 (e.g. -3, unexpected EOF),
#' with the message "can't read annotation file ANN of record REC (getann
#' status S)" (also in legacy mode); getann's own message is printed too.
#' A read limited by sampto stops at the first annotation at or after
#' sampto and reads no further.  WFDB-x.
#'
#' fs: the sampling frequency of the record, used (like the -F option of
#' rdann) only if the record has no header or its header does not specify
#' one.  WFDB-x: there is no default (C assumed 250 Hz; see
#' docs/DIVERGENCES.md): without one, the fs attribute of the result is
#' that of the annotation file (0 if it does not specify one), and time
#' strings that need the sampling frequency (wfdbx_time_needs_freq) are an
#' error.
#'
#' record: the record name, without the .hea extension (a trailing ".hea"
#' is also accepted): a full path, absolute ("/data/mitdb/100") or in the
#' home directory ("~/Documents/100s"), used as given; a relative path
#' ("100s", "data/100s"), read from the input directory if one is set,
#' otherwise from the current directory; or a URL
#' ("https://physionet.org/files/mitdb/1.0.0/100"), read only if network
#' access is on (WFDB-x).
#' Its header, if there is one, gives the sampling frequency.
#'
#' input_dir: the input directory for this call only (optional): a local
#' directory, a ~ path or a URL, under which relative record names are
#' read.  It does not apply to full paths or URLs.  Default: the current
#' setting (see wfdbx_set_input_dir).
#' network: the network permission for this call (see read_record; WFDB-x).
#'
#' The getvec mode (getgvmode) and the time resolution of output
#' annotators (getafreq) are left as they were, also after an error
#' (opening an EDF record sets both, as in C; WFDB-x).
#'
#' legacy: if TRUE, behave as the original package (250 Hz for a record
#' without a header, or whose header does not specify the frequency, unless
#' fs is given), with the library's legacy mode on for the duration of the
#' call.  Kept for compatibility only: the values it assumes are exactly the
#' silent defaults this project removed.
read_annotations <- function(record, annotator, sampfrom = 0, sampto = NULL, fs = NULL,
                             input_dir = NULL, network = NULL,
                             legacy = FALSE) .hl_keep_settings(.hl_legacy(legacy, .hl_input(input_dir, network, {
  legacy <- wfdbx_get_legacy()
  # WFDB-x: sampfrom and sampto are checked as read_record checks them,
  # before anything is opened (a fraction, NA, NaN or an infinite value is
  # an error, not truncated)
  sampfrom <- .hl_sample_number(sampfrom, "sampfrom")
  sampto <- .hl_sample_number(sampto, "sampto")
  if (is.numeric(sampfrom) && sampfrom < 0)
    stop("sampfrom must not be negative")
  if (!is.null(fs) && (length(fs) != 1L || !is.numeric(fs) || is.na(fs) || fs <= 0))
    stop("fs must be > 0")
  wfdbquit()
  # (whatever happens, the annotation file is closed before returning)
  tryCatch({
    sps <- sampfreq(record)
    if (sps <= 0 && !is.null(fs)) {
      setsampfreq(sps <- as.numeric(fs))
    } else if (sps < 0 && legacy) {
      setsampfreq(sps <- WFDB_DEFFREQ)      # legacy mode (original behavior)
    }
    if (sps <= 0 && !legacy) {
      for (t in list(sampfrom, sampto)) {
        if (is.character(t) && wfdbx_time_needs_freq(t))
          stop("sampling frequency of record ", record, " is not specified")
      }
    }
    if (annopen(record, list(anninfo(annotator, WFDB_READ)), 1) < 0)
      stop(sprintf("can't read annotator %s for record %s", annotator, record))
    frm <- .hl_ann_time(sampfrom)
    if (is.null(frm)) frm <- 0
    to <- .hl_ann_time(sampto)
    if (frm != 0 && iannsettime(frm) < 0)
      stop(sprintf("can't seek in annotator %s", annotator))
    # (nofail: the annotations that getann returns before it fails; the
    # failing call is made only if no annotation at or after sampto was
    # read)
    A <- .getann_bulk(0, Inf, nofail = TRUE)
    n <- length(A$time)
    k <- if (is.null(to)) NA else match(TRUE, A$time >= to)
    if (!is.na(k)) {
      n <- k - 1L
    } else {
      stat <- getann(0)$stat
      # -1: the end of the file; anything else (e.g. -3, unexpected EOF)
      # is an error
      if (stat != 0 && stat != -1)
        stop(sprintf("can't read annotation file %s of record %s (getann status %d)",
                     annotator, record, as.integer(stat)))
    }
    s <- seq_len(n)
    afs <- getiafreq(0)
    res <- data.frame(sample = A$time[s], symbol = annstr(A$anntyp[s]), code = A$anntyp[s],
                      subtype = A$subtyp[s], chan = A$chan[s], num = A$num[s],
                      aux = .hl_aux_text(A$aux[s]), stringsAsFactors = FALSE)
    attr(res, "record") <- record
    attr(res, "annotator") <- annotator
    attr(res, "fs") <- afs
  }, finally = wfdbquit())
  res
})))

#' Write an annotation file (as wrann does).
#'
#' sample: the annotation times, a vector of integers from -2^63 + 1 to
#' 2^63 - 2 (the smallest and largest 64-bit integers are reserved by the
#' file format: "annotation time T cannot be written ..."), or a data
#' frame as returned by read_annotations, whose columns then give all
#' fields.  Codes are 0 to 58 (59 to 63, the control codes of the file
#' format, are "reserved"; other values are "out of range"); aux texts are
#' written as their bytes (a character beyond U+00FF in a UTF-8 string is
#' an error, see .hl_check_latin1); sample, symbol, code, subtype, chan
#' and num must not be matrices ("NAME must be a 1-D array").  symbol
#' (mnemonics such as "N") or code (annotation type codes) must be given for
#' one annotation or more ("symbol or code must be given"; with no
#' annotations, an empty file is written); both only if they agree (each symbol is the
#' mnemonic of its code; an empty symbol agrees with any code), else the
#' error is "symbols and codes disagree at annotation K" (K from 0).  NA,
#' NaN and infinite values are errors in sample, code, subtype, chan and
#' num, as is an fs that is not finite and > 0.
#' symbol, code, subtype, chan, num and aux are each one value for all
#' annotations, or one value per annotation (any other length is an error,
#' before the file is created); aux is a character vector (NA for none) or
#' NULL.  As in C, subtypes and annotator numbers are stored as signed
#' bytes and channels as unsigned bytes (other values wrap around).  If fs
#' is given, it is recorded as the time resolution of the file (setafreq).  Annotations out of order are sorted when the file
#' is closed (as the sortann tool does; WFDB-x: in this process, whereas the
#' C library, as legacy mode, runs sortann), unless the WFDBANNSORT
#' environment variable is 0.  record: the record name, without the .hea
#' extension (a trailing ".hea" is also accepted): a plain name or a
#' relative path ("data/100s") is created in the output directory if one is
#' set (see wfdbx_set_output_dir), otherwise in the current directory; a
#' full path, absolute or in the home directory ("~/Documents/100s"), is
#' used as given.  The file is RECORD.ANNOTATOR at that place
#' ("data/100s.qrs").  A URL cannot be written.  dir: the directory (which
#' must exist) in which to create the file, for this call only; record must
#' then be a plain name, without a directory: the file is
#' DIR/RECORD.ANNOTATOR (WFDB-x).  Returns invisibly the status of the last putann
#' (0).  legacy: if TRUE, the library's legacy mode is on for the duration
#' of the call (see read_annotations).
#'
#' sort: NULL (the default): an out-of-order file is sorted unless the
#' WFDBANNSORT environment variable is 0; TRUE: it is sorted, FALSE: it is
#' left in the order given, for this call only, whatever WFDBANNSORT says
#' (in legacy mode too: TRUE runs the sortann tool; the environment is not
#' changed).  WFDB-x.
#'
#' Errors: stop() if the annotator cannot be created ("can't create
#' annotator A for record R"), or if the file cannot be written completely,
#' for example when the disk is full, or putann reports an error ("write
#' error on annotator A for record R", after the library's message), and
#' on invalid arguments.  The arguments are checked before the file is
#' created or changed; the file is written to a temporary file (created
#' owner-only) in its directory, which replaces the existing file only
#' when it is complete (see .staging_begin).  Whatever happens, the
#' annotator is closed (wfdbquit) and no temporary file is left before the
#' function returns,
#' and the getvec mode and the time resolution of output annotators are
#' left as they were (fs applies to this file only; WFDB-x).
write_annotations <- function(record, annotator, sample, symbol = NULL, code = NULL,
                              subtype = 0, chan = 0, num = 0, aux = NULL, fs = NULL,
                              dir = NULL, legacy = FALSE, sort = NULL) {
  # WFDB-x: the getvec mode and the time resolution of output annotators are
  # restored when the function returns (see .hl_keep_settings; fs applies
  # to this file only); after the wfdbquit registered below, which runs
  # first
  afreq0 <- getafreq()
  gvmode0 <- getgvmode()
  on.exit({
    setgvmode(gvmode0)
    setafreq(afreq0)
  }, add = TRUE)
  if (isTRUE(legacy)) {
    old <- wfdbx_set_legacy(TRUE)
    on.exit(wfdbx_set_legacy(old), add = TRUE)
  }
  if (!is.null(dir) && nzchar(dir)) {       # WFDB-x: see .hl_output_dir
    .hl_check_output_dir(record, dir)
    old_dir <- wfdbx_set_output_dir(dir)
    on.exit(wfdbx_set_output_dir(old_dir), add = TRUE)
  }
  if (!is.null(sort) && (!is.logical(sort) || length(sort) != 1L || is.na(sort)))
    stop("sort must be NULL, TRUE or FALSE")
  if (is.data.frame(sample)) {
    df <- sample
    sample <- df$sample
    if (is.null(code) && is.null(symbol)) code <- df$code
    if (missing(subtype) && !is.null(df$subtype)) subtype <- df$subtype
    if (missing(chan) && !is.null(df$chan)) chan <- df$chan
    if (missing(num) && !is.null(df$num)) num <- df$num
    if (is.null(aux) && !is.null(df$aux)) aux <- df$aux
  }
  # WFDB-x: every argument is checked before the file is touched
  if (!is.null(dim(sample)) && length(dim(sample)) != 1L)
    stop("samples must be a 1-D array")
  n <- length(sample)
  # WFDB-x: a per-annotation argument is one value for all annotations, or
  # one value per annotation (a vector: an array of more than one
  # dimension is an error)
  per <- function(v, name) {
    if (!is.null(dim(v)) && length(dim(v)) != 1L) stop(name, " must be a 1-D array")
    if (length(v) != 1L && length(v) != n)
      stop(name, " must have one value per annotation")
    rep_len(as.vector(v), n)
  }
  # WFDB-x: the times are integers within the range of WFDB_Time
  time <- suppressWarnings(as.numeric(sample))
  if (!all(is.finite(time) & time == trunc(time) & time >= -2^63 & time < 2^63))
    stop("annotation times must be integers within the range of a 64-bit integer")
  both <- !is.null(code) && !is.null(symbol)
  if (is.null(code)) {
    if (is.null(symbol)) {
      # WFDB-x: a label is required for each annotation (1.2.2: also in the
      # other languages); no annotations write an empty file
      if (n > 0L) stop("symbol or code must be given")
      symbol <- character(0)
    }
    code <- strann(as.character(per(symbol, "symbol")))
  } else if (both) {
    sym <- as.character(per(symbol, "symbol"))
  }
  # WFDB-x: NA (or NaN, or an infinite value) is an error
  finite <- function(v, name) {
    v <- suppressWarnings(as.numeric(per(v, name)))
    if (!all(is.finite(v))) stop(name, " must not be NA, NaN or infinite")
    v
  }
  code <- finite(code, "code")
  subtype <- finite(subtype, "subtype")
  chan <- finite(chan, "chan")
  num <- finite(num, "num")
  # WFDB-x: the times that the MIT format can store: the smallest 64-bit
  # integer, -2^63, is reserved, as is the largest, 2^63 - 1 (which a
  # double cannot hold: it is beyond the range above), and putann refuses
  # them ("time overflow": the annotation was dropped); any other time is
  # stored (with SKIPs for intervals beyond 1023 samples)
  bad <- which(time == -2^63)
  if (length(bad))
    stop(sprintf(paste0("annotation time %.0f cannot be written (annotation times must be ",
                        "integers from -9223372036854775807 to 9223372036854775806)"),
                 time[bad[1L]]))
  # WFDB-x: the annotation codes are 0 to 58 (ACMAX is 49, and 50 to 58 are
  # free); 59 to 63 are the control codes of the MIT format (SKIP, NUM,
  # SUB, CHN, AUX), which corrupt the file, and other values do not fit in
  # its 6 bits
  bad <- which(code < 0 | code > 58)
  if (length(bad)) {
    c1 <- code[bad[1L]]
    shown <- if (c1 == trunc(c1)) sprintf("%.0f", c1) else format(c1, digits = 15)
    if (c1 > 58 && c1 <= 63 && c1 == trunc(c1))
      stop(sprintf(paste0("annotation code %s is reserved (59 to 63 are the control codes ",
                          "of the annotation file format)"), shown))
    stop(sprintf("annotation code %s is out of range (0 to 58)", shown))
  }
  if (both) {
    # WFDB-x: symbol and code may both be given (as read_annotations
    # returns them) if they agree: each symbol is that of its code (an
    # empty symbol, as read_annotations gives for a code without a
    # mnemonic, agrees with any code)
    bad <- which(!is.na(sym) & nzchar(sym) & !(strann(sym) == code) %in% TRUE)
    if (length(bad))
      stop(sprintf("symbols and codes disagree at annotation %d", bad[1L] - 1L))
  }
  auxl <- vector("list", n)
  if (!is.null(aux)) {
    aux <- as.character(per(aux, "aux"))
    ok <- which(!is.na(aux))
    # (each distinct string is converted once)
    u <- unique(aux[ok])
    # WFDB-x: text is written as its bytes, one byte per character (see
    # .hl_check_latin1)
    for (a in u) .hl_check_latin1(a, "aux text")
    ub <- lapply(u, function(a) {
      b <- charToRaw(a)
      if (length(b) > 255L) b <- b[1:255]   # (the length byte)
      c(as.raw(length(b)), b)
    })
    auxl[ok] <- ub[match(aux[ok], u)]
  }
  afs <- if (!is.null(fs)) suppressWarnings(as.numeric(fs))
  if (!is.null(afs) && !(length(afs) == 1L && is.finite(afs) && afs > 0))
    stop("fs must be finite and > 0")
  wfdbquit()
  errors <- wfdbx_write_errors()
  # (the sort option applies to the file written here only: set after the
  # wfdbquit above, which closes any annotator opened before)
  .ann$sort_override <- sort
  on.exit(.ann$sort_override <- NULL, add = TRUE)
  # WFDB-x: the file is written to a temporary file in the directory of its
  # destination, which is renamed over it when it is complete (and, if
  # needed, sorted); after a failure, it is removed, and the existing file
  # is left as it was (see .staging_begin)
  .staging_begin()
  complete <- FALSE
  renamed <- FALSE
  st <- 0
  tryCatch({
    # (the annotator is closed however this ends)
    tryCatch({
      if (!is.null(afs)) setafreq(afs)
      if (annopen(record, list(anninfo(annotator, WFDB_WRITE)), 1) < 0)
        stop(sprintf("can't create annotator %s for record %s", annotator, record))
      st <- .putann_bulk(0, list(time = time, anntyp = code,
                                 subtyp = subtype, chan = chan, num = num, aux = auxl))
    }, finally = wfdbquit())
    # WFDB-x: an error that putann reports is an error
    complete <- st >= 0 && wfdbx_write_errors() == errors
  }, finally = renamed <- .staging_end(complete))
  if (!renamed)
    stop(sprintf("write error on annotator %s for record %s", annotator, record))
  invisible(st)
}
