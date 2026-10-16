# apps_m2a.R: m2a -- convert an MIT-format annotation file to AHA format.
#
# Copyright (C) 2001 George B. Moody (original C program, convert/m2a.c).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV, 12
# bits and millivolts), because a silently assumed value corrupts every result
# derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).

app_m2a <- function(args = character(0)) {
  app_run(.m2a_main, c("m2a", args))
}

.m2a_help <- function(pname) {
  ceprintf("usage: %s -r RECORD -a MIT-ANNOTATOR AHA-ANNOTATOR [ OPTIONS ... ]\n", pname)
  h <- c(
    "where RECORD is the record name, MIT-ANNOTATOR is the annotator name",
    "for the input annotation file, AHA-ANNOTATOR is the annotator name",
    "for the output (AHA format) annotation file, and OPTIONS may include:",
    " -F FREQ   sampling frequency, if the record header does not specify one",
    " -h        print this usage summary",
    " -s TIME   shift annotation times backwards by the specified TIME,",
    "            and convert them to milliseconds")
  h <- .app_help_text(h, h[4L])           # (-F)
  cerr(paste0(h, "\n", collapse = ""))
}

.m2a_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  ianame <- NULL
  oaname <- NULL
  record <- NULL
  shift <- NULL
  Ffreq <- 0
  i <- 2L
  while (i <= argc) {
    a <- argv[i]
    if (startsWith(a, "-")) {
      c <- substr(a, 2L, 2L)
      if (c == "a") {
        i <- i + 1L
        if (i >= argc) {
          ceprintf("%s: input and output annotator names must follow -a\n", pname)
          cexit(1)
        }
        ianame <- argv[i]
        i <- i + 1L
        oaname <- argv[i]
      } else if (c == "F" && !wfdbx_get_legacy()) {  # frequency follows (wfdb-x)
        i <- i + 1L
        Ffreq <- .app_Fopt(pname, if (i <= argc) argv[i] else NULL)
      } else if (c == "h") {
        .m2a_help(pname)
        cexit(1)
      } else if (c == "r") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: record name must follow -r\n", pname)
          cexit(1)
        }
        record <- argv[i]
      } else if (c == "s") {
        i <- i + 1L
        if (i > argc) {
          ceprintf("%s: time shift must follow -s\n", pname)
          cexit(1)
        }
        shift <- argv[i]
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
  if (is.null(ianame) || is.null(oaname) || is.null(record)) {
    .m2a_help(pname)
    cexit(1)
  }
  if (annopen(record, list(anninfo(ianame, WFDB_READ), anninfo(oaname, WFDB_AHA_WRITE)), 2) < 0)
    cexit(2)
  if (is.null(shift)) {
    A <- .getann_bulk(0, Inf)
  } else {
    # wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    # the record header did not specify one); -F specifies one.
    if (sampfreq(record) <= 0) {
      if (wfdbx_get_legacy()) setsampfreq(WFDB_DEFFREQ)    # wfdb-x: legacy mode
      else if (Ffreq > 0) setsampfreq(Ffreq)
      else .app_nofreq(pname, record, 1, useF = TRUE)
    }
    mssi <- 1000 / strtim("1")              # milliseconds per sample
    dt <- strtim(shift)
    A <- .getann_bulk(0, Inf)
    keep <- A$time >= dt
    A <- lapply(A[c("time", "anntyp", "subtyp", "chan", "num", "aux")], function(x) x[keep])
    A$time <- trunc((A$time - dt) * mssi)     # ((long) ...)
  }
  .putann_bulk(0, A)
  wfdbquit()
  0
}
