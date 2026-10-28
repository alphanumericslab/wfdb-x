# apps_parsescp.R: parsescp -- parse an SCP-ECG file (read from the
# standard input).
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of convert/parsescp.c from the WFDB Software Package
# 10.7.0, by George B. Moody and Edna S. Moody. The translation follows the
# logic and behavior of the original program, but it is new code, not the
# original C code.
#
# Changes from the original: the record is written with the sampling frequency
# given in the SCP file, and is not written if the file gives none (the
# original always wrote 500 Hz); signals and reference beats that could not be
# allocated, and samples beyond the end of a signal shorter than lead 0, are
# read as absent or as zeros (undefined behavior in the original); --legacy, as
# the first argument, restores the original behavior. Each change is marked
# "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
#
# Original C program: convert/parsescp.c, WFDB Software Package 10.7.0.
#   Copyright (C) 2000-2014 George B. Moody and Edna S. Moody; revised
#   2016-2020 by Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This program is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.
#
# The input is held in one byte vector (P$D, integer byte values) and the C
# program's pointers into it are represented by 0-based offsets.  Bytes
# beyond the end of the input (which the C program reads in a few places,
# e.g. at the end of section 7 with -v) are read as 0.  C's 64-bit unsigned
# values (sample counts computed from 32-bit fields) are kept as signed
# values v, standing for v modulo 2^64 (see .scp_ugt).  Signals are integer
# vectors of short values; the Huffman decoding, the filters and the
# formatting of tables use vector operations.  The choices made where the
# C program has undefined behavior are those of docs/KNOWN_C_BEHAVIORS.md.

app_parsescp <- function(args = character(0)) {
  app_run(.scp_main, c("parsescp", args))
}

.SCP_VERSION <- "#ECG/1.0"
.SCP_MAXALLOC <- 2^28          # larger allocations fail
.SCP_MINSIGLEN <- 5000         # minimum length of a signal array
.SCP_CHUNK <- 1048576          # samples processed at a time (memory use)
.SCP_INVALID <- -32768         # WFDB_INVALID_SAMPLE
.SCP_ZMAX <- 2000              # -z: larger values are marked invalid
# The gain (adu/mV) of the WFDB record.  WFDB-x: exact, not assumed: the
# samples have been rescaled to units of 5000 nV (see gref and gres), i.e.,
# 200 adu/mV.  (Its sampling frequency is the one given in the SCP file.)
.SCP_GAIN <- 200
.SCP_LEGACY_SFREQ <- 500       # WFDB-x: legacy mode: the C program's frequency
.SCP_NV <- 29999               # section 10: not computed by analyzer
.SCP_REJ <- 29998              # lead rejected
.SCP_ABSENT <- 19999           # wave not present
.SCP_DEFHUFF <- 19999          # section 2: default Huffman table only

.SCP_MONTH <- c("January", "February", "March", "April", "May", "June", "July",
                "August", "September", "October", "November", "December")

.SCP_LEADNAME <- c(            # standard lead names (IDs 0-85)
  "<Unspecified lead>", "I", "II", "V1", "V2",                         # 0 - 4
  "V3", "V4", "V5", "V6", "V7",                                        # 5 - 9
  "V2R", "V3R", "V4R", "V5R", "V6R",                                   # 10 - 14
  "V7R", "X", "Y", "Z", "CC5",                                         # 15 - 19
  "CM5", "Left Arm", "Right Arm", "Left Leg", "I (Frank)",             # 20 - 24
  "E", "C", "A", "M", "F",                                             # 25 - 29
  "H", "I-cal", "II-cal", "V1-cal", "V2-cal",                          # 30 - 34
  "V3-cal", "V4-cal", "V5-cal", "V6-cal", "V7-cal",                    # 35 - 39
  "V2R-cal", "V3R-cal", "V4R-cal", "V5R-cal", "V6R-cal",               # 40 - 44
  "V7R-cal", "X-cal", "Y-cal", "Z-cal", "CC5-cal",                     # 45 - 49
  "CM5-cal", "Left Arm-cal", "Right Arm-cal", "Left Leg-cal",
  "I-cal (Frank)",                                                     # 50 - 54
  "E-cal", "C-cal", "A-cal", "M-cal", "F-cal",                         # 55 - 59
  "H-cal", "III", "aVR", "aVL", "aVF",                                 # 60 - 64
  "-aVR", "V8", "V9", "V8R", "V9R",                                    # 65 - 69
  "D (Nehb - Dorsal)", "A (Nehb - Anterior)", "J (Nehb - Inferior",
  "Defibrillator lead: anterior-lateral",
  "External pacing lead: anterior-posterior",                          # 70 - 74
  "A1 (Auxiliary unipolar lead 1)", "A2 (Auxiliary unipolar lead 2)",
  "A3 (Auxiliary unipolar lead 3)", "A4 (Auxiliary unipolar lead 4)",
  "V8-cal",                                                            # 75 - 79
  "V9-cal", "V8R-cal", "V9R-cal", "D-cal (Nehb - Dorsal)",
  "A-cal (Nehb - Anterior)",                                           # 80 - 84
  "J-cal (Nehb - Inferior)")                                           # 85

# The 12 leads written, and the IDs (section 3) of the leads stored.
.SCP_LEADS <- c("leadI", "leadII", "leadIII", "aVR", "aVF", "aVL",
                "V1", "V2", "V3", "V4", "V5", "V6")
.SCP_LEADIDS <- c(1, 2, 61, 62, 64, 63, 3, 4, 5, 6, 7, 8)

# Rows of the measurement table (section 10): labels, and the indices of
# the fields in a measurement block (fields: leadid, vlen, Pdur, PRint,
# QRSdur, QTint, Qdur, Rdur, Sdur, Rpdur, Spdur, Qamp, Ramp, Samp, Rpamp,
# Spamp, Jamp, Ppamp, Pnamp, Tpamp, Tnamp, STslope, Pmorph, Tmorph, isoI,
# isoK, tind, qual, st20, st60, st80, strr16, strr8).
.SCP_NMEAS <- 33L
.SCP_MEASLABEL <- c(
  "P duration    ms", "PR interval   ms", "QRS duration  ms", "QT interval   ms",
  "Q duration    ms", "R duration    ms", "S duration    ms", "R' duration   ms",
  "S' duration   ms", "Q amplitude   uV", "R amplitude   uV", "S amplitude   uV",
  "J amplitude   uV", "P+ amplitude  uV", "P- amplitude  uV", "T+ amplitude  uV",
  "T- amplitude  uV", "ST slope    uV/s", "P morphology  --", "T morphology  --",
  "Isoelec (I)   ms", "Isoelec (K)   ms", "Intrins defl  ms", "Quality       --",
  "ST (J+20ms)   uV", "ST (J+60ms)   uV", "ST (J+80ms)   uV", "ST (J+RRm/16) uV",
  "ST (J+RRm/8)  uV")
.SCP_MEASFIELD <- c(3:14, 17:33)

.SCP_CONTENTS <- c(
  " Pointers to data areas in the record\n",
  " Header information - Patient data/ECG acquisition data\n",
  " Huffman tables used in encoding of ECG data\n",
  " ECG lead definition\n",
  " QRS locations\n",
  " Encoded reference beat data\n",
  paste0(" Residual signal after reference beat subtraction (if reference beats\n",
         "  are stored);  otherwise, encoded rhythm data\n"),
  " Global measurements\n",
  " Textual diagnosis from the interpretive device\n",
  " Manufacturer specific diagnostic and overreading data\n",
  " Lead measurement results\n",
  " Universal statement codes resulting from the interpretation\n")

# CRC-CCITT of 16-bit words (polynomial 0x1021): the register after 16
# shifts, for each value of (register XOR word).
.scp_crctab <- local({
  v <- 0:65535
  for (k in 1:16) {
    msb <- v >= 32768L
    v <- (v * 2L) %% 65536L
    v[msb] <- bitwXor(v[msb], 0x1021L)
  }
  v
})

.scp_help <- function(pname) {
  ceprintf("usage: %s -o RECORD [OPTIONS ...] <SCPFILE\n", pname)
  cerr(paste0(
    "  where RECORD is the name (<= 11 alphanumeric characters) of this case,\n",
    "  SCPFILE is the name of a file containing ECG data in SCP-ECG format, and\n",
    "  OPTIONS may include:\n",
    "   -a    anonymize and copy stdin to stdout (suppresses other output).\n",
    "   -f    force parsing of a file with CRC errors.\n",
    "   -h    print brief help\n",
    "   -l    low-pass filter (smooth) the output waveforms.\n",
    "   -v    option to print a (very) detailed analysis of SCPFILE.\n",
    "   -w    produce a WFDB-format record\n",
    "   -z    zero-mean the input\n\n",
    "  Additional options for debugging only:\n",
    "   -b    show baseline (residuals);  suppress templates\n",
    "   -s N  shift templates by N samples before adding\n",
    "   -S N  skip parsing of section N\n",
    "   -t    show templates; suppress baseline\n",
    "   -x    show hex dumps (implies -v)\n"))
}

# ---------------------------------------------------------------------------
# Access to the input buffer

# The byte at offset off (0 beyond the data).
.scp_b <- function(P, off) if (off >= 0 && off < P$n) P$D[off + 1] else 0L

.scp_g16 <- function(P, off) .scp_b(P, off) + 256 * .scp_b(P, off + 1)

# 32-bit little-endian value, sign-extended (*p << 24 is an int in C).
.scp_g32 <- function(P, off) {
  v <- .scp_b(P, off) + 256 * .scp_b(P, off + 1) + 65536 * .scp_b(P, off + 2) +
    16777216 * .scp_b(P, off + 3)
  if (v >= 2147483648) v - 4294967296 else v
}

# n bytes from offset off (0 beyond the data).
.scp_bytes <- function(P, off, n) {
  b <- integer(max(n, 0))
  lo <- max(off, 0)
  hi <- min(off + n, P$n)
  if (hi > lo) b[(lo - off + 1):(hi - off)] <- P$D[(lo + 1):hi]
  b
}

# The sign-extended 32-bit values in rows r to r + 3 of a matrix of bytes
# (one column per table entry).
.scp_i32 <- function(E, r) {
  v <- E[r, ] + 256 * E[r + 1L, ] + 65536 * E[r + 2L, ] + 16777216 * E[r + 3L, ]
  v - 4294967296 * (v >= 2147483648)
}

