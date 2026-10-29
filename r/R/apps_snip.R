# apps_snip.R: snip -- copy an excerpt of a database record.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/snip.c from the WFDB Software Package 10.7.0,
# by George B. Moody. The translation follows the logic and behavior of the
# original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency: the input record
# must give it, for the header of the excerpt (the original assumed 250 Hz);
# --legacy, as the first argument, restores the original behavior. Each change
# is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
#
# Original C program: app/snip.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1989-2013 George B. Moody; revised 2011-2021 by
#   Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# Samples are copied in blocks with getframes()/putframes(), annotations
# with .getann_bulk()/.putann_bulk() (exactly the getvec/putvec and
# getann/putann calls of the C program).

app_snip <- function(args = character(0)) {
  app_run(.snip_main, c("snip", args))
}

.SNIP_CHUNK <- 65536       # sample vectors copied per getframes() call

.snip_help <- function(pname) {
  h <- c(
    "where IREC is the name of the record to be converted, NREC is the name to",
    "be given to the record to be generated, and OPTIONS may include any of:",
    " -a ANNOTATOR [ANNOTATOR ...]  copy annotations for the specified ANNOTATOR",
    "              from IREC;  two or more ANNOTATORs may follow -a",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -l DURATION snip only DURATION (hh:mm:ss or sNNNN; overrides -t)",
    " -m          preserve segments of multsegment input, if possible",
    " -O FORMAT   save output in the specified FORMAT (default: use best fit",
    "              to ADC resolution)",
    " -s          suppress output of info strings in header",
    " -t TIME     stop at specified time",
    "To change the sampling frequency, zero level, or gain, to select a",
    "subset of signals, or to re-order signals, use `xform'.")
  ceprintf("usage: %s -i IREC -n NREC [OPTIONS ...]\n", pname)
  for (s in h) ceprintf("%s\n", s)
}

# Copy the annotations of irec from 'from' to 'to' (0: to the end).
.snip_copy_ann <- function(pname, nrec, irec, from, to, annotators) {
  ai <- lapply(annotators, function(a) anninfo(a, WFDB_READ))
  ao <- lapply(annotators, function(a) anninfo(a, WFDB_WRITE))
  if (annopen(irec, ai, length(ai)) < 0) {
    ceprintf("%s: error opening input annotators\n", pname)
    cexit(2)
  }
  if (annopen(paste0("+", nrec), ao, length(ao)) < 0) {
    ceprintf("%s: error opening output annotators\n", pname)
    cexit(2)
  }
  for (i in seq_along(annotators) - 1L) {
    A <- .getann_bulk(i, Inf)
    keep <- A$time >= from & (to == 0 | A$time < to)
    B <- list(time = A$time[keep] - from, anntyp = A$anntyp[keep],
              subtyp = A$subtyp[keep], chan = A$chan[keep], num = A$num[keep],
              aux = A$aux[keep])
    .putann_bulk(i, B)
  }
  wfdbquit()
}

