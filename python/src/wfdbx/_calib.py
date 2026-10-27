"""Calibration list functions (port of lib/calib.c).

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of lib/calib.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original code, but it is new code, not the original C code.

Changes from the original: none, apart from the language.

Original C code: lib/calib.c, WFDB Software Package 10.7.0.
  Copyright (C) 1991-2013 George B. Moody; revised 2019-2022 by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This library is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import os

from ._cstd import Strtok, strtod
from . import _wfdbio as wio
from ._wfdbio import wfdb_error, wfdb_open, WFDB_READ, WFDB_WRITE, DEFWFDBCAL

__all__ = ["Calinfo", "calopen", "getcal", "putcal", "newcal", "flushcal",
           "WFDB_AC_COUPLED", "WFDB_DC_COUPLED", "WFDB_CAL_SQUARE",
           "WFDB_CAL_SINE", "WFDB_CAL_SAWTOOTH", "WFDB_CAL_UNDEF"]

WFDB_AC_COUPLED = 0
WFDB_DC_COUPLED = 1
WFDB_CAL_SQUARE = 2
WFDB_CAL_SINE = 4
WFDB_CAL_SAWTOOTH = 6
WFDB_CAL_UNDEF = 8


class Calinfo:
    """Calibration information (WFDB_Calinfo): a calibration list entry.

    Attributes:
      low, high  low and high levels of the calibration pulse, in
                 physical units (both 0 if undefined)
      scale      customary plotting scale (physical units per cm)
      sigtype    signal type, matched against the beginning of a signal
                 description (empty: any signal)
      units      physical units
      caltype    WFDB_AC_COUPLED or WFDB_DC_COUPLED, OR-ed with the pulse
                 shape (WFDB_CAL_SQUARE, WFDB_CAL_SINE, WFDB_CAL_SAWTOOTH)
    """

    __slots__ = ("low", "high", "scale", "sigtype", "units", "caltype")

    def __init__(self, low=0.0, high=0.0, scale=0.0, sigtype=None,
                 units=None, caltype=0):
        self.low = low
        self.high = high
        self.scale = scale
        self.sigtype = sigtype
        self.units = units
        self.caltype = caltype

    def copy(self):
        """Return a copy of this entry."""
        return Calinfo(self.low, self.high, self.scale, self.sigtype,
                       self.units, self.caltype)

    def __repr__(self):
        return ("Calinfo(low=%r, high=%r, scale=%r, sigtype=%r, units=%r, "
                "caltype=%d)" % (self.low, self.high, self.scale,
                                 self.sigtype, self.units, self.caltype))


_cal = []      # the calibration list


def calopen(cfname=None):
    """Read a calibration file into the calibration list.

    ``cfname`` is searched for in the WFDB path; if None, the WFDBCAL
    environment variable (or "wfdbcal") is used.  The list is emptied
    first, unless the name begins with '+'.  Returns 0 on success, or -2 if
    the file cannot be read.

    Translation of the C function calopen() (lib/calib.c, WFDB 10.7.0): same
    arguments and results. Differences: the calibration file is found only
    where it is named, not by a search of the WFDB path; see
    docs/DIVERGENCES.md.
    """
    if cfname is None:
        cfname = os.environ.get("WFDBCAL")
        if cfname is None:
            cfname = DEFWFDBCAL
            if cfname is None:
                return 0
    if cfname.startswith("+"):
        cfname = cfname[1:]
    else:
        flushcal()
    cfile = wfdb_open(cfname, None, WFDB_READ)
    if cfile is None:
        wfdb_error("calopen: can't read calibration file %s\n", cfname)
        return -2
    while True:
        buf = cfile.getline()
        if buf == "":
            break
        i = 0
        while i < len(buf) and buf[i] in " \t\r":
            i += 1
        if buf[i:i + 1] == "#":
            continue
        tok = Strtok(buf[i:])
        p1 = tok.next("\t")
        p2 = tok.next(" \t") if p1 is not None else None
        p3 = tok.next(" \t") if p2 is not None else None
        p4 = tok.next(" \t") if p3 is not None else None
        p5 = tok.next(" \t") if p4 is not None else None
        p6 = tok.next(" \t\r\n") if p5 is not None else None
        if p6 is None:
            continue
        c = Calinfo()
        if p1 == "*":
            p1 = ""
        c.sigtype = p1
        if p2 == "-":
            c.caltype = WFDB_AC_COUPLED
            c.low = 0.0
        else:
            c.caltype = WFDB_DC_COUPLED
            c.low = strtod(p2)[0]
        if p3 == "-":
            c.high = c.low = 0.0
        else:
            c.high = strtod(p3)[0]
        if p4 == "square":
            c.caltype |= WFDB_CAL_SQUARE
        elif p4 == "sine":
            c.caltype |= WFDB_CAL_SINE
        elif p4 == "sawtooth":
            c.caltype |= WFDB_CAL_SAWTOOTH
        c.scale = strtod(p5)[0]
        c.units = p6
        _cal.append(c)
    cfile.close()
    return 0


def getcal(desc, units, cal):
    """Find the first calibration entry that matches a signal.

    An entry matches if its sigtype is a prefix of ``desc`` and its units
    equal ``units`` (None matches anything).  The entry is copied into the
    Calinfo object ``cal``.  Returns 0 if found, or -1 otherwise.

    Translation of the C function getcal() (lib/calib.c, WFDB 10.7.0): same
    arguments and results.
    """
    for c in _cal:
        if (desc is None or desc[:len(c.sigtype)] == c.sigtype) and \
                (units is None or units == c.units):
            cal.low = c.low
            cal.high = c.high
            cal.scale = c.scale
            cal.sigtype = c.sigtype
            cal.units = c.units
            cal.caltype = c.caltype
            return 0
    return -1


def putcal(cal):
    """Append a copy of cal to the calibration list; return 0.

    Translation of the C function putcal() (lib/calib.c, WFDB 10.7.0): same
    arguments and results.
    """
    _cal.append(cal.copy())
    return 0


def newcal(cfname):
    """Write the calibration list to the file cfname (in calopen() format).

    Returns 0 on success, or -1 if the name is illegal or the file cannot
    be written.

    Translation of the C function newcal() (lib/calib.c, WFDB 10.7.0): same
    arguments and results.
    """
    if wio.wfdb_checkname(cfname, "calibration file") < 0:
        return -1
    cfile = wfdb_open(cfname, None, WFDB_WRITE)
    if cfile is None:
        wfdb_error("newcal: can't create calibration file %s\n", cfname)
        return -1
    for c in _cal:
        out = ["%s\t" % (c.sigtype if c.sigtype else "*")]
        if c.caltype & WFDB_DC_COUPLED:
            out.append("%g " % c.low)
        else:
            out.append("- ")
        if c.high != c.low:
            out.append("%g " % c.high)
        else:
            out.append("- ")
        pt = c.caltype & ~WFDB_DC_COUPLED
        pulsetype = {WFDB_CAL_SQUARE: "square", WFDB_CAL_SINE: "sine",
                     WFDB_CAL_SAWTOOTH: "sawtooth"}.get(pt, "undefined")
        out.append("%s %g %s\r\n" % (pulsetype, c.scale, c.units))
        cfile.write("".join(out).encode("latin-1"))
    errflag = cfile.ferror()
    if cfile.close():
        errflag = True
    if errflag:
        wfdb_error("newcal: write error in calibration file\n")
        return -1
    return 0


def flushcal():
    """Empty the calibration list.

    Translation of the C function flushcal() (lib/calib.c, WFDB 10.7.0): same
    arguments and results.
    """
    del _cal[:]
