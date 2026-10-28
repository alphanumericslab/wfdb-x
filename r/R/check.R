# check.R: check_record, a checker of WFDB records: their header, their
# signal files and their annotation files.  Every problem found is
# reported, with a severity ("error", "warning" or "info").
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
# It has no counterpart in the original package.
#
# Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# check_record is a WFDB-x addition, specified in the same way for the seven
# languages (the messages, their order and the formatting of numbers are
# identical); the Python implementation (python/src/wfdbx/check.py) is the
# reference.  The checks were designed for WFDB-x; no code or text of
# Benjamin Moody's wfdbcheck was used.  The record is read with the
# library's functions (isigopen, getvec in bulk, getseginfo, annopen,
# getann, annstr); the header file's text is read only for the checks of
# its lines and of the record name.  Strings are handled as bytes.

.CHK_INT32_MAX <- 2147483647
# Bits that each storage format can store (formats 8 and 0: no limit).
.CHK_CAPACITY <- c("80" = 8, "508" = 8, "310" = 10, "311" = 10, "212" = 12,
                   "16" = 16, "61" = 16, "160" = 16, "516" = 16, "24" = 24,
                   "524" = 24, "32" = 32)
.CHK_CHUNK_SAMPLES <- 1048576   # samples (frames x signals) read at a time

# ---------------------------------------------------------------------------
# Text of the messages

.chk_raw <- function(s) if (is.null(s)) raw(0) else if (is.raw(s)) s else charToRaw(s)

# A name quoted for a message: in double quotes, with each byte below 32 or
# above 126 written \xHH (lowercase hex).
.chk_q <- function(name) {
  b <- as.integer(.chk_raw(name))
  if (!length(b)) return("\"\"")
  out <- character(length(b))
  bad <- b < 32L | b > 126L
  out[!bad] <- vapply(b[!bad], function(x) rawToChar(as.raw(x)), "")
  out[bad] <- sprintf("\\x%02x", b[bad])
  paste0("\"", paste(out, collapse = ""), "\"")
}

# "1 frame", "2 frames"
.chk_n <- function(k, word) paste0(.f("%d", k), " ", word, if (k == 1) "" else "s")

# A message about k items: "1 NOUN VERB WHAT: ONE" or "K NOUNs VERB WHAT;
# the first is FIRST".
.chk_count <- function(k, noun, verb_one, verb_many, what, one, first) {
  if (k == 1) return(paste0("1 ", noun, " ", verb_one, " ", what, ": ", one))
  paste0(.f("%d", k), " ", noun, "s ", verb_many, " ", what, "; the first is ", first)
}

.chk_g <- function(x) .f("%g", x)
.chk_d <- function(x) .f("%d", x)

.chk_int16 <- function(x) {
  x <- x %% 65536
  if (x >= 32768) x - 65536 else x
}

.chk_has_control <- function(s) {
  b <- as.integer(.chk_raw(s))
  any(b < 32L | b == 127L)
}

# TRUE if s is only a number: an optional sign, digits with at most one
# '.', and at least one digit.
.chk_is_number <- function(s) {
  b <- as.integer(.chk_raw(s))
  if (length(b) && (b[1L] == 43L || b[1L] == 45L)) b <- b[-1L]
  if (sum(b == 46L) > 1L) return(FALSE)
  d <- b[b != 46L]
  length(d) > 0L && all(d >= 48L & d <= 57L)
}

.chk_beq <- function(a, b) identical(.chk_raw(a), .chk_raw(b))

# The issues found so far (an environment, filled in the order of the checks).
.chk_new <- function() {
  rep <- new.env(parent = emptyenv())
  rep$severity <- rep$code <- rep$where <- rep$message <- character(0)
  rep
}

.chk_add <- function(rep, severity, code, where, message) {
  rep$severity <- c(rep$severity, severity)
  rep$code <- c(rep$code, code)
  rep$where <- c(rep$where, where)
  rep$message <- c(rep$message, message)
  invisible()
}

# "segment s1" + "signal 0" -> "segment s1, signal 0"
.chk_at <- function(prefix, sub) {
  if (nzchar(prefix) && nzchar(sub)) paste0(prefix, ", ", sub) else paste0(prefix, sub)
}

# ---------------------------------------------------------------------------
# The header file

