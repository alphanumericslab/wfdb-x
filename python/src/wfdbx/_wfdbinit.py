"""wfdbinit, wfdbquit, wfdbflush (port of lib/wfdbinit.c).

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of lib/wfdbinit.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original code, but it is new code, not the original C code.

Changes from the original: wfdbquit leaves the input and output directories as
they are (the original restored the WFDB path); legacy mode (wfdbx_set_legacy)
restores the original behavior. Each change is marked "WFDB-x:" in the code;
docs/DIVERGENCES.md gives the reasons.

Original C code: lib/wfdbinit.c, WFDB Software Package 10.7.0.
  Copyright (C) 1983-2012 George B. Moody; revised 2012-2019 by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This library is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

from . import _annot, _signal, _wfdbio

__all__ = ["wfdbinit", "wfdbquit", "wfdbflush"]


def wfdbinit(record, aiarray, nann, siarray, nsig):
    """Open the annotation files and the input signals of a record.

    Equivalent to annopen(record, aiarray, nann) followed, if that
    succeeds, by isigopen(record, siarray, nsig).  Returns the (negative)
    annopen() error code, or else the value returned by isigopen().

    Translation of the C function wfdbinit() (lib/wfdbinit.c, WFDB 10.7.0):
    same arguments and results. Differences: those of annopen() and isigopen();
    see docs/DIVERGENCES.md.
    """
    stat = _annot.annopen(record, aiarray, nann)
    if stat == 0:
        stat = _signal.isigopen(record, siarray, nsig)
    return stat


def wfdbquit():
    """Close all files and reset the library state.

    Output annotation files and signal files are completed (headers are
    not written: use newheader() first).  The input and output directories
    are left as they are (WFDB-x; in legacy mode, the WFDB path is reset to
    its initial value, as by resetwfdb()).

    Translation of the C function wfdbquit() (lib/wfdbinit.c, WFDB 10.7.0):
    same arguments and results. Differences: the input and output directories
    are kept (the WFDB path is restored only in legacy mode); see
    docs/DIVERGENCES.md.
    """
    _annot._wfdb_anclose()
    _signal._wfdb_oinfoclose()
    _signal._wfdb_sigclose()
    if _signal.wfdbx_get_legacy():
        _wfdbio.resetwfdb()
    _signal._wfdb_sampquit()
    _signal._wfdb_freeinfo()


def wfdbflush():
    """Write all buffered output annotations and samples to their files.

    Translation of the C function wfdbflush() (lib/wfdbinit.c, WFDB 10.7.0):
    same arguments and results.
    """
    _annot._wfdb_oaflush()
    _signal._wfdb_osflush()