# Little-endian 16-bit (unsigned) words of n bytes from offset off.
.scp_words <- function(P, off, n) {
  b <- .scp_bytes(P, off, 2 * n)
  b[c(TRUE, FALSE)] + 256 * b[c(FALSE, TRUE)]
}

.scp_put16 <- function(P, val, off) {
  force(val)                   # (it may be computed from P$D)
  D <- P$D
  P$D <- NULL                  # (unbound while modified: no copy)
  if (off >= 0 && off < P$n) D[off + 1] <- as.integer(val %% 256)
  if (off + 1 >= 0 && off + 1 < P$n) D[off + 2] <- as.integer((val %/% 256) %% 256)
  P$D <- D
  invisible()
}

# The NUL-terminated string at offset x (it ends at the end of the data),
# as raw bytes; x may also be a string (raw).
.scp_cstr <- function(P, x) {
  if (is.raw(x)) return(x)
  if (x < 0 || x >= P$n) return(raw(0))
  b <- P$D[(x + 1):P$n]
  z <- match(0L, b)
  as.raw(if (is.na(z)) b else b[seq_len(z - 1L)])
}

.scp_plural <- function(d) if (d == 1) "" else "s"

# The bytes b, printable ones as is, others as \ooo.
.scp_escaped <- function(b) {
  s <- character(length(b))
  pr <- b >= 32L & b < 127L
  s[pr] <- vapply(b[pr], intToUtf8, "")
  s[!pr] <- sprintf("\\%03o", b[!pr])
  paste(s, collapse = "")
}

.scp_getcrc <- function(P, off, len) {
  crc <- 65535L
  if (len <= 0) return(crc)
  b <- .scp_bytes(P, off, len)
  nw <- len %/% 2
  w <- b[2 * seq_len(nw) - 1L] * 256L + b[2 * seq_len(nw)]
  tab <- .scp_crctab
  for (x in w) crc <- tab[bitwXor(crc, x) + 1L]
  if (2 * nw < len) {
    v <- bitwXor(crc, b[len] * 256L)
    for (k in 1:8) v <- if (v >= 32768L) bitwXor((v * 2L) %% 65536L, 0x1021L) else (v * 2L) %% 65536L
    crc <- v
  }
  crc
}

.scp_crcok <- function(P, off, len, crcref, desc) {
  crc <- .scp_getcrc(P, off, len)
  if (crc == crcref) {
    if (P$vflag) cprintf("%s: correct (%d)\n", desc, crc)
    return(TRUE)
  }
  if (P$vflag) cprintf("%s: error (calculated: %d, expected: %d)\n", desc, crc, crcref)
  if (P$fflag) return(FALSE)
  cexit(1)                     # quit on CRC error unless in -f (force) mode
}

# ---------------------------------------------------------------------------
# 64-bit unsigned values (kept as signed values) and signals

.scp_ugt <- function(a, b) if ((a < 0) != (b < 0)) a < 0 else a > b
.scp_umin <- function(a, b) if (.scp_ugt(a, b)) b else a

# calloc(n, sizeof(short)) for a signal; NULL if the allocation fails.
.scp_newsig <- function(n) {
  if (n < 0 || n > .SCP_MAXALLOC) NULL else integer(max(n, .SCP_MINSIGLEN))
}

# Signal k; a lead index outside the ecg array (undefined behavior in C)
# refers to an array of zero samples, like a missing lead.
.scp_sig <- function(P, k) {
  if (!is.null(P$ecg) && k >= 0 && k < length(P$ecg) && !is.null(P$ecg[[k + 1]])) {
    P$ecg[[k + 1]]
  } else integer(max(P$nout, .SCP_MINSIGLEN))
}

.scp_setsig <- function(P, k, s) {
  force(s)                     # (it may be computed from P$ecg)
  if (!is.null(P$ecg) && k >= 0 && k < length(P$ecg) && !is.null(P$ecg[[k + 1]])) {
    e <- P$ecg
    P$ecg <- NULL
    e[[k + 1]] <- s
    P$ecg <- e
  }
  invisible()
}

# nsamp[k], or 0 if k is outside the nsamp array.
.scp_ns <- function(P, k) if (k >= 0 && k < length(P$nsamp)) P$nsamp[k + 1] else 0

# (short)x, via a 32-bit int (vectorized).
.scp_d2s <- function(x) as.integer(cint16(d2i(x)))

# The first indices of the blocks of .SCP_CHUNK elements that cover
# from:to (none if to < from).
.scp_blocks <- function(from, to) if (to < from) numeric(0) else seq(from, to, by = .SCP_CHUNK)

# out[1:m] <- f(a[1:m], b[1:m]) (as doubles), in blocks.
.scp_blockop <- function(f, a, b, out, m) {
  for (b0 in .scp_blocks(1, m)) {
    k <- b0:min(b0 + .SCP_CHUNK - 1, m)
    out[k] <- as.integer(f(as.numeric(a[k]), as.numeric(b[k])))
  }
  out
}

# ---------------------------------------------------------------------------
# Output

# The low-pass filter of -l, applied to all leads.
.scp_lowpass <- function(P) {
  for (i in seq_len(max(P$nleads, 0)) - 1L) {
    inp <- P$ecg[[i + 1]]
    if (is.null(inp)) next
    n <- P$nsamp[i + 1]
    out <- .scp_newsig(n)
    if (is.null(out)) {
      ceprintf("Insufficient memory for filtering\n")
      break
    }
    # Samples beyond the end of the input array read as 0, and writes
    # beyond the end of the output array are skipped.
    nin <- length(inp)
    nout <- length(out)
    x <- function(k) {
      v <- numeric(length(k))
      ok <- k < nin
      v[ok] <- inp[k[ok] + 1]
      v
    }
    put <- function(k, v) if (k < nout) out[k + 1] <<- v
    a <- x(0:3)
    put(0, .scp_d2s(a[1] * 0.67 + a[2] * 0.22 + a[3] * 0.11))
    put(1, .scp_d2s(a[1] * 0.33 + a[2] * 0.34 + a[3] * 0.22 + a[4] * 0.11))
    # C: for (j = 2; j < nsamp[i] - 2; j++), with an unsigned (wrapping)
    # bound; iterations past the end of the output array would only make
    # skipped writes, so the loop stops there (the final writes below are
    # then skipped too).
    jend <- if (n - 2 < 0) nout else min(n - 2, nout)
    j <- 2
    if (jend > 2) {
      for (b0 in .scp_blocks(2, jend - 1)) {
        jj <- b0:min(b0 + .SCP_CHUNK - 1, jend - 1)
        y <- x((b0 - 2):(jj[length(jj)] + 2))
        k <- seq_along(jj) + 2L
        out[jj + 1] <- .scp_d2s(y[k] * 0.34 + (y[k - 1L] + y[k + 1L]) * 0.22 +
                                  (y[k - 2L] + y[k + 2L]) * 0.11)
      }
      j <- jend
    }
    a <- x((j - 2):(j + 1))
    put(j, .scp_d2s(a[1] * 0.11 + a[2] * 0.22 + a[3] * 0.34 + a[4] * 0.33))
    put(j + 1, .scp_d2s(a[2] * 0.11 + a[3] * 0.22 + a[4] * 0.67))
    .scp_setsig(P, i, out)
  }
  invisible()
}

# The measurement table (as precgmeas() prints it), as a string.
.scp_precgmeas <- function(P) {
  M <- P$ecgmeas
  id <- M[, 1L]
  hdr <- ifelse(id > 0 & id <= 85, sprintf("%8s", .SCP_LEADNAME[pmax(id, 0) + 1]),
                sprintf("  <%4d>", id))
  rows <- vapply(seq_along(.SCP_MEASLABEL), function(r) {
    v <- M[, .SCP_MEASFIELD[r]]
    cells <- sprintf("%8d", v)
    cells[v == .SCP_NV] <- "  n/comp"
    cells[v == .SCP_REJ] <- "     rej"
    cells[v == .SCP_ABSENT] <- "  absent"
    paste0("\n", .SCP_MEASLABEL[r], paste(cells, collapse = ""))
  }, "")
  paste0("Parameter  Units", paste(hdr, collapse = ""), paste(rows, collapse = ""), "\n")
}

# The 12 signals written, in the order of .SCP_LEADS.
.scp_order <- function(P) unname(P$L[.SCP_LEADS])

