# apps_signum.R: signum -- print the numbers of the signals of a record
# that have the given names.
#
# Copyright (C) 2008 George B. Moody (original C program, app/signum.c; revised
# 2021 by Benjamin Moody).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU General Public License, version 2 or later (see LICENSE).
#
# The option parsing is shared with signame (.signame_args).

app_signum <- function(args = character(0)) {
  app_run(.signum_main, c("signum", args))
}

.signum_helplines <- c(
  "usage: %s -r RECORD [OPTIONS ...]\n",
  "where RECORD is the name of the input record, and OPTIONS may include:",
  " -h          print this usage summary",
  " -s SIGNAL [SIGNAL ...]  print signal number(s) for the specified signal(s)")

.signum_main <- function(argv) {
  p <- .signame_args(argv, TRUE, .signum_helplines)
  descs <- lapply(p$si, function(s) s$desc)
  for (i in seq_len(p$nosig)) {
    name <- argv[p$isiglist + i]
    found <- which(vapply(descs, function(d) !is.null(d) && d == name, NA))
    # all the matching signal numbers, separated by tabs; X if none
    cprintf("%s\n", if (length(found)) paste(found - 1L, collapse = "\t") else "X")
  }
  wfdbquit()
  0
}
