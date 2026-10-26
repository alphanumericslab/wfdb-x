# apps_xform.R: xform -- sampling frequency, amplitude, and format
# conversion for WFDB records.
#
# Copyright (C) 1983-2010 George B. Moody (original C program, app/xform.c;
# revised 2017-2020 by Benjamin Moody).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV, 12
# bits and millivolts), because a silently assumed value corrupts every result
# derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).
#
# The signals are processed in blocks of frames (getframes/putframes; with
# -M, frames read with getframe), with vector operations that reproduce the
# per-sample C loops exactly: the order of the dither values (rand()), the
# range checks (whose limits move when -c is not given), and the order of
# the progress dots and range messages on the standard error output.
# Annotations are copied with .getann_bulk/.putann_bulk.

app_xform <- function(args = character(0)) {
  app_run(.xform_main, c("xform", args))
}

.XFORM_CHUNK <- 65536      # frames processed per block
.XFORM_MCHUNK <- 4096      # frames per block with -M (read with getframe)

.xform_help <- function(pname) {
  h <- c(
    "where IREC is the name of the record to be converted, and OPTIONS may",
    " include any of:",
    " -a ANNOTATOR [ANNOTATOR ...]  copy annotations for the specified ANNOTATOR",
    "              from IREC;  two or more ANNOTATORs may follow -a",
    " -c          clip output (default: wrap around if out-of-range)",
    " -d          add dither to the input if changing sampling frequency or gain",
    " -f TIME     begin at specified time",
    " -h          print this usage summary",
    " -H          open the input record in `high resolution' mode",
    " -M          process multifrequency record without changing frequencies",
    " -n NREC     create a header file, using record name NREC and signal",
    "              descriptions from IREC",
    " -N NREC     as for -n, but copy signal descriptions from OREC",
    " -o OREC     produce output signal file(s) as specified by the header file",
    "              for record OREC",
    " -s SIGNAL [SIGNAL ...]  write only the specified signal(s)",
    " -S SCRIPT   take answers to prompts from SCRIPT (a text file)",
    " -t TIME     stop at specified time",
    " -u          adjust annotation times if needed to make them unique",
    "Unless you use `-o' to specify an *existing* header that describes the",
    "desired signal files, you will be asked for output specifications.  Use",
    "`-n' to name the record to be created.  Use `-s' to select a subset of the",
    "input signals, or to re-order them in the output file;  arguments that",
    "follow `-s' are *input* signal numbers (0,1,2,...) or names.")
  ceprintf("usage: %s -i IREC [OPTIONS ...]\n", pname)
  for (s in h) ceprintf("%s\n", s)
}

# Approximate greatest common divisor (Euclid's algorithm, modified so that
# an exact answer is not required for non-integral arguments; as in C).
.xform_gcd <- function(x, y) {
  tol <- 0.001 * min(x, y)
  repeat {
    if (x > y && x - y > tol) {
      x <- x - y
    } else if (y > x && y - x > tol) {
      y <- y - x
    } else {
      return(x)
    }
  }
}

# cnt values of DITHER (two rand() calls each, in order): triangular PDF in
# (-1, 1).
.xform_dither <- function(rng, cnt) {
  if (cnt == 0) return(numeric(0))
  r <- glibc_rand(rng, 2 * cnt)
  (r[c(TRUE, FALSE)] + r[c(FALSE, TRUE)]) / RAND_MAX - 1
}

# C rounding to int: (int)(vd + 0.5) if vd >= 0, else (int)(vd - 0.5).
.xform_round <- function(vd) {
  p <- vd >= 0
  vd[p] <- d2i(vd[p] + 0.5)
  vd[!p] <- d2i(vd[!p] - 0.5)
  vd
}

# Add dither to the elements of matrix vd selected by ok, in C order (row
# by row: frame by frame, signal by signal).
.xform_add_dither <- function(vd, ok, rng) {
  vt <- t(vd)
  idx <- which(t(ok))
  vt[idx] <- vt[idx] + .xform_dither(rng, length(idx))
  t(vt)
}

# Transform the input samples x (matrix: frames by output columns) with the
# gains and offsets of their columns, as the C loops do (without range
# checks); invalid samples stay invalid.
.xform_input <- function(x, X, dither = X$dflag) {
  INV <- WFDB_INVALID_SAMPLE
  inv <- x == INV
  nr <- nrow(x)
  if (X$gflag) {
    vd <- x * rep(X$gain, each = nr) + rep(X$deltav, each = nr)
    if (dither) vd <- .xform_add_dither(vd, !inv, X$rng)
    y <- .xform_round(vd)
  } else {
    y <- cint32(x + rep(X$deltav, each = nr))
  }
  y[inv] <- INV
  y
}

