# wfdbinit.R: wfdbinit, wfdbquit, wfdbflush (port of lib/wfdbinit.c).
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is an R translation of lib/wfdbinit.c from the WFDB Software Package
# 10.7.0, by George B. Moody. The translation follows the logic and behavior of
# the original code, but it is new code, not the original C code.
#
# Changes from the original: wfdbquit leaves the input and output directories
# as they are (the original restored the WFDB path); legacy mode
# (wfdbx_set_legacy) restores the original behavior. Each change is marked
# "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
#
# Original C code: lib/wfdbinit.c, WFDB Software Package 10.7.0.
#   Copyright (C) 1983-2012 George B. Moody; revised 2012-2019 by
#   Benjamin Moody.
# R translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

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
