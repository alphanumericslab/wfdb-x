# apps_rdsamp.R: rdsamp -- print an arbitrary number of samples from each
# signal.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/rdsamp.c from the WFDB Software Package 10.7.0,
# by George B. Moody. The translation follows the logic and behavior of the
# original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency or gain: the
# sampling frequency is required for time arguments, time columns and XML
# output (-X), and the gain of each selected signal for physical units (-p, -P)
# (the original assumed 250 Hz and 200 adu/mV); unspecified units are shown as
# "nd" (the original showed "mV"); --legacy, as the first argument, restores
# the original behavior. Each change is marked "WFDB-x:" in the code;
# docs/DIVERGENCES.md gives the reasons.
#
# Original C program: app/rdsamp.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1983-2010 George B. Moody; revised 2017-2020 by
#   Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The samples are read in blocks with getframes() and formatted with
# vectorized C formatting (csprintf_v), one block at a time, through tables
# of the formatted values (.rdsamp_formatter); each block is written at
# once.

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

# The formatted values of a column of a block of lines: the strings tab
# (one per line if i is NULL, else a table indexed by i), and raw, the
# table as a raw matrix (.rdsamp_fixed), if it has been made.
.rdsamp_col <- function(tab, i = NULL, raw = NULL) list(tab = tab, i = i, raw = raw)

# The strings s as a raw matrix, one column per string, the shorter ones
# padded with NUL bytes (which the strings do not contain; attribute pad:
# TRUE if there are any).
.rdsamp_fixed <- function(s) {
  w <- nchar(s, type = "bytes")
  r <- charToRaw(paste0(s, collapse = ""))
  wmax <- max(w, 0L)
  pad <- any(w != wmax)
  if (pad) {
    p <- raw(wmax * length(s))
    p[rep(seq_along(s) - 1L, w) * wmax + sequence(w)] <- r
    r <- p
  }
  dim(r) <- c(wmax, length(s))
  attr(r, "pad") <- pad
  r
}

# The bytes of a block of lines, made of the columns cols (.rdsamp_col)
# and a newline (.rdsamp_put writes them at once).
.rdsamp_put <- function(cols) cout(.rdsamp_lines(cols))

.rdsamp_lines <- function(cols) {
  pad <- FALSE
  rw <- lapply(cols, function(cl) {
    r <- if (is.null(cl$i)) .rdsamp_fixed(cl$tab) else cl$raw
    if (attr(r, "pad")) pad <<- TRUE
    if (is.null(cl$i)) r else r[, cl$i, drop = FALSE]
  })
  rw[[length(rw) + 1L]] <- matrix(as.raw(10L), 1L, ncol(rw[[1L]]))
  b <- as.vector(do.call(rbind, rw))
  if (pad) b[b != as.raw(0L)] else b
}

# A function that formats the samples x of a column (.rdsamp_col) as f(x)
# does (f: a vectorized function of the sample values giving a character
# vector), with the string `invalid` for invalid samples.  It formats
# through a table of f over the range of the valid samples, kept between
# calls and extended as needed, if that range is not larger than the
# number of samples (and formats x directly otherwise).
.rdsamp_formatter <- function(f, invalid) {
  lo <- 0
  tab <- character(0)
  raw <- NULL
  function(x) {
    inv <- x == WFDB_INVALID_SAMPLE
    if (!any(inv)) inv <- NULL
    xv <- if (is.null(inv)) x else x[!inv]
    if (!length(xv)) return(.rdsamp_col(rep(invalid, length(x))))
    r <- range(xv)
    hi <- lo + length(tab) - 1
    if (r[1L] < lo || r[2L] > hi) {
      nlo <- if (length(tab)) min(r[1L], lo) else r[1L]
      nhi <- if (length(tab)) max(r[2L], hi) else r[2L]
      if (nhi - nlo >= max(length(x), 4096)) {
        out <- f(x)
        if (!is.null(inv)) out[inv] <- invalid
        return(.rdsamp_col(out))
      }
      lo <<- nlo
      # (the table, and the invalid string after it)
      tab <<- f(nlo:nhi)
      raw <<- .rdsamp_fixed(c(tab, invalid))
    }
    i <- x - lo + 1
    if (!is.null(inv)) i[inv] <- length(tab) + 1
    .rdsamp_col(c(tab, invalid), i, raw)
  }
}

