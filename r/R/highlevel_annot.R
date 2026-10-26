# highlevel_annot.R: reading and writing whole annotation files
# (read_annotations, write_annotations), built on the C-compatible API
# (annopen, getann, putann), so that they read and write exactly what the
# WFDB library and the rdann and wrann tools do.
#
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV, 12
# bits and millivolts), because a silently assumed value corrupts every result
# derived from it. See docs/DIVERGENCES.md.
# Design decision (Reza Sameni, after a code review, Oct 2026):
# write_annotations takes a dir argument (the file is created in that
# directory), and an out-of-order file is sorted in this process (see
# annot.R).  The original behavior remains available with --legacy (see
# docs/DIVERGENCES.md).
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
#' fs: the sampling frequency of the record, used (like the -F option of
#' rdann) only if the record has no header or its header does not specify
#' one.  wfdb-x: there is no default (C assumed 250 Hz; see
#' docs/DIVERGENCES.md): without one, the fs attribute of the result is
#' that of the annotation file (0 if it does not specify one), and time
#' strings that need the sampling frequency (wfdbx_time_needs_freq) are an
#' error.
#'
#' input_dir, network: the input directory and the network permission for
#' this call (see read_record; wfdb-x).
#'
#' legacy: if TRUE, behave as the original package (250 Hz for a record
#' without a header, or whose header does not specify the frequency, unless
#' fs is given), with the library's legacy mode on for the duration of the
#' call.  Kept for compatibility only: the values it assumes are exactly the
#' silent defaults this project removed.
read_annotations <- function(record, annotator, sampfrom = 0, sampto = NULL, fs = NULL,
                             input_dir = NULL, network = NULL,
                             legacy = FALSE) .hl_legacy(legacy, .hl_input(input_dir, network, {
  legacy <- wfdbx_get_legacy()
  if (!is.null(fs) && (length(fs) != 1L || !is.numeric(fs) || is.na(fs) || fs <= 0))
    stop("fs must be > 0")
  wfdbquit()
  sps <- sampfreq(record)
  if (sps <= 0 && !is.null(fs)) {
    setsampfreq(sps <- as.numeric(fs))
  } else if (sps < 0 && legacy) {
    setsampfreq(sps <- WFDB_DEFFREQ)      # legacy mode (original behavior)
  }
  if (sps <= 0 && !legacy) {
    for (t in list(sampfrom, sampto)) {
      if (is.character(t) && wfdbx_time_needs_freq(t)) {
        wfdbquit()
        stop("sampling frequency of record ", record, " is not specified")
      }
    }
  }
  if (annopen(record, list(anninfo(annotator, WFDB_READ)), 1) < 0) {
    wfdbquit()
    stop(sprintf("can't read annotator %s for record %s", annotator, record))
  }
  frm <- .hl_ann_time(sampfrom)
  if (is.null(frm)) frm <- 0
  to <- .hl_ann_time(sampto)
  if (frm != 0 && iannsettime(frm) < 0) {
    wfdbquit()
    stop(sprintf("can't seek in annotator %s", annotator))
  }
  A <- .getann_bulk(0, Inf)
  n <- length(A$time)
  if (!is.null(to)) {
    k <- match(TRUE, A$time >= to)
    if (!is.na(k)) n <- k - 1L
  }
  s <- seq_len(n)
  afs <- getiafreq(0)
  res <- data.frame(sample = A$time[s], symbol = annstr(A$anntyp[s]), code = A$anntyp[s],
                    subtype = A$subtyp[s], chan = A$chan[s], num = A$num[s],
                    aux = .hl_aux_text(A$aux[s]), stringsAsFactors = FALSE)
  attr(res, "record") <- record
  attr(res, "annotator") <- annotator
  attr(res, "fs") <- afs
  wfdbquit()
  res
}))

#' Write an annotation file (as wrann does).
#'
#' sample: the annotation times (or a data frame as returned by
#' read_annotations, whose columns then give all fields).  Give either
#' symbol (mnemonics such as "N") or code (annotation type codes).
#' subtype, chan and num are recycled; aux is a character vector (NA for
#' none) or NULL.  If fs is given, it is recorded as the time resolution of
#' the file (setafreq).  Annotations out of order are sorted when the file
#' is closed (as the sortann tool does; wfdb-x: in this process, whereas the
#' C library, as legacy mode, runs sortann), unless the WFDBANNSORT
#' environment variable is 0.  dir: if given, the directory (which must
#' exist) in which the file is created (record must not contain a
#' directory; wfdb-x).  Returns invisibly the status of the last putann
#' (0).  legacy: if TRUE, the library's legacy mode is on for the duration
#' of the call (see read_annotations).
#'
#' sort: NULL (the default): an out-of-order file is sorted unless the
#' WFDBANNSORT environment variable is 0; TRUE: it is sorted, FALSE: it is
#' left in the order given, for this call only, whatever WFDBANNSORT says
#' (in legacy mode too: TRUE runs the sortann tool; the environment is not
#' changed).  wfdb-x.
write_annotations <- function(record, annotator, sample, symbol = NULL, code = NULL,
                              subtype = 0, chan = 0, num = 0, aux = NULL, fs = NULL,
                              dir = NULL, legacy = FALSE, sort = NULL) {
  if (isTRUE(legacy)) {
    old <- wfdbx_set_legacy(TRUE)
    on.exit(wfdbx_set_legacy(old), add = TRUE)
  }
  if (!is.null(dir) && nzchar(dir)) {       # wfdb-x: see .hl_output_dir
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
  n <- length(sample)
  if (is.null(code)) {
    if (is.null(symbol)) stop("symbol or code must be given")
    code <- strann(as.character(symbol))
  }
  code <- rep_len(as.numeric(code), n)
  auxl <- vector("list", n)
  if (!is.null(aux)) {
    aux <- rep_len(as.character(aux), n)
    ok <- which(!is.na(aux))
    # (each distinct string is converted once)
    u <- unique(aux[ok])
    ub <- lapply(u, function(a) {
      b <- charToRaw(a)
      if (length(b) > 255L) b <- b[1:255]   # (the length byte)
      c(as.raw(length(b)), b)
    })
    auxl[ok] <- ub[match(aux[ok], u)]
  }
  wfdbquit()
  # (the sort option applies to the file written here only: set after the
  # wfdbquit above, which closes any annotator opened before)
  .ann$sort_override <- sort
  on.exit(.ann$sort_override <- NULL, add = TRUE)
  if (!is.null(fs)) setafreq(as.numeric(fs))
  on.exit(if (!is.null(fs)) setafreq(0), add = TRUE)
  if (annopen(record, list(anninfo(annotator, WFDB_WRITE)), 1) < 0) {
    wfdbquit()
    stop(sprintf("can't create annotator %s for record %s", annotator, record))
  }
  st <- .putann_bulk(0, list(time = trunc(as.numeric(sample)), anntyp = code,
                             subtyp = rep_len(as.numeric(subtype), n),
                             chan = rep_len(as.numeric(chan), n),
                             num = rep_len(as.numeric(num), n), aux = auxl))
  wfdbquit()
  invisible(st)
}
