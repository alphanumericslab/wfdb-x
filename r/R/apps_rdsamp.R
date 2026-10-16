# apps_rdsamp.R: rdsamp -- print an arbitrary number of samples from each
# signal.
#
# Copyright (C) 1983-2010 George B. Moody (original C program, app/rdsamp.c;
# revised 2017-2020 by Benjamin Moody).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV, 12
# bits and millivolts), because a silently assumed value corrupts every result
# derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).
#
# The samples are read in blocks with getframes() and formatted with
# vectorized C formatting (csprintf_v), one block at a time.

app_rdsamp <- function(args = character(0)) {
  app_run(.rdsamp_main, c("rdsamp", args))
}

.rdsamp_help <- function(pname) {
  h <- c(
    " -c          use CSV (comma-separated value) output format",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          read multifrequency signals in high resolution mode",
    " -l INTERVAL truncate output after the specified time interval (hh:mm:ss)",
    " -p          print times and samples in physical units (default: raw units)",
    " -P          same as -p, but with greater precision",
    "              -p and -P may be followed by a character to choose a time",
    "              format;  choices are:",
    "  -pd (or -Pd)  print time of day and date if known",
    "  -pe (or -Pe)  print elapsed time as <hours>:<minutes>:<seconds>",
    "  -ph (or -Ph)  print elapsed time in hours",
    "  -pm (or -Pm)  print elapsed time in minutes",
    "  -ps (or -Ps)  print elapsed time in seconds",
    "  -pS (or -PS)  print elapsed time in sample intervals",
    " -s SIGNAL [SIGNAL ...]  print only the specified signal(s)",
    " -S SIGNAL   search for a valid sample of the specified SIGNAL at or after",
    "\t\tthe time specified with -f, and begin printing then",
    " -t TIME     stop at specified time",
    " -v          print column headings",
    " -X          output in WFDB-XML format")
  ceprintf("usage: %s -r RECORD [OPTIONS ...]\n", pname)
  ceprintf("%s\n", "where RECORD is the name of the input record, and OPTIONS may include:")
  for (s in h) ceprintf("%s\n", s)
}

# Escape quotes and backslashes (see docs/KNOWN_C_BEHAVIORS.md).
.rdsamp_escapify <- function(s) {
  gsub("'", "\\'", gsub("\\", "\\\\", s, fixed = TRUE), fixed = TRUE)
}

