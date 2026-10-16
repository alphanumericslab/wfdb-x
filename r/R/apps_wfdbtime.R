# apps_wfdbtime.R: wfdbtime -- convert between times and sample numbers.
#
# Copyright (C) 2001 George B. Moody (original C program, app/wfdbtime.c;
# revised 2017-2018 by Benjamin Moody).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV, 12
# bits and millivolts), because a silently assumed value corrupts every result
# derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).

app_wfdbtime <- function(args = character(0)) {
  app_run(.wfdbtime_main, c("wfdbtime", args))
}

.wfdbtime_main <- function(argv) {
  argc <- length(argv)
  record <- NULL
  i <- 1L
  while (i < argc) {
    a <- argv[i + 1L]
    if (a == "-r") {
      if (!is.null(record)) wfdbquit()
      i <- i + 1L
      if (i == argc) break
      record <- argv[i + 1L]
      if (isigopen(record, 0)$nsig < 0) cexit(2)
      if (!wfdbx_get_legacy() && sampfreq(NULL) <= 0)  # wfdb-x: no default frequency
                                                       # (except in legacy mode)
        .app_nofreq(argv[1L], record, 2)
    } else if (!is.null(record)) {
      t <- strtim(a)
      if (t < 0) t <- -t
      sbuf <- csprintf("s%ld", t)
      cprintf("%15s\t%15s", sbuf, if (t == 0) "0:00.000" else mstimstr(t))
      cprintf("\t%15s\n", mstimstr(-t))
    }
    i <- i + 1L
  }
  if (is.null(record)) {
    ceprintf("usage: %s [ -r RECORD [ TIME ] ]\n", argv[1L])
    ceprintf(" where RECORD is the name of the input record\n")
    ceprintf(" Each TIME is a time to be converted\n")
    cexit(1)
  }
  wfdbquit()
  0
}
