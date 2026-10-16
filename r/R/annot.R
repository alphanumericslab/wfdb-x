# annot.R: annotation I/O (port of lib/annot.c): annopen, getann, ungetann,
# putann, iannsettime, iannclose, oannclose, the mnemonic and description
# tables (annstr, strann, anndesc, ecgstr, ...), annotation time
# resolution (setafreq, setiafreq, ...), and bulk readers and writers.
#
# Copyright (C) 1989-2013 George B. Moody (original C implementation,
# lib/annot.c; revised 2015-2020 by Benjamin Moody).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).
#
# Design (as in the MATLAB/Octave port): an input annotation file is read
# completely when it is opened and decoded with vector operations
# (.ann_parse) into the sequence of values that the C library's "current
# annotation" (ia->ann) takes in one pass over the file.  getann() then
# steps through that sequence, emulating the 771-byte aux string buffer of
# the C library exactly (its stale contents are visible to applications,
# since annot->aux points into it).  .getann_bulk(an, m) is exactly
# equivalent to m calls of getann(); .putann_bulk(an, A) to a series of
# putann() calls.
#
# An annotation is a list (annotation() in ecgcodes.R): time, anntyp,
# subtyp, chan, num, aux; aux is NULL or a raw vector whose first byte is
# the length of the data that follows (it may be followed by further bytes
# up to a null, as C sees them).

# Constants of annot.c.  An MIT annotation word is code * 2^CS + data
# (6-bit code, 10-bit data field); codes from 59 up are pseudo-annotations.
.A_CMUL <- 1024L        # 2^CS (CS = 10): word %/% .A_CMUL is the code
.A_DATA <- 1023         # 01777: the data field
.A_MAXRR <- 1023        # the longest interval coded in an annotation word
.A_MAXSKIP <- 2147483647  # the longest interval coded by one SKIP
.A_MINSKIP <- -2147483647
.A_SKIPC <- 59L         # codes of the pseudo-annotations SKIP, NUM, SUB, CHN, AUX
.A_NUMC <- 60L
.A_SUBC <- 61L
.A_CHNC <- 62L
.A_AUXC <- 63L
.A_SKIP <- .A_SKIPC * .A_CMUL   # (their annotation words, with data 0)
.A_NUM <- .A_NUMC * .A_CMUL
.A_SUB <- .A_SUBC * .A_CMUL
.A_CHN <- .A_CHNC * .A_CMUL
.A_AUX <- .A_AUXC * .A_CMUL
.A_ABLKSIZ <- 1024      # block size of AHA annotation files
.A_AUXLEN <- 6          # length of the aux data of an AHA annotation
.A_EOAF <- 255          # the end of an AHA annotation file
.A_AHALEN <- 16L        # bytes per AHA annotation
.A_WEOF <- 65535L       # a word read at the end of a file (two EOF bytes)
.A_AUXBUFLEN <- 771     # size of the aux string buffer of an input annotator
.A_DEFWFDBANNSORT <- 1  # default of WFDBANNSORT: sort out-of-order output

# ---------------------------------------------------------------------------
# State

.ann <- new.env(parent = emptyenv())

.ANN_DEFAULT_MNEMONICS <- c(
  " ", "N", "L", "R", "a",
  "V", "F", "J", "A", "S",
  "E", "j", "/", "Q", "~",
  "[15]", "|", "[17]", "s", "T",
  "*", "D", "\"", "=", "p",
  "B", "^", "t", "+", "u",
  "?", "!", "[", "]", "e",
  "n", "@", "x", "f", "(",
  ")", "r", "[42]", "[43]", "[44]",
  "[45]", "[46]", "[47]", "[48]", "[49]")

.ANN_DEFAULT_DESC <- c(
  "",
  "Normal beat",
  "Left bundle branch block beat",
  "Right bundle branch block beat",
  "Aberrated atrial premature beat",
  "Premature ventricular contraction",
  "Fusion of ventricular and normal beat",
  "Nodal (junctional) premature beat",
  "Atrial premature beat",
  "Supraventricular premature or ectopic beat",
  "Ventricular escape beat",
  "Nodal (junctional) escape beat",
  "Paced beat",
  "Unclassifiable beat",
  "Change in signal quality",
  NA,
  "Isolated QRS-like artifact",
  NA,
  "ST segment change",
  "T-wave change",
  "Systole",
  "Diastole",
  "Comment annotation",
  "Measurement annotation",
  "P-wave peak",
  "Bundle branch block beat (unspecified)",
  "(Non-captured) pacemaker artifact",
  "T-wave peak",
  "Rhythm change",
  "U-wave peak",
  "Beat not classified during learning",
  "Ventricular flutter wave",
  "Start of ventricular flutter/fibrillation",
  "End of ventricular flutter/fibrillation",
  "Atrial escape beat",
  "Supraventricular escape beat",
  "Link to external data (aux contains URL)",
  "Non-conducted P-wave (blocked APC)",
  "Fusion of paced and normal beat",
  "Waveform onset",
  "Waveform end",
  "R-on-T premature ventricular contraction",
  NA, NA, NA, NA, NA, NA, NA, NA)

#' Reset the state of the annotation module: closes nothing (use
#' wfdb_anclose() first); with tables = TRUE, also restores the mnemonic and
#' description tables and clears the flags of modified codes, which no
#' function of the C library resets (for tests).
annot_reset <- function(tables = TRUE) {
  a <- .ann
  a$iad <- list()             # input annotators (environments)
  a$oad <- list()             # output annotators (environments)
  if (tables || is.null(a$oafreq)) {
    a$oafreq <- 0
    a$cstring <- .ANN_DEFAULT_MNEMONICS
    a$astring <- .ANN_DEFAULT_MNEMONICS
    a$tstring <- .ANN_DEFAULT_DESC
    a$modified <- logical(50)    # (ACMAX + 1: ecgcodes.R is sourced later)
  }
  a$annclose_error <- 0
  invisible()
}
annot_reset()

# ---------------------------------------------------------------------------
# Helpers

# Round a time (double) to WFDB_Time as getann does (vectorized).
.ann_round <- function(x) {
  t <- trunc(x)
  f <- x - t
  t <- t + (x >= 0 & f >= 0.5) - (x < 0 & f < -0.5)
  t[!is.na(x) & x >= WFDB_TIME_MAX] <- WFDB_TIME_MAX
  t[is.na(x) | x <= WFDB_TIME_MIN] <- WFDB_TIME_MIN
  t
}

# Raw bytes of 16-bit words (little-endian; values taken modulo 65536).
.ann_words <- function(w) {
  w <- w %% 65536
  as.raw(rbind(w %% 256, w %/% 256))
}

# An aux string (raw, with its length byte) from a character string or a
# raw vector of data bytes (length taken modulo 256, as C's (char) cast).
.aux_from <- function(s) {
  b <- if (is.raw(s)) s else charToRaw(s)
  c(as.raw(length(b) %% 256), b)
}

#' The data of an aux string (raw, with its length byte) as a character
#' string, up to the first null (as C's printf("%s", aux + 1)); NULL for
#' NULL.
aux_string <- function(aux) {
  if (is.null(aux)) return(NULL)
  if (is.character(aux)) return(aux)
  cstr(aux[-1L])
}

