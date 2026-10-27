# apps_wrsamp.R: wrsamp -- read a text file of samples and write WFDB
# signal (and header) files.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of app/wrsamp.c from the WFDB Software Package 10.7.0,
# by George B. Moody. The translation follows the logic and behavior of the
# original program, but it is new code, not the original C code.
#
# Changes from the original: no built-in sampling frequency, gain, ADC
# resolution or units: when a record is written (-o), -F, -G and the new option
# -R BITS are required, and the new option -U UNITS for calibrated signals
# unless the input gives the units (the original assumed 250 Hz, 200 adu/mV, a
# resolution based on the format, and millivolts); -G 0 declares the signals
# uncalibrated; -G, -R and -U take one value per signal; --legacy, as the first
# argument, restores the original behavior. Each change is marked "wfdb-x:" in
# the code; docs/DIVERGENCES.md gives the reasons.
#
# Original C program: app/wrsamp.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1993-2014 George B. Moody; revised 2020 by Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The samples are collected in blocks and written with putframes() (the
# same output as one putvec() call per input line).

app_wrsamp <- function(args = character(0)) {
  app_run(.wrsamp_main, c("wrsamp", args))
}

.wrsamp_help <- function(pname) {
  h <- c(
    "where COLUMN selects a field to be copied (leftmost field is column 0),",
    "and OPTIONS may include:",
    " -c          check that each input line contains the same number of fields",
    " -d          add dither to the input",
    " -f N        start copying with line N (default: 0)",
    " -F FREQ     specify frequency to be written to header file (required",
    "              with -o)",
    " -G GAIN     specify gain(s) to be written to header file (required with",
    "              -o; 0 means uncalibrated)",
    " -h          print this usage summary",
    " -i FILE     read input from FILE (default: standard input)",
    " -o RECORD   save output in RECORD.dat, and generate a header file for",
    "              RECORD (default: write to standard output in format 16, do",
    "              not generate a header file)",
    " -O FORMAT   save output in the specified FORMAT (default: 16)",
    " -r RSEP     interpret RSEP as the input line separator (default: linefeed)",
    " -R BITS     specify ADC resolution(s) in bits (required with -o)",
    " -s FSEP     interpret any character in FSEP as an input field separator",
    "             (default: space, tab, carriage-return, or comma)  ",
    " -t N        stop copying at line N (default: end of input file)",
    " -U UNITS    specify units (required with -o for calibrated signals, unless",
    "              the input gives them)",
    " -x SCALE    multiply inputs by SCALE factor(s) (default: 1)",
    " -z          don't copy column 0 unless explicitly specified",
    "",
    "The input is a text file with a sample of each signal on each line. Samples",
    "can be separated by tabs, spaces, commas, or any combination of these.",
    "Consecutive separators are equivalent to single separators.",
    "",
    "To specify different GAIN or SCALE values for each output signal, provide",
    "a quoted list of values, e.g., -G \"100 50\" defines the gain for signal 0",
    "as 100, and the gain for signal 1 (and any additional signals) as 50.",
    "",
    "If the first input line contains any alphabetic characters, it is assumed",
    "to contain column headings, which are copied as signal descriptions into",
    "RECORD.hea.  If the second input line also contains alphabetic characters,",
    "it is assumed to specify the physical units for each column, which are",
    "copied as units strings into RECORD.hea.  The first line containing samples",
    "is line 0.",
    "",
    "If no COLUMN is specified, all fields are copied in order; column 0 can be",
    "omitted in this case by using the '-z' option.")
  if (wfdbx_get_legacy())          # wfdb-x: legacy mode (the original help)
    h <- c(h[1:5],
           " -F FREQ     specify frequency to be written to header file (default: 250)",
           " -G GAIN     specify gain(s) to be written to header file (default: 200)",
           h[10:16], h[18:20], h[23:length(h)])
  ceprintf("usage: %s [OPTIONS ...] [COLUMN ...]\n", pname)
  for (i in seq_along(h)) {
    ceprintf("%s\n", h[i])
    if (i %% 23 == 0) {
      cerr("--More--")
      stdin_bytes()
      cerr("\033[A\033[2K")
    }
  }
}

