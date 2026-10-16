# apps_wrann.R: wrann -- translate an ASCII annotation file (as made by
# rdann) to a binary annotation file.
#
# Copyright (C) 1983-2010 George B. Moody (original C program, app/wrann.c;
# revised 2018 by Benjamin Moody).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).
#
# Input in the usual form (every line with the five fields written by
# rdann) is parsed with vector operations and written with .putann_bulk;
# other input is handled line by line, exactly as the C program does (the
# fields keep their values from line to line when a line omits them).

app_wrann <- function(args = character(0)) {
  app_run(.wrann_main, c("wrann", args))
}

.WRANN_LINELEN <- 400L    # the size of the line buffer of wrann.c (fgets)

.wrann_help <- function(pname) {
  ceprintf("usage: %s -r RECORD -a ANNOTATOR <TEXT-FILE\n", pname)
  ceprintf("TEXT-FILE should be in the format produced by `rdann'.\n")
}

.wrann_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  record <- NULL
  ainame <- NULL
  i <- 2L
  while (i <= argc) {
    a <- argv[i]
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "a") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: annotator must follow -a\n", pname)
          cexit(1)
        }
        ainame <- argv[i]
      } else if (c == "h") {
        .wrann_help(pname)
        cexit(0)
      } else if (c == "r") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: input record name must follow -r\n", pname)
          cexit(1)
        }
        record <- argv[i]
      } else {
        ceprintf("%s: unrecognized option %s\n", pname, a)
        cexit(1)
      }
    } else {
      ceprintf("%s: unrecognized argument %s\n", pname, a)
      cexit(1)
    }
    i <- i + 1L
  }
  if (is.null(record) || is.null(ainame)) {
    .wrann_help(pname)
    cexit(1)
  }
  setafreq(sampfreq(record))
  if (annopen(record, list(anninfo(ainame, WFDB_WRITE)), 1) < 0) cexit(2)
  data <- stdin_bytes()
  A <- if (!l10n_info()$MBCS || !any(data >= as.raw(128L))) .wrann_fast(data) else NULL
  if (is.null(A)) A <- .wrann_lines(data)
  .putann_bulk(0, A)
  wfdbquit()
  0
}

# Python-style slice s[1:k] (k may be negative: counted from the end).
.wrann_head <- function(s, k) {
  n <- nchar(s, type = "bytes")
  k <- rep_len(k, length(s))
  k <- ifelse(k < 0, pmax(n + k, 0), pmin(k, n))
  substr(s, 1L, k)
}

# The aux strings: astr is the mnemonic field of each line when it is not a
# mnemonic ("" otherwise), lines the lines, tab the position of the first
# tab in the rest of the line after the time field (-1 if none).
.wrann_aux <- function(astr, lines, tab) {
  n <- length(lines)
  aux <- vector("list", n)
  w <- which(nzchar(astr) | tab > 0L)
  if (length(w) == 0L) return(aux)
  astr <- astr[w]
  tab <- tab[w]
  hasap <- tab > 0L
  ap <- character(length(w))
  ap[hasap] <- substring(lines[w][hasap], tab[hasap])
  la <- nchar(astr, type = "bytes")
  lp <- nchar(ap, type = "bytes")
  long <- hasap & la + lp + 2 > 256
  ap[long] <- .wrann_head(ap[long], 256 - la[long] - 3)
  sh <- hasap & !long
  ap[sh] <- .wrann_head(ap[sh], -1)
  ap1 <- substring(ap, 2L)
  s <- ifelse(nzchar(astr) & hasap, paste(astr, ap1), ifelse(nzchar(astr), astr, ap1))
  aux[w] <- lapply(s, .aux_from)
  aux
}

