# apps_time2sec.R: time2sec -- convert a time interval to seconds.
#
# Copyright (C) 2003-2009 George B. Moody (original C program, app/time2sec.c).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).

app_time2sec <- function(args = character(0)) {
  app_run(.time2sec_main, c("time2sec", args))
}

.time2sec_main <- function(argv) {
  argc <- length(argv)
  if (argc == 4L && argv[2L] == "-r") {
    isigopen(argv[3L], 0)
    t <- strtim(argv[4L])
    if (t < 0) t <- -t
    sf <- sampfreq(NULL)
    seconds <- d2l(t / sf)                              # (long)
    t <- t - seconds * sf
    milliseconds <- cint32(d2l((t * 1000) / sf + 0.5))  # int = (long)
    if (milliseconds >= 1000) {
      seconds <- seconds + 1
      milliseconds <- milliseconds - 1000
    }
    cprintf("%ld", seconds)
    if (milliseconds != 0) cprintf(".%03d", milliseconds)
    cprintf("\n")
    cexit(0)
  } else if (argc == 2L && !startsWith(argv[2L], "-")) {
    setsampfreq(1000)                     # strtim() then gives milliseconds
    cprintf("%.12g\n", strtim(argv[2L]) / 1000)
    cexit(0)
  }
  ceprintf("usage: %s [-r RECORD] TIME\n", argv[1L])
  ceprintf(" where TIME (in hh:mm:ss format) is a time interval\n")
  ceprintf(" to be converted into seconds.  Enclose TIME in\n")
  ceprintf(" square brackets (e.g., [9:0:0]) to convert a time\n")
  ceprintf(" of day to the elapsed time in seconds from the\n")
  ceprintf(" beginning of the (optionally) specified RECORD.\n")
  cexit(1)
}