# The lines of the input (delimited by the byte rsep; an unterminated last
# line is lost), as character strings (up to a NUL, as C strings).
.wrsamp_lines <- function(data, rsep) {
  ends <- which(data == rsep)
  if (!length(ends)) return(character(0))
  starts <- c(1L, ends[-length(ends)] + 1L)
  if (!any(data == as.raw(0L)) && (!l10n_info()$MBCS || !any(data >= as.raw(128L)))) {
    txt <- rawToChar(data[seq_len(ends[length(ends)])])
    return(substring(txt, starts, ends - 1L))
  }
  vapply(seq_along(ends), function(k) {
    if (ends[k] > starts[k]) cstr(data[starts[k]:(ends[k] - 1L)]) else ""
  }, "")
}

.wrsamp_has_alpha <- function(line) {
  if (is.null(line)) return(0)
  b <- .b(line)
  n <- length(b)
  p <- 1L
  while (p <= n) {
    c <- b[p]
    if (c == 101L || c == 69L) {            # 'e', 'E'
      p <- p + 1L
      nc <- if (p <= n) b[p] else 0L
      if (nc <= 57L || nc == 45L || nc == 43L) {
        p <- p + 1L
        next
      }
      c <- nc
    }
    if ((c >= 65L && c <= 90L) || (c >= 97L && c <= 122L)) return(1)
    p <- p + 1L
  }
  0
}

# parseline() of wrsamp.c: the tokens of a line.
.wrsamp_parseline <- function(line, delim) {
  b <- .b(line)
  dl <- .b(delim)
  if (!any(b %in% c(34L, 39L, 60L, 92L))) {
    # no quotes or escapes: split at runs of delimiters
    isd <- b %in% dl
    if (!length(b) || all(isd)) return(character(0))
    st <- which(!isd & c(TRUE, isd[-length(isd)]))
    en <- which(!isd & c(isd[-1L], TRUE))
    return(substring(line, st, en))
  }
  tokens <- character(0)
  n <- length(b)
  p <- 1L
  while (p <= n) {
    while (p <= n && b[p] %in% dl) p <- p + 1L
    if (p > n) break
    q <- 0L
    c <- b[p]
    if (c == 34L || c == 39L) {
      q <- c
      p <- p + 1L
    } else if (c == 60L) {
      p <- p + 1L
      q <- 62L
    }
    buf <- integer(0)
    while (p <= n && (q != 0L || !(b[p] %in% dl))) {
      c <- b[p]
      if (c == 92L) {
        if (p + 1L > n) break
        buf <- c(buf, b[p + 1L])
        p <- p + 2L
        next
      }
      if (c == q) {
        p <- p + 1L
        q <- 0L
        break
      }
      buf <- c(buf, c)
      p <- p + 1L
    }
    tokens <- c(tokens, .bs(buf))
  }
  tokens
}

# wfdb-x: legacy mode (original behavior): the ADC resolution inferred from
# the format.
.wrsamp_adcres <- function(fmt) {
  if (fmt %in% c(508, 80)) return(8)
  if (fmt %in% c(310, 311)) return(10)
  if (fmt == 212) return(12)
  if (fmt %in% c(516, 16, 160, 61)) return(16)
  if (fmt %in% c(524, 24)) return(24)
  if (fmt == 32) return(32)
  if (fmt > 100 && fmt %% 100 > 0 && fmt %% 100 <= 32) return(fmt %% 100)
  WFDB_DEFRES
}

# bytes i..j of b as a string ("" if j < i)
.bsl <- function(b, i, j) if (j >= i) rawToChar(b[i:j]) else ""

.lstrip_sp <- function(s) sub("^ +", "", s, useBytes = TRUE)

