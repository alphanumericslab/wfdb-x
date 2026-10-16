"""wfdbinit, wfdbquit, wfdbflush (port of lib/wfdbinit.c).

Copyright (C) 1983-2012 George B. Moody (original C implementation,
lib/wfdbinit.c; revised 2012-2019 by Benjamin Moody).
Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
This library is free software; you can redistribute it and/or modify it under
the terms of the GNU Library General Public License as published by the Free
Software Foundation; either version 2 of the License, or (at your option) any
later version.
"""

from . import _annot, _signal, _wfdbio

__all__ = ["wfdbinit", "wfdbquit", "wfdbflush"]


def wfdbinit(record, aiarray, nann, siarray, nsig):
    """Open the annotation files and the input signals of a record.

    Equivalent to annopen(record, aiarray, nann) followed, if that
    succeeds, by isigopen(record, siarray, nsig).  Returns the (negative)
    annopen() error code, or else the value returned by isigopen().
    """
    stat = _annot.annopen(record, aiarray, nann)
    if stat == 0:
        stat = _signal.isigopen(record, siarray, nsig)
    return stat


def wfdbquit():
    """Close all files and reset the library state.

    Output annotation files and signal files are completed (headers are
    not written: use newheader() first).  The WFDB path is reset to its
    initial value.
    """
    _annot._wfdb_anclose()
    _signal._wfdb_oinfoclose()
    _signal._wfdb_sigclose()
    _wfdbio.resetwfdb()
    _signal._wfdb_sampquit()
    _signal._wfdb_freeinfo()


def wfdbflush():
    """Write all buffered output annotations and samples to their files."""
    _annot._wfdb_oaflush()
    _signal._wfdb_osflush()