.scp_write_output <- function(P) {
  if (!nzchar(P$recname)) P$recname <- "ecg"      # default record name
  recname <- P$recname
  names <- paste0(recname, c(".des", ".ecg", ".key", ".txt"))
  nf <- if (P$vflag) 4L else 3L
  cons <- vector("list", nf)
  for (k in seq_len(nf)) {
    cons[[k]] <- .app_fopen(names[k], P$pname)
    if (is.null(cons[[k]])) {
      for (c in cons[seq_len(k - 1L)]) .app_fclose(c)
      ceprintf("%s: can't create '%s'\n", P$pname, names[k])
      return(invisible())
    }
  }
  fw <- function(con, fmt, ...) .app_fwrite(con, csprintf(fmt, ...))

  # Write the description file first.
  dfile <- cons[[1L]]
  fw(dfile, paste0(.SCP_VERSION, " description\n"))
  fw(dfile, "Record: %s (%s %s)\n", recname, P$recdate, P$rectime)
  fw(dfile, "Age: %d\n", P$age)
  fw(dfile, "Sex: %s", switch(as.character(P$sex), "1" = "M\n", "2" = "F\n",
                              "0" = "not known\n", "9" = "unspecified\n", "<error>\n"))
  fw(dfile, "Referring Dr: %s\n", P$referring_dr)
  fw(dfile, "Comments: %s\n", P$comments)
  if (P$tdevid == 0) fw(dfile, "Cart ID: <missing>\n") else fw(dfile, "Cart ID: %d\n", P$tdevid)
  dept <- .scp_cstr(P, P$dept)
  fw(dfile, "Department: %s\n", dept)
  if (P$tdept == 0) fw(dfile, "Department #: <missing>\n") else fw(dfile, "Department #: %s\n", dept)
  fw(dfile, "Institution: %s\n", .scp_cstr(P, P$inst))
  if (P$tinst == 0) {
    fw(dfile, "Institution #: <missing>\n")
  } else {
    fw(dfile, "Institution #: %d\n", P$tinst)
  }
  for (i in seq_len(max(P$stmnts, 0)) - 1L) {
    r <- P$report[i + 1]
    fw(dfile, "Report %d: %s\n", i, if (is.na(r)) NULL else .scp_cstr(P, r))
  }
  fw(dfile, "Bandwidth: %g-%d Hz\n", P$blfilt * 0.0001, P$lpfilt)
  fw(dfile, "Filtering:")
  fb <- as.integer(P$filter_bit)
  if (bitwAnd(fb, 1L)) fw(dfile, " 60 Hz notch")
  if (bitwAnd(fb, 2L)) fw(dfile, " 50 Hz notch")
  if (bitwAnd(fb, 4L)) fw(dfile, " Artifact filter")
  if (bitwAnd(fb, 8L)) fw(dfile, " Baseline filter")
  if (bitwAnd(fb, 0xf0L)) fw(dfile, " <undefined>")
  if (fb == 0L) fw(dfile, " <not specified>")
  fw(dfile, "\n\n")
  fw(dfile, "RR interval: %d\n", P$RRint)
  fw(dfile, "P onset: %d\n", P$Pon)
  fw(dfile, "P end: %d\n", P$Pend)
  fw(dfile, "QRS onset: %d\n", P$QRSon)
  fw(dfile, "QRS end: %d\n", P$QRSend)
  fw(dfile, "T end: %d\n", P$Tend)
  fw(dfile, "P axis: %d\n", P$Paxis)
  fw(dfile, "QRS axis: %d\n", P$QRSaxis)
  fw(dfile, "T axis: %d\n", P$Taxis)
  .app_fwrite(dfile, charToRaw(.scp_precgmeas(P)))
  .app_fclose(dfile)            # WFDB-x: reports a write error

  # Generate the key file.
  kfile <- cons[[3L]]
  fw(kfile, paste0(.SCP_VERSION, " key\n"))
  fw(kfile, "Record: %s (%s %s)\n", recname, P$recdate, P$rectime)
  fw(kfile, "Name: %s\n", P$patient_name)
  fw(kfile, "MRN: %s\n", P$patient_id)
  .app_fclose(kfile)

  # Zero-mean the signals (-z).
  if (P$zflag) {
    buf <- integer(.SCP_MINSIGLEN)  # (kept from one lead to the next)
    for (s in seq_len(max(P$nleads, 0)) - 1L) {
      x <- P$ecg[[s + 1]]
      ns <- P$nsamp[s + 1]
      imax <- if (ns < 0 || ns > .SCP_MINSIGLEN) .SCP_MINSIGLEN else ns
      buf[seq_len(imax)] <- sort(x[seq_len(imax)], method = "radix")
      m <- buf[imax %/% 2 + 1]
      k <- ns - 1
      if (k >= 1 && k < length(x) && x[k + 1] == 0L) x[k + 1] <- x[k]
      kk <- seq_len(P$nout)
      v <- cint16(x[kk] - m)
      v[v < -.SCP_ZMAX | v > .SCP_ZMAX] <- .SCP_INVALID
      x[kk] <- as.integer(v)
      .scp_setsig(P, s, x)
    }
  }

  # Write the WFDB-format record if requested (-w option).
  if (P$wflag) .scp_write_wfdb_record(P)

  order <- .scp_order(P)
  # Write the ECG in text form if requested (-v option).
  if (P$vflag) {
    tfile <- cons[[4L]]
    if (P$vflag > 1)
      .app_fwrite(tfile, charToRaw(paste0("samp#      I     II    III    aVR    aVF    aVL",
                                          "     V1     V2     V3     V4     V5     V6")))
    sigs <- lapply(order, function(k) .scp_sig(P, k))
    for (b0 in .scp_blocks(1, P$nout)) {
      kk <- b0:min(b0 + .SCP_CHUNK - 1, P$nout)
      cols <- lapply(sigs, function(s) s[kk])
      txt <- do.call(sprintf, c(list(paste0("%5d", strrep("%7d", 12L), "\n"), kk - 1L), cols))
      .app_fwrite(tfile, charToRaw(paste(txt, collapse = "")))
    }
    .app_fclose(tfile)
  }

  # Finally, output the ECG in vector (binary) form.
  efile <- cons[[2L]]
  fmt <- paste0(.SCP_VERSION, " signals\nRecord: %s (%s %s)\n")
  if (P$lflag) {
    fmt <- paste0(fmt, "Low-pass filtered\n")
    .scp_lowpass(P)
  }
  PROLOG <- 512L                           # bytes of the prolog of the .dat file
  prolog <- csprintf(fmt, recname, P$recdate, P$rectime)
  prolog <- prolog[seq_len(min(length(prolog), PROLOG))]
  .app_fwrite(efile, c(prolog, raw(PROLOG - length(prolog))))
  SEG <- 1250L                 # samples of each lead in a row (2.5 s)
  rows <- list(c(1L, 4L, 7L, 10L), c(2L, 6L, 8L, 11L), c(3L, 5L, 9L, 12L))
  for (r in rows) {            # (I aVR V1 V4) (II aVL V2 V5) (III aVF V3 V6)
    for (k in 0:3) {
      x <- .scp_sig(P, order[r[k + 1L]])
      .app_fwrite(efile, x[SEG * k + seq_len(SEG)], size = 2L, endian = "little")
    }
  }
  .app_fwrite(efile, .scp_sig(P, order[2L])[seq_len(4L * SEG)], size = 2L, endian = "little")
  .app_fclose(efile)
  invisible()
}

.scp_write_wfdb_record <- function(P) {
  recname <- P$recname
  leadname <- c("I", "II", "III", "aVR", "aVF", "aVL", "V1", "V2", "V3", "V4", "V5", "V6")
  # WFDB-x: the sampling frequency is the one given in the SCP file (the C
  # program always wrote 500 Hz, as legacy mode does); without one, no record
  # is written.
  legacy <- wfdbx_get_legacy()
  if (!legacy) {
    if (P$sfreq <= 0) {
      ceprintf("%s: sampling frequency not specified; record %s not written\n",
               P$pname, recname)
      return(invisible())
    }
    setsampfreq(P$sfreq)
  }
  if (newheader(recname) < 0) return(invisible())
  if (legacy) setsampfreq(.SCP_LEGACY_SFREQ)
  s <- lapply(leadname, function(d) {
    siginfo(fname = paste0(recname, ".dat"), desc = d, units = "mV", fmt = 16,
            gain = .SCP_GAIN, adcres = 16, spf = 0)
  })
  if (osigfopen(s, 12) < 12) return(invisible())
  setbasetime(paste0(P$recdate, " ", P$rectime, "\n"))
  sigs <- lapply(.scp_order(P), function(k) .scp_sig(P, k))
  for (b0 in .scp_blocks(1, P$nout)) {
    kk <- b0:min(b0 + .SCP_CHUNK - 1, P$nout)
    putframes(vapply(sigs, function(s) as.numeric(s[kk]), numeric(length(kk))))
  }
  newheader(recname)
  sex <- if (P$sex == 1) "M" else if (P$sex == 2) "F" else "?"
  putinfo(rawToChar(csprintf("<age>: %d <sex>: %s", min(P$age, 90), sex)))
  wfdbquit()
  invisible()
}

# ---------------------------------------------------------------------------
# Sections

.scp_hexdump <- function(P, p, ln) {
  b <- .scp_bytes(P, p, ln)
  i <- seq_along(b) - 1L
  s <- sprintf(" %2x", b)
  st <- i %% 16L == 0L
  s[st] <- paste0(sprintf("\n%4d:  ", i[st]), s[st])
  cout(paste0("Hex dump of data area:\n\n", paste(s, collapse = ""), "\n\n"))
}

.scp_section0 <- function(P, p, ln) {
  vflag <- P$vflag
  if (!identical(.scp_bytes(P, p + 10, 6), as.integer(charToRaw("SCPECG")))) {
    if (vflag) cprintf(" Warning: SCPECG identifier is missing in header\n")
  }
  p <- p + 16
  ln <- ln - 16
  if (ln < 10) {
    if (vflag) cprintf(" Error: section 0 contains no data\n")
    return(invisible())
  }
  ENTLEN <- 10                 # section number, length, index
  nent <- ceiling(ln / ENTLEN)
  if (vflag) {
    E <- matrix(.scp_bytes(P, p, ENTLEN * nent), ENTLEN)
    cout(paste(csprintf_v("  Section %2d:%6ld bytes beginning at byte %6ld\n",
                          E[1L, ] + 256 * E[2L, ], .scp_i32(E, 3L), .scp_i32(E, 7L)),
               collapse = ""))
  }
  ln <- ln - ENTLEN * nent
  if (ln < 0 && vflag) cprintf(" Error: section 0 overlaps the next section\n")
  invisible()
}

# Overwrite (ln - 1) bytes (modulo 2^16) from offset p with c, then a NUL.
.scp_censor <- function(P, p, ln, c) {
  cnt <- (ln - 1) %% 65536
  D <- P$D
  P$D <- NULL
  hi <- min(p + cnt, P$n)
  if (hi > p) D[(p + 1):hi] <- c
  if (p + cnt < P$n) D[p + cnt + 1] <- 0L
  P$D <- D
  invisible()
}

# Section 1 tags: description and type of value.
.SCP_TEXT <- 0L
.SCP_DATE <- 1L
.SCP_TIME <- 2L
.SCP_B1 <- 3L
.SCP_B2 <- 4L
.SCP_B2B1 <- 5L
.SCP_BN <- 6L
.SCP_MIXED <- 7L
.SCP_TAGS <- list(
  list("Last name", .SCP_TEXT), list("First name", .SCP_TEXT),
  list("Patient ID number", .SCP_TEXT), list("Second last name", .SCP_TEXT),
  list("Age", .SCP_B2B1), list("Date of birth", .SCP_DATE), list("Height", .SCP_B2B1),
  list("Weight", .SCP_B2B1), list("Sex", .SCP_B1), list("Race", .SCP_B1),
  list("Drug", .SCP_MIXED), list("Systolic blood pressure", .SCP_B2),
  list("Diastolic blood pressure", .SCP_B2),
  list("Diagnosis or referral indication", .SCP_TEXT),
  list("ID of the acquiring device", .SCP_MIXED),
  list("ID of the analyzing device", .SCP_MIXED), list("Acquiring institution", .SCP_TEXT),
  list("Analyzing institution", .SCP_TEXT), list("Acquiring department", .SCP_TEXT),
  list("Analyzing department", .SCP_TEXT), list("Referring physician", .SCP_TEXT),
  list("Latest confirming physician", .SCP_TEXT), list("Technician", .SCP_TEXT),
  list("Room", .SCP_TEXT), list("Stat code (urgency)", .SCP_B1),
  list("Date of acquisition", .SCP_DATE), list("Time of acquisition", .SCP_TIME),
  list("Baseline filter", .SCP_B2), list("Low-pass filter", .SCP_B2),
  list("Filter bit map", .SCP_B1), list("Free text field (comments)", .SCP_TEXT),
  list("Sequence number", .SCP_TEXT), list("Medical history codes", .SCP_BN),
  list("Electrode configuration code", .SCP_B2), list("Time zone", .SCP_MIXED),
  list("Free text medical history", .SCP_TEXT))