# The samples of the data lines L (a matrix, one row per line): the
# columns fv of each line, read with sscanf("%lf"), multiplied by scalef,
# dithered (rng, if not NULL: two glibc rand() values per sample, in the
# order of the C program) and rounded; invalid samples where a column is
# missing or not a number.
.wrsamp_values <- function(L, delim, fv, scalef, rng) {
  n <- length(L)
  nosig <- length(fv)
  out <- matrix(WFDB_INVALID_SAMPLE, n, nosig)
  if (nosig == 0L || n == 0L) return(out)
  # (lines without quotes or escapes: split at runs of delimiters)
  special <- grepl("\"", L, fixed = TRUE) | grepl("'", L, fixed = TRUE) |
    grepl("<", L, fixed = TRUE) | grepl("\\", L, fixed = TRUE)
  db <- .b(delim)
  d1 <- rawToChar(as.raw(db[1L]))
  sp <- strsplit(chartr(delim, strrep(d1, length(db)), L), d1, fixed = TRUE, useBytes = TRUE)
  if (any(special)) sp[special] <- lapply(L[special], .wrsamp_parseline, delim = delim)
  lens <- lengths(sp)
  tok <- unlist(sp, use.names = FALSE)
  lid <- rep.int(seq_len(n), lens)
  keep <- nzchar(tok) | rep(special, lens)
  tok <- tok[keep]
  lid <- lid[keep]
  cnt <- tabulate(lid, nbins = n)
  start <- c(0L, cumsum(cnt))[seq_len(n)]
  vals <- matrix(NA_real_, n, nosig)
  for (k in seq_len(nosig)) {
    has <- cnt > fv[k]
    if (any(has)) vals[has, k] <- .strtod_v(tok[start[has] + fv[k] + 1])
  }
  x <- vals * rep(scalef, each = n)
  ok <- !is.na(vals) | is.nan(vals)
  if (!is.null(rng)) {
    # (row-major order)
    okt <- t(ok)
    m <- sum(okt)
    if (m > 0) {
      r <- glibc_rand(rng, 2 * m)
      dith <- (r[seq(1, by = 2, length.out = m)] + r[seq(2, by = 2, length.out = m)]) /
        RAND_MAX - 1
      xt <- t(x)
      xt[okt] <- xt[okt] + dith
      x <- t(xt)
    }
  }
  pos <- !is.na(x) & x >= 0
  out[ok] <- ifelse(pos[ok], d2i(x[ok] + 0.5), d2i(x[ok] - 0.5))
  out
}

# Vectorized sscanf(s, "%lf"): the values (NA where no conversion).
.strtod_v <- function(s) {
  v <- rep(NA_real_, length(s))
  simple <- grepl("^[ \t\n\v\f\r]*[+-]?([0-9]+[.]?[0-9]*|[.][0-9]+)$", s, useBytes = TRUE)
  if (any(simple)) {
    x <- sub("^[ \t\n\v\f\r]+", "", s[simple], useBytes = TRUE)
    neg <- startsWith(x, "-")
    body <- sub("^[+-]", "", x, useBytes = TRUE)
    dot <- regexpr(".", body, fixed = TRUE, useBytes = TRUE)
    nfrac <- ifelse(dot > 0, nchar(body, type = "bytes") - dot, 0L)
    digits <- sub(".", "", body, fixed = TRUE, useBytes = TRUE)
    sig <- sub("^0+", "", digits, useBytes = TRUE)
    fast <- nchar(sig, type = "bytes") <= 15L & nfrac <= 22L
    r <- rep(NA_real_, length(x))
    if (any(fast)) {
      m <- as.numeric(ifelse(nzchar(sig[fast]), sig[fast], "0"))
      r[fast] <- m / 10^nfrac[fast]
      r[fast & neg] <- -r[fast & neg]
    }
    if (any(!fast)) r[!fast] <- vapply(x[!fast], function(t) .scan_lf(t) %||% NA_real_, 0)
    v[simple] <- r
  }
  if (any(!simple)) {
    v[!simple] <- vapply(s[!simple], function(t) {
      r <- .scan_lf(t)
      if (is.null(r)) NA_real_ else r
    }, 0, USE.NAMES = FALSE)
  }
  v
}

# sscanf(s, "%lf") == 1: the value, or NULL.
.scan_lf <- function(s) {
  b <- cbytes(s)
  r <- strtod(b)
  if (r[2L] == 1) NULL else r[1L]
}