# The header file that the library reads for record `name`: list(text (raw),
# base (the record name that its file name gives: without directory and
# ".hea"), path), or NULL if there is none (no such file, or a record read
# from another format, such as EDF).
.chk_header_text <- function(name) {
  b <- charToRaw(name)
  q <- length(b)
  while (q > 1L && !(b[q] %in% charToRaw("./:\\"))) q <- q - 1L
  if (q >= 1L && b[q] == as.raw(46L)) {
    if (!identical(b[-seq_len(q)], charToRaw("hea"))) return(NULL)   # (EDF: no WFDB header)
    f <- wfdb_open(NULL, name, WFDB_READ)
  } else {
    f <- wfdb_open("hea", name, WFDB_READ)
  }
  if (is.null(f)) return(NULL)
  path <- .wfdb_io$wfdb_filename
  if (is.null(path) || !nzchar(path)) path <- name
  text <- wf_readall(f)
  wf_close(f)
  pb <- charToRaw(path)
  nd <- nchar(.dirname(path), type = "bytes")
  base <- if (nd) pb[-seq_len(nd)] else pb
  nb <- length(base)
  if (nb >= 4L && identical(base[(nb - 3L):nb], charToRaw(".hea"))) {
    base <- base[seq_len(nb - 4L)]
  } else if (nb >= 4L && identical(base[1:4], charToRaw("hea."))) {
    base <- base[-(1:4)]
  }
  list(text = text, base = base, path = path)
}

# The lines of a text (raw): split at each LF, no line after a final LF.
.chk_lines <- function(text) {
  if (!length(text)) return(list())
  nl <- which(text == as.raw(10L))
  starts <- c(1L, nl + 1L)
  ends <- c(nl - 1L, length(text))
  if (starts[length(starts)] > length(text)) {
    starts <- starts[-length(starts)]
    ends <- ends[-length(ends)]
  }
  mapply(function(s, e) if (e >= s) text[s:e] else raw(0), starts, ends, SIMPLIFY = FALSE)
}

# The fields of a header line (raw), separated by spaces, tabs and CRs.
.chk_fields <- function(line) {
  sep <- line %in% as.raw(c(32L, 9L, 13L))
  if (!length(line) || all(sep)) return(list())
  r <- rle(sep)
  ends <- cumsum(r$lengths)
  starts <- ends - r$lengths + 1L
  k <- which(!r$values)
  lapply(k, function(i) line[starts[i]:ends[i]])
}

# The fields (raw vectors) of the record line of a header (the first line
# whose first field does not begin with '#'), or NULL.
.chk_record_line <- function(text) {
  for (line in .chk_lines(text)) {
    fields <- .chk_fields(line)
    if (length(fields) && fields[[1L]][1L] != as.raw(35L)) return(fields)
  }
  NULL
}

# Checks 1.5-1.7: the lines of the header file and its record name.
.chk_text <- function(hdr, where, rep) {
  lines <- .chk_lines(hdr$text)
  lines <- lapply(lines, function(l) {
    n <- length(l)
    if (n && l[n] == as.raw(13L)) l[-n] else l
  })
  for (k in seq_along(lines)) {
    if (length(lines[[k]]) > 255L)
      .chk_add(rep, "error", "header_line_long", where,
               .f("line %d of the header is longer than 255 characters", k))
  }
  for (k in seq_along(lines)) {
    if (any(as.integer(lines[[k]]) > 127L)) {
      .chk_add(rep, "warning", "header_not_ascii", where,
               .f("line %d of the header contains non-ASCII characters", k))
      break
    }
  }
  fields <- .chk_record_line(hdr$text)
  if (length(fields)) {
    f1 <- fields[[1L]]
    x <- f1
    if (length(f1) > 1L) {
      k <- match(as.raw(47L), f1[-1L])
      if (!is.na(k)) x <- f1[seq_len(k)]
    }
    if (!identical(x, hdr$base))
      .chk_add(rep, "warning", "header_name", where,
               paste0("the header names the record ", .chk_q(x),
                      ", but its file name is ", .chk_q(hdr$base)))
  }
  invisible()
}

# The length (number of samples) on the record line: 0 if not given.
.chk_header_length <- function(text) {
  fields <- .chk_record_line(text)
  if (length(fields) < 4L) return(0)
  v <- as.integer(fields[[4L]])
  k <- match(FALSE, v >= 48L & v <= 57L)
  if (is.na(k)) k <- length(v) + 1L
  if (k == 1L) return(0)
  as.numeric(rawToChar(as.raw(v[seq_len(k - 1L)])))
}

# ---------------------------------------------------------------------------
# Signal specifications (section 2)