# aux_string() of each element of a list of aux strings (raw or NULL):
# character vector, "" for NULL.
.aux_strings <- function(aux) {
  r <- character(length(aux))
  k <- which(lengths(aux) > 0L)
  if (length(k) == 0L) return(r)
  ax <- aux[k]
  len <- lengths(ax)
  b <- unlist(ax, use.names = FALSE)
  if (!is.raw(b) || (l10n_info()$MBCS && any(b >= as.raw(128L)))) {
    r[k] <- vapply(ax, function(a) if (is.raw(a)) cstr(a[-1L]) else a, "")
    return(r)
  }
  st <- cumsum(c(1L, len[-length(len)]))  # positions of the length bytes
  e <- st + len - 1L                      # last bytes
  z <- which(b == as.raw(0L))
  z <- z[!(z %in% st)]                    # nulls in the data
  if (length(z)) {
    el <- findInterval(z, st)
    f <- !duplicated(el)
    e[el[f]] <- z[f] - 1L                 # (up to the first null)
    b[b == as.raw(0L)] <- as.raw(1L)
  } else {
    b[st] <- as.raw(1L)
  }
  r[k] <- substring(rawToChar(b), st + 1L, e)
  r
}

# ---------------------------------------------------------------------------
# Decoding a whole annotation file

# P <- .ann_parse(D, aha): decode the bytes D (raw: the whole file) as
# getann reads them in one pass from the start of the file.  The result
# describes the successive values of the current annotation (ia->ann):
#   N                   number of annotations read
#   tt                  their times in file units (before scaling by tmul)
#   typ, sub, chan, num anntyp, subtyp, chan, num (chan and num carry
#                       over from one annotation to the next, as in C)
#   eofend              TRUE if the file ends inside annotation N (reading
#                       it sets ateof = -1, so getann then reports an
#                       unexpected EOF instead of returning it)
#   tokfirst, tokcnt    (MIT) the AUX words of each annotation: indices
#                       into tokln (length byte), tokoff (0-based offset of
#                       the data in D), tokav (bytes of data available)
#   auxoff, auxav, badseq  (AHA) the 6 aux bytes; TRUE if the annotation
#                       number is <= 0
#   D                   the file bytes (integer codes)
.ann_parse <- function(D, aha) {
  b <- as.integer(D)
  P <- if (aha) .ann_parse_aha(b) else .ann_parse_mit(b)
  P$D <- b
  P$aha <- aha
  P
}

.ann_parse_aha <- function(b) {
  L <- length(b)
  # (bytes past the end read as EOF bytes, 0xFF)
  Dp <- c(b, rep.int(255L, .A_AHALEN + 2L))
  R <- L %/% .A_AHALEN + 1L
  off <- .A_AHALEN * (0:(R - 1L))
  lb <- Dp[off + 1L]
  stop <- which(lb == .A_EOAF | .A_AHALEN * (1:R) + 2L > L)[1L]
  if (lb[stop] == .A_EOAF) {
    N <- stop - 1L
    eofend <- FALSE
  } else {
    N <- stop
    eofend <- TRUE
  }
  off <- off[seq_len(N)]
  hi <- Dp[off + 2L]
  typ <- cint8(ammap(hi))
  x <- Dp[off + 3L] + 256 * Dp[off + 4L]
  x <- x - 65536 * (x >= 32768)
  y <- Dp[off + 5L] + 256 * Dp[off + 6L]
  q <- Dp[off + 7L] + 256 * Dp[off + 8L]
  q <- q - 65536 * (q >= 32768)
  sub <- Dp[off + 9L]
  sub <- sub - 256 * (sub >= 128)
  sub[hi == 85L & sub == 0] <- -1             # 'U'
  list(N = N, eofend = eofend, tt = x * 65536 + y, typ = typ, sub = sub,
       chan = as.numeric(Dp[off + 10L]), num = numeric(N), badseq = q <= 0,
       auxoff = off + 10L, auxav = pmax(0L, pmin(6L, L - (off + 10L))))
}

.ann_parse_mit <- function(b) {
  L <- length(b)
  nW <- L %/% 2L
  Wd <- if (nW > 0L) b[seq.int(1L, by = 2L, length.out = nW)] +
    256L * b[seq.int(2L, by = 2L, length.out = nW)] else integer(0)
  # (a word read at the end of the file: its missing bytes are EOF bytes,
  # 0xFF)
  weof <- if (L %% 2L) 65280L + b[L] else .A_WEOF
  Wx <- c(Wd, weof, .A_WEOF, .A_WEOF, .A_WEOF)
  wat <- function(i) if (i <= nW + 1L) Wx[i] else .A_WEOF
  g32 <- function(i) {
    x <- wat(i)
    if (x >= 32768L) x <- x - 65536
    x * 65536 + wat(i + 1L)
  }
  empty <- list(N = 0L, eofend = FALSE, tt = numeric(0), typ = numeric(0),
                sub = numeric(0), chan = numeric(0), num = numeric(0),
                tokfirst = integer(0), tokcnt = integer(0), tokln = integer(0),
                tokoff = integer(0), tokav = integer(0))
  # the SKIP words at the start of the file (read by annopen)
  i <- 1L
  tt0 <- 0
  while (wat(i) %/% .A_CMUL == .A_SKIPC) {
    tt0 <- tt0 + g32(i + 1L)
    i <- i + 3L
  }
  s0 <- i
  if (s0 > nW) {
    # the first annotation word is read at the end of the file
    w <- wat(s0)
    P <- empty
    P$N <- 1L
    P$tt <- tt0 + w %% .A_CMUL
    P$typ <- cint8(w %/% .A_CMUL)
    P$sub <- 0
    P$chan <- 0
    P$num <- 0
    P$tokfirst <- 1L
    P$tokcnt <- 0L
    P$eofend <- TRUE
    return(P)
  }
  if (Wd[s0] == 0L) return(empty)
  code <- Wd %/% .A_CMUL
  # Nodes of the walk: SKIP and AUX words (which are followed by operands
  # or data), and zero words (end of file).  From each node the walk
  # continues at the first node at or after its jump target.
  node <- which(code == .A_SKIPC | code == .A_AUXC | Wd == 0L)
  node <- node[node > s0]
  M <- length(node)
  eofhit <- FALSE
  if (M == 0L) {
    rs <- s0 + 1L
    re <- nW
    eofhit <- TRUE
  } else {
    isz <- Wd[node] == 0L
    cnode <- code[node]
    jump <- ifelse(cnode == .A_SKIPC, node + 3L, node + 1L + (Wd[node] %% 256L + 1L) %/% 2L)
    cnt <- cumsum(c(0L, tabulate(node, nbins = nW)))  # nodes before position p: cnt[p]
    J <- rep.int(M + 1L, M + 1L)                # M + 1: no next node
    ok <- !isz & jump <= nW
    J[which(ok)] <- cnt[jump[ok]] + 1L
    # the nodes visited, from the first one: idx[k] = J^(k-1)(1), by
    # pointer doubling
    idx <- rep.int(1L, M)
    ii <- 0:(M - 1L)
    Jp <- J
    bb <- 1L
    while (bb <= M - 1L) {
      sel <- bitwAnd(ii, bb) != 0L
      idx[sel] <- Jp[idx[sel]]
      Jp <- Jp[Jp]
      bb <- bb * 2L
    }
    vis <- idx[idx <= M]
    vis <- vis[!duplicated(vis)]
    nv <- length(vis)
    last <- vis[nv]
    # ranges of words read: [s0 + 1, node(v1)], [jump(v1), node(v2)], ...
    rs <- c(s0 + 1L, jump[vis[-nv]])
    re <- node[vis]
    if (isz[last]) {
      re[nv] <- re[nv] - 1L           # (the zero word ends the file)
    } else if (jump[last] > nW) {
      eofhit <- TRUE
    } else {
      rs <- c(rs, jump[last])           # no further node: to the end
      re <- c(re, nW)
      eofhit <- TRUE
    }
  }
  k <- re >= rs
  rs <- rs[k]
  re <- re[k]
  C <- c(s0, sequence(re - rs + 1L, from = rs))
  w <- Wd[C]
  cd <- w %/% .A_CMUL
  isstart <- cd < .A_SKIPC
  isstart[1L] <- TRUE
  aid <- cumsum(isstart)
  N <- aid[length(aid)]
  contrib <- numeric(length(C))
  contrib[isstart] <- w[isstart] %% .A_CMUL
  ks <- which(cd == .A_SKIPC & !isstart)
  if (length(ks)) {
    x <- Wx[pmin(C[ks] + 1L, nW + 4L)]
    x[C[ks] + 1L > nW + 1L] <- .A_WEOF
    y <- Wx[pmin(C[ks] + 2L, nW + 4L)]
    y[C[ks] + 2L > nW + 1L] <- .A_WEOF
    x <- x - 65536 * (x >= 32768L)
    contrib[ks] <- x * 65536 + y
  }
  ttall <- cumsum(c(tt0, contrib))[-1L]
  P <- empty
  P$N <- N
  P$tt <- ttall[isstart]
  P$typ <- cint8(cd[isstart])
  sub <- numeric(N)
  kk <- which(cd == .A_SUBC & !isstart)
  if (length(kk)) sub[aid[kk]] <- cint8(w[kk] %% .A_CMUL)
  P$sub <- sub
  P$chan <- .ann_carry(N, aid, w, cd == .A_CHNC & !isstart, FALSE)
  P$num <- .ann_carry(N, aid, w, cd == .A_NUMC & !isstart, TRUE)
  ka <- which(cd == .A_AUXC & !isstart)
  P$tokln <- w[ka] %% 256L
  P$tokoff <- 2L * C[ka]
  P$tokav <- pmax(0L, pmin(2L * ((P$tokln + 1L) %/% 2L), L - P$tokoff))
  P$tokcnt <- tabulate(aid[ka], nbins = N)
  P$tokfirst <- cumsum(c(1L, P$tokcnt[-N]))
  P$eofend <- eofhit
  P
}