.wrsamp_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  arg <- function(i) argv[i + 1L]
  gain <- ""
  res <- ""                       # wfdb-x: -R
  uopt <- NULL                    # wfdb-x: -U
  scale <- ""
  record <- NULL
  rsep <- as.raw(10L)
  sflag <- 0
  xflag <- 0; zflag <- 0; dflag <- 0
  legacy <- wfdbx_get_legacy()
  # wfdb-x: no default frequency (legacy mode: that of the C program)
  freq <- if (legacy) WFDB_DEFFREQ else 0
  fmt <- 16
  t0 <- 0; t1 <- 0
  delim <- " \t\r\n,"
  rng <- NULL
  infile <- NULL
  i <- 1
  while (i < argc && startsWith(arg(i), "-")) {
    a <- charToRaw(arg(i))
    c <- if (length(a) >= 2L) rawToChar(a[2L]) else ""
    if (c == "c") {
    } else if (c == "d") {
      dflag <- 1
      rng <- glibc_rand_new(0)
    } else if (c == "f") {
      i <- i + 1
      if (i < argc) t0 <- strtol(arg(i))[1L]
      if (i >= argc || t0 <= 0) {
        ceprintf("%s: starting line # must follow -f\n", pname)
        cexit(1)
      }
    } else if (c == "F") {
      i <- i + 1
      if (i < argc) freq <- atof(arg(i))
      if (i >= argc || freq <= 0) {
        ceprintf("%s: sampling frequency must follow -F\n", pname)
        cexit(1)
      }
    } else if (c == "G") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: gain(s) must follow -G\n", pname)
        cexit(1)
      }
      gain <- arg(i)
    } else if (c == "h") {
      .wrsamp_help(pname)
      cexit(1)
    } else if (c == "R" && !legacy) {     # wfdb-x: ADC resolution(s) in bits
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: ADC resolution(s) must follow -R\n", pname)
        cexit(1)
      }
      res <- arg(i)
    } else if (c == "U" && !legacy) {     # wfdb-x: units
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: units must follow -U\n", pname)
        cexit(1)
      }
      uopt <- arg(i)
    } else if (c == "i") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: input file name must follow -i\n", pname)
        cexit(1)
      }
      if (arg(i) == "-") {
        infile <- NULL
      } else {
        fn <- arg(i)
        infile <- if (file.exists(fn) && !dir.exists(fn))
          tryCatch(readBin(fn, "raw", file.size(fn)), error = function(e) NULL) else NULL
        if (is.null(infile)) {
          ceprintf("%s: can't read `%s'\n", pname, fn)
          cexit(2)
        }
      }
    } else if (c == "l") {
      i <- i + 1
      if (i >= argc) i <- i - 1
      ceprintf("%s: -l is obsolete, ignored\n", pname)
    } else if (c == "o") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: record name must follow -o\n", pname)
        cexit(1)
      }
      record <- arg(i)
    } else if (c == "O") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: output format must follow -O\n", pname)
        cexit(1)
      }
      fmt <- atoi(arg(i))
    } else if (c == "r") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: line separator must follow -r\n", pname)
        cexit(1)
      }
      rb <- charToRaw(arg(i))
      rsep <- if (length(rb)) rb[1L] else as.raw(0L)
    } else if (c == "s") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: field separator(s) must follow -s\n", pname)
        cexit(1)
      }
      sflag <- 1
      delim <- arg(i)
    } else if (c == "t") {
      i <- i + 1
      if (i < argc) t1 <- strtol(arg(i))[1L]
      if (i >= argc || t1 <= 0) {
        ceprintf("%s: ending line # must follow -t\n", pname)
        cexit(1)
      }
    } else if (c == "x") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: scaling factor(s) must follow -x\n", pname)
        cexit(1)
      }
      scale <- arg(i)
    } else if (c == "z") {
      zflag <- 1
    } else {
      ceprintf("%s: unrecognized option %s\n", pname, arg(i))
      cexit(1)
    }
    i <- i + 1
  }
  # wfdb-x: the sampling frequency, the gains, the ADC resolutions, and the
  # units (of calibrated signals) must be specified when a header is written
  # (the C program assumed 250 Hz, 200 adu/mV, a resolution based on the
  # format, and millivolts), as legacy mode does.
  check <- !is.null(record) && !legacy
  if (check && freq <= 0) {
    ceprintf("%s: the sampling frequency must be specified (-F)\n", pname)
    cexit(1)
  }
  if (check && !nzchar(gain)) {
    ceprintf("%s: the gain(s) must be specified (-G)\n", pname)
    cexit(1)
  }
  if (check && !nzchar(res)) {
    ceprintf("%s: the ADC resolution(s) must be specified (-R)\n", pname)
    cexit(1)
  }
  nosig <- argc - i
  if (is.null(infile)) infile <- stdin_bytes()
  lines <- .wrsamp_lines(infile, rsep)
  nlines <- length(lines)
  li <- 0L
  read_line <- function() {
    if (li >= nlines) {
      li <<- nlines + 1L
      return(NULL)
    }
    li <<- li + 1L
    lines[li]
  }
  line <- read_line()
  if (is.null(line)) {
    if (rsep != as.raw(10L)) {
      if (is.null(record)) {
        ceprintf("%s: use -o to specify the output record name", pname)
      } else {
        ceprintf("%s: no record separators in input\nTry specifying a different separator after the -r option.\n",
                 pname)
      }
    } else {
      ceprintf("%s: no newlines in input\n", pname)
    }
    cexit(3)
  }
  dstrings <- NULL
  ustrings <- NULL
  ncols <- 0
  if (startsWith(line, "<?xml ")) {
    xflag <- zflag <- 1
    repeat {
      line <- read_line()
      if (is.null(line)) {
        ceprintf("%s: XML input, but no <wfdbsampleset> found\n", pname)
        cexit(1)
      }
      if (line == "<wfdbsampleset>") break
    }
    repeat {
      line <- read_line()
      if (is.null(line)) {
        ceprintf("%s: empty <wfdbsampleset>\n", pname)
        cexit(1)
      }
      lb <- charToRaw(line)
      nl <- length(lb)
      if (startsWith(line, "<samplingfrequency>")) {
        v <- .scan_lf(lb[seq_len(nl) > 19L])
        if (!is.null(v)) freq <- v
      } else if (startsWith(line, "<description>")) {
        ta <- .wrsamp_parseline(.bsl(lb, 14L, nl - 14L), delim)
        dstrings <- ta
        ncols <- length(ta)
      } else if (startsWith(line, "<units>")) {
        ta <- .wrsamp_parseline(.bsl(lb, 8L, nl - 8L), delim)
        ustrings <- ta
      }
      if (line == "<samplevectors>") break
    }
    line <- read_line()
    if (is.null(line)) {
      ceprintf("%s: empty <wfdbsampleset>\n", pname)
      cexit(1)
    }
  } else {
    if (sflag == 0 && grepl("\t", line, fixed = TRUE, useBytes = TRUE)) delim <- "\t"
    ta <- .wrsamp_parseline(line, delim)
    ncols <- length(ta)
    if (.wrsamp_has_alpha(line)) {
      dstrings <- .lstrip_sp(ta)
      line <- read_line()
      if (is.null(line)) {
        ceprintf("%s: no data\n", pname)
        cexit(1)
      } else if (.wrsamp_has_alpha(line)) {
        ta <- .wrsamp_parseline(line, delim)
        ustrings <- vapply(ta, function(t) {
          t <- .lstrip_sp(t)
          tb <- charToRaw(t)
          if (length(tb) && tb[1L] == as.raw(40L)) {
            last <- tb[length(tb)]
            tb <- tb[-1L]
            if (last == as.raw(41L)) tb <- tb[-length(tb)]
            t <- rawToChar(tb)
          }
          t
        }, "", USE.NAMES = FALSE)
        line <- read_line()
        if (is.null(line)) {
          ceprintf("%s: no data\n", pname)
          cexit(1)
        }
      }
    }
  }
  if (nosig) {
    fv <- numeric(nosig)
    for (k in seq_len(nosig)) {
      a <- argv[argc - nosig + k]
      r <- csscanf(a, "%d")
      if (r$n != 1 || cint32(r$v[[1L]]) < 0 || cint32(r$v[[1L]]) >= ncols) {
        ceprintf("%s: unrecognized argument %s\n", pname, a)
        cexit(1)
      }
      fv[k] <- cint32(r$v[[1L]])
    }
  } else {
    nosig <- ncols - zflag
    fv <- zflag + seq_len(max(nosig, 0)) - 1
  }
  ofname <- if (is.null(record)) "-" else paste0(record, ".dat")
  si <- vector("list", max(nosig, 0))
  scalef <- numeric(max(nosig, 0))
  gs <- charToRaw(gain)
  xs <- charToRaw(scale)
  rs <- charToRaw(res)
  us <- if (!is.null(uopt)) charToRaw(uopt) else NULL
  lstrip_b <- function(b) {
    k <- 1L
    while (k <= length(b) && b[k] == as.raw(32L)) k <- k + 1L
    b[seq_along(b) >= k]
  }
  skip_word <- function(b) {
    j <- 1L
    while (j <= length(b) && b[j] != as.raw(32L)) j <- j + 1L
    b[seq_along(b) >= j]
  }
  for (k in seq_len(max(nosig, 0))) {
    s <- siginfo(fname = ofname)
    f <- fv[k]
    if (!is.null(dstrings)) {
      s["desc"] <- list(if (f < length(dstrings)) dstrings[f + 1] else "")
    } else {
      s["desc"] <- list(.f("col %d", f))
    }
    if (!is.null(us)) {
      # wfdb-x: -U (the last one applies to the rest)
      us <- lstrip_b(us)
      if (length(us)) {
        w <- skip_word(us)
        s["units"] <- list(rawToChar(us[seq_len(length(us) - length(w))]))
        us <- w
      } else {
        s["units"] <- list(if (k == 1) "" else si[[k - 1]]$units)
      }
    } else if (!is.null(ustrings)) {
      s["units"] <- list(if (f < length(ustrings)) ustrings[f + 1] else "")
    } else {
      s["units"] <- list("")
    }
    s$group <- 0
    s$fmt <- fmt
    s$spf <- 1
    s$bsize <- 0
    # wfdb-x: the ADC resolutions are given by -R (the last one applies to
    # the remaining signals); the C program inferred them from the format or
    # assumed WFDB_DEFRES, as legacy mode does.
    if (legacy) {
      s$adcres <- .wrsamp_adcres(fmt)
    } else {
      rs <- lstrip_b(rs)
      r <- csscanf(as.integer(rs), "%d")
      if (r$n < 1L) {
        s$adcres <- if (k == 1) 0 else si[[k - 1]]$adcres
      } else {
        s$adcres <- cint32(r$v[[1L]])
        rs <- skip_word(rs)
      }
      if (!is.null(record) && s$adcres < 1) {
        ceprintf("%s: the ADC resolution(s) must be specified (-R)\n", pname)
        cexit(1)
      }
    }
    s$adczero <- 0
    s$baseline <- 0
    gs <- lstrip_b(gs)
    v <- .scan_lf(gs)
    if (is.null(v)) {
      # (wfdb-x: the C program, and legacy mode: WFDB_DEFGAIN)
      s$gain <- if (k > 1) si[[k - 1]]$gain else if (legacy) WFDB_DEFGAIN else 0
    } else {
      s$gain <- v
      gs <- skip_word(gs)
    }
    # wfdb-x: the units of a calibrated signal must be specified, by -U or by
    # the input (the C program left them out: millivolts).
    if (check && s$gain != 0 && !nzchar(s$units)) {
      ceprintf("%s: the units must be specified (-U)\n", pname)
      cexit(1)
    }
    xs <- lstrip_b(xs)
    v <- .scan_lf(xs)
    if (is.null(v)) {
      scalef[k] <- if (k == 1) 1 else scalef[k - 1]
    } else {
      scalef[k] <- v
      xs <- skip_word(xs)
    }
    si[[k]] <- s
  }
  while (.wrsamp_has_alpha(line)) line <- read_line()
  if (osigfopen(si, nosig) < nosig || setsampfreq(freq) < 0) cexit(2)
  t <- 0
  while (t < t0) {
    line <- read_line()
    t <- t + 1
  }
  if (zflag && !is.null(line)) {
    lb <- charToRaw(line)
    if (length(lb) && lb[1L] == as.raw(91L)) {
      setbasetime(rawToChar(lb[seq_len(min(length(lb), 24L))][-1L]))
    } else if (length(lb) >= 2L && lb[2L] == as.raw(91L)) {
      setbasetime(rawToChar(lb[seq_len(min(length(lb), 25L))][-(1:2)]))
    }
  }
  # The data lines (from the current one): up to the line before
  # "</samplevectors>" (XML input), at most t1 - t lines with -t.
  if (!is.null(line)) {
    first <- li
    last <- nlines
    xmlend <- 0L
    if (xflag && first < nlines) {
      j <- which(startsWith(lines[(first + 1L):nlines], "</samplevectors>"))
      if (length(j)) {
        xmlend <- first + j[1L]
        last <- xmlend - 1L
      }
    }
    if (t1 != 0) {
      m <- max(t1 - t, 0)
      if (last - first + 1 > m) {
        last <- first + m - 1
        xmlend <- 0L
      }
    }
    if (last >= first) {
      vout <- .wrsamp_values(lines[first:last], delim, fv[seq_len(max(nosig, 0))],
                             scalef, rng)
      CH <- 1048576L                     # (frames written per putframes call)
      for (r0 in seq(1L, nrow(vout), by = CH)) {
        if (putframes(vout[r0:min(nrow(vout), r0 + CH - 1L), , drop = FALSE]) < 0) break
      }
    }
    if (xmlend > 0L && xmlend < nlines && lines[xmlend + 1L] != "</wfdbsampleset>")
      ceprintf("%s: (warning) unexpected EOF in XML input\n", pname)
  }
  setsampfreq(freq)
  if (!is.null(record)) newheader(record)
  wfdbquit()
  0
}