# The sample numbers tv (consecutive, increasing, >= 0) formatted as C's
# printf does with fmt ("%15d" or "%d"): two columns (.rdsamp_col), the
# thousands and the last three digits.
.RDSAMP_DIGITS3 <- sprintf("%03d", 0:999)
.RDSAMP_SPACES <- strrep(" ", 0:15)     # (0 to 15 spaces)
.RDSAMP_DIGITS3_RAW <- .rdsamp_fixed(.RDSAMP_DIGITS3)

.rdsamp_samplenum <- function(tv, fmt) {
  q <- tv %/% 1000
  qlo <- q[1L]
  qfmt <- if (fmt == "%15d") "%12d" else "%d"
  if (qlo > 0) {
    qs <- csprintf_v(qfmt, qlo:q[length(q)])
    return(list(.rdsamp_col(qs, q - qlo + 1, .rdsamp_fixed(qs)),
                .rdsamp_col(.RDSAMP_DIGITS3, tv - 1000 * q + 1, .RDSAMP_DIGITS3_RAW)))
  }
  # (numbers below 1000: formatted whole)
  small <- q == 0
  lead <- csprintf_v(qfmt, 0:q[length(q)])[q + 1]
  lead[small] <- csprintf_v(fmt, tv[small])
  low <- .RDSAMP_DIGITS3[tv - 1000 * q + 1]
  low[small] <- ""
  list(.rdsamp_col(lead), .rdsamp_col(low))
}

# The times x formatted as C's printf does with fmt ("%15.Df" or "%.Df",
# D decimals): columns (.rdsamp_col) of the integer part, the point and
# the decimals.  x rounded to D decimals is computed in double arithmetic,
# exact except near a tie (half a unit of the last decimal): blocks with
# such a time (or negative, or large) are formatted by csprintf_v.
.rdsamp_fixedpoint <- function(x, fmt) {
  d <- as.numeric(sub(".*\\.([0-9])f$", "\\1", fmt))
  s <- 10^d
  y <- x * s
  if (!isTRUE(all(y >= 0 & y < 2^50)) ||      # (or nan)
      any(abs(y - floor(y) - 0.5) <= 1e-12 * pmax(y, 1)))
    return(list(.rdsamp_col(csprintf_v(fmt, x))))
  n <- floor(y + 0.5)
  ip <- n %/% s
  fr <- n - ip * s
  lo <- ip[1L]
  ips <- csprintf_v(if (startsWith(fmt, "%15")) sprintf("%%%dd", 14 - d) else "%d",
                    lo:ip[length(ip)])
  cols <- list(.rdsamp_col(ips, ip - lo + 1, .rdsamp_fixed(ips)),
               .rdsamp_col(".", rep(1, length(x)), .rdsamp_fixed(".")))
  if (d > 3) {
    # (the decimals before the last three)
    hs <- sprintf(sprintf("%%0%dd", d - 3), seq_len(10^(d - 3)) - 1)
    h <- fr %/% 1000
    cols[[3L]] <- .rdsamp_col(hs, h + 1, .rdsamp_fixed(hs))
    fr <- fr - h * 1000
  }
  c(cols, list(.rdsamp_col(.RDSAMP_DIGITS3, fr + 1, .RDSAMP_DIGITS3_RAW)))
}