.chk_adc_range <- function(info) {
  b <- info$adcres
  c(info$adczero - 2^(b - 1), info$adczero + 2^(b - 1) - 1)
}

# Checks 2.1-2.13 of the signals si of a record opened under the name
# opened_as.  skip_null: signals of format 0 are not checked (a segment of a
# multi-segment record).
.chk_specs <- function(si, opened_as, prefix, rep, skip_null) {
  descs <- character(0)       # (the descriptions of the signals checked)
  for (s in seq_along(si) - 1L) {
    info <- si[[s + 1L]]
    null <- info$fmt == 0
    if (null && skip_null) next
    where <- .chk_at(prefix, paste0("signal ", s))
    desc <- info$desc
    if (is.null(desc) || !nzchar(desc) ||
        .chk_beq(desc, .f("record %s, signal %d", opened_as, s))) {
      .chk_add(rep, "warning", "desc_missing", where, "the signal has no description")
    } else {
      descs <- c(descs, desc)
      if (.chk_is_number(desc))
        .chk_add(rep, "warning", "desc_number", where,
                 paste0("the description ", .chk_q(desc), " is only a number"))
      if (.chk_has_control(desc))
        .chk_add(rep, "error", "desc_control", where,
                 paste0("the description ", .chk_q(desc), " contains control characters"))
    }
    if (info$fmt == 8)
      .chk_add(rep, "warning", "format_difference", where,
               "format 8 stores first differences, which cannot follow steep slopes")
    if (info$gain == 0) {
      .chk_add(rep, "warning", "gain_missing", where,
               "the signal is uncalibrated (no gain is given)")
    } else if (info$gain < 0) {
      .chk_add(rep, "info", "gain_negative", where,
               paste0("the gain is negative (", .chk_g(info$gain), ")"))
    }
    units <- info$units
    if (info$gain != 0 && (is.null(units) || !nzchar(units)))
      .chk_add(rep, "warning", "units_missing", where, "the units are not specified")
    if (!is.null(units) && nzchar(units) && .chk_has_control(units))
      .chk_add(rep, "error", "units_control", where,
               paste0("the units ", .chk_q(units), " contain control characters"))
    b <- info$adcres
    cap <- if (null) NA else .CHK_CAPACITY[as.character(info$fmt)]
    if (b == 0) {
      .chk_add(rep, "warning", "adcres_missing", where, "the ADC resolution is not specified")
    } else if (!is.na(cap) && b > cap) {
      .chk_add(rep, "error", "adcres_too_large", where,
               .f("the ADC resolution (%d bits) exceeds what format %d can store (%d bits)",
                  b, info$fmt, cap))
    } else if (!is.na(cap) && b >= 1) {
      r <- .chk_adc_range(info)
      fmin <- -2^(cap - 1)
      fmax <- 2^(cap - 1) - 1
      if (r[1L] < fmin || r[2L] > fmax)
        .chk_add(rep, "error", "adc_range", where,
                 .f("the ADC range (%d to %d) does not fit in format %d (%d to %d)",
                    r[1L], r[2L], info$fmt, fmin, fmax))
    }
    fname <- if (is.null(info$fname)) "" else info$fname
    if (!null && fname != "-" && fname != "~") {
      fb <- as.integer(charToRaw(fname))
      ok <- (fb >= 48L & fb <= 57L) | (fb >= 65L & fb <= 90L) | (fb >= 97L & fb <= 122L) |
        fb == 95L | fb == 45L | fb == 46L | fb == 47L
      if (!all(ok))
        .chk_add(rep, "warning", "filename", where,
                 paste0("the signal file name ", .chk_q(fname),
                        " contains characters other than letters, digits, '_', '-' and '.'"))
    }
  }
  u <- unique(descs)
  k <- tabulate(match(descs, u), length(u))
  for (i in which(k > 1L))
    .chk_add(rep, "warning", "desc_duplicate", prefix,
             paste0(.f("%d", k[i]), " signals have the description ", .chk_q(u[i])))
  invisible()
}

# ---------------------------------------------------------------------------
# Signal data (section 3)