# Copy the signals of irec from 'from' to 'to' (0: to the end) into record
# nrec; with recurse, the segments of a multi-segment record are copied
# into a multi-segment record.  s: list(pname, fmt, sflag), returned
# updated (the C globals).
.snip_copy_sig <- function(s, nrec, irec, from, to, recurse) {
  pname <- s$pname
  wfdbquit()
  nsig <- isigopen(irec, 0)$nsig
  if (nsig < 0) {
    ceprintf("%s: error opening header for %s\n", pname, irec)
    cexit(2)
  }
  r <- isigopen(irec, nsig)
  if (r$nsig != nsig) {
    ceprintf("%s: error opening signals for %s\n", pname, irec)
    cexit(2)
  }
  si <- r$si

  # The start time of the excerpt (without the date, unless one is given).
  tstring <- NULL
  p <- mstimstr(-from)
  if (startsWith(p, "[")) {
    tstring <- sub("\\].*", "", substring(p, 2L), useBytes = TRUE)
    k <- regexpr(" ", tstring, fixed = TRUE, useBytes = TRUE)
    if (k > 0 && !grepl("/", substring(tstring, k), fixed = TRUE, useBytes = TRUE))
      tstring <- substr(tstring, 1L, k - 1L)
  }

  seginfo <- getseginfo()
  maxseg <- length(seginfo)
  if (recurse && maxseg > 0) {
    # irec has multiple segments
    sfreq <- sampfreq(NULL)
    ohfname <- paste0(nrec, ".hea")
    ohfile <- .app_fopen(ohfname, pname)
    if (is.null(ohfile)) {
      ceprintf("%s: can't create master header\n", pname)
      cexit(2)
    }
    on.exit(.app_fclose(ohfile, report = FALSE))
    if (seginfo[[1L]]$nsamp == 0) {
      # irec has variable layout
      olrecname <- paste0(nrec, "_layout")
      for (k in seq_len(nsig)) {
        si[[k]]$fname <- "~"
        si[[k]]$fmt <- 0
        si[[k]]$nsamp <- 0
        si[[k]]$cksum <- 0
      }
      if (!is.null(tstring)) setbasetime(tstring)
      if (setheader(olrecname, si, nsig) < 0) {
        ceprintf("%s: can't create layout header\n", pname)
        cexit(2)
      }
      if (s$sflag == 0) {
        wfdbquiet()
        info <- getinfo(irec)
        while (!is.null(info)) {
          putinfo(info)
          info <- getinfo(NULL)
        }
        wfdbverbose()
        s$sflag <- 1
      }
    }

    # Which input segments contain data to be copied.
    first_seg <- 0
    last_seg <- maxseg - 1
    for (i in seq_len(maxseg) - 1) {
      t <- seginfo[[i + 1]]$samp0
      tf <- t + seginfo[[i + 1]]$nsamp
      if (t <= from && from < tf) first_seg <- i
      if (t <= to && to <= tf) {
        last_seg <- i
        break
      }
    }
    nseg <- last_seg - first_seg + 1
    if (seginfo[[1L]]$nsamp == 0) nseg <- nseg + 1
    tf <- seginfo[[last_seg + 1]]$samp0 + seginfo[[last_seg + 1]]$nsamp
    if (to > tf) to <- tf

    # The master output header.
    .app_fwrite(ohfile, csprintf("%s/%d %d %.12g %ld", nrec, nseg, nsig, sfreq, to - from))
    if (!is.null(tstring)) .app_fwrite(ohfile, csprintf(" %s", tstring))
    .app_fwrite(ohfile, charToRaw("\r\n"))
    if (seginfo[[1L]]$nsamp == 0) .app_fwrite(ohfile, csprintf("%s_layout 0\r\n", nrec))
    i <- 0
    for (j in first_seg:last_seg) {
      t <- seginfo[[j + 1]]$samp0
      tf <- t + seginfo[[j + 1]]$nsamp
      if (to < tf) tf <- to             # the last segment with data to copy
      if (from > t) {
        start <- from - t
        len <- tf - from
      } else {
        start <- 0
        len <- tf - t
      }
      if (seginfo[[j + 1]]$recname == "~") {
        orseg <- "~"
      } else {
        i <- i + 1
        orseg <- rawToChar(csprintf("%s_%04d", nrec, i))
        s <- .snip_copy_sig(s, orseg, seginfo[[j + 1]]$recname, start, start + len, 0)
      }
      .app_fwrite(ohfile, csprintf("%s %ld\r\n", orseg, len))
    }
    .app_fclose(ohfile)         # WFDB-x: reports a write error
    return(s)
  }

  if (s$fmt <= 0) {
    # no -O option: choose the format from the ADC resolution
    adcres <- vapply(si, function(x) x$adcres, 0)
    fmts <- vapply(si, function(x) x$fmt, 0)
    maxres <- max(adcres)
    fmt <- if (all(fmts == fmts[1L])) fmts[1L] else 0
    if (fmt == 0) {
      fmt <- if (maxres > 24) 32 else if (maxres > 16) 24 else if (maxres > 12) 16
             else if (maxres > 10) 212 else if (maxres > 8) 310 else 80
    }
    s$fmt <- fmt
  }

  # Open the output signals.
  ofname <- paste0(nrec, ".dat")
  for (k in seq_len(nsig)) {
    si[[k]]$fname <- ofname
    si[[k]]$group <- 0
    si[[k]]$fmt <- s$fmt
    si[[k]]$spf <- 1
  }
  if (osigfopen(si, nsig) != nsig) cexit(2)
  if (isigsettime(from) < 0) cexit(2)
  wfdbquiet()
  if (to == 0) {
    # copy to the end
    repeat {
      x <- getframes(.SNIP_CHUNK)$v
      putframes(x)
      if (nrow(x) < .SNIP_CHUNK) break
    }
  } else {
    # copy to - from vectors; the last one is written even if it could not
    # be read (as in C, the caller's vector then holds what getvec left in it)
    remaining <- to - from
    last <- NULL
    while (remaining > 1) {
      k <- min(.SNIP_CHUNK, remaining - 1)
      x <- getframes(k)$v
      putframes(x)
      remaining <- remaining - nrow(x)
      if (nrow(x) < k) break
      last <- x[k, ]
    }
    if (remaining == 1) {
      if (!is.null(last)) .sig$gvec[seq_len(nsig)] <- last   # C's v
      putvec(getvec()$v)
    }
  }
  wfdbverbose()
  setsampfreq(sampfreq(NULL))
  if (!is.null(tstring)) setbasetime(tstring)
  newheader(nrec)
  s
}

