# apps_sortann.R: sortann -- rearrange annotations in canonical order.
#
# Copyright (C) 1997-2010 George B. Moody (original C program, app/sortann.c;
# revised 2017-2018 by Benjamin Moody).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV, 12
# bits and millivolts), because a silently assumed value corrupts every result
# derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).
#
# The annotations are read in bulk; input that is already in order is
# recognized with vector operations, and out-of-order input is sorted with
# the doubly-linked list algorithm of sortann.c (which also determines
# which duplicates are discarded).

app_sortann <- function(args = character(0)) {
  app_run(.sortann_main, c("sortann", args))
}

.sortann_help <- function(pname) {
  ceprintf("usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n", pname)
  h <- c("where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
         " -f TIME    start at specified TIME",
         " -F FREQ    sampling frequency, if the record header does not specify one",
         " -h         print this usage summary",
         " -o OUTANN  write output as annotator OUTANN (required with -f or -t)",
         " -t TIME    stop at specified TIME",
         "The sorted output replaces the input if -o is omitted, the input is in",
         "the current directory, and the input is not already sorted.")
  h <- .app_help_text(h, h[3L])           # (-F)
  for (s in h) ceprintf("%s\n", s)
}

# The order of the annotations (indices into T, N, C: time, num, chan)
# after inserting them in turn into the list of sortann.c; in_order is
# FALSE if some annotation was inserted out of order.
.sortann_order <- function(T, N, C) {
  n <- length(T)
  if (n == 0L) return(list(order = integer(0), in_order = TRUE))
  if (n == 1L) return(list(order = 1L, in_order = TRUE))
  k <- 2:n
  gt <- T[k] > T[k - 1L] | (T[k] == T[k - 1L] & N[k] > N[k - 1L]) |
    (T[k] == T[k - 1L] & N[k] == N[k - 1L] & C[k] > C[k - 1L])
  if (all(gt)) return(list(order = seq_len(n), in_order = TRUE))
  # node 1 is the list head (an all-zero annotation, which takes part in
  # comparisons as in sortann.c); node j + 1 is annotation j; 0 is NULL
  TT <- c(0, T)
  NN <- c(0, N)
  CC <- c(0, C)
  nxt <- integer(n + 1L)
  prv <- integer(n + 1L)
  head <- 1L
  lastp <- head
  in_order <- TRUE
  for (j in seq_len(n)) {
    new <- j + 1L
    t <- TT[new]
    nm <- NN[new]
    ch <- CC[new]
    last <- lastp
    if (last == head || t > TT[last] || (t == TT[last] && nm > NN[last]) ||
        (t == TT[last] && nm == NN[last] && ch > CC[last])) {
      prv[new] <- last
      nxt[last] <- new
      lastp <- new
      nxt[new] <- 0L
      next
    }
    in_order <- FALSE
    ap <- last
    while (ap != 0L) {
      if (t > TT[ap] || (t == TT[ap] && nm > NN[ap]) ||
          (t == TT[ap] && nm == NN[ap] && ch >= CC[ap])) break
      ap <- prv[ap]
    }
    if (ap == 0L) {
      prv[new] <- 0L
      nxt[new] <- nxt[head]
      nxt[head] <- new
      prv[nxt[new]] <- new
    } else if (t == TT[ap] && nm == NN[ap] && ch == CC[ap]) {
      prv[new] <- prv[ap]
      if (prv[new] != 0L) nxt[prv[new]] <- new
      nxt[new] <- nxt[ap]
      if (nxt[new] != 0L) prv[nxt[new]] <- new else lastp <- new
      # If ap was the first entry of the list but its 'prev' link does not
      # lead back to the list head (an entry inserted at the beginning gets
      # a null link, and one whose predecessor replaced the head is
      # detached), C leaves the head pointing to the freed entry (undefined
      # behavior): here the head is updated, so that the duplicate is
      # replaced (see docs/KNOWN_C_BEHAVIORS.md).
      if (ap != head && nxt[head] == ap) nxt[head] <- new
    } else {
      prv[new] <- ap
      nxt[new] <- nxt[ap]
      nxt[ap] <- new
      prv[nxt[new]] <- new
    }
  }
  ord <- integer(n)
  m <- 0L
  p <- nxt[head]
  while (p != 0L) {
    m <- m + 1L
    ord[m] <- p - 1L
    p <- nxt[p]
  }
  list(order = ord[seq_len(m)], in_order = in_order)
}