# Range checks of the values x (matrix: frames by output columns; sigof:
# the signal (1-based) of each column).  Returns list(x = the values as
# clipped, msgs = data frame (row, sig, value) of the "out of range"
# messages in C order, X with vmax and vmin updated as in C).  ok (same
# shape as x) says which values are checked: those computed from valid
# inputs (a computed value may equal WFDB_INVALID_SAMPLE, and is then
# checked as in C).
.xform_check <- function(x, sigof, X, ok = x != WFDB_INVALID_SAMPLE) {
  INV <- WFDB_INVALID_SAMPLE
  mrow <- numeric(0); mcol <- numeric(0); mval <- numeric(0)
  nr <- nrow(x)
  if (nr > 0) {
    for (k in unique(sigof)) {
      cols <- which(sigof == k)
      nc <- length(cols)
      # the samples of signal k in C order (frame by frame)
      c <- as.vector(t(x[, cols, drop = FALSE]))
      valid <- as.vector(t(ok[, cols, drop = FALSE]))
      c0 <- c                               # (the messages show the values before clipping)
      if (X$clip) {
        hi <- valid & c > X$vmax[k]
        lo <- valid & !hi & c < X$vmin[k]
        r <- which(hi | lo)
        if (!length(r)) next
        c[hi] <- X$vmax[k]
        c[lo] <- X$vmin[k]
        x[, cols] <- matrix(c, nr, nc, byrow = TRUE)
      } else {
        ch <- c
        ch[!valid] <- -Inf
        cl <- c
        cl[!valid] <- Inf
        if (!(any(ch > X$vmax[k]) || any(cl < X$vmin[k]))) next
        # each value beyond the limits becomes the new limit
        pm <- cummax(c(X$vmax[k], ch))
        pn <- cummin(c(X$vmin[k], cl))
        n <- length(c)
        hi <- ch > pm[seq_len(n)]
        lo <- !hi & cl < pn[seq_len(n)]
        r <- which(hi | lo)
        X$vmax[k] <- pm[n + 1L]
        X$vmin[k] <- pn[n + 1L]
      }
      mrow <- c(mrow, (r - 1) %/% nc + 1)
      mcol <- c(mcol, cols[(r - 1) %% nc + 1])
      mval <- c(mval, c0[r])
    }
  }
  o <- order(mrow, mcol)
  list(x = x, msgs = list(row = mrow[o], sig = sigof[mcol[o]], value = mval[o]), X = X)
}

# Write the progress dots (one per minute of input) for nframes more input
# frames and the range messages msgs (printed while processing input frame
# msgframe[j] of the block), in the order of C (a frame's dot first).
.xform_report <- function(X, nframes, msgs, msgframe) {
  P <- max(X$spm, 1)
  first <- P - X$nsm                  # first frame of the block with a dot
  dots <- if (first <= nframes) seq(first, nframes, by = P) else numeric(0)
  X$nsm <- (X$nsm + nframes) %% P
  nm <- length(msgs$row)
  if (!length(dots) && !nm) return(X)
  text <- character(length(dots) + nm)
  isdot <- c(rep(TRUE, length(dots)), rep(FALSE, nm))
  if (nm) {
    text[!isdot] <- csprintf_v("v[%d] = %d (out of range)\n", msgs$sig - 1, msgs$value)
  }
  # after every 60th dot, a newline
  nd <- length(dots)
  if (nd) {
    count <- X$nminutes + seq_len(nd)
    text[seq_len(nd)] <- ifelse(count %% 60 == 0, ".\n", ".")
    X$nminutes <- (X$nminutes + nd) %% 60
  }
  o <- order(c(dots, msgframe), !isdot)
  cerr(paste0(text[o], collapse = ""))
  X
}