.scp_section1 <- function(P, p, ln) {
  vflag <- P$vflag
  aflag <- P$aflag
  X <- utf8ToInt("x")
  ZERO <- utf8ToInt("0")
  tpatid <- trefdr <- tcomments <- tdate <- ttime <- pyob <- NULL
  firstname <- lastname <- NULL
  p_save <- p
  len_save <- ln
  p <- p + 16
  ln <- ln - 16
  if (ln < 3) {
    if (vflag) cprintf(" Error: section 1 contains no data\n")
    return(invisible())
  }
  while (ln > 2) {
    tag <- .scp_b(P, p)
    if (tag == 255L) break     # tag 255 is the terminator
    vlen <- .scp_g16(P, p + 1)
    if (vlen > ln) {
      if (vflag) cprintf(" Error: tagged field overlaps next section\n")
      return(invisible())
    }
    if (tag < length(.SCP_TAGS)) {
      td <- .SCP_TAGS[[tag + 1L]]
      if (vflag) cprintf("\n  %s\n", td[[1L]])
      vtype <- td[[2L]]
    } else {
      if (vflag) cprintf("\n  <Undefined tag>\n")
      vtype <- .SCP_MIXED
    }
    v <- p + 3                 # the value
    if (tag == 0L) {
      lastname <- v
      if (aflag) .scp_censor(P, v, vlen, X)
    } else if (tag == 1L) {
      firstname <- v
      if (aflag) .scp_censor(P, v, vlen, X)
    } else if (tag == 2L) {
      tpatid <- v
      if (aflag) .scp_censor(P, v, vlen, ZERO)
    } else if (tag == 3L) {
      if (aflag) .scp_censor(P, v, vlen, X)
    } else if (tag == 4L) {
      P$age <- .scp_g16(P, v)
      if (aflag && P$age > 90) .scp_put16(P, 90, v)   # censor age if over 90
    } else if (tag == 5L) {
      if (aflag) {
        pyob <- v
        .scp_put16(P, 257, v + 2)                      # censor month and day
      }
    } else if (tag == 8L) {
      P$sex <- .scp_b(P, v)
    } else if (tag == 14L) {
      P$tdevid <- .scp_g16(P, v + 4)
      P$tinst <- .scp_g16(P, v)                        # institution #
      P$tdept <- .scp_g16(P, v + 2)                    # department #
      if (vflag) .scp_devid(P, v)
    } else if (tag == 16L) {
      P$inst <- v
      if (aflag) .scp_censor(P, v, vlen, X)
    } else if (tag >= 17L && tag <= 23L) {
      if (aflag) .scp_censor(P, v, vlen, X)
      if (tag == 18L) {
        P$dept <- v
      } else if (tag == 20L) {
        trefdr <- v
      }
    } else if (tag == 25L) {
      tdate <- v
      if (aflag) .scp_put16(P, 257, v + 2)             # censor month and day
    } else if (tag == 26L) {
      ttime <- v
    } else if (tag == 27L) {
      P$blfilt <- .scp_g16(P, v)
    } else if (tag == 28L) {
      P$lpfilt <- .scp_g16(P, v)
    } else if (tag == 29L) {
      P$filter_bit <- .scp_b(P, v)
    } else if (tag == 30L) {
      tcomments <- v
    }
    if (vflag) cprintf("   Tag%3d (%2d bytes): ", tag, vlen)
    p <- v
    ln <- ln - (vlen + 3)
    if (vlen == 0) {
      if (vflag) cprintf("<not defined>\n")
      next
    }
    if (vflag) .scp_tagvalue(P, p, vlen, vtype)
    p <- p + vlen
  }

  # (tdate and ttime are pointers to signed char)
  if (!is.null(tdate)) {
    mon <- cint8(.scp_b(P, tdate + 2)) - 1
    P$recdate <- sprintf("%d %s %d", cint8(.scp_b(P, tdate + 3)),
                         if (mon >= 0 && mon < 12) .SCP_MONTH[mon + 1] else "???",
                         .scp_g16(P, tdate))
  }
  if (!is.null(ttime)) {
    P$rectime <- sprintf("%02d:%02d:%02d", cint8(.scp_b(P, ttime)),
                         cint8(.scp_b(P, ttime + 1)), cint8(.scp_b(P, ttime + 2)))
  }
  lastname <- if (is.null(lastname)) charToRaw("<last name missing>") else .scp_cstr(P, lastname)
  firstname <- if (is.null(firstname)) charToRaw("<first name missing>") else .scp_cstr(P, firstname)
  NAMELEN <- 100               # (buffer size, with ", " and the NUL)
  if (length(lastname) + length(firstname) < NAMELEN - 3) {
    P$patient_name <- c(lastname, charToRaw(", "), firstname)
  } else {
    ceprintf("Patient name (%s, %s) is too long\n", lastname, firstname)
    P$patient_name <- charToRaw("Name not available -- too long")
  }
  # (the strings are truncated to the sizes of their buffers)
  field <- function(x, missing, n) {
    x <- .scp_cstr(P, if (is.null(x)) charToRaw(missing) else x)
    x[seq_len(min(length(x), n))]
  }
  P$patient_id <- field(tpatid, "<patient ID missing>", 30L)
  P$referring_dr <- field(trefdr, "<referring physician missing>", 100L)
  P$comments <- field(tcomments, "<comments missing>", 200L)

  if (.scp_b(P, p) != 255L && vflag) cprintf(" Error: header terminator (tag 255) is missing\n")
  # (tpatid cannot be NULL here, so that error is never reported)
  if ((P$tdevid == -1 || P$tinst == -1 || P$tdept == -1) && vflag)
    cprintf(" Error: device ID number (tag 14) is missing\n")
  if (is.null(tdate) && vflag) cprintf(" Error: date of acquisition (tag 25) is missing\n")
  if (is.null(ttime) && vflag) cprintf(" Error: time of acquisition (tag 26) is missing\n")
  if (aflag && !is.null(pyob)) {
    # (the censored year of birth is computed but never stored)
    # Recalculate the CRC for this section.
    .scp_put16(P, .scp_getcrc(P, p_save + 2, len_save - 2), p_save)
  }
  invisible()
}

# Section 1, tag 14 (-v): the description of the acquiring device at v.
.scp_devid <- function(P, v) {
  cprintf("   Institution number: %d\n", .scp_g16(P, v))
  cprintf("   Department number: %d\n", .scp_g16(P, v + 2))
  cprintf("   Device ID: %d\n", .scp_g16(P, v + 4))
  code <- .scp_b(P, v + 6)
  cprintf("   Device type: %d (%s)\n", code,
          if (code == 0L) "cart" else if (code == 1L) "system or host" else "<error>")
  cprintf("   Manufacturer code: %d\n", .scp_b(P, v + 7))
  cprintf("   Text model description: [%d]", .scp_b(P, v + 8))
  cprintf("   SCP-ECG protocol revision number: %g\n", .scp_b(P, v + 14) / 10.0)
  cprintf("   SCP-ECG protocol compatibility level: %d\n", .scp_b(P, v + 15))
  cprintf("   Language support code: %d\n", .scp_b(P, v + 16))
  cprintf("   Device capabilities: %d\n", .scp_b(P, v + 17))
  code <- .scp_b(P, v + 18)
  cprintf("   AC mains frequency environment: %d ", code)
  cprintf(switch(as.character(code), "0" = "(unspecified)\n", "1" = "(50 Hz)\n",
                 "2" = "(60 Hz)\n", "<error>"))
  q <- v + 36
  for (label in c("Analyzing program revision number", "Serial number of acquisition device",
                  "Acquisition device system software ID",
                  "Acquisition device SCP implementation ID",
                  "Manufacturer of acquisition device")) {
    s <- .scp_cstr(P, q)
    cprintf("   %s: [%s]\n", label, s)
    q <- q + length(s) + 1
  }
}

# Section 1 (-v): print a value of vlen (> 0) bytes at p.
.scp_tagvalue <- function(P, p, vlen, vtype) {
  if (vtype == .SCP_TEXT) {
    cprintf("[%*s]", vlen - 1, .scp_cstr(P, p))
  } else if (vtype == .SCP_DATE) {
    if (vlen != 4) {
      cprintf("  Error: incorrect date format (%d bytes)\n", vlen)
    } else {
      cprintf("%4d/%02d/%02d", .scp_g16(P, p), .scp_b(P, p + 2), .scp_b(P, p + 3))
    }
  } else if (vtype == .SCP_TIME) {
    if (vlen != 3) {
      cprintf("  Error: incorrect time format (%d bytes)\n", vlen)
    } else {
      cprintf("%02d:%02d:%02d", .scp_b(P, p), .scp_b(P, p + 1), .scp_b(P, p + 2))
    }
  } else if (vtype == .SCP_B1) {
    if (vlen != 1) {
      cprintf("  Error: incorrect format (%d bytes instead of 1)\n", vlen)
    } else {
      cprintf("%d", .scp_b(P, p))
    }
  } else if (vtype == .SCP_B2) {
    if (vlen != 2) {
      cprintf("  Error: incorrect format (%d bytes instead of 2)\n", vlen)
    } else {
      cprintf("%d", .scp_g16(P, p))
    }
  } else if (vtype == .SCP_B2B1) {
    if (vlen != 3) {
      cprintf("  Error: incorrect format (%d bytes instead of 3)\n", vlen)
    } else {
      cprintf("%d (code %d)", .scp_g16(P, p), .scp_b(P, p + 2))
    }
  } else if (vtype == .SCP_BN) {
    cout(paste0(.scp_bytes(P, p, vlen), ", ", collapse = ""))
  } else {
    cout(paste0(.scp_escaped(.scp_bytes(P, p, vlen)), "\n"))
  }
}