.snip_copy_info <- function(pname, irec, startp) {
  wfdbquiet()
  info <- getinfo(irec)
  while (!is.null(info)) {
    putinfo(info)
    info <- getinfo(NULL)
  }
  putinfo(csprintf("Produced by %s from record %s, beginning at %s", pname, irec, startp))
  wfdbverbose()
}

.snip_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  arg <- function(i) argv[i + 1L]          # C argv[i]
  ch <- function(a, k) {                    # C a[k] (0-based), "" past the end
    b <- charToRaw(a)
    if (k < length(b)) rawToChar(b[k + 1L]) else ""
  }
  s <- list(pname = pname, fmt = 0, sflag = 0)
  mflag <- 0
  nrec <- NULL; irec <- NULL; startp <- NULL; endp <- NULL; len <- NULL
  ann_first <- 0
  nann <- 0
  i <- 1
  while (i < argc) {
    a <- arg(i)
    if (ch(a, 0) != "-") {
      ceprintf("%s: unrecognized argument %s\n", pname, a)
      cexit(1)
    }
    c <- ch(a, 1)
    if (c == "a") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: annotator(s) must follow -a\n", pname)
        cexit(1)
      }
      # the next argument unconditionally, then those up to the next option.
      # As in C, the count of annotators is not reset if -a is given more
      # than once, and the names are those that follow the last -a (see
      # "Undefined behaviors" in docs/KNOWN_C_BEHAVIORS.md).
      ann_first <- i
      repeat {
        nann <- nann + 1
        i <- i + 1
        if (!(i < argc && ch(arg(i), 0) != "-")) break
      }
      if (i < argc) i <- i - 1
    } else if (c == "f") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: time must follow -f\n", pname)
        cexit(1)
      }
      startp <- arg(i)
    } else if (c == "h") {
      .snip_help(pname)
      cexit(0)
    } else if (c == "i" || c == "r") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: input record name must follow -i\n", pname)
        cexit(1)
      }
      irec <- arg(i)
    } else if (c == "l") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: duration must follow -l\n", pname)
        cexit(1)
      }
      len <- arg(i)
    } else if (c == "m") {
      mflag <- 1
    } else if (c == "n") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: new record name must follow -n\n", pname)
        cexit(1)
      }
      nrec <- arg(i)
    } else if (c == "O") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: output format must follow -O\n", pname)
        cexit(1)
      }
      s$fmt <- cint32(strtol(arg(i))[1L])
    } else if (c == "s") {
      s$sflag <- 1
    } else if (c == "t") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: time must follow -t\n", pname)
        cexit(1)
      }
      endp <- arg(i)
    } else {
      ceprintf("%s: unrecognized option %s\n", pname, a)
      cexit(1)
    }
    i <- i + 1
  }
  if (is.null(irec) || is.null(nrec)) {
    .snip_help(pname)
    cexit(1)
  }
  if (is.null(startp)) startp <- "0"
  if (is.null(endp)) endp <- "e"

  # Verify that the output record can be written.
  if (newheader(nrec) < 0) {
    ceprintf("%s: can't create output header\n", pname)
    cexit(2)
  }
  nsig <- isigopen(irec, 0)$nsig
  if (nsig < 0) {
    ceprintf("%s: error reading input header\n", pname)
    cexit(2)
  }
  # WFDB-x: the output header needs the sampling frequency (the C program
  # assumed 250 Hz if the input header did not specify one).
  if (!wfdbx_get_legacy() && isTRUE(sampfreq(NULL) <= 0)) {     # (legacy mode: no check)
    wfdbquit()
    .app_nofreq(pname, irec, 2)
  }

  # Evaluate the time limits.
  from <- strtim(startp)
  if (from < 0) from <- -from
  if (!is.null(len)) {
    to <- from + strtim(len)
  } else {
    to <- strtim(endp)
    if (to < 0) to <- -to
  }
  endt <- strtim("e")
  if ((endt > 0 && endt < from) || (to > 0 && to < from)) {
    ceprintf("%s: improper interval selected\n", pname)
    wfdbquit()
    cexit(1)
  }

  # (names beyond the last argument, which C reads past the end of argv, are
  # ignored)
  annotators <- if (nann > 0) argv[(ann_first:min(ann_first + nann - 1, argc - 1)) + 1L] else
    character(0)
  if (length(annotators)) .snip_copy_ann(pname, nrec, irec, from, to, annotators)
  if (nsig > 0) s <- .snip_copy_sig(s, nrec, irec, from, to, mflag)
  if (!s$sflag) .snip_copy_info(pname, irec, startp)
  wfdbquit()
  0
}