# The time columns (.rdsamp_col) of the pieces p of time strings
# (.fmstimstr_v0), quoted without their leading spaces if cflag, or
# right-aligned in 15 characters if pad15 (NULL if the pieces after the
# first one do not have a constant width).
.rdsamp_timecols <- function(p, cflag, pad15) {
  tabs <- lapply(p, function(q) q$tab)
  if (cflag) {
    tabs[[1L]] <- paste0("'", sub("^ +", "", tabs[[1L]]))
    tabs[[length(tabs) + 1L]] <- "'"
    p[[length(p) + 1L]] <- list(i = rep(1L, length(p[[1L]]$i)))
  } else if (pad15) {
    w <- vapply(tabs[-1L], function(s) {
      w <- nchar(s, type = "bytes")
      if (all(w == w[1L])) w[1L] else NA_integer_
    }, 0L)
    if (anyNA(w)) return(NULL)
    w1 <- nchar(tabs[[1L]], type = "bytes") + sum(w)
    tabs[[1L]] <- paste0(.RDSAMP_SPACES[pmax(15L - w1, 0L) + 1L], tabs[[1L]])
  }
  lapply(seq_along(tabs), function(k) .rdsamp_col(tabs[[k]], p[[k]]$i, .rdsamp_fixed(tabs[[k]])))
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
  if (legacy) {        # WFDB-x: legacy mode (original behavior): default gain
    for (k in seq_len(nsig)) if (si[[k]]$gain == 0) si[[k]]$gain <- WFDB_DEFGAIN
  }
  if (highres) setgvmode(WFDB_HIGHRES)
  freq <- sampfreq(NULL)
  # WFDB-x: no default sampling frequency (the C program assumed 250 Hz if
  # the header did not specify one).
  if (!legacy && isTRUE(freq <= 0) &&
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
  # WFDB-x: no default gain (the C program assumed 200 adu/mV for
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
    } else if (isTRUE(freq > 1)) {
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
        if (is.null(p))     # WFDB-x: unspecified units shown as "nd" (C, legacy mode: mV)
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
    fcol <- lapply(seq_len(nsig), function(j) {
      b <- base[j]
      g <- gain[j]
      .rdsamp_formatter(function(x) csprintf_v(vfmt, (x - b) / g), invalid)
    })
    while (to == 0 || from < to) {
      k <- if (to == 0) CHUNK else min(CHUNK, to - from)
      arr <- getframes(k)$v
      m <- nrow(arr)
      if (m) {
        tv <- from + seq_len(m) - 1
        if (tsf == 0) {
          tcols <- if (timeunits == SAMPLES) .rdsamp_samplenum(tv, tfmt) else
            .rdsamp_fixedpoint(tv / freq, tfmt)
        } else {
          tcols <- NULL
          if (tsf == TIMSTR) {
            tcol <- .ftimstr_v(-tv, tf)
          } else {
            # (as pieces, if possible: .rdsamp_timecols)
            r <- .fmstimstr_v0(if (tsf == HHMMSS) tv else -tv, tf,
                               pieces = tsf != HHMMSS || all(tv != 0))
            if (!is.null(r$p)) tcols <- .rdsamp_timecols(r$p, cflag, tsf == HHMMSS)
            if (is.null(tcols)) {
              tcol <- if (is.null(r$s)) do.call(paste0, lapply(r$p, function(q) q$tab[q$i])) else r$s
              if (tsf == HHMMSS) tcol[tv == 0] <- "0:00.000"
            }
          }
          if (is.null(tcols)) {
            if (cflag) {
              tcol <- paste0("'", sub("^ +", "", tcol), "'")
            } else if (tsf == HHMMSS) {
              # ("%15s")
              tcol <- paste0(.RDSAMP_SPACES[pmax(15L - nchar(tcol, type = "bytes"), 0L) + 1L], tcol)
            }
            tcols <- list(.rdsamp_col(tcol))
          }
        }
        .rdsamp_put(c(tcols,
                      lapply(seq_len(nsig), function(j) fcol[[j]](arr[, sig[j] + 1]))))
        from <- from + m
      }
      if (m < k) break
    }
  } else {
    if (xflag) cout("<samplevectors>\n")
    fcol <- lapply(seq_len(nsig), function(j)
      .rdsamp_formatter(function(x) csprintf_v(vfmt, x), csprintf_v(vfmt, WFDB_INVALID_SAMPLE)))
    while (to == 0 || from < to) {
      k <- if (to == 0) CHUNK else min(CHUNK, to - from)
      arr <- getframes(k)$v
      m <- nrow(arr)
      if (m) {
        .rdsamp_put(c(.rdsamp_samplenum(from + seq_len(m) - 1, tfmt),
                      lapply(seq_len(nsig), function(j) fcol[[j]](arr[, sig[j] + 1]))))
        from <- from + m
      }
      if (m < k) break
    }
  }
  if (xflag) cout("</samplevectors>\n</wfdbsampleset>\n")
  wfdbquit()
  0
}