.xform_main <- function(argv) {
  INV <- WFDB_INVALID_SAMPLE
  pname <- argv[1L]
  argc <- length(argv)
  arg <- function(i) argv[i + 1L]          # C argv[i]
  ch <- function(a, k) {                    # C a[k] (0-based), "" past the end
    b <- charToRaw(a)
    if (k < length(b)) rawToChar(b[k + 1L]) else ""
  }
  isopt <- function(i) ch(arg(i), 0) == "-"
  irec <- NULL; orec <- NULL; nrec <- NULL
  startp <- "0:0"
  script <- NULL
  rng <- NULL
  ofreq <- 0
  clip <- 0; dflag <- 0; fflag <- 0; gflag <- 0; Hflag <- 0; Mflag <- 0
  nosig <- 0; reopen <- 0; sflag <- 0; uflag <- 0
  use_irec_desc <- 1
  siglist_args <- numeric(0)
  from <- 0; to <- 0
  nsamp <- -1
  ainames <- character(0)
  i <- 1
  while (i < argc) {
    a <- arg(i)
    if (ch(a, 0) != "-") {
      ceprintf("%s: unrecognized argument %s\n", pname, a)
      cexit(1)
    }
    c <- ch(a, 1)
    if (c == "a") {
      # the next argument unconditionally, then those up to the next option
      j <- 0
      while ((i <- i + 1) < argc && (j == 0 || !isopt(i))) j <- j + 1
      if (j == 0) {
        ceprintf("%s: annotator(s) must follow -a\n", pname)
        cexit(1)
      }
      i <- i - j
      ainames <- c(ainames, argv[i + seq_len(j)])
      i <- i + j - 1
    } else if (c == "c") {
      clip <- 1
    } else if (c == "d") {
      dflag <- 1
      rng <- glibc_rand_new(0)              # srand(0): seed of the dither
    } else if (c == "f") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: time must follow -f\n", pname)
        cexit(1)
      }
      from <- i
    } else if (c == "h") {
      .xform_help(pname)
      cexit(0)
    } else if (c == "H") {
      Hflag <- 1
    } else if (c == "i") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: input record name must follow -i\n", pname)
        cexit(1)
      }
      irec <- arg(i)
    } else if (c == "M") {
      Mflag <- 1
    } else if (c == "n" || c == "N") {
      if (c == "N") use_irec_desc <- 0
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: new record name must follow -%s\n", pname, c)
        cexit(1)
      }
      nrec <- arg(i)
    } else if (c == "o") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: output record name must follow -o\n", pname)
        cexit(1)
      }
      orec <- arg(i)
    } else if (c == "s") {
      sflag <- 1
      j <- 0
      while ((i <- i + 1) < argc && !isopt(i)) j <- j + 1
      if (j == 0) {
        ceprintf("%s: signal list must follow -s\n", pname)
        cexit(1)
      }
      i <- i - j
      siglist_args <- c(siglist_args, i + seq_len(j) - 1)
      i <- i + j - 1
    } else if (c == "S") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: script name must follow -S\n", pname)
        cexit(1)
      }
      script <- arg(i)
    } else if (c == "t") {
      i <- i + 1
      if (i >= argc) {
        ceprintf("%s: time must follow -t\n", pname)
        cexit(1)
      }
      to <- i
    } else if (c == "u") {
      uflag <- 1
    } else {
      ceprintf("%s: unrecognized option %s\n", pname, a)
      cexit(1)
    }
    i <- i + 1
  }
  if (is.null(irec)) {
    .xform_help(pname)
    cexit(1)
  }
  if (!is.null(nrec) && !is.null(orec) && nrec == orec) {
    ceprintf("%s: arguments of -n (or -N) and -o cannot be identical\n", pname)
    cexit(1)
  }

  # The input signals, and the list of those to be written (0-based).
  nisig <- isigopen(irec, 0)$nsig
  if (nisig < 0) cexit(2)
  dfin <- list()
  dfout <- list()
  siglist <- numeric(0)
  if (nisig == 0) {
    nosig <- 0
  } else {
    r <- isigopen(irec, nisig)
    if (r$nsig != nisig) cexit(2)
    dfin <- r$si
    if (sflag) {
      for (k in siglist_args) {
        s <- arg(k)
        j <- findsig(s)
        if (j < 0) {
          ceprintf("%s: warning: record %s doesn't have a signal '%s'\n", pname, irec, s)
        } else {
          siglist <- c(siglist, j)
        }
      }
      nosig <- length(siglist)
      if (nosig == 0) sflag <- 0
    }
    if (sflag == 0) {
      nosig <- nisig
      siglist <- seq_len(nosig) - 1
    }
  }

  # The input sampling frequency.
  if (Mflag) {
    setgvmode(WFDB_LOWRES)
  } else if (Hflag) {
    setgvmode(WFDB_HIGHRES)
  }
  ifreq <- sampfreq(NULL)
  # wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
  # the input header did not specify one, as legacy mode does).
  legacy <- wfdbx_get_legacy()
  if (ifreq <= 0 && !legacy) {
    wfdbquit()
    .app_nofreq(pname, irec, 2)
  }
  spf <- getspf()
  fmt <- 0

  if (!is.null(orec)) {
    # an output record was specified
    if (!is.null(nrec) && newheader(nrec) < 0) cexit(2)
    ofreq <- sampfreq(orec)
    if (ofreq == 0 && !legacy) {   # wfdb-x: no default sampling frequency
      wfdbquit()
      .app_nofreq(pname, orec, 2)
    }
    setsampfreq(ifreq / spf)
    if (ifreq != ofreq && Mflag != 0) {
      ceprintf("%s: -M option may not be used if sampling frequency is to be changed\n",
               pname)
      wfdbquit()
      cexit(1)
    }
  } else {
    # The output specifications are asked for; the answers are read from
    # SCRIPT, /dev/tty, or the standard input.
    con <- NULL
    data <- raw(0)
    pos <- 1L
    opened <- FALSE
    if (!is.null(script)) {
      d <- tryCatch(readBin(script, "raw", file.info(script)$size), error = function(e) NULL)
      if (!is.null(d) && !isTRUE(file.info(script)$isdir)) {
        data <- d
        opened <- TRUE
      }
    } else {
      con <- tryCatch(suppressWarnings(file("/dev/tty", "rb")), error = function(e) NULL)
      opened <- !is.null(con)
    }
    if (!opened) data <- stdin_bytes()
    if (!is.null(con)) on.exit(close(con), add = TRUE)
    # C fgets(buf, size, ttyin): NULL at the end of the input
    rfgets <- function(size) {
      lim <- size - 1L
      if (!is.null(con)) {
        b <- raw(0)
        while (length(b) < lim) {
          x <- readBin(con, "raw", 1L)
          if (!length(x)) break
          b <- c(b, x)
          if (x == as.raw(10L)) break
        }
        if (!length(b)) return(NULL)
        return(cstr(b))
      }
      n <- length(data)
      if (pos > n) return(NULL)
      e <- min(n, pos + lim - 1L)
      k <- which(data[pos:e] == as.raw(10L))
      if (length(k)) e <- pos + k[1L] - 1L
      b <- data[pos:e]
      pos <<- e + 1L
      cstr(b)
    }
    script_fgets <- function(size) {
      s <- rfgets(size)
      if (is.null(s)) {
        if (!is.null(script)) {
          ceprintf("\n%s: unexpected end of file in %s\n", pname, script)
          cexit(1)
        }
        s <- "\n"
      }
      s
    }
    chop <- function(s) substr(s, 1L, nchar(s, type = "bytes") - 1L)  # drop last byte
    scan1 <- function(answer, f, old) {     # sscanf(answer, f, &old)
      r <- csscanf(answer, f)
      if (r$n == 1) r$v[[1L]] else old
    }
    answer <- ""
    if (is.null(nrec)) {
      repeat {
        ceprintf("Choose a name for the output record (up to %d characters): ", WFDB_MAXRNL)
        record <- chop(script_fgets(WFDB_MAXRNL + 2))
        if (nzchar(record) && newheader(record) >= 0) break
      }
      nrec <- record
    }
    if (sflag == 0) {
      repeat {
        nosig <- nisig
        ceprintf("Number of signals to be written (1-%d) [%d]: ", nisig, nosig)
        answer <- script_fgets(32)
        nosig <- scan1(answer, "%d", nosig)
        if (nosig == 0) {
          ceprintf("No signals will be written.  Are you sure? [n]: ")
          answer <- script_fgets(32)
          if (!(startsWith(answer, "y") || startsWith(answer, "Y"))) nosig <- -1
        }
        if (!(nosig < 0 || nosig > nisig)) break
      }
    }
    if (Mflag) {
      ofreq <- ifreq
      ceprintf("Sampling frequency (%g frames/sec) will be unchanged\n", ofreq)
    } else {
      repeat {
        ofreq <- ifreq
        ceprintf("Output sampling frequency (Hz per signal, > 0) [%g]: ", ofreq)
        answer <- script_fgets(32)
        ofreq <- scan1(answer, "%lf", ofreq)
        if (!(ofreq < 0)) break
      }
    }
    if (ofreq == 0 && legacy) {    # wfdb-x: legacy mode (as the C program)
      ofreq <- WFDB_DEFFREQ
    } else if (ofreq == 0) {       # wfdb-x: the C program assumed 250 Hz
      ceprintf("%s: the output sampling frequency must be > 0\n", pname)
      wfdbquit()
      cexit(1)
    }
    if (nosig > 0) {
      cerr("Specify the name of the directory in which the output\n")
      cerr(" signals should be written, or press <return> to write\n")
      cerr(" them in the current directory: ")
      directory <- script_fgets(31)
      directory <- if (startsWith(directory, "\n")) "" else paste0(chop(directory), "/")
      cerr(paste0(
        "Any of these output formats may be used:\n",
        "    8   8-bit first differences\n",
        "   16   16-bit two's complement amplitudes (LSB first)\n",
        "   61   16-bit two's complement amplitudes (MSB first)\n",
        "   80   8-bit offset binary amplitudes\n",
        "  160   16-bit offset binary amplitudes\n",
        "  212   2 12-bit amplitudes bit-packed in 3 bytes\n",
        "  310   3 10-bit amplitudes bit-packed in 15 LS bits of each of 2 words\n",
        "  311   3 10-bit amplitudes bit-packed in 30 LS bits of 4 bytes\n",
        "   24   24-bit two's complement amplitudes (LSB first)\n",
        "   32   32-bit two's complement amplitudes (LSB first)\n",
        "  508  8-bit amplitudes with FLAC compression\n",
        "  516  16-bit amplitudes with FLAC compression\n",
        "  524  24-bit amplitudes with FLAC compression\n"))
      repeat {
        fmt <- dfin[[1L]]$fmt
        ceprintf("Choose an output format from the list above [%d]: ", fmt)
        answer <- script_fgets(32)
        fmt <- scan1(answer, "%d", fmt)
        if (fmt %in% WFDB_FMT_LIST[-1L]) break       # (format 0 excluded)
      }
      if (nosig > 1) {
        cerr("Save all signals in one file? [y]: ")
        answer <- script_fgets(32)
      }
      # the input signal specifications are the defaults for output
      dfout <- dfin[siglist[seq_len(nosig)] + 1]
      if (nosig <= 1 || !(startsWith(answer, "n") || startsWith(answer, "N"))) {
        fn <- paste0(directory, nrec, ".dat")
        for (k in seq_len(nosig)) {
          dfout[[k]]$fname <- fn
          dfout[[k]]$group <- 0
        }
      } else {
        for (k in seq_len(nosig)) {
          dfout[[k]]$fname <- rawToChar(csprintf("%s%s.d%d", directory, nrec, k - 1))
          dfout[[k]]$group <- k - 1
        }
      }
    }
    for (k in seq_len(nosig)) {
      d <- dfout[[k]]
      d$fmt <- fmt
      if (Mflag == 0) d$spf <- 1
      d$bsize <- 0
      if (!use_irec_desc) {
        ceprintf("Signal %d description (up to %d characters): ", k - 1, WFDB_MAXDSL)
        d["desc"] <- list(chop(script_fgets(WFDB_MAXDSL + 2)))
        ceprintf("Signal %d units (up to %d characters): ", k - 1, WFDB_MAXUSL)
        units <- sub("\n.*", "", script_fgets(WFDB_MAXUSL + 2), useBytes = TRUE)
        units <- gsub("[ \t]", "_", units, useBytes = TRUE)
        d["units"] <- list(if (nzchar(units)) units else NULL)
      }
      ceprintf(" Signal %d gain (adu/%s) [%g]: ", k - 1,
               if (!is.null(d$units)) d$units else if (legacy) "mV" else "nd",
               d$gain)                    # wfdb-x: C (legacy mode) showed "mV"
      answer <- script_fgets(32)
      d$gain <- scan1(answer, "%lf", d$gain)
      # wfdb-x: a resolution is offered only if it comes from the input (or
      # the previous output signal) and suits the output format; the C
      # program otherwise offered one based on the format (12 bits for
      # 16-bit formats).  Without one, the user must give it.  Legacy mode: as
      # in the C program.
      if (legacy) repeat {
        if (k > 1) d$adcres <- dfout[[k - 1]]$adcres
        lim <- switch(as.character(d$fmt), "80" = , "508" = 8, "212" = 12, "310" = 10,
                      "24" = , "524" = 24, "32" = 32, 16)
        if (lim == 8) {
          d$adcres <- 8
        } else if (d$adcres < 8 || d$adcres > lim) {
          d$adcres <- if (lim == 16) WFDB_DEFRES else lim
        }
        ceprintf(" Signal %d ADC resolution in bits (8-32) [%d]: ", k - 1, d$adcres)
        answer <- script_fgets(32)
        d$adcres <- scan1(answer, "%d", d$adcres)
        if (!(d$adcres < 8 || d$adcres > 32)) break
      } else repeat {
        if (k > 1) d$adcres <- dfout[[k - 1]]$adcres
        maxres <- switch(as.character(d$fmt), "80" = , "508" = 8, "212" = 12, "310" = 10,
                         "24" = , "524" = 24, "32" = 32, 16)
        if (d$adcres >= 8 && d$adcres <= maxres) {
          ceprintf(" Signal %d ADC resolution in bits (8-32) [%d]: ", k - 1, d$adcres)
        } else {
          ceprintf(" Signal %d ADC resolution in bits (8-32): ", k - 1)
          d$adcres <- 0
        }
        answer <- script_fgets(32)
        d$adcres <- scan1(answer, "%d", d$adcres)
        if (d$adcres == 0) {
          ceprintf("%s: the ADC resolution of signal %d must be specified\n", pname, k - 1)
          wfdbquit()
          cexit(1)
        }
        if (!(d$adcres < 8 || d$adcres > 32)) break
      }
      ceprintf(" Signal %d ADC zero level (adu) [%d]: ", k - 1, d$adczero)
      answer <- script_fgets(32)
      d$adczero <- scan1(answer, "%d", d$adczero)
      dfout[[k]] <- d
    }
  }

  # The starting and ending times.
  siglist <- siglist[seq_len(max(nosig, 0))]
  if (from) startp <- arg(from)
  from <- strtim(startp)
  if (from < 0) from <- -from
  btstring <- mstimstr(-from)
  if (to) {
    to <- strtim(arg(to))
    if (to < 0) to <- -to
    if (to > 0) {
      nsamp <- to - from
      if (nsamp <= 0) {
        ceprintf("%s: 'to' time must be later than 'from' time\n", pname)
        cexit(1)
      }
    }
  }
  spm <- strtim("1:0")
  if (Mflag) {
    # 'from' and 'to' (frames) in high-resolution sample numbers, for the
    # annotations
    setgvmode(WFDB_HIGHRES)
    spf <- getspf()
    from <- from * spf
    to <- to * spf
    setafreq(ofreq * spf)
  } else {
    setafreq(0)
  }

  # The annotation files.
  nann <- length(ainames)
  if (nann > 0) {
    ai <- lapply(ainames, function(a) anninfo(a, WFDB_READ))
    if (annopen(irec, ai, nann) < 0 || iannsettime(from) < -1) cexit(2)
    ao <- lapply(ainames, function(a) anninfo(a, WFDB_WRITE))
    if (annopen(paste0("+", if (!is.null(nrec)) nrec else orec), ao, nann) < 0) cexit(2)
    for (k in seq_len(nann) - 1) {
      # read up to the first annotation after 'to'
      A <- .getann_bulk(k, Inf, FALSE, TRUE)
      na <- length(A$time)
      last <- na
      if (to != 0) {
        e <- which(A$time > to)
        if (length(e)) last <- e[1L] - 1
      }
      if (A$stat == 1 && last == na) getann(k)     # the call that fails, as in C
      keep <- seq_len(na) <= last &
        !(A$time == 0 & A$subtyp == 0 & A$chan == 0 & A$num == 0 &
          (A$anntyp == NOTQRS | A$anntyp == NOTE))
      t <- trunc((A$time[keep] - from) * ofreq / ifreq)
      chan <- A$chan[keep]
      if (uflag) {
        # times made increasing (equal times allowed for increasing chan)
        tt <- 0
        cc <- -129                         # below any chan value
        for (j in seq_along(t)) {
          if (t[j] < tt || (t[j] == tt && chan[j] <= cc)) {
            tt <- tt + 1
            t[j] <- tt
          } else {
            tt <- t[j]
          }
          cc <- chan[j]
        }
      }
      .putann_bulk(k, list(time = t, anntyp = A$anntyp[keep], subtyp = A$subtyp[keep],
                           chan = chan, num = A$num[keep], aux = A$aux[keep]))
    }
    for (k in rev(seq_len(nann) - 1)) {
      iannclose(k)
      oannclose(k)
    }
  }
  if (nosig == 0) cexit(0)

  cerr("Checking input signals ...")
  if (isigsettime(from) < 0) cexit(2)
  cerr(" done\n")
  wfdbquiet()
  if (!is.null(orec)) {
    r <- osigopen(orec, nosig)
    if (r$nsig != nosig) {
      # wfdb-x: say why if an output file is one of the input files (the
      # library's message, quieted above, is the last error)
      e <- charToRaw(wfdberror())
      tail <- charToRaw(" is also an input file\n")
      if (!wfdbx_get_legacy() && startsWith(rawToChar(e), "osigopen: output file ") &&
          length(e) > 22L + 23L && identical(e[(length(e) - 22L):length(e)], tail)) {
        ceprintf("%s: can't write output signals (%s)\n", pname, e[-length(e)])
      } else {
        ceprintf("%s: can't write output signals\n", pname)
      }
      cexit(2)
    }
    dfout <- r$si
  }
  wfdbverbose()
  for (k in seq_len(nosig)) {
    if (dfout[[k]]$fmt == 0) {
      ceprintf("%s: signal %d format cannot be 0 (changing to format 16)\n", pname, k - 1)
      dfout[[k]]$fmt <- 16
      reopen <- 1
    }
  }
  # Without -M, the output frames hold one sample of each signal (as for
  # output signals specified interactively), so signals of the -o record
  # with more than one sample per frame are (re)opened with one.  (C reads
  # past the end of its output array; see "Undefined behaviors" in
  # docs/KNOWN_C_BEHAVIORS.md.)
  if (Mflag == 0) {
    for (k in seq_len(nosig)) {
      if (dfout[[k]]$spf > 1) {
        dfout[[k]]$spf <- 1
        reopen <- 1
      }
    }
  }
  if (!is.null(nrec) && use_irec_desc) {
    for (k in seq_len(nosig)) dfout[[k]]["desc"] <- list(dfin[[siglist[k] + 1]]$desc)
    reopen <- 1
  }

  # Relative gains and offsets of the signals.
  gain <- numeric(nosig)
  deltav <- numeric(nosig)
  for (k in seq_len(nosig)) {
    j <- siglist[k] + 1
    di <- dfin[[j]]
    dk <- dfout[[k]]
    if (dk$gain == 0) {
      # output gain not specified: scale by the ratio of the resolutions.
      # wfdb-x: this needs both resolutions (the C program guessed an
      # unspecified input resolution from the format, assuming WFDB_DEFRES
      # for 16-bit formats, as legacy mode does).
      if (legacy) {
        if (di$adcres == 0) {
          di$adcres <- switch(as.character(di$fmt), "80" = , "508" = 8, "212" = 12,
                              "310" = 10, "24" = , "524" = 24, "32" = 32, WFDB_DEFRES)
          dfin[[j]] <- di
        }
      } else if (di$adcres == 0 || dk$adcres == 0) {
        ceprintf("%s: ADC resolution of signal %d of record %s is not specified\n", pname,
                 if (di$adcres == 0) j - 1 else k - 1,
                 if (di$adcres == 0) irec else if (!is.null(orec)) orec else nrec)
        wfdbquit()
        cexit(2)
      }
      gain[k] <- 2^dk$adcres / 2^di$adcres
    } else if (di$gain == 0 && legacy) {
      gain[k] <- dk$gain / WFDB_DEFGAIN    # wfdb-x: legacy mode (as the C program)
    } else if (di$gain == 0) {
      # wfdb-x: an uncalibrated input signal cannot be rescaled to the given
      # gain (the C program assumed an input gain of WFDB_DEFGAIN).
      ceprintf("%s: signal %d of record %s is uncalibrated; it cannot be rescaled to the specified gain\n",
               pname, j - 1, irec)
      wfdbquit()
      cexit(2)
    } else {
      gain[k] <- dk$gain / di$gain
    }
    if (gain[k] != 1) gflag <- 1
    deltav[k] <- d2i(dk$adczero - gain[k] * di$adczero)
    if (dk$gain != di$gain * gain[k] || dk$baseline != di$baseline * gain[k]) {
      dk$gain <- di$gain * gain[k]
      dk$baseline <- d2i(di$baseline * gain[k])
      reopen <- 1
    }
    dfout[[k]] <- dk
  }
  if (reopen && osigfopen(dfout, nosig) != nosig) cexit(2)

  # The legal range of the output samples, and the processing state.
  adczero <- vapply(dfout, function(d) d$adczero, 0)
  adcres <- vapply(dfout, function(d) d$adcres, 0)
  X <- list(clip = clip, vmax = cint32(adczero + 2^(adcres - 1) - 1),
            vmin = cint32(adczero - 2^(adcres - 1)), spm = spm, nsm = 0, nminutes = 0,
            gflag = gflag, dflag = dflag, rng = rng, gain = gain, deltav = deltav)
  cols <- siglist + 1                       # input column of each output signal
  sigs <- seq_len(nosig)

  m <- 0; n <- 0
  if (ifreq != ofreq) {
    f <- .xform_gcd(ifreq, ofreq)
    fflag <- 1
    m <- trunc(ifreq / f)
    n <- trunc(ofreq / f)
    x <- getvec()$v[cols]
    vv <- d2i(x * gain + deltav)            # (truncated: vv is an int array)
    vv[x == INV] <- INV
  }

  if (Mflag) {
    # Frames, one getframe() call each; output column -> input column and
    # signal
    ospf <- vapply(dfout, function(d) d$spf, 0)
    ispf <- vapply(dfin, function(d) d$spf, 0)
    ioff <- cumsum(c(0, ispf))[siglist + 1]
    sigof <- rep(sigs, ospf)
    icol <- ioff[sigof] + sequence(ospf)
    XM <- X
    XM$gain <- gain[sigof]
    XM$deltav <- deltav[sigof]
    remaining <- nsamp
    done <- FALSE
    while (!done) {
      blk <- matrix(0, .XFORM_MCHUNK, length(icol))
      nr <- 0
      while (nr < .XFORM_MCHUNK) {
        g <- getframe()
        if (g$stat < nisig) {
          done <- TRUE
          break
        }
        if (remaining != -1) {
          more <- remaining > 0
          remaining <- remaining - 1
          if (!more) {
            done <- TRUE
            break
          }
        }
        nr <- nr + 1
        blk[nr, ] <- g$v[icol]
      }
      bk <- blk[seq_len(nr), , drop = FALSE]
      y <- .xform_input(bk, XM)
      ck <- .xform_check(y, sigof, XM, bk != INV)
      XM <- .xform_report(ck$X, nr, ck$msgs, ck$msgs$row)
      if (putframes(ck$x) < 0) break
    }
    X <- XM
  } else if (fflag == 0) {
    remaining <- nsamp
    repeat {
      if (remaining == 0) {
        getvec()                            # C reads one more vector
        break
      }
      k <- if (remaining < 0) .XFORM_CHUNK else min(.XFORM_CHUNK, remaining)
      V <- getframes(k, nisig)$v       # (getvec(vin) >= nisig)
      L <- nrow(V)
      Vc <- V[, cols, drop = FALSE]
      ck <- .xform_check(.xform_input(Vc, X), sigs, X, Vc != INV)
      X <- .xform_report(ck$X, L, ck$msgs, ck$msgs$row)
      if (putframes(ck$x) < 0 || L < k) break
      if (remaining > 0) remaining <- remaining - L
    }
  } else {
    # Resampling: output frame q (0, 1, ...) is computed while input frame
    # iq = ceil(q*m/n) + 1 is processed (frame 1 is the first one after the
    # frame read above), by interpolation between input frames iq - 1 and
    # iq.
    remaining <- nsamp
    i0 <- 0                                 # input frames processed
    q0 <- 0                                 # output frames written
    repeat {
      if (remaining == 0) {
        getvec()                            # C reads one more vector
        break
      }
      k <- if (remaining < 0) .XFORM_CHUNK else min(.XFORM_CHUNK, remaining)
      V <- getframes(k, nisig)$v       # (getvec(vin) >= nisig)
      L <- nrow(V)
      if (L == 0) break
      q1 <- ((i0 + L - 1) * n) %/% m        # the last output of this block
      q <- if (q1 >= q0) q0:q1 else numeric(0)
      nq <- length(q)
      iq <- (q * m + n - 1) %/% n + 1 - i0  # its input frame (in the block)
      r <- (q * m) %% n
      x <- ifelse(r == 0, 1, r / n)
      xin <- V[, cols, drop = FALSE]
      dout <- NULL
      if (dflag && gflag) {
        # rand() calls interleaved, in C order: for each input frame, the
        # dither of its samples, then that of the outputs computed while
        # processing it.  An output is dithered if both of its (dithered
        # and rounded) inputs are valid, so this is done one frame at a
        # time (a rounded input may equal WFDB_INVALID_SAMPLE).
        vdin <- xin * rep(gain, each = L) + rep(deltav, each = L)
        y <- matrix(0, L, nosig)
        dout <- matrix(0, nq, nosig)
        prev <- vv
        jq <- 1
        for (j in seq_len(L)) {
          for (kk in seq_len(nosig)) {
            y[j, kk] <- if (xin[j, kk] == INV) INV else
              .xform_round(vdin[j, kk] + .xform_dither(X$rng, 1))
          }
          # the outputs computed while frame j is processed
          while (jq <= nq && iq[jq] == j) {
            for (kk in seq_len(nosig)) {
              if (prev[kk] != INV && y[j, kk] != INV) dout[jq, kk] <- .xform_dither(X$rng, 1)
            }
            jq <- jq + 1
          }
          prev <- y[j, ]
        }
      } else {
        y <- .xform_input(xin, X)
      }
      Y <- rbind(vv, y)
      a <- Y[iq, , drop = FALSE]
      b <- Y[iq + 1, , drop = FALSE]
      vd <- a + x * cint32(b - a)       # (an int difference in C)
      bad <- a == INV | b == INV
      if (dflag) {
        vd <- if (is.null(dout)) .xform_add_dither(vd, !bad, X$rng) else vd + dout
      }
      out <- .xform_round(vd)
      out[bad] <- INV
      ck <- .xform_check(out, sigs, X, !bad)
      X <- .xform_report(ck$X, L, ck$msgs, iq[ck$msgs$row])
      if (putframes(ck$x) < 0 || L < k) break
      vv <- y[L, ]
      i0 <- i0 + L
      q0 <- q1 + 1
      if (remaining > 0) remaining <- remaining - L
    }
  }
  if (X$nminutes > 0) cerr("\n")

  # The new header file, if requested.
  if (!is.null(nrec)) {
    setsampfreq(ofreq)
    if (startsWith(btstring, "["))
      setbasetime(substr(btstring, 2L, nchar(btstring, type = "bytes") - 1L))
    newheader(nrec)
    wfdbquiet()
    info <- getinfo(irec)
    while (!is.null(info)) {
      putinfo(info)
      info <- getinfo(NULL)
    }
    putinfo(csprintf("Produced by %s from record %s, beginning at %s", pname, irec, startp))
    for (k in seq_len(nosig)) {
      if (siglist[k] != k - 1) {
        xinfo <- csprintf("record %s, signal %d <- record %s, signal %d",
                          nrec, k - 1, irec, siglist[k])
        if (gain[k] != 1) xinfo <- c(xinfo, csprintf(" * %g", gain[k]))
        if (deltav[k] != 0)
          xinfo <- c(xinfo, csprintf(" %c %d", if (deltav[k] > 0) "+" else "-", abs(deltav[k])))
        putinfo(xinfo)
      }
    }
    wfdbverbose()
  }
  wfdbquit()
  0
}