# Read up to n frames (getvec semantics): list(v = matrix, one row per
# frame read, stat = the status of the first frame that could not be read,
# or the number of signals if all n were read).  A frame for which getvec
# returns -4 is included, and reading stops after it.
.chk_frames <- function(n) {
  st <- .sig
  nsig <- max(st$nvsig, st$nisig)
  parts <- list()
  got <- 0
  stat <- nsig
  acc <- NULL
  nrows <- 0
  while (got < n) {
    blk <- .bulk_frames(min(n - got, .BULK_MAXFRAMES))
    if (!is.null(blk) && nrow(blk) > 0) {
      if (nrows > 0) {
        parts[[length(parts) + 1L]] <- acc[seq_len(nrows), , drop = FALSE]
        nrows <- 0
      }
      parts[[length(parts) + 1L]] <- blk
      got <- got + nrow(blk)
      next
    }
    r <- .getvec(st$gvec)
    st$gvec <- r$v
    stat <- r$stat
    if (stat < 0 && stat != -4) break
    if (is.null(acc) || nrows == nrow(acc)) {
      if (nrows > 0) {
        parts[[length(parts) + 1L]] <- acc
        nrows <- 0
      }
      acc <- matrix(0, min(max(64, 2 * if (is.null(acc)) 0 else nrow(acc)), 65536), nsig)
    }
    nrows <- nrows + 1
    acc[nrows, ] <- r$v[seq_len(nsig)]
    got <- got + 1
    if (stat < 0) break
  }
  if (nrows > 0) parts[[length(parts) + 1L]] <- acc[seq_len(nrows), , drop = FALSE]
  v <- if (length(parts) == 1L) parts[[1L]] else if (length(parts)) {
    do.call(rbind, parts)
  } else {
    matrix(0, 0, nsig)
  }
  list(v = v, stat = stat)
}

# The size of the local file of signal group ig, or NULL.
.chk_file_size <- function(ig) {
  f <- ig$fp
  if (is.null(f) || f$is_std || f$type != WFDB_LOCAL) return(NULL)
  sz <- suppressWarnings(file.size(.rfile_name(f$name)))
  if (is.na(sz)) NULL else sz
}