.scp_section2 <- function(P, p, ln) {
  p <- p + 16
  ln <- ln - 16
  if (ln < 2) {
    if (P$vflag) cprintf("  Error: section 2 contains no data\n")
    return(invisible())
  }
  if (.scp_g16(P, p) == .SCP_DEFHUFF) {
    if (P$vflag) cprintf("  Using standard Huffman table only\n")
  } else if (P$vflag) {
    cprintf("  Number of Huffman tables defined: %d\n", .scp_g16(P, p))
    cprintf("  Number of code structures in table 1: %d\n", .scp_g16(P, p + 2))
  }
  invisible()
}

.scp_section3 <- function(P, p, ln) {
  vflag <- P$vflag
  nsmax <- 0
  p <- p + 16
  ln <- ln - 16
  if (ln < 2) {
    if (vflag) cprintf("  Error: section3 contains no data\n")
    return(invisible())
  }
  nleads <- .scp_b(P, p)
  P$nleads <- nleads
  p <- p + 1
  if (vflag) cprintf("  Number of leads: %d\n", nleads)
  ln <- ln - 1
  nsamp <- numeric(nleads + 4)
  flags <- .scp_b(P, p)
  if (vflag) {
    cprintf("  Flag byte: %xH\n", flags)
    cprintf(if (bitwAnd(flags, 1L)) "   Reference beat subtraction used for compression\n"
            else "   Reference beat subtraction not used for compression\n")
    if (bitwAnd(flags, 4L)) {
      cprintf("   All leads recorded simultaneously\n")
    } else {
      cprintf("   %d leads recorded simultaneously\n", bitwAnd(bitwShiftR(flags, 3L), 15L))
    }
  }
  ln <- ln - 1
  p <- p + 1

  # the leads: 9 bytes each (first sample, last sample, lead ID)
  ENTLEN <- 9
  nent <- max(0, ceiling((ln - 8) / ENTLEN))
  if (nent > 0) {
    E <- matrix(.scp_bytes(P, p, ENTLEN * nent), ENTLEN)
    s0 <- .scp_i32(E, 1L)
    s1 <- .scp_i32(E, 5L)
    ids <- E[9L, ]
    if (vflag) {
      nm <- ifelse(ids < length(.SCP_LEADNAME), .SCP_LEADNAME[pmin(ids, 85L) + 1L],
                   ifelse(ids < 100L, "<Reserved lead>", "<Manufacturer-defined lead>"))
      cout(paste(csprintf_v("  %s: ID %d, samples %lu to %lu\n", nm, ids, s0, s1), collapse = ""))
    }
    for (k in seq_along(.SCP_LEADIDS)) {   # (the last entry of a lead counts)
      w <- which(ids == .SCP_LEADIDS[k])
      if (length(w)) P$L[k] <- w[length(w)] - 1
    }
    if (nent > length(nsamp)) length(nsamp) <- nent
    nsamp[seq_len(nent)] <- s1 - s0 + 1
    ln <- ln - ENTLEN * nent
  }

  # allocate space for 4 extra signals that will be calculated later
  ecg <- vector("list", nleads + 5L)
  P$ecg <- ecg
  for (i in seq_len(nleads + 4L) - 1L) {
    if (i >= nleads) {
      nsamp[i + 1] <- nsmax
    } else if (.scp_ugt(nsamp[i + 1], nsmax)) {
      nsmax <- cint32(nsamp[i + 1])
    }
    if (nsamp[i + 1] == 0) nsamp[i + 1] <- 1
    P$nsamp <- nsamp
    s <- .scp_newsig(nsamp[i + 1])
    if (is.null(s)) {
      if (vflag) cprintf("  Error: too many (%d) leads\n", nleads)
      P$ecg <- ecg
      return(invisible())
    }
    ecg[[i + 1L]] <- s
  }
  P$ecg <- ecg
  P$nsamp <- nsamp
  invisible()
}

.scp_section4 <- function(P, p, ln) {
  vflag <- P$vflag
  p <- p + 16
  ln <- ln - 16
  if (ln < 6) {
    if (vflag) cprintf("  Error: section 4 contains no data\n")
    return(invisible())
  }
  P$rblenms <- .scp_g16(P, p)
  P$fcM <- .scp_g16(P, p + 2)
  nqrs <- .scp_g16(P, p + 4)
  P$nqrs <- nqrs
  if (vflag) {
    cprintf("  Length of reference beat type 0 data: %ld msec\n", P$rblenms)
    cprintf("  Sample # of fiducial relative to start of ref beat type 0: %d\n", P$fcM)
    cprintf("  Number of QRS complexes in the entire record: %d\n", nqrs)
  }
  if (nqrs < 1) return(invisible())   # no beats -- nothing else to do here
  p <- p + 6
  ln <- ln - 6
  # the reference beat subtraction zones (NA: missing)
  P$zone <- list(type = rep(NA_real_, nqrs), t0 = numeric(nqrs), t1 = numeric(nqrs),
                 t2 = numeric(nqrs))
  ZLEN <- 14
  if (ln >= nqrs * ZLEN) {
    if (vflag) cprintf("  Reference beat subtraction zones:\n")
    E <- matrix(.scp_bytes(P, p, ZLEN * nqrs), ZLEN)
    ty <- cint16(E[1L, ] + 256 * E[2L, ])
    t <- lapply(c(3L, 7L, 11L), function(r) .scp_i32(E, r))
    ty[ty == 0 & t[[3L]] == 0] <- 9
    P$zone <- list(type = ty, t0 = t[[1L]], t1 = t[[2L]], t2 = t[[3L]])
    if (vflag) {
      line <- sprintf("   %2d  Type: %2d  start: %7d  fiducial: %7d  end: %7d\n",
                      seq_len(nqrs), ty, t[[1L]], t[[2L]], t[[3L]])
      bad <- ty != 0 & (t[[1L]] != 0 | t[[3L]] != 0)
      line[bad] <- paste0(line[bad],
                          "  Error: start and end should be zero for beats of non-zero types\n")
      cout(paste(line, collapse = ""))
    }
    p <- p + ZLEN * nqrs
    ln <- ln - ZLEN * nqrs
  } else if (vflag) {
    cprintf("  Error: reference beat subtraction zones are missing\n")
  }
  QLEN <- 8
  if (ln >= nqrs * QLEN) {
    if (vflag) {
      cprintf("  QRS locations:\n")
      E <- matrix(.scp_bytes(P, p, QLEN * nqrs), QLEN)
      # (sign-extended, then printed as unsigned long)
      cout(paste(csprintf_v("   %2d  start: %7lu  end: %7lu\n", seq_len(nqrs), .scp_i32(E, 1L),
                            .scp_i32(E, 5L)),
                 collapse = ""))
    }
  } else if (vflag) {
    cprintf("  Error: QRS locations are missing\n")
  }
  invisible()
}

.scp_section5 <- function(P, p, ln) {
  p <- p + 16
  ln <- ln - 16
  if (ln <= 0) {
    if (P$vflag) cprintf(" Error: section 5 contains no data\n")
    return(invisible())
  }
  # Calculate length of template in samples
  d <- .scp_g16(P, p + 2)
  x <- P$rblenms * 1000.0
  x <- if (d) x / d else if (x == 0) NaN else Inf
  rblen <- d2l(x)
  P$rblen <- rblen
  nleads <- P$nleads
  refbeat <- vector("list", max(nleads + 1, 0))
  for (i in seq_len(max(nleads, 0))) {
    if (rblen < 0 || rblen > .SCP_MAXALLOC) {
      ceprintf("  Error: too many (%d) leads\n", nleads)
      P$refbeat <- refbeat
      return(invisible())
    }
    refbeat[[i]] <- integer(rblen)
  }
  P$refbeat <- refbeat
  .scp_huffdecode(P, p, ln, 5L)
}

.scp_section6 <- function(P, p, ln) {
  p <- p + 16
  ln <- ln - 16
  if (ln <= 6) {
    if (P$vflag) cprintf(" Error: section 6 contains no data\n")
    return(invisible())
  }
  .scp_huffdecode(P, p, ln, 6L)
}

# Decode the values encoded with the default Huffman table of the SCP
# standard from the bits that begin at the MSB of the byte at p, while
# fewer than nmax values have been decoded and fewer than tbits bits read
# (as successive getbits() calls do).  Returns list(x = values, nb =
# number of bits read).
#
# A code is a run of r one bits (r <= 10) and, for r < 9, a zero bit;
# r = 0 is the value 0, 1 <= r <= 8 is +-r (then a sign bit: 1 for -r),
# r = 9 an 8-bit and r = 10 a 16-bit two's complement value.  The codes
# that are decoded (those that begin where the previous one ends) are
# found with pointer doubling.
.scp_huffvals <- function(P, p, tbits, nmax) {
  if (nmax <= 0 || tbits <= 0) return(list(x = numeric(0), nb = 0))
  MAXCODE <- 26                # longest code (bits)
  nbytes <- ceiling(tbits / 8) + ceiling(MAXCODE / 8) + 1
  by <- .scp_bytes(P, p, nbytes)
  B <- as.integer(matrix(rawToBits(as.raw(by)), 8L)[8:1, ])   # MSB first
  L <- length(B)
  # number of one bits from each position (up to the next zero)
  zpos <- seq_len(L)
  zpos[B == 1L] <- L + 1L
  nz <- rev(cummin(rev(zpos)))             # next zero (1-based)
  r <- nz[seq_len(tbits)] - seq_len(tbits)
  len <- ifelse(r == 0L, 1L, ifelse(r <= 8L, r + 2L, ifelse(r == 9L, 18L, MAXCODE)))
  # the chain of codes from position 0
  nxt <- c(pmin(seq_len(tbits) + len, tbits + 1L), tbits + 1L)
  on <- logical(tbits + 1L)
  on[1L] <- TRUE
  J <- nxt
  while (J[1L] <= tbits) {
    on[J[on]] <- TRUE
    J <- J[J]
  }
  on[J[on]] <- TRUE
  s <- which(on[seq_len(tbits)])           # 1-based starts
  if (length(s) > nmax) s <- s[seq_len(nmax)]
  nb <- s[length(s)] - 1 + len[s[length(s)]]
  rs <- pmin(r[s], 10L)
  x <- numeric(length(s))
  k <- rs >= 1L & rs <= 8L
  x[k] <- rs[k] * (1 - 2 * B[s[k] + rs[k] + 1L])
  w <- function(k, nbits) {                # the nbits bits after the prefix
    v <- numeric(length(k))
    for (q in seq_len(nbits)) v <- 2 * v + B[s[k] + 9L + q]
    v - 2^nbits * (v >= 2^(nbits - 1))
  }
  k <- which(rs == 9L)
  if (length(k)) x[k] <- w(k, 8L)
  k <- which(rs == 10L)
  if (length(k)) x[k] <- w(k, 16L)
  list(x = x, nb = nb)
}