# chan (or num) of each annotation: the last CHN (NUM) word read so far in
# the pass (0 at the start).
.ann_carry <- function(N, aid, w, sel, signed) {
  k <- which(sel)
  if (length(k) == 0L) return(numeric(N))
  x <- w[k] %% .A_CMUL
  x <- if (signed) cint8(x) else x %% 256L
  cv <- rep(NA_real_, N)
  cv[aid[k]] <- x
  f <- !is.na(cv)
  vals <- c(0, cv[f])
  vals[cumsum(f) + 1L]
}

# ---------------------------------------------------------------------------
# The aux ring buffer

# Store the m-th AUX token of P in the ring buffer of ia; returns the
# position (0-based) of the string.
.ann_auxput <- function(ia, P, m) {
  buf <- ia$buf
  ia$buf <- NULL
  index <- ia$index
  ln <- P$tokln[m]
  if (index >= .A_AUXBUFLEN - 2L - ln) index <- 0L
  pos <- index
  buf[index + 1L] <- ln
  index <- index + 1L
  av <- P$tokav[m]
  if (av > 0L) {
    o <- P$tokoff[m]
    buf[(index + 1L):(index + av)] <- P$D[(o + 1L):(o + av)]
  }
  buf[index + ln + 1L] <- 0L
  ia$index <- index + ln + 1L
  ia$buf <- buf
  pos
}

# What C finds at annot->aux when it points to position pos (0-based) of
# the buffer: the length byte, the data and any further bytes up to a null.
.ann_auxget <- function(buf, pos) {
  e <- pos + 1L + buf[pos + 1L]          # 0-based end of the data
  if (e >= .A_AUXBUFLEN) {
    e <- .A_AUXBUFLEN
  } else {
    z <- match(0L, buf[(e + 1L):.A_AUXBUFLEN])
    e <- if (is.na(z)) .A_AUXBUFLEN else e + z - 1L
  }
  as.raw(buf[(pos + 1L):e])
}

# ---------------------------------------------------------------------------
# Reading

# Make the next annotation of the decoded file the current one (second
# half of getann in annot.c).
.ann_next <- function(ia) {
  P <- ia$P
  j <- ia$k + 1L
  if (j > P$N) {
    ia$ateof <- 1
    return(invisible())
  }
  ia$k <- j
  tt <- P$tt[j]
  ia$ann_tt <- tt
  ia$ann <- list(time = .ann_round(tt * ia$tmul), anntyp = P$typ[j], subtyp = P$sub[j],
                 chan = P$chan[j], num = P$num[j], aux = NULL)
  if (P$aha) {
    if (P$badseq[j])
      wfdb_error("getann: unexpected annot number in annotator %s\n", ia$name)
    buf <- ia$buf
    ia$buf <- NULL
    if (ia$index >= 256L - (.A_AUXLEN + 2L)) ia$index <- 0L
    kk <- ia$index + 1L                   # 0-based position of the data
    av <- P$auxav[j]
    if (av > 0L) {
      o <- P$auxoff[j]
      buf[(kk + 1L):(kk + av)] <- P$D[(o + 1L):(o + av)]
    }
    if (buf[kk + 1L] != 0L) {
      buf[ia$index + 1L] <- .A_AUXLEN
      ia$auxpos <- ia$index
      buf[kk + .A_AUXLEN + 1L] <- 0L
      ia$index <- ia$index + .A_AUXLEN + 2L
    } else {
      ia$auxpos <- -1L
    }
    ia$buf <- buf
  } else {
    ia$auxpos <- -1L
    tc <- P$tokcnt[j]
    if (tc > 0L) {
      for (m in P$tokfirst[j]:(P$tokfirst[j] + tc - 1L)) ia$auxpos <- .ann_auxput(ia, P, m)
    }
  }
  if (j == P$N && P$eofend) ia$ateof <- -1
  invisible()
}

# getann for one input annotator: list(stat, annot).
.ann_get1 <- function(ia) {
  if (ia$pann$anntyp != 0) {
    a <- ia$pann
    ia$pann$anntyp <- 0
    ia$prev_time <- a$time
    ia$prev_tt <- ia$pann_tt
    return(list(stat = 0, annot = a))
  }
  if (ia$ateof != 0) {
    if (ia$ateof != -1) return(list(stat = -1, annot = NULL))
    wfdb_error("getann: unexpected EOF in annotator %s\n", ia$name)
    return(list(stat = -3, annot = NULL))
  }
  a <- ia$ann
  ia$prev_time <- a$time
  ia$prev_tt <- ia$ann_tt
  retpos <- ia$auxpos
  .ann_next(ia)
  if (retpos >= 0L) a["aux"] <- list(.ann_auxget(ia$buf, retpos))
  list(stat = 0, annot = a)
}