# Checks 3.1-3.9: read the signals of the record opened as `name` (header
# signals si, header length ns).
.chk_data <- function(name, si, prefix, ns, length_missing, rep) {
  n <- length(si)
  if (n == 0) return(invisible())
  fmts <- vapply(si, function(x) x$fmt, 0)
  fnames <- vapply(si, function(x) if (is.null(x$fname)) "" else x$fname, "")
  if (any(fnames == "-" & fmts != 0)) return(invisible())   # (the standard input)
  wfdbquit()
  r <- isigopen(name, n)
  if (r$nsig < n) {
    have <- vapply(r$si, function(x) if (is.null(x$fname)) "" else x$fname, "")
    reported <- character(0)
    for (s in seq_len(n)) {
      if (fmts[s] != 0 && !(fnames[s] %in% have) && !(fnames[s] %in% reported)) {
        reported <- c(reported, fnames[s])
        .chk_add(rep, "error", "file_unreadable", prefix,
                 paste0("the signal file ", .chk_q(fnames[s]), " cannot be read"))
      }
    }
    if (!length(reported))
      .chk_add(rep, "error", "file_unreadable", prefix,
               paste0("the signal file ", .chk_q(fnames[1L]), " cannot be read"))
    wfdbquit()
    return(invisible())
  }
  st <- .sig
  groups <- vapply(si, function(x) x$group, 0)
  for (g in seq_along(st$igd)) {
    size <- .chk_file_size(st$igd[[g]])
    if (!is.null(size) && size > .CHK_INT32_MAX) {
      fname <- fnames[match(g - 1, groups)]
      .chk_add(rep, "warning", "file_large", prefix,
               paste0("the signal file ", .chk_q(fname), " has more than 2147483647 bytes, ",
                      "which 32-bit applications cannot handle"))
    }
  }
  setgvmode(WFDB_LOWRES)
  inv <- WFDB_INVALID_SAMPLE
  lo <- hi <- rep(NA_real_, n)
  for (s in seq_len(n)) {
    b <- si[[s]]$adcres
    if (b >= 1 && b <= 32 && fmts[s] != 0) {
      r <- .chk_adc_range(si[[s]])
      lo[s] <- r[1L]
      hi[s] <- r[2L]
    }
  }
  n_out <- n_inv <- numeric(n)
  first_out <- first_val <- first_inv <- rep(NA_real_, n)
  rows <- max(1024, .CHK_CHUNK_SAMPLES %/% n)
  m <- 0                      # frames read
  stat <- n
  residual <- NULL            # checksum residuals after ns frames
  # (the checksums: not for EDF, nor for a record with skewed signals, whose
  # samples the library reads ahead)
  skews <- vapply(seq_len(n) - 1L, wfdbgetskew, 0)
  checked <- ns > 0 && !st$isedf && all(skews == 0)
  st$cksum_quiet <- TRUE
  on.exit(st$cksum_quiet <- FALSE)
  repeat {
    want <- rows
    if (checked && is.null(residual)) want <- min(rows, ns - m)
    fr <- .chk_frames(want)
    stat <- fr$stat
    got <- nrow(fr$v)
    if (got) {
      for (s in seq_len(n)) {
        if (fmts[s] == 0) next          # (a null signal: no data)
        col <- fr$v[, s]
        bad <- col == inv
        if (any(bad)) {
          if (is.na(first_inv[s])) first_inv[s] <- m + which(bad)[1L] - 1
          n_inv[s] <- n_inv[s] + sum(bad)
        }
        if (!is.na(lo[s])) {
          out <- !bad & (col < lo[s] | col > hi[s])
          if (any(out)) {
            if (is.na(first_out[s])) {
              j <- which(out)[1L]
              first_out[s] <- m + j - 1
              first_val[s] <- col[j]
            }
            n_out[s] <- n_out[s] + sum(out)
          }
        }
      }
      m <- m + got
    }
    if (checked && is.null(residual) && m >= ns)
      residual <- vapply(st$isd[seq_len(n)], function(is) is$info$cksum, 0)
    if (stat == -4) next
    if (got < want) break
  }
  st$cksum_quiet <- FALSE
  # (with skewed signals, getvec returns the frames of the files less the
  # largest skew)
  skew <- max(vapply(seq_len(n) - 1L, wfdbgetskew, 0))
  wfdbquit()
  if (skew && m > 0) m <- m + skew
  for (s in seq_len(n)) {
    where <- .chk_at(prefix, paste0("signal ", s - 1L))
    if (n_out[s]) {
      x <- .f("sample %d (value %d)", first_out[s], first_val[s])
      .chk_add(rep, "error", "sample_range", where,
               .chk_count(n_out[s], "sample", "is", "are",
                          .f("outside the ADC range (%d to %d)", lo[s], hi[s]), x, x))
    }
    if (n_inv[s]) {
      x <- .f("sample %d", first_inv[s])
      .chk_add(rep, "info", "invalid_samples", where,
               .chk_count(n_inv[s], "sample", "is", "are", "invalid (missing data)", x, x))
    }
  }
  if (!is.null(residual)) {
    for (s in seq_len(n)) {
      info <- si[[s]]
      if (info$nsamp > 0 && info$fmt != 0 && residual[s] %% 65536 != 0)
        .chk_add(rep, "error", "checksum", .chk_at(prefix, paste0("signal ", s - 1L)),
                 .f("the checksum does not match: the header gives %d, the samples sum to %d",
                    .chk_int16(info$cksum), .chk_int16(info$cksum - residual[s])))
    }
  }
  end_ok <- stat == -1 || stat >= 0
  short <- ns > 0 && m < ns && (stat == -1 || stat == -3)
  if (short)
    .chk_add(rep, "error", "length_short", prefix,
             paste0("the signal files end after ", .chk_n(m, "frame"), ", before the ",
                    .chk_d(ns), " given in the header"))
  if (ns > 0 && m > ns)
    .chk_add(rep, "warning", "length_long", prefix,
             paste0("the signal files hold ", .chk_n(m, "frame"), ", more than the ",
                    .chk_d(ns), " given in the header"))
  if (length_missing && end_ok)
    .chk_add(rep, "info", "length_unspecified_frames", prefix,
             paste0("the signal files hold ", .chk_n(m, "frame")))
  if (!end_ok && !short)
    .chk_add(rep, "error", "read_error", prefix,
             paste0("the signal data cannot be read after ", .chk_n(m, "frame"),
                    .f(" (getvec status %d)", stat)))
  invisible()
}

# ---------------------------------------------------------------------------
# A record (sections 1-4)

# Open the header of record `name` (wfdbquit first).  Returns list(n, si,
# fs, nsamples, segs) or NULL if the header cannot be read.
.chk_open_header <- function(name) {
  wfdbquit()
  n <- isigopen(name, 0)$nsig
  if (n < 0) {
    wfdbquit()
    return(NULL)
  }
  si <- if (n > 0) isigopen(name, -n)$si else list()
  st <- .sig
  segs <- getseginfo()
  nsamples <- if (st$in_msrec || length(segs)) st$msnsamples else st$nsamples
  fs <- sampfreq(NULL)
  wfdbquit()
  list(n = n, si = si, fs = fs, nsamples = nsamples,
       segs = lapply(segs, function(x) list(name = x$recname, len = x$nsamp)))
}