# Vectorized parse of the whole input; NULL if some line needs the
# line-by-line parser.
.wrann_fast <- function(data) {
  lines <- fgets_lines(data, .WRANN_LINELEN)
  n <- length(lines)
  if (n == 0L) return(list(time = numeric(0)))
  # the time field: from line[9] up to a space (for lines beginning with
  # '[', a space after the first ']' from line[9]); then the five fields
  ws <- "[ \t\n\v\f\r]*"
  num <- "([+-]?[0-9]{1,15}+)(?![0-9])"
  re <- paste0("^(?:\\[.{8}[^\\]\n]*+|(?!\\[).{9})[^ \n]*+ ()", ws, num, ws,
               "([^ \t\n\v\f\r]+)", ws, num, ws, num, ws, num)
  m <- regexpr(re, lines, perl = TRUE)
  if (any(m < 0L)) return(NULL)
  cs <- attr(m, "capture.start")
  ce <- cs + attr(m, "capture.length") - 1L
  fld <- function(k) substring(lines, cs[, k], ce[, k])
  tm <- as.numeric(fld(2L))
  annstr <- fld(3L)
  sub <- cint32(as.numeric(fld(4L)))
  ch <- cint32(as.numeric(fld(5L)))
  nm <- cint32(as.numeric(fld(6L)))
  tab <- regexpr("\t", lines, fixed = TRUE)
  if (any(tab > 0L & tab < cs[, 1L])) return(NULL)
  br <- startsWith(lines, "[")
  typ <- strann(annstr)
  time <- tm
  if (any(br)) time[br] <- -vapply(lines[br], strtim, 0, USE.NAMES = FALSE)
  keep <- !br | time >= 0
  isnote <- typ == NOTQRS
  typ[isnote] <- NOTE
  astr <- character(n)
  astr[isnote] <- annstr[isnote]
  if (!all(keep)) {
    lines <- lines[keep]
    astr <- astr[keep]
    tab <- tab[keep]
  }
  list(time = time[keep], anntyp = typ[keep], subtyp = cint8(sub[keep]),
       chan = cuint8(ch[keep]), num = cint8(nm[keep]), aux = .wrann_aux(astr, lines, tab))
}

# Line-by-line parse (exactly as wrann.c).
.wrann_lines <- function(data) {
  lines <- fgets_lines(data, .WRANN_LINELEN, as_raw = TRUE)
  n <- length(lines)
  time <- typ <- sb <- chn <- nmv <- numeric(n)
  aux <- vector("list", n)
  cnt <- 0L
  # (these keep their values from line to line, as in C)
  tm <- 0
  sub <- ch <- nm <- 0
  annstr <- raw(0)
  for (ln in lines) {
    z <- match(as.raw(0L), ln)
    if (!is.na(z)) ln <- ln[seq_len(z - 1L)]
    L <- length(ln)
    p <- 10L                              # line[9]
    br <- L >= 1L && ln[1L] == as.raw(91L)
    if (br) while (p <= L && ln[p] != as.raw(93L)) p <- p + 1L
    while (p <= L && ln[p] != as.raw(32L)) p <- p + 1L
    rest <- if (p + 1L <= L) ln[(p + 1L):L] else raw(0)
    r <- csscanf(as.integer(rest), "%lld%s%d%d%d")
    v <- r$v
    if (length(v) >= 1L) tm <- v[[1L]]
    if (length(v) >= 2L) annstr <- charToRaw(v[[2L]])
    if (length(v) >= 3L) sub <- v[[3L]]
    if (length(v) >= 4L) ch <- v[[4L]]
    if (length(v) >= 5L) nm <- v[[5L]]
    avs <- rawToChar(annstr)
    at <- strann(avs)
    if (br) {
      t <- -strtim(rawToChar(ln))
      if (t < 0) next
    } else {
      t <- tm
    }
    if (at == NOTQRS) {
      at <- NOTE
      astr <- avs
    } else {
      annstr <- raw(0)
      astr <- ""
    }
    cnt <- cnt + 1L
    time[cnt] <- t
    typ[cnt] <- at
    sb[cnt] <- cint8(sub)
    chn[cnt] <- cuint8(ch)
    nmv[cnt] <- cint8(nm)
    # (the aux string, from the bytes of the line)
    k <- match(as.raw(9L), rest)
    if (!is.na(k) || nzchar(astr)) {
      ab <- charToRaw(astr)
      ap <- if (!is.na(k)) rest[k:length(rest)] else NULL
      if (!is.null(ap)) {
        if (length(ab) + length(ap) + 2L > 256L) {
          e <- 256L - length(ab) - 3L
          e <- if (e < 0L) max(length(ap) + e, 0L) else min(e, length(ap))
          ap <- ap[seq_len(e)]
        } else {
          ap <- ap[seq_len(length(ap) - 1L)]
        }
      }
      ap1 <- if (length(ap) >= 2L) ap[-1L] else raw(0)
      s <- if (length(ab) && !is.null(ap)) c(ab, as.raw(32L), ap1) else
        if (length(ab)) ab else ap1
      aux[[cnt]] <- c(as.raw(length(s) %% 256L), s)
    }
  }
  s <- seq_len(cnt)
  list(time = time[s], anntyp = typ[s], subtyp = sb[s], chan = chn[s], num = nmv[s],
       aux = aux[s])
}