.ann_ia <- function(an) {
  iad <- .ann$iad
  if (!is.numeric(an) || length(an) != 1L || is.na(an) || an < 0 || an >= length(iad))
    return(NULL)
  iad[[an + 1L]]
}

#' Read the next annotation from input annotator an (0-based):
#' list(stat, annot), stat 0 on success (annot is the annotation), -1 at
#' the end of the file, -2 for an invalid annotator, -3 after an
#' unexpected end of file (annot is then NULL).
getann <- function(an) {
  ia <- .ann_ia(an)
  if (is.null(ia)) {
    wfdb_error("getann: can't read annotator %d\n", an)
    return(list(stat = -2, annot = NULL))
  }
  P <- ia$P
  j <- ia$k + 1L
  if (ia$pann$anntyp == 0 && ia$ateof == 0 && ia$auxpos < 0L && j <= P$N && !P$aha &&
      P$tokcnt[j] == 0L && (j < P$N || !P$eofend)) {
    # fast path (MIT format, no aux strings involved)
    a <- ia$ann
    ia$prev_time <- a$time
    ia$prev_tt <- ia$ann_tt
    ia$k <- j
    tt <- P$tt[j]
    ia$ann_tt <- tt
    x <- tt * ia$tmul
    t <- if (x >= 0 && x < 9007199254740992) {
      t <- trunc(x)
      t + (x - t >= 0.5)
    } else .ann_round(x)
    ia$ann <- list(time = t, anntyp = P$typ[j], subtyp = P$sub[j], chan = P$chan[j],
                   num = P$num[j], aux = NULL)
    return(list(stat = 0, annot = a))
  }
  .ann_get1(ia)
}

#' Read many annotations at once: exactly the effect of up to m calls of
#' getann(an) (m may be Inf), stopping at the first call that fails.
#' Returns list(stat, time, anntyp, subtyp, chan, num, aux) (vectors; aux
#' a list of NULL or raw vectors); stat is 0 if m annotations were read,
#' otherwise the status of the call that failed.  With noaux = TRUE the aux
#' strings are not returned (aux is an empty list).  With nofail = TRUE the
#' failing call is not made: stat is then 1 if fewer than m annotations
#' could be read (the next getann call will fail and print any message).
.getann_bulk <- function(an, m, noaux = FALSE, nofail = FALSE) {
  res <- list(stat = 0, time = numeric(0), anntyp = numeric(0), subtyp = numeric(0),
              chan = numeric(0), num = numeric(0), aux = list())
  ia <- .ann_ia(an)
  if (is.null(ia)) {
    if (m > 0) {
      wfdb_error("getann: can't read annotator %d\n", an)
      res$stat <- -2
    }
    return(res)
  }
  pre <- NULL
  if (m > 0 && ia$pann$anntyp != 0) {
    pre <- .ann_get1(ia)$annot
    m <- m - 1
  }
  if (m <= 0 || ia$ateof != 0 || ia$P$aha) {
    # one annotation at a time (AHA files)
    cap <- if (is.finite(m)) min(m, 1024) else 1024
    tm <- an_ <- sb <- ch <- nm <- numeric(cap)
    ax <- vector("list", cap)
    nb <- 0L
    stat <- 0
    while (m > 0) {
      if (nofail && ia$pann$anntyp == 0 && ia$ateof != 0) {
        stat <- 1
        break
      }
      r <- .ann_get1(ia)
      if (r$stat != 0) {
        stat <- r$stat
        break
      }
      a <- r$annot
      nb <- nb + 1L
      if (nb > cap) {
        cap <- 2L * cap
        length(tm) <- cap
        length(an_) <- cap
        length(sb) <- cap
        length(ch) <- cap
        length(nm) <- cap
        length(ax) <- cap
      }
      tm[nb] <- a$time
      an_[nb] <- a$anntyp
      sb[nb] <- a$subtyp
      ch[nb] <- a$chan
      nm[nb] <- a$num
      if (!is.null(a$aux)) ax[[nb]] <- a$aux
      m <- m - 1
    }
    s <- seq_len(nb)
    res <- list(stat = stat, time = tm[s], anntyp = an_[s], subtyp = sb[s], chan = ch[s],
                num = nm[s], aux = if (noaux) list() else ax[s])
    return(.ann_prepend(res, pre, noaux))
  }
  P <- ia$P
  N <- P$N
  j0 <- ia$k
  cmax <- if (P$eofend) N - j0 else N - j0 + 1L
  cc <- as.integer(min(m, cmax))          # number of successful calls (>= 1)
  lastread <- j0 + cc                     # last annotation read (N + 1: end)
  jr <- if (min(lastread, N) >= j0 + 1L) (j0 + 1L):min(lastread, N) else integer(0)
  ret <- if (cc >= 2L) (j0 + 1L):(j0 + cc - 1L) else integer(0)
  cur <- ia$ann
  tmul <- ia$tmul
  rt <- if (length(ret)) .ann_round(P$tt[ret] * tmul) else numeric(0)
  res$time <- c(cur$time, rt)
  res$anntyp <- c(cur$anntyp, P$typ[ret])
  res$subtyp <- c(cur$subtyp, P$sub[ret])
  res$chan <- c(cur$chan, P$chan[ret])
  res$num <- c(cur$num, P$num[ret])
  # The aux ring buffer: writes for the annotations read (jr), and the aux
  # strings of the annotations returned, each taken after the next one has
  # been read (C returns a pointer into the buffer).
  tc <- P$tokcnt
  tf <- P$tokfirst
  hasw <- jr[tc[jr] > 0L]
  posrec <- rep.int(-1L, length(jr))      # auxpos of each read (j - j0)
  if (noaux) {
    for (j in hasw) {
      for (q in tf[j]:(tf[j] + tc[j] - 1L)) p <- .ann_auxput(ia, P, q)
      posrec[j - j0] <- p
    }
  } else {
    aux <- vector("list", cc)
    rr <- ret[tc[ret] > 0L]
    steps <- rr + 1L
    curpos <- ia$auxpos
    if (curpos >= 0L) steps <- c(j0 + 1L, steps)
    ev <- sort(unique(c(hasw, steps)))
    for (s in ev) {
      if (s <= N && s >= j0 + 1L && tc[s] > 0L) {
        for (q in tf[s]:(tf[s] + tc[s] - 1L)) p <- .ann_auxput(ia, P, q)
        posrec[s - j0] <- p
      }
      r <- s - 1L                         # the returned annotation
      if (r == j0) {
        if (curpos >= 0L) aux[[1L]] <- .ann_auxget(ia$buf, curpos)
      } else if (r <= j0 + cc - 1L && tc[r] > 0L) {
        aux[[r - j0 + 1L]] <- .ann_auxget(ia$buf, posrec[r - j0])
      }
    }
    res$aux <- aux
  }
  # the state after the last read
  ia$prev_time <- res$time[cc]
  ia$prev_tt <- if (cc >= 2L) P$tt[j0 + cc - 1L] else ia$ann_tt
  kf <- min(lastread, N)
  if (kf > j0) {
    ia$k <- kf
    ia$ann_tt <- P$tt[kf]
    ia$ann <- list(time = .ann_round(P$tt[kf] * tmul), anntyp = P$typ[kf], subtyp = P$sub[kf],
                   chan = P$chan[kf], num = P$num[kf], aux = NULL)
    ia$auxpos <- posrec[kf - j0]
  }
  if (lastread > N) {
    ia$ateof <- 1
  } else if (lastread == N && P$eofend) {
    ia$ateof <- -1
  }
  if (cc < m) res$stat <- if (nofail) 1 else .ann_get1(ia)$stat
  .ann_prepend(res, pre, noaux)
}