.chk_length_large <- function(nsamples, where, rep) {
  if (nsamples > .CHK_INT32_MAX)
    .chk_add(rep, "info", "length_large", where,
             "the record has more than 2147483647 samples, which 32-bit applications cannot handle")
}

# Sections 1.2-1.8 and 2 for a single-segment record.  Returns TRUE if the
# header gives no length (length_missing).
.chk_single <- function(record, info, hdr, rep) {
  if (info$n == 0) .chk_add(rep, "info", "no_signals", "", "the record has no signals")
  if (info$fs == 0)
    .chk_add(rep, "warning", "fs_missing", "", "the sampling frequency is not specified")
  if (info$nsamples == 0)
    .chk_add(rep, "warning", "length_missing", "", "the record length is not specified")
  if (!is.null(hdr)) .chk_text(hdr, "", rep)
  .chk_length_large(info$nsamples, "", rep)
  if (info$n > 0) .chk_specs(info$si, record, "", rep, FALSE)
  info$nsamples == 0
}

# The absolute form of a local directory name (with a final '/').
.chk_absdir <- function(d) {
  p <- normalizePath(if (nzchar(d)) d else ".", winslash = "/", mustWork = FALSE)
  if (endsWith(p, "/")) p else paste0(p, "/")
}

# Sections 1-4.  Returns the record length in samples for the annotation
# checks (0 if unknown), or NULL if the header cannot be read.
.chk_record_signals <- function(record, rep) {
  hdr <- .chk_header_text(record)
  info <- .chk_open_header(record)
  if (is.null(info)) {
    .chk_add(rep, "error", "header_unreadable", "", "the header cannot be read")
    if (!is.null(hdr)) .chk_text(hdr, "", rep)
    return(NULL)
  }
  segs <- info$segs
  if (!length(segs)) {
    length_missing <- .chk_single(record, info, hdr, rep)
    if (info$n > 0) .chk_data(record, info$si, "", info$nsamples, length_missing, rep)
    return(info$nsamples)
  }
  # A multi-segment record: the master header
  fs <- info$fs
  if (info$n == 0) .chk_add(rep, "info", "no_signals", "", "the record has no signals")
  if (fs == 0)
    .chk_add(rep, "warning", "fs_missing", "", "the sampling frequency is not specified")
  given <- if (!is.null(hdr)) .chk_header_length(hdr$text) else info$nsamples
  if (given == 0)
    .chk_add(rep, "warning", "length_missing", "", "the record length is not specified")
  if (!is.null(hdr)) .chk_text(hdr, "", rep)
  .chk_length_large(info$nsamples, "", rep)
  # The segments, next to the master header
  hpath <- if (!is.null(hdr)) hdr$path else {
    p <- wfdbfile("hea", record)
    if (is.null(p)) "" else p
  }
  d <- .dirname(hpath)
  if (!nzchar(d) || (!.is_url(d) && !.is_absolute_path(d))) d <- .chk_absdir(d)
  variable <- segs[[1L]]$len == 0
  layout_descs <- NULL
  done <- character(0)
  for (k in seq_along(segs)) {
    seg <- segs[[k]]$name
    if (seg == "~" || seg %in% done) next
    done <- c(done, seg)
    prefix <- paste0("segment ", seg)
    is_layout <- variable && k == 1L
    if (!.in_header_dir(seg)) {
      .chk_add(rep, "error", "segment_unreadable", prefix, "the segment cannot be read")
      next
    }
    path <- paste0(d, seg)
    seg_hdr <- .chk_header_text(path)
    sinfo <- .chk_open_header(path)
    if (!is.null(sinfo) && length(sinfo$segs)) {
      .chk_add(rep, "error", "nested", prefix, "the segment is itself a multi-segment record")
      next
    }
    if (is.null(sinfo)) {
      .chk_add(rep, "error", "segment_unreadable", prefix, "the segment cannot be read")
      next
    }
    if (sinfo$fs > 0 && fs > 0 && sinfo$fs != fs)
      .chk_add(rep, "error", "segment_fs", prefix,
               paste0("the segment's sampling frequency (", .chk_g(sinfo$fs),
                      ") differs from the record's (", .chk_g(fs), ")"))
    if (sinfo$n == 0) .chk_add(rep, "info", "no_signals", prefix, "the record has no signals")
    if (!is.null(seg_hdr)) .chk_text(seg_hdr, prefix, rep)
    .chk_length_large(sinfo$nsamples, prefix, rep)
    ssi <- sinfo$si
    if (sinfo$n > 0) .chk_specs(ssi, path, prefix, rep, !is_layout)
    if (is_layout) {
      layout_descs <- vapply(ssi, function(x) if (is.null(x$desc)) "" else x$desc, "")
      next
    }
    if (variable) {
      for (s in seq_along(ssi)) {
        x <- ssi[[s]]
        desc <- if (is.null(x$desc)) "" else x$desc
        if (x$fmt != 0 && !(desc %in% layout_descs))
          .chk_add(rep, "error", "layout_missing_signal",
                   .chk_at(prefix, paste0("signal ", s - 1L)),
                   paste0("the signal ", .chk_q(desc), " is not in the layout"))
      }
    } else {
      .chk_layout(ssi, info$si, prefix, rep)
    }
    if (sinfo$n > 0) .chk_data(path, ssi, prefix, sinfo$nsamples, FALSE, rep)
  }
  total <- sum(vapply(segs, function(x) x$len, 0))
  if (given > 0 && total != given)
    .chk_add(rep, "warning", "segment_lengths", "",
             paste0("the segment lengths add up to ", .chk_n(total, "sample"),
                    ", but the master header gives ", .chk_d(given)))
  total                       # (the end of the signals)
}