.scp_huffdecode <- function(P, p, ln, section) {
  vflag <- P$vflag
  g <- .scp_g16(P, p)
  # (in units of the 5 uV (5000 nV) amplitude of the output)
  if (section == 5L) P$gref <- g / 5000.0 else P$gres <- g / 5000.0
  if (vflag) cprintf("  Amplitude value multiplier: %g nanovolts per unit\n", g)
  sampint <- .scp_g16(P, p + 2)
  if (vflag) cprintf("  Sample time interval: %d microseconds\n", sampint)
  if (sampint > 0) {
    if (P$sfreq > 0 && P$sfreq != 1.0e6 / sampint)
      cprintf("Warning: section 5 and 6 sample intervals don't match")
    P$sfreq <- 1.0e6 / sampint
  } else if (wfdbx_get_legacy()) {   # WFDB-x: as in the C program
    cprintf("Error: sampling frequency not specified;  assuming 500 Hz\n")
    P$sfreq <- .SCP_LEGACY_SFREQ
  } else {                     # WFDB-x: the C program assumed 500 Hz
    cprintf("Error: sampling frequency not specified\n")
  }
  # (sic: bytes 3 and 4, see docs/KNOWN_C_BEHAVIORS.md)
  code <- .scp_b(P, p + 3)
  if (vflag) cprintf("  Encoding type: %d ", code)
  if (code <= 2L) {
    if (vflag) cprintf(c("(amplitudes)\n", "(first differences)\n", "(second differences)\n")[code + 1L])
    enctype <- code
  } else {
    if (vflag) cprintf("<undefined, assuming second differences>\n")
    enctype <- 2L
  }
  if (section == 6L && vflag) {
    code <- .scp_b(P, p + 4)
    cprintf("  Compression type: %d ", code)
    cprintf(if (code == 0L) "(non-bimodal)\n" else if (code == 1L) "(bimodal)\n"
            else "<undefined, assuming bimodal>\n")
  }
  p <- p + 6
  ln <- ln - 6

  nleads <- P$nleads
  if (nleads < 0) {
    if (vflag) cprintf("  Error: number of leads undefined -- section 3 missing or out of order\n")
    return(invisible())
  }
  if (nleads == 0) {
    if (vflag) cprintf("  Error: no leads recorded\n")
    return(invisible())
  }
  leadlen <- .scp_words(P, p, nleads)
  tleadlen <- sum(leadlen)
  if (vflag) cout(paste(sprintf("  Lead %d:%5d bytes\n", seq_len(nleads) - 1L, leadlen),
                        collapse = ""))
  p <- p + 2 * nleads
  ln <- ln - 2 * nleads
  if (ln >= 0 && ln < tleadlen) {
    if (vflag) {
      d <- tleadlen - ln
      cprintf("  Error: %lu data byte%s missing from section %d\n", d, .scp_plural(d), section)
    }
    return(invisible())
  } else if (ln < 0 || ln > tleadlen + tleadlen %% 2) {
    if (vflag) {
      d <- ln - tleadlen
      cprintf("  Warning: %lu extra byte%s in section %d\n", d, .scp_plural(d), section)
    }
  }

  for (i in seq_len(nleads) - 1L) {
    if (vflag) {
      cprintf("  Lead %d data\n", i)
      cout(paste0(paste(sprintf(" %02x", .scp_bytes(P, p, 10)), collapse = ""), "\n"))
    }
    if (section == 6L) {
      explen <- cint32(P$nsamp[i + 1])
      dest <- if (is.null(P$ecg)) NULL else P$ecg[[i + 1]]
      gain <- P$gres
    } else {
      explen <- cint32(P$rblen)
      dest <- P$refbeat[[i + 1]]
      gain <- P$gref
    }
    tbits <- leadlen[i + 1] * 8
    h <- .scp_huffvals(P, p, tbits, explen)
    x <- h$x
    j <- length(x)
    if (j > 0) {
      S <- cumsum(x)
      xx <- cint16(S)
      xxx <- x
      if (j >= 2) {
        dx <- cint16(S[-1L] - 2 * x[1L])
        xxx[-1L] <- cint16(x[2L] + c(0, cumsum(dx[-1L])))
      }
      xout <- if (enctype == 0L) x else if (enctype == 1L) xx else xxx
      if (!is.null(dest)) {
        m <- min(j, length(dest))
        dest[seq_len(m)] <- .scp_d2s(xout[seq_len(m)] * gain)
        if (section == 6L) {
          .scp_setsig(P, i, dest)
        } else {
          rb <- P$refbeat
          rb[[i + 1]] <- dest
          P$refbeat <- rb
        }
      }
      if (vflag > 1) cout(paste(sprintf("   %5d %5d %5d %5d\n", seq_len(j) - 1L, x, xx, xxx),
                                collapse = ""))
    }
    if (j < explen && vflag) {
      d <- leadlen[i + 1] - j
      cprintf("   Error: %ld sample%s missing in lead %d\n", d, .scp_plural(d), i)
    }
    if (h$nb < tbits && vflag) {
      d <- tbits - h$nb
      cprintf("   Warning: %ld extra bit%s in lead %d\n", d, .scp_plural(d), i)
    }
    p <- p + leadlen[i + 1]
    if (vflag) cprintf("\n")
  }
  invisible()
}

.scp_section7 <- function(P, p, ln) {
  vflag <- P$vflag
  p <- p + 16
  ln <- ln - 16
  if (ln <= 0) {
    if (vflag) cprintf(" Error: section 7 contains no data\n")
    return(invisible())
  }
  if (P$xflag && vflag) .scp_hexdump(P, p, ln)
  if (ln < 20) {               # there isn't enough room left for measurements
    if (vflag) cprintf(" Error: section 7 is too short (len = %ld)\n", ln)
    return(invisible())
  }
  P$RRint <- .scp_g16(P, p + 2)
  # get P onset, etc from first measurement block
  q <- p + 6
  P$Pon <- .scp_g16(P, q)
  P$Pend <- .scp_g16(P, q + 2)
  P$QRSon <- .scp_g16(P, q + 4)
  P$QRSend <- .scp_g16(P, q + 6)
  P$Tend <- .scp_g16(P, q + 8)
  P$Paxis <- cint16(.scp_g16(P, q + 10))
  P$QRSaxis <- cint16(.scp_g16(P, q + 12))
  P$Taxis <- cint16(.scp_g16(P, q + 14))

  nmb <- .scp_b(P, p)
  nps <- .scp_b(P, p + 1)
  off <- cint16(6 + 16 * nmb + 10 * nps)
  if (off > ln) off <- cint16(ln)
  if (off > ln) {
    if (vflag) cprintf(" Error: section 7 is too short (nmb = %d, nps = %d)\n", nmb, nps)
    return(invisible())
  }
  sec7qrs <- .scp_g16(P, p + off) %% 256
  if (!vflag) return(invisible())

  cprintf(" QRS complexes measured: %d\n", sec7qrs)
  cprintf(" Measurement blocks: %d\n", nmb)
  if (nmb == sec7qrs + 1) {
    cprintf(paste0("  (First measurement block contains measurements for reference beat type 0;\n",
                   "   Others contain measurements for each individual beat)\n"))
  } else {
    cprintf("  (Measurements for each reference beat type)\n")
  }
  cprintf("  Number of measurement blocks: %d\n", nmb)
  cprintf("  Number of pacemaker spikes: %d\n", nps)
  cprintf("  Mean RR interval: %d ms\n", P$RRint)
  cprintf("  Mean PP interval: %d ms\n", .scp_g16(P, p + 4))
  q <- p + 6
  labels <- c("P axis:   ", "QRS axis: ", "T axis:   ")
  for (i in seq_len(nmb) - 1L) {
    cprintf("   Block %d\n", i)
    cprintf("    P onset:   %d ms\n", .scp_g16(P, q))
    cprintf("    P end:     %d ms\n", .scp_g16(P, q + 2))
    cprintf("    QRS onset: %d ms\n", .scp_g16(P, q + 4))
    cprintf("    QRS  end:  %d ms\n", .scp_g16(P, q + 6))
    cprintf("    T end:     %d ms\n", .scp_g16(P, q + 8))
    for (k in 1:3) {
      n <- cint16(.scp_g16(P, q + 8 + 2 * k))
      if (n == 999) {                       # (999: undefined)
        cprintf("    %s undefined\n", labels[k])
      } else {
        cprintf("    %s %d degrees\n", labels[k], n)
      }
    }
    q <- q + 16
  }
  if (nps > 0) cprintf(" Pacemaker spike measurement data\n")
  r <- q + nps * 4
  for (i in seq_len(nps) - 1L) {
    cprintf("Spike %d: %u ms, %d microvolts ", i, .scp_g16(P, q), .scp_g16(P, q + 2))
    code <- .scp_b(P, r)
    if (code <= 3L) {
      cprintf(c("(unknown spike type, ", "(triggers neither P nor QRS, ", "(triggers a QRS, ",
                "(triggers a P, ")[code + 1L])
    } else {
      cprintf("(spike type %d, ", code)
    }
    code <- .scp_b(P, r + 1)
    if (code <= 2L) {
      cprintf(c("source unknown, ", "internal, ", "external, ")[code + 1L])
    } else {
      cprintf("source type %d, ", code)
    }
    n <- cint16(.scp_g16(P, r + 2))
    if (n == 0) cprintf(" not linked to a QRS, ") else cprintf(" linked to QRS #%d, ", n)
    n <- cint16(.scp_g16(P, r + 4))
    if (n == 0) cprintf("width unknown)\n") else cprintf("%d microseconds\n)", n)
    q <- q + 4
    r <- r + 6
  }
  # The next part doesn't seem to be right ...
  cprintf(" <!> sec7qrs = <%d>\n", sec7qrs)
  if (sec7qrs > 0) cprintf(" QRS type information (%d beats)\n", .scp_g16(P, r))
  q <- r + 2
  if (sec7qrs > 0)
    cout(paste(sprintf("  QRS %d: reference beat type %d\n", seq_len(sec7qrs) - 1L,
                       .scp_bytes(P, q, sec7qrs)), collapse = ""))
  q <- q + sec7qrs
  cprintf("%ld bytes remaining in section 7\n", ln - (q - p))
  nrem <- p + ln - q
  if (nrem > 0) {
    # get16(q) reads one byte past the end of the section at the last
    # iteration (read as 0 beyond the end of the data)
    b <- .scp_bytes(P, q, nrem + 1)
    w <- b[seq_len(nrem)] + 256 * b[seq_len(nrem) + 1L]
    cout(paste(sprintf(" %5d [%3d]", w, b[seq_len(nrem)]), collapse = ""))
  }
  cout("\n")
  invisible()
}