.rdsamp_main <- function(argv) {
  SECONDS <- 1; MINUTES <- 2; HOURS <- 3; TIMSTR <- 4; MSTIMSTR <- 5
  SHORTTIMSTR <- 6; HHMMSS <- 7; SAMPLES <- 8
  CHUNK <- 65536
  pname <- argv[1L]
  argc <- length(argv)
  record <- NULL
  search <- NULL
  cflag <- 0; highres <- 0; pflag <- 0; vflag <- 0; xflag <- 0
  nosig <- 0
  isiglist <- 0
  timeunits <- SECONDS
  from_i <- 0; maxl_i <- 0; to_i <- 0
  arg <- function(i) argv[i + 1L]          # C argv[i]
  ch <- function(a, k) {                    # C a[k] (0-based), "" past the end
    b <- charToRaw(a)
    if (k < length(b)) rawToChar(b[k + 1L]) else ""
  }
  i <- 1
  while (i < argc) {
    a <- arg(i)
    if (ch(a, 0) == "-") {
      c <- ch(a, 1)
      if (c == "c") {
        cflag <- 1
      } else if (c == "f") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: time must follow -f\n", pname)
          cexit(1)
        }
        from_i <- i
      } else if (c == "h") {
        .rdsamp_help(pname)
        cexit(0)
      } else if (c == "H") {
        highres <- 1
      } else if (c == "l") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: max output length must follow -l\n", pname)
          cexit(1)
        }
        maxl_i <- i
      } else if (c == "P" || c == "p") {
        pflag <- pflag + if (c == "P") 2 else 1
        d <- ch(a, 2)
        timeunits <- if (!nzchar(d)) SECONDS else
          switch(d, d = TIMSTR, e = HHMMSS, h = HOURS, m = MINUTES, S = SAMPLES, SECONDS)
      } else if (c == "r") {
        i <- i + 1
        if (i >= argc) {
          ceprintf("%s: record name must follow -r\n", pname)
          cexit(1)
        }
        record <- arg(i)
      } else if (c == "s") {
        isiglist <- i + 1
        while (i + 1 < argc && ch(arg(i + 1), 0) != "-") {
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
        to_i <- i
      } else if (c == "v") {
        vflag <- 1
      } else if (c == "X") {
        xflag <- cflag <- vflag <- 1
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
    .rdsamp_help(pname)
    cexit(1)
  }
  nsig <- isigopen(record, 0)$nsig
  if (nsig <= 0) cexit(2)
  r <- isigopen(record, nsig)
  nsig <- r$nsig
  si <- r$si
  if (nsig <= 0) cexit(2)
  legacy <- wfdbx_get_legacy()
  if (legacy) {        # wfdb-x: legacy mode (original behavior): default gain
    for (k in seq_len(nsig)) if (si[[k]]$gain == 0) si[[k]]$gain <- WFDB_DEFGAIN
  }
  if (highres) setgvmode(WFDB_HIGHRES)
  freq <- sampfreq(NULL)
  # wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
  # the header did not specify one).
  if (!legacy && freq <= 0 &&
      ((from_i > 0 && wfdbx_time_needs_freq(arg(from_i))) ||
       (to_i > 0 && wfdbx_time_needs_freq(arg(to_i))) ||
       (maxl_i > 0 && wfdbx_time_needs_freq(arg(maxl_i))) ||
       xflag || (pflag && (timeunits != SAMPLES || vflag))))
    .app_nofreq(pname, record, 2)
  from <- 0
  if (from_i > 0) {
    from <- strtim(arg(from_i))
    if (from < 0) from <- -from
  }
  if (isigsettime(from) < 0) cexit(2)
  to <- 0
  if (to_i > 0) {
    to <- strtim(arg(to_i))
    if (to < 0) to <- -to
  }
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
    nsig <- nosig
  } else {
    sig <- seq_len(nsig) - 1
  }
  # wfdb-x: no default gain (the C program assumed 200 adu/mV for
  # uncalibrated signals).
  if (pflag && !legacy) {
    for (s in sig) if (si[[s + 1]]$gain == 0) .app_uncalibrated(pname, s, record, 2)
  }
  if (!is.null(search)) {
    s <- findsig(search)
    if (s >= 0) from <- tnextvec(s, from)
    if (s < 0 || from < 0) {
      ceprintf("%s: can't read signal '%s'\n", pname, search)
      cexit(2)
    }
  }
  maxl <- 0
  if (maxl_i > 0) {
    maxl <- strtim(arg(maxl_i))
    if (maxl < 0) maxl <- -maxl
  }
  if (maxl && (to == 0 || to > from + maxl)) to <- from + maxl
  if (timeunits == TIMSTR) {
    p <- timstr(0)
    if (!startsWith(p, "[")) {
      timeunits <- HHMMSS
    } else if (nchar(p, type = "bytes") < 16) {
      timeunits <- SHORTTIMSTR
    } else if (freq > 1) {
      timeunits <- MSTIMSTR
    }
  }
  if (timeunits == HOURS) {
    freq <- freq * 3600
  } else if (timeunits == MINUTES) {
    freq <- freq * 60
  }
  tufmt <- ""; tnfmt <- ""; tfmt <- ""; vfmt <- ""; invalid <- ""; snfmt <- ""
  if (cflag) {
    snfmt <- ",'%s'"
    if (pflag) {
      if (timeunits == SAMPLES) {
        tnfmt <- "'sample interval'"
        tufmt <- .f("'%g sec'", 1 / freq)
      } else if (timeunits == SHORTTIMSTR) {
        tnfmt <- "'Time'"; tufmt <- "'hh:mm:ss.mmm'"
      } else if (timeunits == TIMSTR) {
        tnfmt <- "'Time and date'"; tufmt <- "'hh:mm:ss dd/mm/yyyy'"
      } else if (timeunits == MSTIMSTR) {
        tnfmt <- "'Time and date'"; tufmt <- "'hh:mm:ss.mmm dd/mm/yyyy'"
      } else if (timeunits == HHMMSS) {
        tnfmt <- "'Elapsed time'"; tufmt <- "'hh:mm:ss.mmm'"
      } else if (timeunits == HOURS) {
        tnfmt <- "'Elapsed time'"; tufmt <- "'hours'"
      } else if (timeunits == MINUTES) {
        tnfmt <- "'Elapsed time'"; tufmt <- "'minutes'"
      } else {
        tnfmt <- "'Elapsed time'"; tufmt <- "'seconds'"
      }
      invalid <- ",-"
      vfmt <- if (pflag > 1) ",%.8f" else ",%.3f"
    } else {
      tnfmt <- "'sample #'"
      tfmt <- "%d"
      vfmt <- ",%d"
    }
  } else {
    if (pflag) {
      if (timeunits == SAMPLES) {
        tnfmt <- "sample interval"
        speriod <- .btrunc(.f("(%g", 1 / freq), 10)
        tufmt <- .f("%10s sec)", speriod)
      } else if (timeunits == SHORTTIMSTR) {
        tnfmt <- "     Time"; tufmt <- "(hh:mm:ss.mmm)"
      } else if (timeunits == TIMSTR) {
        tnfmt <- "   Time      Date    "; tufmt <- "(hh:mm:ss dd/mm/yyyy)"
      } else if (timeunits == MSTIMSTR) {
        tnfmt <- "      Time      Date    "; tufmt <- "(hh:mm:ss.mmm dd/mm/yyyy)"
      } else if (timeunits == HHMMSS) {
        tnfmt <- "   Elapsed time"; tufmt <- "   hh:mm:ss.mmm"
      } else if (timeunits == HOURS) {
        tnfmt <- "   Elapsed time"; tufmt <- "        (hours)"
      } else if (timeunits == MINUTES) {
        tnfmt <- "   Elapsed time"; tufmt <- "      (minutes)"
      } else {
        tnfmt <- "   Elapsed time"; tufmt <- "      (seconds)"
      }
      if (pflag > 1) {
        snfmt <- "\t%15s"
        invalid <- "\t              -"
        vfmt <- "\t%15.8f"
      } else {
        snfmt <- "\t%7s"
        invalid <- "\t      -"
        vfmt <- "\t%7.3f"
      }
    } else {
      snfmt <- "\t%7s"
      tnfmt <- "       sample #"
      tfmt <- "%15d"
      vfmt <- "\t%7d"
    }
  }
  if (xflag) {
    cout(paste0("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n",
                "<?xml-stylesheet type=\"text/xsl\" href=\"wfdb.xsl\"?>\n",
                "<!DOCTYPE wfdbsampleset PUBLIC \"-//PhysioNet//DTD WFDB 1.0//EN\"",
                " \"http://physionet.org/physiobank/database/XML/wfdb.dtd\">\n"))
    cprintf("<wfdbsampleset>\n<samplingfrequency>%g</samplingfrequency>\n<signals>%d</signals>\n<description>",
            freq, nsig)
  }
  if (vflag) {
    cout(tnfmt)
    for (k in seq_len(nsig)) {
      p <- si[[sig[k] + 1]]$desc
      if (grepl(", signal ", p, fixed = TRUE, useBytes = TRUE)) p <- .f("sig %d", sig[k])
      if (cflag == 0) {
        pb <- charToRaw(p)
        ln <- length(pb)
        lim <- if (pflag > 1) 15L else 7L
        if (ln > lim) p <- rawToChar(pb[(ln - lim + 1L):ln])
      } else {
        p <- .rdsamp_escapify(p)
      }
      cprintf(snfmt, p)
    }
    if (xflag) cout("</description>")
    cout("\n")
  }
  if (pflag) {
    if (vflag) {
      if (xflag) cout("<units>")
      cout(tufmt)
      for (k in seq_len(nsig)) {
        p <- si[[sig[k] + 1]]$units
        if (is.null(p))     # wfdb-x: unspecified units shown as "nd" (C, legacy mode: mV)
          p <- if (legacy) "mV" else "nd"
        if (cflag == 0) {
          ln <- min(nchar(p, type = "bytes"), if (pflag > 1) 13L else 5L)
          ustring <- paste0("(", .btrunc(p, ln))
          cprintf(if (pflag > 1) "\t%14s)" else "\t%6s)", ustring)
        } else {
          cprintf(",'%s'", .rdsamp_escapify(p))
        }
      }
      if (xflag) cout("</units>")
      cout("\n")
    }
    if (xflag) cout("<samplevectors>\n")
    base <- vapply(si[sig + 1], function(x) x$baseline, 0)
    gain <- vapply(si[sig + 1], function(x) x$gain, 0)
    tsf <- 0
    if (timeunits %in% c(TIMSTR, SHORTTIMSTR, MSTIMSTR, HHMMSS)) {
      tsf <- timeunits
    } else if (cflag == 0) {
      tfmt <- if (timeunits == SAMPLES) "%15d" else if (timeunits == MINUTES) "%15.5f" else
        if (timeunits == HOURS) "%15.7f" else "%15.3f"
    } else {
      tfmt <- if (timeunits == SAMPLES) "%d" else if (timeunits == MINUTES) "%.5f" else
        if (timeunits == HOURS) "%.7f" else "%.3f"
    }
    tf <- .tfreq()
    while (to == 0 || from < to) {
      k <- if (to == 0) CHUNK else min(CHUNK, to - from)
      arr <- getframes(k)$v
      m <- nrow(arr)
      if (m) {
        tv <- from + seq_len(m) - 1
        if (tsf == 0) {
          tcol <- csprintf_v(tfmt, if (timeunits == SAMPLES) tv else tv / freq)
        } else {
          if (tsf == TIMSTR) {
            tcol <- .ftimstr_v(-tv, tf)
          } else if (tsf == HHMMSS) {
            tcol <- .fmstimstr_v(tv, tf)
            tcol[tv == 0] <- "0:00.000"
          } else {
            tcol <- .fmstimstr_v(-tv, tf)
          }
          if (cflag) {
            tcol <- paste0("'", sub("^ +", "", tcol), "'")
          } else if (tsf == HHMMSS) {
            tcol <- sprintf("%15s", tcol)      # (ASCII)
          }
        }
        cols <- vector("list", nsig)
        for (j in seq_len(nsig)) {
          x <- arr[, sig[j] + 1]
          cj <- csprintf_v(vfmt, (x - base[j]) / gain[j])
          inv <- x == WFDB_INVALID_SAMPLE
          if (any(inv)) cj[inv] <- invalid
          cols[[j]] <- cj
        }
        cout(paste0(do.call(paste0, c(list(tcol), cols, list("\n"))), collapse = ""))
        from <- from + m
      }
      if (m < k) break
    }
  } else {
    if (xflag) cout("<samplevectors>\n")
    lfmt <- paste0(tfmt, strrep(vfmt, nsig), "\n")
    while (to == 0 || from < to) {
      k <- if (to == 0) CHUNK else min(CHUNK, to - from)
      arr <- getframes(k)$v
      m <- nrow(arr)
      if (m) {
        args <- c(list(lfmt, from + seq_len(m) - 1),
                  lapply(sig, function(s) arr[, s + 1]))
        cout(paste0(do.call(csprintf_v, args), collapse = ""))
        from <- from + m
      }
      if (m < k) break
    }
  }
  if (xflag) cout("</samplevectors>\n</wfdbsampleset>\n")
  wfdbquit()
  0
}
