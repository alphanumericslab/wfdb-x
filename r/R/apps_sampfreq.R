# apps_sampfreq.R: sampfreq -- print the sampling frequency of a record.
#
# Copyright (C) 1998-2012 George B. Moody (original C program, app/sampfreq.c).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
# gain, ADC resolution or units. Values that the record or the user does not
# give are never assumed (the original package assumed 250 Hz, 200 adu/mV, 12
# bits and millivolts), because a silently assumed value corrupts every result
# derived from it. See docs/DIVERGENCES.md.
# GNU General Public License, version 2 or later (see LICENSE).

app_sampfreq <- function(args = character(0)) {
  app_run(.sampfreq_main, c("sampfreq", args))
}

.sampfreq_help <- function(pname) {
  ceprintf("usage: %s [OPTION] RECORD\n", pname)
  ceprintf("%s", paste0(
    " where RECORD is the name of the input record\n",
    " and OPTION may be either of:\n",
    "  -a   list all signals and their sampling frequencies\n",
    "  -h   show this help\n",
    "  -H   show the maximum sampling frequency of a multifrequency record)\n",
    " If no OPTION is used, show the base sampling frequency (frame rate).\n"))
}

.sampfreq_main <- function(argv) {
  pname <- argv[1L]
  argc <- length(argv)
  if (argc == 1L) {
    .sampfreq_help(pname)
    cexit(1)
  }
  if (argc == 2L) {
    cprintf("%g\n", sampfreq(argv[2L]))
    cexit(0)
  }
  if (argc == 3L && argv[2L] %in% c("-a", "-H")) {
    si <- list()
    nsig <- isigopen(argv[3L], 0)$nsig
    if (nsig > 0) si <- isigopen(argv[3L], nsig)$si
    if (argv[2L] == "-H") {
      setgvmode(WFDB_HIGHRES)
      cprintf("%g\n", sampfreq(NULL))
      cexit(0)
    }
    setgvmode(WFDB_LOWRES)
    freq <- sampfreq(NULL)
    for (i in seq_len(max(nsig, 0)))
      cprintf("%s\t%g\n", si[[i]]$desc, si[[i]]$spf * freq)
  }
  0
}