.scp_section8 <- function(P, p, ln) {
  vflag <- P$vflag
  p <- p + 16
  ln <- ln - 16
  if (ln <= 0) {
    if (vflag) cprintf(" Error: section 8 contains no data\n")
    return(invisible())
  }
  if (vflag) {
    code <- .scp_b(P, p)
    cprintf(" Status: %d ", code)
    cprintf(if (code <= 2L) c("(original report, not confirmed)\n", "(confirmed report)\n",
                           "(overread report, but not confirmed)\n")[code + 1L] else "<undefined>\n")
    cprintf(" Date: %4d/%02d/%02d\n", .scp_g16(P, p + 1), .scp_b(P, p + 3), .scp_b(P, p + 4))
    cprintf(" Time: %02d:%02d:%02d\n", .scp_b(P, p + 5), .scp_b(P, p + 6), .scp_b(P, p + 7))
  }
  n <- .scp_b(P, p + 8)
  P$stmnts <- n
  if (vflag) cprintf(" Number of statements: %d\n", n)
  p <- p + 9
  ln <- ln - 9
  i <- 0
  report <- P$report
  while (i < n && ln > 2) {
    report[i + 1] <- p + 3
    slen <- .scp_g16(P, p + 1)
    if (vflag) {
      cprintf("  Statement %2d: (%d bytes)\n", .scp_b(P, p), slen)
      cprintf("   [%*s]\n", slen, .scp_cstr(P, p + 3))
    }
    p <- p + slen + 3
    ln <- ln - (slen + 3)
    i <- i + 1
  }
  P$report <- report
  if (i < n && vflag) cprintf("  Error: data missing in section 8\n")
  invisible()
}

.scp_section9 <- function(P, p, ln) {
  p <- p + 16
  ln <- ln - 16
  if (ln <= 0) {
    if (P$vflag) cprintf(" Error: section 9 contains no data\n")
    return(invisible())
  }
  if (P$vflag) cout(paste0("  Data:\n   ", .scp_escaped(.scp_bytes(P, p, ln)), "\n"))
  invisible()
}

.scp_section10 <- function(P, p, ln) {
  p <- p + 16
  ln <- ln - 16
  if (ln <= 0) {
    if (P$vflag) cprintf(" Error: section 10 contains no data\n")
    return(invisible())
  }
  nsecleads <- .scp_g16(P, p)
  P$nsecleads <- nsecleads
  M <- matrix(0, nsecleads, .SCP_NMEAS)
  p <- p + 4
  for (i in seq_len(nsecleads)) {
    v <- cint16(.scp_words(P, p, .SCP_NMEAS))
    M[i, ] <- v
    p <- p + v[2L] + 4         # (vlen)
  }
  P$ecgmeas <- M
  if (P$vflag) {
    cprintf(" Results for %d leads\n", nsecleads)
    cout(.scp_precgmeas(P))
  }
  invisible()
}

.scp_section11 <- function(P, p, ln) {
  if (ln - 16 <= 0 && P$vflag) cprintf(" Error: section 11 contains no data\n")
  invisible()
}

.SCP_SECTIONS <- c(".scp_section0", ".scp_section1", ".scp_section2", ".scp_section3",
                   ".scp_section4", ".scp_section5", ".scp_section6", ".scp_section7",
                   ".scp_section8", ".scp_section9", ".scp_section10", ".scp_section11")

# ---------------------------------------------------------------------------
# Main

# The parser state (the global variables of the C program).
.scp_new <- function(pname) {
  P <- new.env(parent = emptyenv())
  P$pname <- pname
  P$D <- integer(0)
  P$n <- 0
  P$aflag <- P$bflag <- P$fflag <- P$lflag <- P$tflag <- 0
  P$vflag <- P$wflag <- P$xflag <- P$zflag <- 0
  P$shift <- 0
  P$skip <- logical(12)
  P$nleads <- -1
  P$nqrs <- -1
  P$nsamp <- numeric(0)
  P$rblen <- 0
  P$rblenms <- 0
  P$fcM <- 0
  P$gref <- P$gres <- 0
  P$sfreq <- -1.0
  P$recdate <- ""
  P$rectime <- ""
  P$recname <- ""
  P$patient_name <- raw(0)
  P$referring_dr <- raw(0)
  P$comments <- raw(0)
  P$patient_id <- raw(0)
  P$age <- -1
  P$sex <- -1
  P$RRint <- P$Pon <- P$Pend <- P$QRSon <- P$QRSend <- P$Tend <- -1
  P$Paxis <- P$QRSaxis <- P$Taxis <- 999
  P$blfilt <- P$lpfilt <- P$filter_bit <- -1
  P$tdevid <- P$tinst <- P$tdept <- -1
  P$dept <- charToRaw("<missing>")     # string, or offset of a C string
  P$inst <- charToRaw("<missing>")
  P$stmnts <- -1
  P$report <- rep(NA_real_, 1200)         # (char *report[1200] in C)
  P$zone <- NULL               # reference beat subtraction zones (section 4)
  P$ecg <- NULL
  P$refbeat <- list()
  P$L <- structure(rep(-1, 12), names = .SCP_LEADS)   # lead indices
  P$ecgmeas <- matrix(0, 0, .SCP_NMEAS)
  P$nsecleads <- 0
  P$nout <- 0
  P
}

.scp_main <- function(argv) {
  pname <- sub(".*/", "", argv[1L])
  P <- .scp_new(pname)
  argc <- length(argv)
  i <- 2L
  while (i <= argc) {
    a <- argv[i]
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "a") {
        P$aflag <- 1
        P$xflag <- P$vflag <- 0
      } else if (c == "b") {
        P$bflag <- 1
        P$tflag <- 0
      } else if (c == "f") {
        P$fflag <- 1
      } else if (c == "h") {
        .scp_help(pname)
        cexit(1)
      } else if (c == "l") {
        P$lflag <- 1
      } else if (c == "o") {
        i <- i + 1L
        if (i <= argc && nchar(argv[i], type = "bytes") <= 11L) {
          P$recname <- argv[i]
        } else {
          ceprintf("%s: a record name of 11 or fewer alphanumericcharacters must\n follow -o\n",
                   pname)
          cexit(1)
        }
      } else if (c == "s") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: number of samples to shift templates must follow -s\n", pname)
          cexit(1)
        }
        P$shift <- atoi(argv[i])
      } else if (c == "S") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: number of section to skip, or '-', must follow -S\n", pname)
          cexit(1)
        }
        if (startsWith(argv[i], "-")) {
          P$skip[] <- TRUE
        } else {
          index <- atoi(argv[i])
          if (index >= 0 && index <= 11) P$skip[index + 1] <- !P$skip[index + 1]
        }
      } else if (c == "t") {
        P$tflag <- 1
        P$bflag <- 0
      } else if (c == "v") {
        P$vflag <- P$vflag + 1
        P$aflag <- 0
      } else if (c == "w") {
        P$wflag <- P$wflag + 1
      } else if (c == "x") {
        P$xflag <- P$vflag <- 1
        P$aflag <- 0
      } else if (c == "z") {
        P$zflag <- P$zflag + 1
      } else {
        ceprintf("%s: unrecognized option '%s'\n", pname, a)
        .scp_help(pname)
        cexit(1)
      }
    } else {
      ceprintf("%s: unrecognized argument '%s'\n", pname, a)
      .scp_help(pname)
      cexit(1)
    }
    i <- i + 1L
  }

  vflag <- P$vflag
  HDRLEN <- 6                  # CRC and record length
  input <- stdin_bytes()
  if (length(input) < HDRLEN) {
    ceprintf("%s: input too short (only %lu bytes)\n", pname, length(input))
    cexit(1)
  }
  P$D <- as.integer(input[seq_len(HDRLEN)])
  P$n <- HDRLEN
  crc <- .scp_g16(P, 0)
  reclen <- .scp_g32(P, 2)
  if (vflag) cprintf("CRC = %d, expected length = %ld bytes\n", crc, reclen)
  if (reclen < 0) {
    ceprintf("%s: insufficient memory (%ld bytes needed)\n", pname, reclen)
    cexit(2)
  }
  bytesread <- max(HDRLEN, min(reclen, length(input)))
  if (bytesread < reclen) {
    d <- reclen - bytesread
    ceprintf("%s: input too short (%lu byte%s missing)\n", pname, d, .scp_plural(d))
    cexit(3)
  }
  P$D <- as.integer(input[seq_len(bytesread)])
  P$n <- bytesread
  if (vflag) cprintf("Record length: %ld bytes\n", reclen)
  .scp_crcok(P, 2, reclen - 2, crc, "Top-level CRC")

  # Now check the sections.
  SECHDR <- 8                  # minimum section length (its header)
  p <- HDRLEN                  # skip the record header -- p points to section 0
  while (p < reclen) {         # true if there is at least 1 more section
    crc <- .scp_g16(P, p)
    sec_id <- .scp_g16(P, p + 2)
    sec_len <- .scp_g32(P, p + 4)
    if (vflag) cprintf("\nSection %d length: %ld bytes\n", sec_id, sec_len)
    if (sec_len >= 0 && sec_len < SECHDR) {
      if (vflag) {
        cprintf(paste0(" Warning: section length too short (must be at least 8 bytes)\n",
                       "  Remaining data (%lu bytes) following short section will not be read\n"),
                reclen - (p + SECHDR))
      }
      sec_len <- SECHDR
    }
    if (sec_len < 0 || sec_len > reclen - p) {
      if (vflag) cprintf(paste0(" Warning: section length exceeds amount of remaining data\n",
                                "  This section will not be parsed\n"))
      break
    }
    .scp_crcok(P, p + 2, sec_len - 2, crc, rawToChar(csprintf(" Section %d CRC", sec_id)))
    if (vflag) {
      cprintf(" Section version number: %d\n", .scp_b(P, p + 8))
      cprintf(" Protocol version number: %d\n", .scp_b(P, p + 9))
      cprintf(" Contents: ")
    }
    if (sec_id < 12) {
      if (vflag) cprintf(.SCP_CONTENTS[sec_id + 1])
      if (P$skip[sec_id + 1]) {
        cprintf("  [skipped]\n")
      } else {
        get(.SCP_SECTIONS[sec_id + 1])(P, p, sec_len)
      }
    } else if (vflag) {
      cprintf(" Manufacturer-defined (non-standard) section %d\n", sec_id)
    }
    p <- p + sec_len
  }

  .scp_filter_residuals(P)
  if (P$bflag == 0) .scp_add_refbeats(P)       # (true unless -b was given)
  .scp_fill_signals(P)
  .scp_derive_leads(P)

  if (P$aflag) {
    # Recalculate the top-level CRC.
    .scp_put16(P, .scp_getcrc(P, 2, bytesread - 2), 0)
    cout(as.raw(P$D[seq_len(bytesread)]))
  } else if (P$nleads > 0) {
    .scp_write_output(P)
  }
  0
}