.ann_prepend <- function(res, a, noaux) {
  if (is.null(a)) return(res)
  res$time <- c(a$time, res$time)
  res$anntyp <- c(a$anntyp, res$anntyp)
  res$subtyp <- c(a$subtyp, res$subtyp)
  res$chan <- c(a$chan, res$chan)
  res$num <- c(a$num, res$num)
  if (!noaux) res$aux <- c(list(a$aux), res$aux)
  res
}

#' Push an annotation back into input annotator an (read again by the next
#' getann).  Returns 0, -1 if the pushback buffer is full, -2 for an
#' invalid annotator.
ungetann <- function(an, annot) {
  ia <- .ann_ia(an)
  if (is.null(ia)) {
    wfdb_error("ungetann: annotator %d is not initialized\n", an)
    return(-2)
  }
  if (ia$pann$anntyp != 0) {
    wfdb_error("ungetann: pushback buffer is full\n")
    wfdb_error("ungetann: annotation at %d, annotator %d not pushed back\n", annot$time, an)
    return(-1)
  }
  a <- annotation()
  for (f in c("time", "anntyp", "subtyp", "chan", "num")) if (!is.null(annot[[f]])) a[[f]] <- annot[[f]]
  a["aux"] <- list(annot$aux)
  ia$pann <- a
  ia$pann_tt <- if (annot$time == ia$prev_time) ia$prev_tt else annot$time / ia$tmul
  0
}

#' Skip input annotators to the first annotation at or after time t (an
#' absolute time if negative).  Returns 0, or -1 if no annotator could be
#' positioned.
iannsettime <- function(t) {
  iad <- .ann$iad
  stat <- 0
  niavalid <- length(iad)
  if (t < 0 && t != WFDB_TIME_MIN) t <- -t
  for (i in seq_along(iad)) {
    ia <- iad[[i]]
    if (ia$ann$time >= t) {
      ia$pann$anntyp <- 0
      if (wf_seek(ia$file, 0, 0) == -1) {
        wfdb_error("iannsettime: improper seek\n")
        return(-1)
      }
      ia$ann$subtyp <- 0
      ia$ann$chan <- 0
      ia$ann$num <- 0
      ia$ateof <- 0
      ia$ann$time <- 0
      ia$k <- 0L                          # a new pass over the file
      .ann_get1(ia)
    }
    if (ia$ann$time < t && ia$pann$anntyp != 0) stat <- .ann_get1(ia)$stat
    if (ia$ann$time < t) {
      # getann until the current annotation is at or after t
      m <- Inf
      P <- ia$P
      if (ia$ateof == 0 && ia$k < P$N) {
        x <- P$tt[(ia$k + 1L):P$N] * ia$tmul
        c1 <- match(TRUE, .ann_round(x) >= t)
        if (!is.na(c1)) m <- c1
      }
      stat <- .getann_bulk(i - 1L, m, noaux = TRUE)$stat
    }
    if (stat < 0) niavalid <- niavalid - 1L
  }
  if (niavalid > 0) 0 else -1
}

# ---------------------------------------------------------------------------
# Opening and closing

# Read the modification labels at the start of input annotator i (0-based).
.ann_gettable <- function(i) {
  ia <- .ann$iad[[i + 1L]]
  ia$tmul <- 1
  ia$afreq <- 0
  r <- getann(i)
  if (r$stat < 0) return(-1)
  annot <- r$annot
  repeat {
    r <- getann(i)
    if (r$stat != 0) break
    annot <- r$annot
    if (!(annot$time == 0 && annot$anntyp == NOTE && annot$subtyp == 0)) break
    if (is.null(annot$aux) || as.integer(annot$aux[1L]) < 1L) next
    b <- cbytes(annot$aux[-1L])
    n <- length(b)
    if (n >= 1L && b[1L] == 35L) {          # '#'
      if (n >= 20L && identical(b[1:20], as.integer(charToRaw("## time resolution: ")))) {
        v <- strtod(b, 20L)
        if (v[2L] != 20) ia$afreq <- v[1L]
      }
      next
    }
    p1 <- 1L
    while (p1 <= n && (b[p1] == 32L || b[p1] == 9L)) p1 <- p1 + 1L
    v <- strtol(b, 10, p1)
    a <- v[1L]
    p2 <- as.integer(v[2L])
    if (a < 0 || a > ACMAX || p1 == p2) next
    while (p2 <= n && b[p2] != 32L && b[p2] != 9L) p2 <- p2 + 1L
    p1 <- p2
    while (p1 <= n && (b[p1] == 32L || b[p1] == 9L)) p1 <- p1 + 1L
    p2 <- p1
    while (p2 <= n && b[p2] != 32L && b[p2] != 9L) p2 <- p2 + 1L
    if (p2 != p1) {
      if (p2 <= n) {
        setanndesc(a, if (p2 < n) rawToChar(as.raw(b[(p2 + 1L):n])) else "")
      } else {
        setanndesc(a, NULL)
      }
      setannstr(a, rawToChar(as.raw(b[p1:(p2 - 1L)])))
    }
  }
  if (annot$time != 0 || annot$anntyp != NOTE || annot$subtyp != 0 || is.null(annot$aux))
    ungetann(i, annot)
  setiafreq(i, getifreq())
  0
}

# Write the modification labels at the start of output annotator i.
.ann_puttable <- function(i) {
  oa <- .ann$oad[[i + 1L]]
  flag <- 0
  annot <- annotation(0, NOTE, 0, 0, 0, NULL)
  oafreq <- .ann$oafreq
  if (oafreq != oa$afreq && oafreq > 0) {
    annot$aux <- .aux_from(csprintf("## time resolution: %.12g", oafreq))
    oa$afreq <- oafreq
    if (putann(i, annot) < 0) return(-1)
    flag <- 1
  }
  for (a in 0:ACMAX) {
    if (.ann$modified[a + 1L]) {
      if (flag < 2) {
        annot$aux <- .aux_from("## annotation type definitions")
        if (putann(i, annot) < 0) return(-1)
      }
      d <- anndesc(a)
      st <- if (!is.null(d)) csprintf("%d %s %s", a, annstr(a), d) else
        csprintf("%d %s ", a, annstr(a))
      annot$aux <- c(as.raw(min(length(st), 255L)), st)
      if (putann(i, annot) < 0) return(-1)
      flag <- 2
    }
  }
  if (flag == 2) {
    annot$aux <- .aux_from("## end of definitions")
    if (putann(i, annot) < 0) return(-1)
  }
  if (flag) {
    annot$anntyp <- 0
    annot["aux"] <- list(NULL)
    if (putann(i, annot) < 0) return(-1)
  }
  0
}