.sortann_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  record <- NULL
  in_name <- out_name <- NULL
  from <- to <- 0
  Ffreq <- 0
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
        in_name <- argv[i]
      } else if (c == "f") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: starting time must follow -f\n", pname)
          cexit(1)
        }
        from <- i
      } else if (c == "F" && !wfdbx_get_legacy()) {  # frequency follows (wfdb-x)
        i <- i + 1L
        Ffreq <- .app_Fopt(pname, if (i <= argc) argv[i] else NULL)
      } else if (c == "h") {
        .sortann_help(pname)
        cexit(0)
      } else if (c == "o") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: annotator must follow -o\n", pname)
          cexit(1)
        }
        out_name <- argv[i]
      } else if (c == "r") {
        if (nchar(a, type = "bytes") > 2L) setwfdb(substr(a, 3L, nchar(a, type = "bytes")))
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: input record name must follow -r\n", pname)
          cexit(1)
        }
        record <- argv[i]
      } else if (c == "t") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: end time must follow -t\n", pname)
          cexit(1)
        }
        to <- i
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
  if (is.null(record) || is.null(in_name)) {
    .sortann_help(pname)
    cexit(1)
  }
  if ((from || to) && is.null(out_name)) {
    ceprintf("%s: -o required when using -f or -t options\n", pname)
    cexit(1)
  }
  if (!is.null(out_name) && in_name == out_name) {
    ceprintf("%s: must specify different annotator names after -a and -o\n", pname)
    cexit(1)
  }
  Sys.setenv(WFDBANNSORT = "0")
  # wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
  # the record had no header); -F specifies one.  It is needed only to
  # convert the -f and -t times.
  sps <- sampfreq(record)
  if (wfdbx_get_legacy()) {              # wfdb-x: legacy mode (original behavior)
    if (sps < 0) setsampfreq(sps <- WFDB_DEFFREQ)
  } else if (sps <= 0 && Ffreq > 0) {
    setsampfreq(sps <- Ffreq)
  }
  if (sps <= 0 && !wfdbx_get_legacy() &&
      ((from && wfdbx_time_needs_freq(argv[from])) ||
       (to && wfdbx_time_needs_freq(argv[to]))))
    .app_nofreq(pname, record, 1, useF = TRUE)
  if (annopen(record, list(anninfo(in_name, WFDB_READ)), 1) < 0) cexit(2)
  if (from) {
    from <- strtim(argv[from])
    if (from < 0) from <- -from
  }
  if (to) {
    to <- strtim(argv[to])
    if (to < 0) to <- -to
  }
  tps <- getiaorigfreq(0)
  if (tps > 0) {
    setafreq(tps)
    setiafreq(0, tps)
    if (wfdbx_get_legacy() || sps > 0) {
      from <- trunc(from * tps / sps + 0.5)
      to <- trunc(to * tps / sps + 0.5)
    } else if (from || to) {           # wfdb-x: no default sampling frequency
      .app_nofreq(pname, record, 1, useF = TRUE)
    }
  }
  A <- .getann_bulk(0, Inf)
  keep <- !(A$time < from | (to > 0 & A$time >= to))
  idx <- which(keep)
  so <- .sortann_order(A$time[idx], A$num[idx], A$chan[idx])
  iannclose(0)
  if (so$in_order && is.null(out_name)) {
    ceprintf("%s: input is already ordered -- no output written\n", pname)
    cexit(0)
  }
  if (from == 0 && to == 0 && is.null(out_name)) out_name <- in_name
  if (annopen(record, list(anninfo(out_name, WFDB_WRITE)), 1) < 0) cexit(2)
  k <- idx[so$order]
  k <- k[A$anntyp[k] != NOTQRS]
  .putann_bulk(0, list(time = A$time[k], anntyp = A$anntyp[k], subtyp = A$subtyp[k],
                       chan = A$chan[k], num = A$num[k], aux = A$aux[k]))
  wfdbquit()
  0
}