# Check 4.4: the signals of a segment of a fixed-layout record match the
# record's signals.
.chk_layout <- function(ssi, si, prefix, rep) {
  if (length(ssi) != length(si))
    .chk_add(rep, "error", "layout_signals", prefix,
             paste0("the segment has ", .chk_n(length(ssi), "signal"),
                    ", but the record has ", .chk_d(length(si))))
  for (s in seq_len(min(length(ssi), length(si)))) {
    a <- ssi[[s]]
    b <- si[[s]]
    if (a$fmt == 0) next
    where <- .chk_at(prefix, paste0("signal ", s - 1L))
    fields <- list(
      c("description", .chk_q(a$desc), .chk_q(b$desc)),
      c("units", .chk_q(a$units), .chk_q(b$units)),
      c("gain", .chk_g(a$gain), .chk_g(b$gain)),
      c("baseline", .chk_d(a$baseline), .chk_d(b$baseline)),
      c("samples per frame", .chk_d(a$spf), .chk_d(b$spf)))
    for (f in fields) {
      if (f[2L] != f[3L])
        .chk_add(rep, "error", "layout_mismatch", where,
                 paste0(.f("the signal differs from the record's signal %d in its ", s - 1L),
                        f[1L], " (", f[2L], ", expected ", f[3L], ")"))
    }
  }
  invisible()
}

# ---------------------------------------------------------------------------
# Annotators (section 5)

.chk_annotator <- function(record, an, len, rep) {
  where <- paste0("annotator ", an)
  ab <- as.integer(charToRaw(an))
  if (length(ab) && all(ab >= 48L & ab <= 57L))
    .chk_add(rep, "warning", "annotator_name", where,
             "the annotator name consists only of digits")
  wfdbquit()
  if (!is.null(len)) sampfreq(record)   # (the record's frequency, for getann)
  a <- .ann
  saved <- list(a$astring, a$tstring, a$modified)
  on.exit({
    wfdbquit()
    a$astring <- saved[[1L]]
    a$tstring <- saved[[2L]]
    a$modified <- saved[[3L]]
  })
  if (annopen(record, list(anninfo(an, WFDB_READ)), 1) < 0) {
    .chk_add(rep, "error", "annotations_unreadable", where, "the annotation file cannot be read")
    return(invisible())
  }
  A <- .getann_bulk(0, Inf, noaux = TRUE, nofail = TRUE)
  stat <- getann(0)$stat               # (the status that ended the reading)
  tm <- A$time
  cd <- A$anntyp
  undefined <- cd >= 1 & cd <= ACMAX
  undefined[undefined] <- annstr(cd[undefined]) == sprintf("[%d]", as.integer(cd[undefined]))
  count <- length(tm)
  if (stat != -1)
    .chk_add(rep, "error", "annotations_truncated", where,
             paste0("the annotation file ends unexpectedly after ", .chk_n(count, "annotation")))
  if (count > 1L) {
    ooo <- which(tm[-1L] < tm[-count])
    if (length(ooo)) {
      j <- ooo[1L]
      x <- .f("at sample %d, after sample %d", tm[j + 1L], tm[j])
      .chk_add(rep, "error", "annotations_order", where,
               .chk_count(length(ooo), "annotation", "is", "are", "out of order", x, x))
    }
  }
  k <- which(cd > ACMAX)
  if (length(k)) {
    x <- .f("at sample %d (code %d)", tm[k[1L]], cd[k[1L]])
    .chk_add(rep, "error", "annotation_code", where,
             .chk_count(length(k), "annotation", "has", "have", "an invalid code", x, x))
  }
  k <- which(cd == 0)
  if (length(k)) {
    x <- .f("at sample %d", tm[k[1L]])
    .chk_add(rep, "warning", "annotation_null", where,
             .chk_count(length(k), "annotation", "has", "have", "code 0 (NOTQRS)", x, x))
  }
  k <- which(undefined)
  if (length(k)) {
    x <- .f("at sample %d (code %d)", tm[k[1L]], cd[k[1L]])
    msg <- if (length(k) == 1L) paste0("1 annotation uses a code without a mnemonic: ", x) else
      paste0(.f("%d", length(k)), " annotations use codes without a mnemonic; the first is ", x)
    .chk_add(rep, "warning", "annotation_undefined", where, msg)
  }
  if (!is.null(len) && len > 0) {
    k <- which(tm >= len)
    if (length(k)) {
      x <- .f("at sample %d", tm[k[1L]])
      .chk_add(rep, "warning", "annotations_after_end", where,
               .chk_count(length(k), "annotation", "is", "are",
                          paste0("after the end of the record (", .chk_n(len, "sample"), ")"),
                          x, x))
    }
  }
  invisible()
}