#' Open the annotation files of a record.  aiarray is an anninfo() (or a
#' list of them; nann of them are opened).  A record name beginning with
#' '+' keeps the annotators already open.  Returns 0, or a negative error
#' code (-3: can't read, -4: can't write, -5: illegal stat).
annopen <- function(record, aiarray, nann = NULL) {
  if (!is.null(aiarray) && !is.null(aiarray$stat) && !is.list(aiarray$stat))
    aiarray <- list(aiarray)
  if (is.null(nann)) nann <- length(aiarray)
  .ann$annclose_error <- 0
  if (startsWith(record, "+")) {
    record <- substr(record, 2L, nchar(record, type = "bytes"))
  } else {
    wfdb_anclose()
  }
  if (nann == 0) return(.ann$annclose_error)
  record <- wfdb_striphea(record)
  for (i in seq_len(nann)) {
    s <- aiarray[[i]]$stat
    if (!(s %in% c(WFDB_READ, WFDB_AHA_READ, WFDB_WRITE, WFDB_AHA_WRITE))) {
      wfdb_error("annopen: illegal stat %d for annotator %s, record %s\n", s,
                 aiarray[[i]]$name, record)
      return(-5)
    }
  }
  for (i in seq_len(nann)) {
    ai <- aiarray[[i]]
    if (ai$stat == WFDB_READ || ai$stat == WFDB_AHA_READ) {
      wfdb_setirec(record)
      f <- wfdb_open(ai$name, record, WFDB_READ)
      if (is.null(f)) {
        wfdb_error("annopen: can't read annotator %s for record %s\n", ai$name, record)
        return(-3)
      }
      D <- wf_readall(f)
      w <- if (length(D) >= 2L) as.integer(D[1L]) + 256L * as.integer(D[2L]) else
        if (length(D) == 1L) as.integer(D[1L]) + 65280L else .A_WEOF
      a <- w %/% 256L
      if (w %% 256L != 0L || ammap(a) == NOTQRS || a == 91L || a == 93L) {
        if (ai$stat != WFDB_READ) {
          wfdb_error("warning (annopen, annotator %s, record %s):\n", ai$name, record)
          wfdb_error(" file appears to be in MIT format\n")
          wfdb_error(" ... continuing under that assumption\n")
        }
        istat <- WFDB_READ
      } else {
        if (ai$stat != WFDB_AHA_READ) {
          wfdb_error("warning (annopen, annotator %s, record %s):\n", ai$name, record)
          wfdb_error(" file appears to be in AHA format\n")
          wfdb_error(" ... continuing under that assumption\n")
        }
        istat <- WFDB_AHA_READ
      }
      ia <- new.env(parent = emptyenv())
      ia$file <- f
      ia$name <- ai$name
      ia$stat <- istat
      ia$P <- .ann_parse(D, istat == WFDB_AHA_READ)
      ia$k <- 0L
      ia$ateof <- 0
      ia$tmul <- 0
      ia$afreq <- 0
      ia$ann <- annotation()
      ia$ann_tt <- 0
      ia$pann <- annotation()
      ia$pann_tt <- 0
      ia$prev_tt <- 0
      ia$prev_time <- 0
      ia$buf <- integer(.A_AUXBUFLEN)
      ia$index <- 0L
      ia$auxpos <- -1L
      iad <- .ann$iad
      iad[[length(iad) + 1L]] <- ia
      .ann$iad <- iad
      .ann_gettable(length(iad) - 1L)
    } else {
      if (wfdb_checkname(ai$name, "annotator")) return(-4)
      f <- wfdb_open(ai$name, record, WFDB_WRITE)
      if (is.null(f)) {
        wfdb_error("annopen: can't write annotator %s for record %s\n", ai$name, record)
        return(-4)
      }
      oa <- new.env(parent = emptyenv())
      oa$file <- f
      oa$name <- ai$name
      oa$stat <- ai$stat
      oa$rname <- record
      oa$ann <- annotation()
      oa$afreq <- 0
      oa$seqno <- 0
      oa$out_of_order <- 0
      oa$table_written <- 0
      oad <- .ann$oad
      oad[[length(oad) + 1L]] <- oa
      .ann$oad <- oad
    }
  }
  0
}

#' Close input annotator n (later annotators move down by one).
iannclose <- function(n) {
  ia <- .ann_ia(n)
  if (!is.null(ia) && !is.null(ia$file)) {
    wf_close(ia$file)
    iad <- .ann$iad
    iad[[n + 1L]] <- NULL
    .ann$iad <- iad
  }
  invisible()
}

.ann_oa <- function(an) {
  oad <- .ann$oad
  if (!is.numeric(an) || length(an) != 1L || is.na(an) || an < 0 || an >= length(oad))
    return(NULL)
  oad[[an + 1L]]
}

#' Close output annotator n (writing the end-of-file marker; if the
#' annotations were written out of order, they are sorted by running the
#' sortann tool, unless WFDBANNSORT is 0).
oannclose <- function(n) {
  oa <- .ann_oa(n)
  if (is.null(oa) || is.null(oa$file)) return(invisible())
  f <- oa$file
  if (oa$stat == WFDB_WRITE) {
    wf_p16(f, 0)
  } else if (oa$stat == WFDB_AHA_WRITE) {
    i <- .A_ABLKSIZ - (wf_tell(f) %% 4294967296) %% .A_ABLKSIZ
    wf_write(f, as.raw(rep.int(.A_EOAF, i)))
  }
  errflag <- wf_ferror(f)
  if (wf_close(f) != 0) errflag <- TRUE
  if (errflag) {
    wfdb_error("oannclose: write error on annotation file %s\n", oa$name)
    .ann$annclose_error <- -7
  }
  if (oa$out_of_order) {
    dosort <- .A_DEFWFDBANNSORT
    p <- cgetenv("WFDBANNSORT")
    if (!is.null(p)) dosort <- strtol(p)[1L]
    if (dosort) {
      wfdb_error("Rearranging annotations for output annotator %s ...", oa$name)
      cmd <- paste(tool_command("sortann"), "-r.", shell_quote(oa$rname), "-a",
                   shell_quote(oa$name))
      cout()
      st <- tryCatch(suppressWarnings(system(cmd)), error = function(e) -1)
      if (st == 0) {
        wfdb_error("done!\n")
        oa$out_of_order <- 0
      } else {
        wfdb_error("\nAnnotations still need to be rearranged.\n")
      }
      if (.ann$annclose_error == 0) .ann$annclose_error <- -6
    }
  }
  if (oa$out_of_order) {
    wfdb_error("Use the command:\n  sortann -r %s -a %s\n", oa$rname, oa$name)
    wfdb_error("to rearrange annotations in the correct order.\n")
    if (.ann$annclose_error == 0) .ann$annclose_error <- -6
  }
  oad <- .ann$oad
  oad[[n + 1L]] <- NULL
  .ann$oad <- oad
  invisible()
}

