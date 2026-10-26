# wfdbinit.R: wfdbinit, wfdbquit, wfdbflush (port of lib/wfdbinit.c).
#
# Copyright (C) 1983-2012 George B. Moody (original C implementation,
# lib/wfdbinit.c; revised 2012-2019 by Benjamin Moody).
# R implementation part of wfdb-x, Reza Sameni, Oct 2026.
# GNU Library General Public License, version 2 or later (see LICENSE.LIB).

#' Open the annotation files (aiarray: list of anninfo lists) and the input
#' signals (up to nsig) of a record.  Returns list(stat, si): stat is the
#' annopen status if it failed, otherwise that of isigopen (si: the siginfo
#' lists of the signals opened).
wfdbinit <- function(record, aiarray, nsig) {
  stat <- annopen(record, aiarray)
  if (stat == 0) {
    r <- isigopen(record, nsig)
    return(list(stat = r$nsig, si = r$si))
  }
  list(stat = stat, si = list())
}

#' Close all annotation and signal files and reset the library state (the
#' state that C keeps across wfdbquit is kept: see docs/KNOWN_C_BEHAVIORS.md).
wfdbquit <- function() {
  wfdb_anclose()
  .wfdb_oinfoclose()
  .wfdb_sigclose()
  # wfdb-x: the input and output directories are left as they are (in
  # legacy mode, the WFDB path is reset, as in C)
  if (wfdbx_get_legacy()) resetwfdb()
  .wfdb_sampquit()
  wfdb_freeinfo()
  invisible()
}

#' Write all buffered output annotations and samples to their files.
wfdbflush <- function() {
  wfdb_oaflush()
  .wfdb_osflush()
  invisible()
}