# ---------------------------------------------------------------------------

#' Check a record and its annotation files, and report every problem.
#'
#' The header, the signal specifications, the signal files (all samples
#' are read) and the given annotation files are checked.  Problems in the
#' record never stop() with an error: they are reported.  The checks run
#' in normal mode, even if legacy mode is on, and the library prints no
#' messages during the call (the settings are restored afterwards).
#'
#' record: a record name (relative to the input directory, or a full path,
#' ~ path or URL, as for read_record).  annotators: a character vector of
#' annotator names to check (default: none).  input_dir, network: see
#' read_record.
#'
#' Returns an object of class "wfdbx_check_report": a list with record (as
#' given), ok (TRUE if no issue has the severity "error") and issues (a
#' data frame with the columns severity ("error", "warning" or "info"),
#' code, where and message, one row per problem, in the order of the
#' checks).  format(report) gives the text form (one line per issue,
#' "SEVERITY: WHERE: MESSAGE", or "no problems found"); print(report)
#' prints it.
#'
#' Errors: stop() if record is not a single non-empty string, or
#' annotators is not a character vector.
check_record <- function(record, annotators = character(0), input_dir = NULL,
                         network = NULL) {
  if (!is.character(record) || length(record) != 1L || is.na(record))
    stop("record must be a string")
  if (!nzchar(record)) stop("record must not be empty")
  if (is.null(annotators)) annotators <- character(0)
  if (!is.character(annotators) || anyNA(annotators))
    stop("annotator names must be strings")
  rep <- .chk_new()
  .hl_input(input_dir, network, {
    legacy <- wfdbx_set_legacy(FALSE)
    printing <- .wfdb_io$error_print
    .wfdb_io$error_print <- FALSE
    gvmode <- getgvmode()
    tryCatch({
      wfdbquit()
      len <- .chk_record_signals(record, rep)
      for (a in annotators) .chk_annotator(record, a, len, rep)
    }, finally = {
      wfdbquit()
      setgvmode(gvmode)         # (the mode before the call: WFDB-x)
      .wfdb_io$error_print <- printing
      wfdbx_set_legacy(legacy)
    })
  })
  issues <- data.frame(severity = rep$severity, code = rep$code, where = rep$where,
                       message = rep$message, stringsAsFactors = FALSE)
  structure(list(record = record, ok = !any(rep$severity == "error"), issues = issues),
            class = "wfdbx_check_report")
}

#' The text form of a check report: one line per issue, or "no problems
#' found".
format.wfdbx_check_report <- function(x, ...) {
  i <- x$issues
  if (!nrow(i)) return("no problems found")
  ifelse(nzchar(i$where), paste0(i$severity, ": ", i$where, ": ", i$message),
         paste0(i$severity, ": ", i$message))
}

print.wfdbx_check_report <- function(x, ...) {
  writeLines(format(x))
  invisible(x)
}