#' Close all annotators (called by wfdbquit).
wfdb_anclose <- function() {
  for (an in rev(seq_along(.ann$iad))) iannclose(an - 1L)
  for (an in rev(seq_along(.ann$oad))) oannclose(an - 1L)
  invisible()
}

#' Write the buffered output annotations (called by wfdbflush).
wfdb_oaflush <- function() {
  for (oa in .ann$oad) wf_flush(oa$file)
  invisible()
}

# ---------------------------------------------------------------------------
# Writing

#' Write an annotation to output annotator an.  Returns 0, or -1 (write
#' error, time overflow), -2 (invalid annotator).
putann <- function(an, annot) {
  oa <- .ann_oa(an)
  if (is.null(oa) || is.null(oa$file)) {
    wfdb_error("putann: can't write annotation file %d\n", an)
    return(-2)
  }
  t <- annot$time
  if (!oa$table_written) {
    oa$table_written <- 1
    if (.ann_puttable(an) < 0) return(-1)
  }
  f <- oa$file
  prev <- oa$ann
  pt <- prev$time
  achan <- cuint8(annot$chan)
  anum <- cint8(annot$num)
  typ <- annot$anntyp
  sub <- cint8(annot$subtyp)
  aux <- annot$aux
  if (is.character(aux)) aux <- .aux_from(aux)
  if (!(achan > cuint8(prev$chan) || anum > cint8(prev$num) || t > pt || (t == 0 && pt == 0)))
    oa$out_of_order <- 1
  if (oa$stat == WFDB_AHA_WRITE) {
    x <- t %% 4294967296
    hi <- x %/% 65536
    oa$seqno <- oa$seqno + 1
    sq <- oa$seqno %% 65536
    b <- integer(16)
    b[2L] <- mamap(typ, sub) %% 256
    b[3:8] <- c(hi %% 256, hi %/% 256, (x %% 65536) %% 256, (x %% 65536) %/% 256,
                sq %% 256, sq %/% 256)
    b[9L] <- sub %% 256
    b[10L] <- typ %% 256
    if (!is.null(aux)) {
      ln <- min(as.integer(aux[1L]), .A_AUXLEN)
      if (ln > 0L && length(aux) >= 2L) {
        d <- as.integer(aux[2:min(length(aux), ln + 1L)])
        b[10L + seq_along(d)] <- d
      }
    }
    wf_write(f, as.raw(b))
  } else {
    if (t <= WFDB_TIME_MIN || t >= WFDB_TIME_MAX) {
      wfdb_error("putann: time overflow in annotation file %d\n", an)
      return(-1)
    }
    d <- t - pt
    # a SKIP of interval x: its word, then x as a 32-bit value (high word
    # first)
    skipw <- function(x) {
      x <- x %% 4294967296
      c(.A_SKIP, x %/% 65536, x %% 65536)
    }
    w <- numeric(0)
    if (t > pt) {
      while (d > .A_MAXSKIP) {
        w <- c(w, skipw(.A_MAXSKIP))
        d <- d - .A_MAXSKIP
      }
    } else {
      while (d < .A_MINSKIP) {
        w <- c(w, skipw(.A_MINSKIP))
        d <- d - .A_MINSKIP
      }
    }
    if (typ == 0) {
      w <- c(w, skipw(d - 1))
      d <- 1
    } else if (d > .A_MAXRR || d < 0) {
      w <- c(w, skipw(d))
      d <- 0
    }
    w <- c(w, d + typ * .A_CMUL)
    if (sub != 0) w <- c(w, .A_SUB + sub %% .A_CMUL)
    if (achan != cuint8(prev$chan)) w <- c(w, .A_CHN + achan)
    if (anum != cint8(prev$num)) w <- c(w, .A_NUM + anum %% .A_CMUL)
    b <- .ann_words(w)
    if (!is.null(aux) && aux[1L] != as.raw(0L)) {
      ln <- as.integer(aux[1L])
      d <- raw(ln + ln %% 2L)
      if (length(aux) >= 2L) {
        x <- aux[2:min(length(aux), ln + 1L)]
        d[seq_along(x)] <- x
      }
      b <- c(b, .ann_words(.A_AUX + ln), d)
    }
    wf_write(f, b)
  }
  if (wf_ferror(f)) {
    wfdb_error("putann: write error on annotation file %s\n", oa$name)
    return(-1)
  }
  a <- list(time = t, anntyp = typ, subtyp = annot$subtyp, chan = annot$chan,
            num = annot$num, aux = NULL)
  a["aux"] <- list(aux)
  oa$ann <- a
  0
}

#' Write many annotations at once: exactly the effect of putann(an, a) for
#' each annotation a of A, a list of vectors time, anntyp, subtyp, chan,
#' num and aux (a list of NULL or raw vectors, or NULL for none), as
#' returned by .getann_bulk.  Returns the status of the last call (0 on
#' success), or the first negative status.  MIT-format output is encoded
#' with vector operations.
.putann_bulk <- function(an, A) {
  n <- length(A$time)
  stat <- 0
  if (n == 0L) return(0)
  rep_n <- function(x, def = 0) if (is.null(x)) rep(def, n) else rep_len(x, n)
  A$anntyp <- rep_n(A$anntyp)
  A$subtyp <- rep_n(A$subtyp)
  A$chan <- rep_n(A$chan)
  A$num <- rep_n(A$num)
  if (is.null(A$aux)) A$aux <- vector("list", n)
  scalar <- function(idx) {
    st <- 0
    for (k in idx) {
      s <- putann(an, list(time = A$time[k], anntyp = A$anntyp[k], subtyp = A$subtyp[k],
                           chan = A$chan[k], num = A$num[k], aux = A$aux[[k]]))
      if (st == 0 || s < 0) st <- s
    }
    st
  }
  oa <- .ann_oa(an)
  if (is.null(oa) || is.null(oa$file)) return(scalar(seq_len(n)))
  first <- 1L
  if (!oa$table_written) {
    stat <- scalar(1L)
    if (n == 1L) return(stat)
    first <- 2L
  }
  idx <- first:n
  t <- A$time[idx]
  pt <- c(oa$ann$time, t[-length(t)])
  d <- t - pt
  if (oa$stat != WFDB_WRITE || any(d > .A_MAXSKIP | d < .A_MINSKIP) ||
      any(t <= WFDB_TIME_MIN | t >= WFDB_TIME_MAX) || oa$file$is_std) {
    s <- scalar(idx)
    if (stat == 0 || s < 0) stat <- s
    return(stat)
  }
  m <- length(idx)
  typ <- A$anntyp[idx]
  sub <- cint8(A$subtyp[idx])
  achan <- cuint8(A$chan[idx])
  pchan <- c(cuint8(oa$ann$chan), achan[-m])
  anum <- cint8(A$num[idx])
  pnum <- c(cint8(oa$ann$num), anum[-m])
  if (any(!(achan > pchan | anum > pnum | t > pt | (t == 0 & pt == 0)))) oa$out_of_order <- 1
  aux <- A$aux[idx]
  hasaux <- lengths(aux) > 0L
  wa <- which(hasaux)
  for (k in wa[vapply(aux[wa], is.character, TRUE)]) aux[[k]] <- .aux_from(aux[[k]])
  auxln <- numeric(m)
  auxln[wa] <- vapply(aux[wa], function(x) as.numeric(x[1L]), 0)
  z <- typ == 0
  sk <- z | d > .A_MAXRR | d < 0
  skv <- d
  skv[z] <- d[z] - 1
  skv <- skv %% 4294967296
  dd <- d
  dd[z] <- 1
  dd[sk & !z] <- 0
  annwd <- (dd + typ * .A_CMUL) %% 65536
  hs <- sub != 0
  hc <- achan != pchan
  hn <- anum != pnum
  ha <- auxln != 0
  auxb <- auxln + auxln %% 2
  nw <- 3 * sk + 1 + hs + hc + hn + ha
  nb <- 2 * nw + auxb * ha
  off <- cumsum(c(0, nb[-m]))             # 0-based start of each segment
  B <- integer(sum(nb))
  p <- off
  putw <- function(pos, w) {
    B[pos + 1] <<- w %% 256
    B[pos + 2] <<- w %/% 256
  }
  k <- which(sk)
  putw(p[k], rep(.A_SKIP, length(k)))
  putw(p[k] + 2, skv[k] %/% 65536)
  putw(p[k] + 4, skv[k] %% 65536)
  p[k] <- p[k] + 6
  putw(p, annwd)
  p <- p + 2
  k <- which(hs)
  putw(p[k], .A_SUB + sub[k] %% .A_CMUL)
  p[k] <- p[k] + 2
  k <- which(hc)
  putw(p[k], .A_CHN + achan[k])
  p[k] <- p[k] + 2
  k <- which(hn)
  putw(p[k], .A_NUM + anum[k] %% .A_CMUL)
  p[k] <- p[k] + 2
  k <- which(ha)
  putw(p[k], .A_AUX + auxln[k])
  p[k] <- p[k] + 2
  if (length(k)) {
    dl <- lapply(k, function(q) {
      x <- aux[[q]]
      ln <- auxln[q]
      v <- integer(ln)
      if (length(x) >= 2L) {
        y <- as.integer(x[2:min(length(x), ln + 1)])
        v[seq_along(y)] <- y
      }
      v
    })
    B[sequence(auxln[k], from = p[k] + 1)] <- unlist(dl, use.names = FALSE)
  }
  wf_write(oa$file, as.raw(B))
  a <- list(time = A$time[n], anntyp = A$anntyp[n], subtyp = A$subtyp[n], chan = A$chan[n],
            num = A$num[n], aux = NULL)
  a["aux"] <- list(aux[[m]])
  oa$ann <- a
  if (wf_ferror(oa$file)) {
    wfdb_error("putann: write error on annotation file %s\n", oa$name)
    stat <- -1
  }
  stat
}