# The reference beat subtraction zones of the last section 4 that gave a
# number of QRS complexes, or NULL.
.scp_zones <- function(P) if (P$nqrs >= 1) P$zone else NULL

# Low-pass filter the residuals (or with -t, replace them with zeros).
.scp_filter_residuals <- function(P) {
  z <- .scp_zones(P)
  for (i in seq_len(max(P$nleads, 0)) - 1L) {
    inp <- P$ecg[[i + 1]]
    if (is.null(inp)) next
    n <- P$nsamp[i + 1]
    out <- .scp_newsig(n)
    if (is.null(out)) {
      ceprintf("Insufficient memory for filtering\n")
      break
    }
    if (P$tflag == 0) {        # true unless -t was given
      out[1L] <- inp[1L]
      if (n - 1 > 1) {
        for (b0 in .scp_blocks(2, n - 1)) {
          j <- b0:min(b0 + .SCP_CHUNK - 1, n - 1)    # (1-based)
          v <- inp[j - 1] + inp[j] + inp[j + 1]
          y <- integer(length(v))
          y[v > 0] <- (v[v > 0] + 2L) %/% 3L
          y[v < 0] <- -((2L - v[v < 0]) %/% 3L)
          out[j] <- y
        }
      }
      je <- max(n - 1, 1)
      out[je + 1] <- inp[je + 1]
      if (!is.null(z)) {
        # restore unfiltered samples within protected zones and adjacent
        # samples on either end of them
        k <- which(!is.na(z$type) & z$type == 0)
        lo <- pmax(z$t0[k] - 1, 0)
        hi <- pmin(z$t2[k] + 2, length(out))
        k <- hi > lo
        if (any(k)) {
          cnt <- numeric(length(out) + 1)
          cnt <- cnt + tabulate(lo[k] + 1, length(out) + 1) - tabulate(hi[k] + 1, length(out) + 1)
          prot <- cumsum(cnt)[seq_along(out)] > 0
          out[prot] <- inp[prot]
        }
      }
    }
    .scp_setsig(P, i, out)
  }
  invisible()
}

# Add the reference beats back into the residuals.
.scp_add_refbeats <- function(P) {
  z <- .scp_zones(P)
  nleads <- P$nleads
  if (is.null(z) || nleads <= 0) return(invisible())
  rblen <- P$rblen
  for (k in which(!is.na(z$type) & z$type == 0)) {
    t0 <- z$t0[k]
    t1 <- z$t1[k]
    t2 <- z$t2[k]
    m <- if (t2 - t0 + 1 > rblen) -1 else cint32(P$fcM - t1 + t0 - 1)
    if (m < 0) {
      ceprintf("error: subtraction zone is larger than template\n")
      cexit(1)
    }
    for (i in seq_len(nleads) - 1L) {
      s <- P$ecg[[i + 1]]
      # WFDB-x: a reference beat that was not allocated (e.g. section 3
      # follows section 5 and gives more leads) is absent
      ref <- if (i < length(P$refbeat)) P$refbeat[[i + 1]] else NULL
      if (is.null(s) || is.null(ref)) next
      j <- t0 - 1 + P$shift
      jend <- t2 - 1 + P$shift
      mm <- m
      if (j < 0) {             # skip samples before the start of the signal
        mm <- mm - j
        j <- 0
      }
      cnt <- min(jend - j + 1, length(s) - j, length(ref) - mm)
      if (cnt > 0) {
        kk <- seq_len(cnt)
        s[j + kk] <- as.integer(cint16(s[j + kk] + ref[mm + kk]))
        .scp_setsig(P, i, s)
      }
    }
  }
  invisible()
}

# WFDB-x: signals that could not be allocated (undefined behavior in C)
# are read as zeros, and so are samples beyond the end of a signal shorter
# than lead 0.
.scp_fill_signals <- function(P) {
  if (is.null(P$ecg)) return(invisible())
  n0 <- if (length(P$nsamp)) P$nsamp[1L] else 0
  if (n0 < 0 || n0 > .SCP_MAXALLOC) n0 <- 0
  P$nout <- n0
  P$ecg <- lapply(P$ecg, function(s) {
    if (is.null(s)) s <- .scp_newsig(0)
    if (length(s) < n0) s[(length(s) + 1):n0] <- 0L
    s
  })
  invisible()
}

# Calculate the missing leads.
.scp_derive_leads <- function(P) {
  vflag <- P$vflag
  nleads <- P$nleads
  n0 <- P$nout
  L <- function(name) P$L[[name]]
  sig <- function(name) .scp_sig(P, L(name))
  ns <- function(name) .scp_ns(P, L(name))
  # lead `name` <- f(lead a, lead b) on n samples
  derive <- function(name, a, b, f, nsa, nsb, n) {
    force(nsa)
    force(nsb)
    P$L[[name]] <- nleads
    nleads <<- nleads + 1
    nsamp <- P$nsamp
    nsamp[L(name) + 1] <- .scp_umin(nsa, nsb)
    P$nsamp <- nsamp
    .scp_setsig(P, L(name), .scp_blockop(f, sig(a), sig(b), sig(name), n(nsamp[L(name) + 1])))
  }
  all_n0 <- function(nn) n0
  if (L("leadIII") < 0) {      # we need to calculate lead III
    if (L("leadI") >= 0 && L("leadII") >= 0) {
      if (vflag) cprintf(" Calculating lead III\n")
      derive("leadIII", "leadI", "leadII", function(a, b) cint16(b - a), ns("leadI"),
             ns("leadII"), function(nn) {
               lens <- c(length(sig("leadI")), length(sig("leadII")), length(sig("leadIII")))
               if (nn < 0) min(lens) else min(nn, lens)
             })
    } else if (L("leadI") < 0) {
      if (L("leadII") < 0) ceprintf("Leads I, II, and III are missing\n")
      else ceprintf("Leads I and III are missing\n")
    } else {
      ceprintf("Leads II and III are missing\n")
    }
  } else if (L("leadII") < 0) {        # we need to calculate lead II
    if (L("leadI") >= 0) {
      if (vflag) cprintf(" Calculating lead II\n")
      derive("leadII", "leadI", "leadIII", function(a, b) cint16(a + b), ns("leadI"),
             ns("leadIII"), all_n0)
    } else {
      ceprintf("Leads I and II are missing\n")
    }
  } else if (L("leadI") < 0) {         # we need to calculate lead I
    if (vflag) cprintf(" Calculating lead I\n")
    derive("leadI", "leadII", "leadIII", function(a, b) cint16(a - b), ns("leadII"),
           ns("leadIII"), all_n0)
  }

  # We need both lead I and lead II to derive aVR.
  if (L("aVR") < 0) {
    if (L("leadI") >= 0 && L("leadII") >= 0) {
      if (vflag) cprintf(" Calculating lead aVR\n")
      derive("aVR", "leadI", "leadII", function(a, b) cint16(-cdiv(a + b, 2)), ns("leadI"),
             ns("leadII"), all_n0)
    } else {
      ceprintf("Lead aVR cannot be derived\n")
    }
  }
  # We need both lead II and lead III to derive aVL.
  if (L("aVL") < 0) {
    if (L("leadII") >= 0 && L("leadIII") >= 0) {
      if (vflag) cprintf(" Calculating lead aVL\n")
      derive("aVL", "leadII", "leadIII", function(a, b) cint16(cdiv(a, 2) - b), ns("leadII"),
             ns("leadIII"), all_n0)
    } else {
      ceprintf("Lead aVL cannot be derived\n")
    }
  }
  # We need both lead I and lead III to derive aVF.  (sic: the C program
  # tests leads I and II)
  if (L("aVF") < 0) {
    if (L("leadI") >= 0 && L("leadII") >= 0) {
      if (vflag) cprintf(" Calculating lead aVF\n")
      derive("aVF", "leadI", "leadIII", function(a, b) cint16(cdiv(a, 2) + b), ns("leadI"),
             ns("leadIII"), all_n0)
    } else {
      ceprintf("Lead aVF cannot be derived\n")
    }
  }

  for (v in c("V1", "V2", "V3", "V4", "V5", "V6"))
    if (L(v) < 0) ceprintf("Lead %s is missing\n", v)

  if (nleads > 0 && any(P$L < 0)) {
    # Use an array of zero samples for the missing lead(s).
    if (is.null(P$ecg[[nleads + 1]])) {
      e <- P$ecg
      e[[nleads + 1]] <- .scp_newsig(0)
      P$ecg <- e
    }
    P$L[P$L < 0] <- nleads
  }
  P$nleads <- nleads
  invisible()
}