# ---------------------------------------------------------------------------
# Annotation code <-> mnemonic and description

.code_str <- function(tab, code) {
  r <- character(length(code))
  ok <- !is.na(code) & code >= 0 & code <= ACMAX
  r[ok] <- tab[code[ok] + 1]
  r[!ok] <- sprintf("[%s]", format(code[!ok], scientific = FALSE, trim = TRUE))
  r
}

#' The fixed mnemonic of annotation codes (vectorized).
ecgstr <- function(code) .code_str(.ann$cstring, code)

#' The annotation code of fixed mnemonics (NOTQRS if none; vectorized).
strecg <- function(s) {
  if (is.null(s)) s <- ""
  k <- match(s, .ann$cstring[-1L])
  ifelse(is.na(k), NOTQRS, as.numeric(k))
}

#' Redefine the fixed mnemonic of a code (0 to ACMAX).
setecgstr <- function(code, s) {
  if (code >= NOTQRS && code <= ACMAX) {
    .ann$cstring[code + 1] <- if (is.null(s)) "" else s
    return(0)
  }
  wfdb_error("setecgstr: illegal annotation code %d\n", code)
  -1
}

#' The (possibly redefined) mnemonic of annotation codes (vectorized).
annstr <- function(code) .code_str(.ann$astring, code)

#' The annotation code of mnemonics (NOTQRS if none; vectorized).
strann <- function(s) {
  if (is.null(s)) s <- ""
  k <- match(s, .ann$astring[-1L])
  ifelse(is.na(k), NOTQRS, as.numeric(k))
}

#' Redefine the mnemonic of a code; a positive code marks it as modified
#' (written as a modification label at the start of output annotation
#' files), a negative one (-code) does not.
setannstr <- function(code, s) {
  mflag <- code > 0
  if (!mflag) code <- -code
  if (code <= ACMAX) {
    if (is.null(s)) s <- ""
    if (is.na(.ann$astring[code + 1]) || .ann$astring[code + 1] != s) {
      .ann$astring[code + 1] <- s
      if (mflag) .ann$modified[code + 1] <- TRUE
    }
    return(0)
  }
  wfdb_error("setannstr: illegal annotation code %d\n", code)
  -1
}

#' The description of an annotation code (NULL if it has none).
anndesc <- function(code) {
  if (code >= 0 && code <= ACMAX) {
    d <- .ann$tstring[code + 1]
    return(if (is.na(d)) NULL else d)
  }
  "illegal annotation code"
}

#' Redefine the description of a code (see setannstr for negative codes).
setanndesc <- function(code, s) {
  mflag <- code > 0
  if (!mflag) code <- -code
  if (code <= ACMAX) {
    if (is.null(s)) s <- ""
    if (is.na(.ann$tstring[code + 1]) || .ann$tstring[code + 1] != s) {
      .ann$tstring[code + 1] <- s
      if (mflag) .ann$modified[code + 1] <- TRUE
    }
    return(0)
  }
  wfdb_error("setanndesc: illegal annotation code %d\n", code)
  -1
}

# ---------------------------------------------------------------------------
# Time resolution

#' Set the time resolution (ticks per second) recorded in output annotation
#' files opened later (not reset by wfdbquit).
setafreq <- function(f) {
  .ann$oafreq <- f
  invisible()
}

getafreq <- function() .ann$oafreq

#' Set the time resolution in which getann returns the times of input
#' annotator n.
setiafreq <- function(n, f) {
  ia <- .ann_ia(n)
  if (is.null(ia)) return(invisible())
  if (f > 0 && ia$afreq > 0) {
    ia$tmul <- f / ia$afreq
  } else {
    sf <- if (f > 0) sampfreq(NULL) else 0
    ia$tmul <- if (f > 0 && sf > 0) f * getspf() / sf else 1
  }
  ia$ann$time <- .ann_round(ia$ann_tt * ia$tmul)
  ia$pann$time <- .ann_round(ia$pann_tt * ia$tmul)
  ia$prev_time <- .ann_round(ia$prev_tt * ia$tmul)
  invisible()
}

#' The time resolution of input annotator n (-2 if it is not open).
getiafreq <- function(n) {
  ia <- .ann_ia(n)
  if (is.null(ia)) return(-2)
  if (ia$afreq > 0) return(ia$afreq * ia$tmul)
  sampfreq(NULL) * ia$tmul / getspf()
}

#' The time resolution recorded in input annotator n (0 if none; -2 if it
#' is not open).
getiaorigfreq <- function(n) {
  ia <- .ann_ia(n)
  if (is.null(ia)) -2 else ia$afreq
}

# ---------------------------------------------------------------------------
# Helpers for the tools
