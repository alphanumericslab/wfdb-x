"""Annotation I/O for the WFDB library (port of lib/annot.c).

Annotation files are read with getann() and written with putann(), in
either MIT or AHA format.  An annotation's ``aux`` field, when present, is
a ``bytes`` object whose first byte is the length of the data that follows,
exactly as in the C library.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of lib/annot.c from the WFDB Software Package
10.7.0, by George B. Moody. The translation follows the logic and behavior of
the original code, but it is new code, not the original C code.

Changes from the original: oannclose sorts an out-of-order output annotation
file in this process, with the same result as the sortann program, which the
original ran through the shell; the sort does not lose an out-of-order
annotation at time 0 (num 0, chan 0), nor those inserted after it; the sort
option of the high-level write_annotations decides, for its call, whether the
file is sorted; legacy mode (wfdbx_set_legacy) restores the original behavior.
Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the
reasons.

Original C code: lib/annot.c, WFDB Software Package 10.7.0.
  Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This library is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import os
import subprocess
import sys

from ._cstd import LONG_MIN, LONG_MAX, int8, uint8, strtol, strtod, sprintf
from . import _wfdbio as wio
from ._wfdbio import (wfdb_error, wfdb_open, WFDB_READ, WFDB_WRITE,
                      WFDB_AHA_READ, WFDB_AHA_WRITE)
from ._ecgcodes import ACMAX, NOTE, NOTQRS, ammap, mamap

__all__ = [
    "Anninfo", "Annotation", "annopen", "getann", "ungetann", "putann",
    "iannsettime", "ecgstr", "strecg", "setecgstr", "annstr", "strann",
    "setannstr", "anndesc", "setanndesc", "setafreq", "getafreq",
    "setiafreq", "getiafreq", "getiaorigfreq", "iannclose", "oannclose",
]

# Layout of a 16-bit MIT annotation word (names as in annot.c).
CODE = 0o176000         # annotation code segment of an annotation word
CS = 10                 # number of places by which code must be shifted
DATA = 0o1777           # data segment of an annotation word
MAXRR = 0o1777          # longest interval that can be coded in a word
MAXSKIP = 0x7FFFFFFF    # largest interval represented by a SKIP
MINSKIP = -0x7FFFFFFF   # smallest interval represented by a SKIP
# Pseudo-annotation codes (between PAMIN and CODE; PAMIN > ACMAX << CS).
PAMIN = 59 << CS
SKIP = 59 << CS         # long null annotation
NUM = 60 << CS          # change 'num' field
SUB = 61 << CS          # subtype
CHN = 62 << CS          # change 'chan' field
AUX = 63 << CS          # auxiliary information
# Constants for AHA annotation files only.
ABLKSIZ = 1024          # AHA annotation file block length
AUXLEN = 6              # length of AHA aux field
EOAF = 0o377            # padding for end of AHA annotation files
WFDB_TIME_MIN = LONG_MIN
WFDB_TIME_MAX = LONG_MAX
DEFWFDBANNSORT = 1
_U64 = (1 << 64) - 1    # mask for unsigned 64-bit arithmetic
_TIME_RES = "## time resolution: "      # prefix of the time-resolution note


class Anninfo:
    """Annotator information (WFDB_Anninfo), as passed to annopen().

    Attributes:
      name   annotator name, i.e. the annotation file suffix (e.g. "atr")
      stat   file mode: WFDB_READ or WFDB_WRITE (MIT format), or
             WFDB_AHA_READ or WFDB_AHA_WRITE (AHA format)
    """

    __slots__ = ("name", "stat")

    def __init__(self, name=None, stat=WFDB_READ):
        self.name = name
        self.stat = stat

    def __repr__(self):
        return "Anninfo(name=%r, stat=%d)" % (self.name, self.stat)


class Annotation:
    """An annotation (WFDB_Annotation).

    Attributes:
      time    time of the annotation, in sample intervals
      anntyp  annotation type code (NORMAL, PVC, ...; see annstr())
      subtyp  annotation subtype
      chan    channel number
      num     annotator number
      aux     None, or a bytes object: aux[0] is the length of the auxiliary
              data, which follows in aux[1:] (see aux_string())
    """

    __slots__ = ("time", "anntyp", "subtyp", "chan", "num", "aux")

    def __init__(self, time=0, anntyp=0, subtyp=0, chan=0, num=0, aux=None):
        self.time = time
        self.anntyp = anntyp
        self.subtyp = subtyp
        self.chan = chan
        self.num = num
        self.aux = aux

    def copy(self):
        """Return a copy of this annotation."""
        return Annotation(self.time, self.anntyp, self.subtyp, self.chan,
                          self.num, self.aux)

    def assign(self, other):
        """Copy the fields of another annotation into this one."""
        self.time = other.time
        self.anntyp = other.anntyp
        self.subtyp = other.subtyp
        self.chan = other.chan
        self.num = other.num
        self.aux = other.aux

    def aux_string(self):
        """Return the aux data as a str (up to the first NUL byte), or None."""
        if self.aux is None:
            return None
        b = bytes(self.aux[1:1 + self.aux[0]])
        i = b.find(b"\0")
        if i >= 0:
            b = b[:i]
        return b.decode("latin-1")

    def __repr__(self):
        return ("Annotation(time=%d, anntyp=%d, subtyp=%d, chan=%d, num=%d, "
                "aux=%r)" % (self.time, self.anntyp, self.subtyp, self.chan,
                             self.num, self.aux))


AUXBUFLEN = 771      # size of the aux string buffer of an input annotator


class _IAData:
    __slots__ = ("file", "info", "ann", "pann", "afreq", "word", "ateof",
                 "tmul", "tt", "ann_tt", "pann_tt", "prev_tt", "prev_time",
                 "auxstr", "index", "auxpos")

    def __init__(self):
        self.file = None
        self.info = Anninfo()
        self.ann = Annotation()
        self.pann = Annotation()
        self.afreq = 0.0
        self.word = 0
        self.ateof = 0
        self.tmul = 0.0
        self.tt = 0.0
        self.ann_tt = 0.0
        self.pann_tt = 0.0
        self.prev_tt = 0.0
        self.prev_time = 0
        # The aux strings are kept in a buffer of AUXBUFLEN bytes, used as a
        # ring, as in C (stale bytes in it are visible to applications).
        self.auxstr = bytearray(AUXBUFLEN)
        self.index = 0          # next available position in auxstr
        self.auxpos = -1        # position of the aux string of ann, or -1


class _OAData:
    __slots__ = ("file", "info", "ann", "afreq", "seqno", "rname", "fname",
                 "out_of_order", "table_written")

    def __init__(self):
        self.file = None
        self.info = Anninfo()
        self.ann = Annotation()
        self.afreq = 0.0
        self.seqno = 0
        self.rname = None
        self.fname = None       # WFDB-x: the name of the file (as created)
        self.out_of_order = 0
        self.table_written = 0


class _AnnState:
    def __init__(self):
        self.iad = []
        self.oad = []
        self.oafreq = 0.0
        self.annclose_error = 0
        self.modified = [0] * (ACMAX + 1)
        # WFDB-x: if not None, whether oannclose sorts an out-of-order file
        # (instead of WFDBANNSORT); set by write_annotations(sort=...)
        self.sort_override = None


_a = _AnnState()


class _AnnDefs:
    """A table of annotation type definitions (WFDB-x): mnemonics,
    descriptions, and flags marking the modified types.  _lib_defs (defined
    below) is that of the library; _sort_ann_file uses one of its own."""
    __slots__ = ("astr", "tstr", "mod")

    def __init__(self, astr, tstr, mod):
        self.astr = astr
        self.tstr = tstr
        self.mod = mod


def _round_to_time(x):
    if x != x:
        return WFDB_TIME_MIN
    if x >= 0:
        if x >= WFDB_TIME_MAX:
            return WFDB_TIME_MAX
        t = int(x)
        return t + 1 if x - t >= 0.5 else t
    if x <= WFDB_TIME_MIN:
        return WFDB_TIME_MIN
    t = int(x)
    return t - 1 if x - t < -0.5 else t


def _cstr(b):
    i = b.find(b"\0")
    return b if i < 0 else b[:i]


def _read_ann_table(ia, defs):
    """The body of _get_ann_table (WFDB-x), for the input annotator ia and
    the definition table defs (the library's, or that of _sort_ann_file)."""
    ia.tmul = 1.0
    ia.afreq = 0.0
    annot = Annotation()
    if _getann_ia(ia, annot) < 0:
        return -1
    while _getann_ia(ia, annot) == 0 and annot.time == 0 and \
            annot.anntyp == NOTE and annot.subtyp == 0:
        if annot.aux is None or annot.aux[0] < 1:
            continue
        text = _cstr(bytes(annot.aux[1:])).decode("latin-1")
        if text.startswith("#"):
            if text.startswith(_TIME_RES):
                # sscanf(aux + 20, "%lf", ...) in C: aux[0] is the length.
                pos = len(_TIME_RES) - 1
                v, end = strtod(text, pos)
                if end != pos:
                    ia.afreq = v
            continue
        p1 = 0
        n = len(text)
        while p1 < n and text[p1] in " \t":
            p1 += 1
        a, p2 = strtol(text, 10, p1)
        if a < 0 or a > ACMAX or p1 == p2:
            continue
        while p2 < n and text[p2] not in " \t":
            p2 += 1
        p1 = p2
        while p1 < n and text[p1] in " \t":
            p1 += 1
        p2 = p1
        while p2 < n and text[p2] not in " \t":
            p2 += 1
        if p2 != p1:
            if p2 < n:
                _set_def_string(defs.tstr, defs.mod, a, text[p2 + 1:])
            else:
                _set_def_string(defs.tstr, defs.mod, a, None)
            _set_def_string(defs.astr, defs.mod, a, text[p1:p2])
    if annot.time != 0 or annot.anntyp != NOTE or annot.subtyp != 0 or \
            annot.aux is None:
        _ungetann_ia(ia, annot)
    return 0


def _get_ann_table(i):
    if _read_ann_table(_a.iad[i], _lib_defs) < 0:
        return -1
    from ._signal import getifreq
    setiafreq(i, getifreq())
    return 0


def _put_ann_table(oa, n, freq, defs):
    """Write the table to the output annotator oa (number n), with the time
    resolution freq and the definition table defs (WFDB-x: the C library
    used oad[n], oafreq, and the library's table)."""
    flag = 0
    annot = Annotation(0, NOTE, 0, 0, 0, None)

    def aux_of(s):
        b = s.encode("latin-1")
        return bytes((len(b) & 0xFF,)) + b

    if freq != oa.afreq and freq > 0.0:
        annot.aux = aux_of(sprintf(_TIME_RES + "%.12g", freq))
        oa.afreq = freq
        if _put_ann_word(oa, n, annot) < 0:
            return -1
        flag = 1
    for a in range(ACMAX + 1):
        if defs.mod[a]:
            if flag < 2:
                annot.aux = aux_of("## annotation type definitions")
                if _put_ann_word(oa, n, annot) < 0:
                    return -1
            d = defs.tstr[a]
            if d is not None:
                st = "%d %s %s" % (a, defs.astr[a], d)
            else:
                st = "%d %s " % (a, defs.astr[a])
            b = st.encode("latin-1")
            n = len(b)      # the length byte saturates at 255, as in C
            annot.aux = bytes((255 if n > 255 else n,)) + b
            if _put_ann_word(oa, n, annot) < 0:
                return -1
            flag = 2
    if flag == 2:
        annot.aux = aux_of("## end of definitions")
        if _put_ann_word(oa, n, annot) < 0:
            return -1
    if flag:
        annot.anntyp = 0
        annot.aux = None
        if _put_ann_word(oa, n, annot) < 0:
            return -1
    return 0


def _ann_file_format(ia):
    """Read the first word of the input annotation file of ia, and return
    its format: WFDB_READ (MIT format; any initial null annotations are then
    read as well) or WFDB_AHA_READ.  (WFDB-x: this was part of annopen.)"""
    # AHA-format files begin with a null byte and an ASCII character which
    # is one of the legal AHA annotation codes other than '[' or ']'.
    ia.word = ia.file.g16() & 0xFFFFFFFF
    a = (ia.word >> 8) & 0xFF
    if (ia.word & 0xFF) or ammap(a) == NOTQRS or a == ord("[") or \
            a == ord("]"):
        while (ia.word & CODE) == SKIP:
            ia.tt += ia.file.g32()
            ia.word = ia.file.g16() & 0xFFFFFFFF
        return WFDB_READ
    return WFDB_AHA_READ


def annopen(record, aiarray, nann=None):
    """Open annotation files for a record.

    Annotators already open are closed first, unless ``record`` begins
    with '+'.  Input annotators are numbered from 0 in the order given
    (the ``n`` argument of getann()), and likewise output annotators (the
    ``n`` argument of putann()).

    Arguments:
      record   record name
      aiarray  list of Anninfo objects (annotator name and mode)
      nann     number of entries of aiarray to use (default: all)

    Returns:
       0  success
      -3  an input annotation file cannot be opened
      -4  an output annotation file cannot be created (or illegal name)
      -5  illegal stat in aiarray
      -6  output annotations closed by this call could not be sorted
          (only if nann is 0)
      -7  write error while closing output annotations (only if nann is 0)

    Translation of the C function annopen() (lib/annot.c, WFDB 10.7.0): same
    arguments and results. Differences: the annotation files are found only
    where they are named, not by a search of the WFDB path; see
    docs/DIVERGENCES.md.
    """
    if nann is None:
        nann = len(aiarray) if aiarray else 0
    _a.annclose_error = 0
    if record.startswith("+"):
        record = record[1:]
    else:
        _wfdb_anclose()
    if nann == 0:
        return _a.annclose_error
    record = wio.wfdb_striphea(record)
    for i in range(nann):
        if aiarray[i].stat not in (WFDB_READ, WFDB_AHA_READ, WFDB_WRITE,
                                   WFDB_AHA_WRITE):
            wfdb_error("annopen: illegal stat %d for annotator %s, record "
                       "%s\n", aiarray[i].stat, aiarray[i].name, record)
            return -5
    for i in range(nann):
        ai = aiarray[i]
        if ai.stat in (WFDB_READ, WFDB_AHA_READ):
            ia = _IAData()
            wio.wfdb_setirec(record)
            ia.file = wfdb_open(ai.name, record, WFDB_READ)
            if ia.file is None:
                wfdb_error("annopen: can't read annotator %s for record %s\n",
                           ai.name, record)
                return -3
            ia.info.name = ai.name
            if _ann_file_format(ia) == WFDB_READ:
                if ai.stat != WFDB_READ:
                    wfdb_error("warning (annopen, annotator %s, record %s):\n",
                               ai.name, record)
                    wfdb_error(" file appears to be in MIT format\n")
                    wfdb_error(" ... continuing under that assumption\n")
                ia.info.stat = WFDB_READ
            else:
                if ai.stat != WFDB_AHA_READ:
                    wfdb_error("warning (annopen, annotator %s, record %s):\n",
                               ai.name, record)
                    wfdb_error(" file appears to be in AHA format\n")
                    wfdb_error(" ... continuing under that assumption\n")
                ia.info.stat = WFDB_AHA_READ
            ia.ann.anntyp = 0
            _a.iad.append(ia)
            _get_ann_table(len(_a.iad) - 1)
        else:
            if wio.wfdb_checkname(ai.name, "annotator"):
                return -4
            oa = _OAData()
            oa.file = wfdb_open(ai.name, record, WFDB_WRITE)
            if oa.file is None:
                wfdb_error("annopen: can't write annotator %s for record %s\n",
                           ai.name, record)
                return -4
            oa.info.name = ai.name
            oa.rname = record
            oa.fname = wio.wfdbfile(None, None)     # WFDB-x: for sorting
            oa.ann.time = 0
            oa.info.stat = ai.stat
            oa.out_of_order = 0
            oa.table_written = 0
            _a.oad.append(oa)
    return 0


def getann(n, annot):
    """Read the next annotation from input annotator n into ``annot``.

    ``annot`` is an Annotation object whose fields are replaced.

    Returns:
       0  success
      -1  end of file (annot is not valid)
      -2  n is not an open input annotator
      -3  unexpected physical end of file

    Translation of the C function getann() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    iad = _a.iad
    if n < 0 or n >= len(iad) or iad[n] is None or iad[n].file is None:
        wfdb_error("getann: can't read annotator %d\n", n)
        return -2
    return _getann_ia(iad[n], annot)


def _getann_ia(ia, annot):
    """The body of getann (WFDB-x), for the input annotator ia."""
    if ia.pann.anntyp:
        annot.assign(ia.pann)
        ia.pann.anntyp = 0
        ia.prev_time = annot.time
        ia.prev_tt = ia.pann_tt
        return 0
    if ia.ateof:
        if ia.ateof != -1:
            return -1
        wfdb_error("getann: unexpected EOF in annotator %s\n", ia.info.name)
        return -3
    annot.assign(ia.ann)
    ia.prev_time = annot.time
    ia.prev_tt = ia.ann_tt
    # In C, annot->aux points into the aux buffer, so reading the next
    # annotation (below) may overwrite the aux data of the one returned.
    retpos = ia.auxpos
    _getann_next(ia)
    annot.aux = _aux_from_buffer(ia, retpos) if retpos >= 0 else None
    return 0


def _aux_from_buffer(ia, pos):
    """The aux string at position pos of the aux buffer: the length byte,
    the data, and any following bytes up to a null (as C would read it)."""
    buf = ia.auxstr
    ln = buf[pos]
    i = pos + 1
    while i < AUXBUFLEN and (i - pos - 1 < ln or buf[i]):
        i += 1
    return bytes(buf[pos:i])


def _getann_next(ia):
    """Read the next annotation of an input annotator into ia.ann."""
    f = ia.file
    buf = ia.auxstr
    if ia.info.stat == WFDB_AHA_READ:
        if (ia.word & 0o377) == EOAF:
            ia.ateof = 1
            return
        a = ia.word >> 8
        ia.ann.anntyp = int8(ammap(a))
        ia.ann_tt = float(f.g32())
        if f.g16() <= 0:
            wfdb_error("getann: unexpected annot number in annotator %s\n",
                       ia.info.name)
        ia.ann.subtyp = int8(f.getc())
        if a == ord("U") and ia.ann.subtyp == 0:
            ia.ann.subtyp = -1
        ia.ann.chan = uint8(f.getc())
        if ia.index >= 256 - (AUXLEN + 2):
            ia.index = 0
        k = ia.index + 1
        auxd = f.read(AUXLEN)
        buf[k:k + len(auxd)] = auxd
        if buf[k]:
            buf[ia.index] = AUXLEN
            ia.auxpos = ia.index
            buf[k + AUXLEN] = 0
            ia.index += AUXLEN + 2
        else:
            ia.auxpos = -1
        ia.word = f.g16() & 0xFFFFFFFF
    else:
        if ia.word == 0:
            ia.ateof = 1
            return
        ia.tt += ia.word & DATA
        ia.ann_tt = ia.tt
        ia.ann.anntyp = int8((ia.word & CODE) >> CS)
        ia.ann.subtyp = 0
        ia.auxpos = -1
        while True:
            ia.word = f.g16() & 0xFFFFFFFF
            w = ia.word
            if (w & CODE) < PAMIN or f.feof():
                break
            c = w & CODE
            if c == SKIP:
                ia.tt += f.g32()
            elif c == SUB:
                ia.ann.subtyp = int8(DATA & w)
            elif c == CHN:
                ia.ann.chan = uint8(DATA & w)
            elif c == NUM:
                ia.ann.num = int8(DATA & w)
            elif c == AUX:
                ln = w & 0o377
                if ia.index >= AUXBUFLEN - 2 - ln:
                    ia.index = 0
                ia.auxpos = ia.index
                buf[ia.index] = ln
                ia.index += 1
                # An extra byte may be present to preserve word alignment;
                # it is read and then overwritten by the null.
                data = f.read((ln + 1) & ~1)
                buf[ia.index:ia.index + len(data)] = data
                buf[ia.index + ln] = 0
                ia.index += ln + 1
    ia.ann.time = _round_to_time(ia.ann_tt * ia.tmul)
    if f.feof():
        ia.ateof = -1


def ungetann(n, annot):
    """Push an annotation back into input annotator n.

    The next getann(n, ...) returns a copy of ``annot``.  Only one
    annotation can be pushed back at a time.  Returns 0 on success, -1 if
    the push-back buffer is full, or -2 if n is not an input annotator.

    Translation of the C function ungetann() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    iad = _a.iad
    if n < 0 or n >= len(iad) or iad[n] is None:
        wfdb_error("ungetann: annotator %d is not initialized\n", n)
        return -2
    ia = iad[n]
    if ia.pann.anntyp:
        wfdb_error("ungetann: pushback buffer is full\n")
        wfdb_error("ungetann: annotation at %d, annotator %d not pushed "
                   "back\n", annot.time, n)
        return -1
    return _ungetann_ia(ia, annot)


def _ungetann_ia(ia, annot):
    """The body of ungetann (WFDB-x), after its checks, for the input
    annotator ia (whose pushback buffer is empty)."""
    ia.pann = annot.copy()
    if annot.time == ia.prev_time:
        ia.pann_tt = ia.prev_tt
    else:
        ia.pann_tt = annot.time / ia.tmul
    return 0


def putann(n, annot):
    """Write an annotation to output annotator n.

    Annotations should be written in canonical order (by time, then
    channel); otherwise the file is sorted when it is closed (see
    oannclose).  Returns 0 on success, -1 on a write error, or -2 if n is
    not an open output annotator.

    Translation of the C function putann() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    oad = _a.oad
    if n < 0 or n >= len(oad) or oad[n] is None or oad[n].file is None:
        wfdb_error("putann: can't write annotation file %d\n", n)
        return -2
    oa = oad[n]
    if not oa.table_written:
        oa.table_written = 1
        if _put_ann_table(oa, n, _a.oafreq, _lib_defs) < 0:
            return -1
    return _put_ann_word(oa, n, annot)


def _put_ann_word(oa, n, annot):
    """The body of putann (WFDB-x), after the table, for the output
    annotator oa (number n, in messages)."""
    t = annot.time
    f = oa.file
    delta = (t - oa.ann.time) & _U64
    achan = uint8(annot.chan)
    anum = int8(annot.num)
    if not (achan > uint8(oa.ann.chan) or anum > int8(oa.ann.num) or
            t > oa.ann.time or (t == 0 and oa.ann.time == 0)):
        oa.out_of_order = 1
    if oa.info.stat == WFDB_AHA_WRITE:
        f.putc(0)
        f.putc(mamap(annot.anntyp, annot.subtyp))
        f.p32(t)
        oa.seqno += 1
        f.p16(oa.seqno)
        f.putc(annot.subtyp)
        f.putc(annot.anntyp)
        if annot.aux is not None:
            ln = annot.aux[0] if annot.aux[0] < AUXLEN else AUXLEN
        else:
            ln = 0
        i = 0
        while i < ln:
            f.putc(annot.aux[1 + i])
            i += 1
        while i < AUXLEN:
            f.putc(0)
            i += 1
    else:
        if t == WFDB_TIME_MIN or t == WFDB_TIME_MAX:
            wfdb_error("putann: time overflow in annotation file %d\n", n)
            return -1
        if t > oa.ann.time:
            while delta > MAXSKIP:
                f.p16(SKIP)
                f.p32(MAXSKIP)
                delta = (delta - MAXSKIP) & _U64
        else:
            while ((-delta) & _U64) > -MINSKIP:
                f.p16(SKIP)
                f.p32(MINSKIP)
                delta = (delta - MINSKIP) & _U64
        if annot.anntyp == 0:
            f.p16(SKIP)
            f.p32((delta - 1) & 0xFFFFFFFF)
            delta = 1
        elif delta > MAXRR:
            f.p16(SKIP)
            f.p32(delta & 0xFFFFFFFF)
            delta = 0
        annwd = (delta + (annot.anntyp << CS)) & 0xFFFFFFFF
        f.p16(annwd)
        if annot.subtyp != 0:
            f.p16(SUB + (DATA & annot.subtyp))
        if achan != uint8(oa.ann.chan):
            f.p16(CHN + (DATA & achan))
        if anum != int8(oa.ann.num):
            f.p16(NUM + (DATA & anum))
        if annot.aux is not None and annot.aux[0] != 0:
            ln = annot.aux[0]
            f.p16(AUX + ln)
            data = bytes(annot.aux[1:1 + ln])
            data = data + b"\0" * (ln - len(data))
            f.write(data)
            if ln & 1:
                f.putc(0)
    if f.ferror():
        wfdb_error("putann: write error on annotation file %s\n",
                   oa.info.name)
        return -1
    oa.ann = annot.copy()
    oa.ann.time = t
    return 0


def _putanns(n, times, anntyps, subtyps, chans, nums, auxes,
             packed_aux=False):
    """putann(n, annot) for each annotation given by the sequences times,
    anntyps, subtyps, chans, nums and auxes (aux: None, or bytes as in
    Annotation.aux), in order (WFDB-x: for write_annotations).  An
    annotation that putann rejects (time overflow) is skipped, with
    putann's message.  Returns 0, -1 on a write error, or -2 if n is not
    an open output annotator.  With packed_aux=True, auxes is a pair
    (data, lengths): the aux texts one after the other in data (bytes,
    without length bytes), and the length of each (0: none); a text
    longer than 255 bytes is cut.

    For an MIT-format file the annotations are encoded with NumPy into one
    buffer, byte for byte as by _put_ann_word, and written at once (calling
    putann for each was the slowest part of writing a file); other formats
    use putann."""
    oad = _a.oad
    if n < 0 or n >= len(oad) or oad[n] is None or oad[n].file is None:
        wfdb_error("putann: can't write annotation file %d\n", n)
        return -2
    oa = oad[n]
    count = len(times)
    if packed_aux and oa.info.stat != WFDB_WRITE:
        auxes = _unpacked_aux(auxes, count)
    if oa.info.stat != WFDB_WRITE:
        times, anntyps, subtyps, chans, nums = (
            _int_list(v) for v in (times, anntyps, subtyps, chans, nums))
        stat = 0
        for k in range(count):
            a = Annotation(times[k], anntyps[k], subtyps[k], chans[k],
                           nums[k], auxes[k])
            if putann(n, a) == -1 and stat == 0:
                stat = -1
        return stat
    if count == 0:
        return 0
    if not oa.table_written:
        oa.table_written = 1
        if _put_ann_table(oa, n, _a.oafreq, _lib_defs) < 0:
            return -1
    buf = _encode_anns(oa, n, times, anntyps, subtyps, chans, nums, auxes,
                       packed_aux)
    if buf is None:     # (values beyond 64 bits, or aux not bytes)
        if packed_aux:
            auxes = _unpacked_aux(auxes, count)
        times, anntyps, subtyps, chans, nums = (
            _int_list(v) for v in (times, anntyps, subtyps, chans, nums))
        return _putanns_loop(oa, n, count, times, anntyps, subtyps, chans,
                             nums, auxes)
    f = oa.file
    f.write(buf)
    if f.ferror():
        wfdb_error("putann: write error on annotation file %s\n",
                   oa.info.name)
        return -1
    return 0


def _unpacked_aux(packed, count):
    # packed aux texts (see _putanns) as a list of count auxes as in
    # Annotation.aux (None, or a length byte and the text, cut to 255
    # bytes)
    data, lens = packed
    out, pos = [], 0
    for ln in lens[:count]:
        ln = int(ln)
        x = data[pos:pos + ln]
        pos += ln
        out.append(bytes((min(ln, 255),)) + bytes(x[:255]) if ln else None)
    return out


def _int_list(v):
    # v (a sequence of integers, or a NumPy array) as a list of Python ints
    if hasattr(v, "tolist"):
        v = v.tolist()
    return [int(x) for x in v]


def _int64_array(v, np):
    """v as an int64 NumPy array, or None if a value does not fit in 64
    bits (signed) or is not an integer."""
    if isinstance(v, np.ndarray):
        if v.dtype.kind == "i":
            return v.astype(np.int64, copy=False)
        if v.dtype.kind == "u":
            if v.size and int(v.max()) > LONG_MAX:
                return None
            return v.astype(np.int64)
        if v.dtype.kind != "O":
            return None
        v = v.tolist()
    try:
        a = np.array(v, dtype=np.int64)
    except (OverflowError, TypeError, ValueError):
        return None
    if a.ndim != 1:
        return None
    # (np.array truncates floats; putann took Python ints only)
    if any(type(x) is not int and not isinstance(x, np.integer) for x in v):
        return None
    return a


def _encode_anns(oa, n, times, anntyps, subtyps, chans, nums, auxes,
                 packed_aux=False):
    """The bytes that putann writes for the given annotations in an
    MIT-format file (after the table), computed with NumPy (WFDB-x), or
    None if the values cannot be handled so (an integer beyond 64 bits, an
    aux that is not bytes): _putanns_loop then encodes them.  Updates
    oa.ann (the last annotation written) and oa.out_of_order as putann
    does, and prints putann's message for each time overflow (skipped).
    With packed_aux, auxes holds the texts packed (see _putanns).

    Every item of an MIT-format annotation is a whole number of 16-bit
    words (an aux string is padded to an even length), so the output is
    laid out as words: each annotation gets, in this order, the SKIPs of a
    gap longer than MAXSKIP (rare: written one by one), the SKIP of a gap
    longer than MAXRR or of a code 0, its annotation word, and the SUB,
    CHN, NUM and AUX words that it needs, then the aux bytes."""
    import numpy as np
    count = len(times)
    cols = [_int64_array(v, np) for v in (times, anntyps, subtyps, chans,
                                           nums)]
    if any(c is None or len(c) < count for c in cols):
        return None
    t_all, typ_all, sub_all, chan_all, num_all = (c[:count] for c in cols)
    # aux: the texts given as bytes with their length bytes (items, with
    # aux_idx the annotations that have one, None: all), or packed
    if packed_aux:
        pdata, plens = auxes
        plens = plens_all = np.asarray(plens, np.int64)
        if len(plens) < count or not isinstance(pdata, bytes) or \
                int(plens.sum()) > len(pdata) or (plens < 0).any():
            return None
        plens = plens[:count]
        pstarts = np.zeros(count, np.int64)
        np.cumsum(plens[:-1], out=pstarts[1:])
        pstarts_all = pstarts
        aux_idx, items = None, None
    else:
        if len(auxes) != count:
            auxes = auxes[:count]
        types = set(map(type, auxes))
        if types <= {bytes, bytearray}:
            aux_idx, items = None, auxes
        elif types <= {bytes, bytearray, type(None)}:
            aux_idx = [k for k, x in enumerate(auxes) if x is not None]
            items = [auxes[k] for k in aux_idx]
        else:
            return None
    achan_all = chan_all & 0xFF
    anum_all = ((num_all + 128) & 0xFF) - 128       # (signed char)
    keep = (t_all != WFDB_TIME_MIN) & (t_all != WFDB_TIME_MAX)
    if keep.all():
        # the previous annotation written: the one before, or oa.ann
        sel = None
        t, typ, sub, achan, anum = t_all, typ_all, sub_all, achan_all, \
            anum_all
        pt = np.empty(count, np.int64)
        pt[0] = oa.ann.time
        pt[1:] = t[:-1]
        pchan = np.empty(count, np.int64)
        pchan[0] = uint8(oa.ann.chan)
        pchan[1:] = achan[:-1]
        pnum = np.empty(count, np.int64)
        pnum[0] = int8(oa.ann.num)
        pnum[1:] = anum[:-1]
        in_order = (achan > pchan) | (anum > pnum) | (t > pt) | \
            ((t == 0) & (pt == 0))
    else:
        # time overflows (skipped): the previous annotation written is the
        # last one kept before each annotation, or oa.ann
        k_idx = np.where(keep, np.arange(count), -1)
        prev = np.empty(count, np.int64)
        prev[0] = -1
        prev[1:] = np.maximum.accumulate(k_idx)[:-1]
        first = prev < 0
        p = np.where(first, 0, prev)
        pt_all = np.where(first, oa.ann.time, t_all[p])
        pchan_all = np.where(first, uint8(oa.ann.chan), achan_all[p])
        pnum_all = np.where(first, int8(oa.ann.num), anum_all[p])
        in_order = (achan_all > pchan_all) | (anum_all > pnum_all) | \
            (t_all > pt_all) | ((t_all == 0) & (pt_all == 0))
        for k in np.flatnonzero(~keep).tolist():
            wfdb_error("putann: time overflow in annotation file %d\n", n)
        sel = np.flatnonzero(keep)
        t, typ, sub = t_all[sel], typ_all[sel], sub_all[sel]
        achan, anum = achan_all[sel], anum_all[sel]
        pt, pchan, pnum = pt_all[sel], pchan_all[sel], pnum_all[sel]
        if packed_aux:
            plens, pstarts = plens[sel], pstarts[sel]
        elif aux_idx is None:
            items = [items[k] for k in sel.tolist()]
        else:
            pos = {k: i for i, k in enumerate(sel.tolist())}
            aux_sel = [(pos[k], x) for k, x in zip(aux_idx, items)
                       if k in pos]
            aux_idx = [i for i, _ in aux_sel]
            items = [x for _, x in aux_sel]
    oa.out_of_order = oa.out_of_order or not bool(in_order.all())
    m = len(t)
    if m == 0:
        return b""
    last = int(sel[-1]) if sel is not None else count - 1
    # The interval from the previous annotation, as putann computes it
    # (modulo 2^64).  A gap of more than MAXSKIP samples forward, or
    # -MINSKIP backward, takes SKIPs of MAXSKIP (or MINSKIP) first, and
    # leaves an interval of 1..MAXSKIP (or -MAXSKIP..0); such gaps are
    # rare, and computed with Python ints.
    delta = t - pt                  # (wraps around if |t - pt| >= 2^63)
    nloop = None
    big = (delta > MAXSKIP) | (delta < MINSKIP) | ((t > pt) != (delta > 0))
    if big.any():
        nloop = np.zeros(m, np.int64)
        for i in np.flatnonzero(big).tolist():
            ti, pi = int(t[i]), int(pt[i])
            mag = abs(ti - pi)
            q = (mag - 1) // MAXSKIP
            nloop[i] = q
            mag -= q * MAXSKIP
            delta[i] = mag if ti > pi else -mag
    zero = typ == 0
    skip = zero | (delta < 0) | (delta > MAXRR)
    skipval = np.where(zero, delta - 1, delta) & 0xFFFFFFFF
    delta = np.where(zero, 1, np.where(skip, 0, delta))
    has_sub = sub != 0
    has_chn = achan != pchan
    has_num = anum != pnum
    # aux strings: the length stated (the first byte, or the length of a
    # raw text), the bytes given
    nitem = m if packed_aux else len(items)
    if nitem:
        if packed_aux:
            blob = np.frombuffer(pdata, np.uint8)
            stated = np.minimum(plens, 255)
            avail = stated
            src0 = pstarts
        else:
            lens = np.fromiter(map(len, items), np.int64, nitem)
            if lens.min() == 0:
                return None
            blob = np.frombuffer(b"".join(items), np.uint8)
            starts = np.zeros(nitem, np.int64)
            np.cumsum(lens[:-1], out=starts[1:])
            stated = blob[starts].astype(np.int64)
            avail = np.minimum(stated, lens - 1)
            src0 = starts + 1
        if aux_idx is None:
            aux_len = stated
            aidx = None
        else:
            aidx = np.array(aux_idx, np.int64)
            aux_len = np.zeros(m, np.int64)
            aux_len[aidx] = stated
    else:
        aux_len = np.zeros(m, np.int64)
    has_aux = aux_len != 0
    nwords = 3 * skip + 1 + has_sub + has_chn + has_num + has_aux + \
        (aux_len + 1) // 2
    if nloop is not None:
        nwords += 3 * nloop
    off = np.zeros(m + 1, np.int64)
    np.cumsum(nwords, out=off[1:])
    nbytes = 2 * int(off[-1])
    out = np.zeros(nbytes + 1, np.uint8)      # (+1: see the aux bytes)
    words = out[:nbytes].view("<u2")
    w = off[:-1]
    if nloop is not None:
        for i in np.flatnonzero(nloop).tolist():
            val = MAXSKIP if t[i] > pt[i] else MINSKIP
            rep = np.array([SKIP, (val >> 16) & 0xFFFF, val & 0xFFFF], "<u2")
            o = int(off[i])
            words[o:o + 3 * int(nloop[i])] = np.tile(rep, int(nloop[i]))
        w = w + 3 * nloop
    ws = w[skip]
    words[ws] = SKIP
    sv = skipval[skip]
    words[ws + 1] = sv >> 16
    words[ws + 2] = sv & 0xFFFF
    w = w + 3 * skip
    words[w] = (delta + (typ << CS)) & 0xFFFF
    w = w + 1
    if has_sub.any():
        words[w[has_sub]] = (SUB + (DATA & sub[has_sub])) & 0xFFFF
        w = w + has_sub
    if has_chn.any():
        words[w[has_chn]] = (CHN + (DATA & achan[has_chn])) & 0xFFFF
        w = w + has_chn
    if has_num.any():
        words[w[has_num]] = (NUM + (DATA & anum[has_num])) & 0xFFFF
        w = w + has_num
    if nitem:
        words[w[has_aux]] = (AUX + aux_len[has_aux]) & 0xFFFF
        w = w + has_aux
        # the given bytes of each string, at byte 2 * w (the zero padding
        # to the stated length and to an even length is there already):
        # the bytes in the strings, marked as runs of 1 by a running sum
        dst0 = 2 * (w if aidx is None else w[aidx])
        total = int(avail.sum())
        if total:
            def runs(size, p0):
                # (starts are distinct, and so are ends; an end may be the
                # start of the next string)
                mark = np.zeros(size + 1, np.int8)
                nz = avail > 0
                mark[p0[nz]] += 1
                mark[(p0 + avail)[nz]] -= 1
                return np.cumsum(mark[:size], dtype=np.int8).view(bool)
            if packed_aux and len(blob) == total:
                data = blob         # (all the texts, none cut)
            else:
                data = blob[runs(len(blob), src0)]
            out[:nbytes][runs(nbytes, dst0)] = data
    oa.ann = Annotation(int(t_all[last]), int(typ_all[last]),
                        int(sub_all[last]), int(chan_all[last]),
                        int(num_all[last]),
                        _unpacked_aux((pdata[pstarts_all[last]:],
                                       plens_all[last:last + 1]), 1)[0]
                        if packed_aux else auxes[last])
    return memoryview(out)[:nbytes]


def _putanns_loop(oa, n, count, times, anntyps, subtyps, chans, nums,
                  auxes):
    """The MIT-format encoder of _putanns, one annotation at a time (for
    values that _encode_anns does not take)."""
    buf = bytearray()
    put = buf.extend

    def p16(x):
        put((x & 0xFFFF).to_bytes(2, "little"))

    def p32(x):
        p16((x >> 16) & 0xFFFF)
        p16(x & 0xFFFF)

    # The previous annotation written (oa.ann): time, chan (as unsigned
    # char) and num (as signed char) are all that the encoding uses.
    pt = oa.ann.time
    pchan = uint8(oa.ann.chan)
    pnum = int8(oa.ann.num)
    last = None
    out_of_order = oa.out_of_order
    for k in range(count):
        t = times[k]
        anntyp = anntyps[k]
        subtyp = subtyps[k]
        chan = chans[k]
        num = nums[k]
        aux = auxes[k]
        achan = chan & 0xFF
        anum = num & 0xFF
        if anum & 0x80:
            anum -= 0x100       # (signed char)
        if not (achan > pchan or anum > pnum or t > pt or
                (t == 0 and pt == 0)):
            out_of_order = 1
        if t == WFDB_TIME_MIN or t == WFDB_TIME_MAX:
            wfdb_error("putann: time overflow in annotation file %d\n", n)
            continue
        delta = (t - pt) & _U64
        if t > pt:
            while delta > MAXSKIP:
                p16(SKIP)
                p32(MAXSKIP)
                delta = (delta - MAXSKIP) & _U64
        else:
            while ((-delta) & _U64) > -MINSKIP:
                p16(SKIP)
                p32(MINSKIP)
                delta = (delta - MINSKIP) & _U64
        if anntyp == 0:
            p16(SKIP)
            p32((delta - 1) & 0xFFFFFFFF)
            delta = 1
        elif delta > MAXRR:
            p16(SKIP)
            p32(delta & 0xFFFFFFFF)
            delta = 0
        put(((delta + (anntyp << CS)) & 0xFFFF).to_bytes(2, "little"))
        if subtyp != 0:
            p16(SUB + (DATA & subtyp))
        if achan != pchan:
            p16(CHN + (DATA & achan))
        if anum != pnum:
            p16(NUM + (DATA & anum))
        if aux is not None and aux[0] != 0:
            ln = aux[0]
            p16(AUX + ln)
            data = bytes(aux[1:1 + ln])
            put(data)
            # (zero padding to the stated length, and to an even length)
            put(bytes(ln - len(data) + (ln & 1)))
        pt, pchan, pnum = t, achan, anum
        last = k
    oa.out_of_order = out_of_order
    f = oa.file
    f.write(buf)
    if f.ferror():
        wfdb_error("putann: write error on annotation file %s\n",
                   oa.info.name)
        return -1
    if last is not None:
        oa.ann = Annotation(times[last], anntyps[last], subtyps[last],
                            chans[last], nums[last], auxes[last])
    return 0


def iannsettime(t):
    """Seek all input annotators to the first annotation at or after time t.

    ``t`` is in sample intervals (a negative t, as returned by strtim() for
    a time of day, is negated).  Returns 0 on success, or -1 on an
    improper seek or if every input annotator reached the end of its file.

    Translation of the C function iannsettime() (lib/annot.c, WFDB 10.7.0):
    same arguments and results.
    """
    stat = 0
    niavalid = len(_a.iad)
    if t < 0 and t != WFDB_TIME_MIN:
        t = -t
    tempann = Annotation()
    for i, ia in enumerate(_a.iad):
        if ia.ann.time >= t:
            ia.pann.anntyp = 0
            if ia.file.seek(0, 0) == -1:
                wfdb_error("iannsettime: improper seek\n")
                return -1
            ia.ann.subtyp = ia.ann.chan = ia.ann.num = ia.ateof = 0
            ia.ann.time = 0
            ia.tt = 0.0
            ia.word = ia.file.g16() & 0xFFFFFFFF
            if ia.info.stat == WFDB_READ:
                while (ia.word & CODE) == SKIP:
                    ia.tt += ia.file.g32()
                    ia.word = ia.file.g16() & 0xFFFFFFFF
            getann(i, tempann)
        while ia.ann.time < t:
            stat = getann(i, tempann)
            if stat != 0:
                break
        if stat < 0:
            niavalid -= 1
    return 0 if niavalid > 0 else -1


# ---------------------------------------------------------------------------
# Annotation code <-> mnemonic/description conversion

_DEFAULT_MNEMONICS = [
    " ", "N", "L", "R", "a",
    "V", "F", "J", "A", "S",
    "E", "j", "/", "Q", "~",
    "[15]", "|", "[17]", "s", "T",
    "*", "D", "\"", "=", "p",
    "B", "^", "t", "+", "u",
    "?", "!", "[", "]", "e",
    "n", "@", "x", "f", "(",
    ")", "r", "[42]", "[43]", "[44]",
    "[45]", "[46]", "[47]", "[48]", "[49]",
]

_cstring = list(_DEFAULT_MNEMONICS)
_astring = list(_DEFAULT_MNEMONICS)
_tstring = [
    "",
    "Normal beat",
    "Left bundle branch block beat",
    "Right bundle branch block beat",
    "Aberrated atrial premature beat",
    "Premature ventricular contraction",
    "Fusion of ventricular and normal beat",
    "Nodal (junctional) premature beat",
    "Atrial premature beat",
    "Supraventricular premature or ectopic beat",
    "Ventricular escape beat",
    "Nodal (junctional) escape beat",
    "Paced beat",
    "Unclassifiable beat",
    "Change in signal quality",
    None,
    "Isolated QRS-like artifact",
    None,
    "ST segment change",
    "T-wave change",
    "Systole",
    "Diastole",
    "Comment annotation",
    "Measurement annotation",
    "P-wave peak",
    "Bundle branch block beat (unspecified)",
    "(Non-captured) pacemaker artifact",
    "T-wave peak",
    "Rhythm change",
    "U-wave peak",
    "Beat not classified during learning",
    "Ventricular flutter wave",
    "Start of ventricular flutter/fibrillation",
    "End of ventricular flutter/fibrillation",
    "Atrial escape beat",
    "Supraventricular escape beat",
    "Link to external data (aux contains URL)",
    "Non-conducted P-wave (blocked APC)",
    "Fusion of paced and normal beat",
    "Waveform onset",
    "Waveform end",
    "R-on-T premature ventricular contraction",
    None, None, None, None, None, None, None, None,
]
_DEFAULT_DESCRIPTIONS = tuple(_tstring)     # WFDB-x: for _sort_ann_file
_lib_defs = _AnnDefs(_astring, _tstring, _a.modified)


def ecgstr(code):
    """Return the standard mnemonic of an annotation code (e.g. "N").

    Unlike annstr(), the result is not affected by setannstr() or by the
    mnemonics defined in annotation files.  A code out of range gives
    "[code]".

    Translation of the C function ecgstr() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    if 0 <= code <= ACMAX:
        return _cstring[code]
    return "[%d]" % code


def strecg(s):
    """Return the annotation code of a standard mnemonic (see ecgstr()).

    Returns NOTQRS (0) if the mnemonic is not defined.

    Translation of the C function strecg() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    if s is None:
        s = ""
    for code in range(1, ACMAX + 1):
        if s == _cstring[code]:
            return code
    return NOTQRS


def setecgstr(code, s):
    """Redefine the standard mnemonic used by ecgstr() and strecg() for a code.

    Returns 0 on success, or -1 if the code is illegal.

    Translation of the C function setecgstr() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    if NOTQRS <= code <= ACMAX:
        _cstring[code] = s if s is not None else ""
        return 0
    wfdb_error("setecgstr: illegal annotation code %d\n", code)
    return -1


def annstr(code):
    """Return the mnemonic of an annotation code (e.g. "N" for NORMAL).

    The mnemonic may have been redefined by setannstr() or by an annotation
    file opened for reading.  A code out of range gives "[code]".

    Translation of the C function annstr() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    if 0 <= code <= ACMAX:
        return _astring[code]
    return "[%d]" % code


def strann(s):
    """Return the annotation code of a mnemonic (see annstr()).

    Returns NOTQRS (0) if the mnemonic is not defined.

    Translation of the C function strann() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    if s is None:
        s = ""
    for code in range(1, ACMAX + 1):
        if s == _astring[code]:
            return code
    return NOTQRS


def _set_def_string(table, mod, code, s):
    """The body of setannstr and setanndesc (WFDB-x), for a string table (of
    mnemonics or descriptions) and the modification flags (mod) of a
    definition table.  Returns 0, or -1 if code is illegal."""
    mflag = 0
    if code > 0:
        mflag = 1
    else:
        code = -code
    if code <= ACMAX:
        if s is None:
            s = ""
        if table[code] is None or table[code] != s:
            table[code] = s
            if mflag:
                mod[code] = 1
        return 0
    return -1


def setannstr(code, s):
    """Redefine the mnemonic of an annotation code (see annstr()).

    A positive code marks the new mnemonic to be recorded in output
    annotation files; a negative code (-code) changes it for this program
    only.  Returns 0 on success, or -1 if the code is illegal.

    Translation of the C function setannstr() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    if _set_def_string(_astring, _a.modified, code, s) == 0:
        return 0
    wfdb_error("setannstr: illegal annotation code %d\n", abs(code))
    return -1


def anndesc(code):
    """Return the description of an annotation code.

    Returns None if the code has no description, or "illegal annotation
    code" if the code is out of range.

    Translation of the C function anndesc() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    if 0 <= code <= ACMAX:
        return _tstring[code]
    return "illegal annotation code"


def setanndesc(code, s):
    """Redefine the description of an annotation code (see anndesc()).

    A positive code marks the new description to be recorded in output
    annotation files; a negative code (-code) changes it for this program
    only.  Returns 0 on success, or -1 if the code is illegal.

    Translation of the C function setanndesc() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    if _set_def_string(_tstring, _a.modified, code, s) == 0:
        return 0
    wfdb_error("setanndesc: illegal annotation code %d\n", abs(code))
    return -1


def setafreq(f):
    """Set the time resolution (ticks per second) of output annotators.

    Applies to output annotators that have not yet written an annotation;
    the value is recorded at the start of each such file.  0 (the
    default) records no time resolution: times are then in sample
    intervals of the record.

    Translation of the C function setafreq() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    _a.oafreq = f


def getafreq():
    """Return the time resolution set by setafreq() (0 if not set).

    Translation of the C function getafreq() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    return _a.oafreq


def setiafreq(n, f):
    """Set the frequency in which times of input annotator n are expressed.

    After this call, getann(n, ...) returns times in units of 1/f seconds.

    Translation of the C function setiafreq() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    iad = _a.iad
    if 0 <= n < len(iad) and iad[n] is not None:
        ia = iad[n]
        from ._signal import sampfreq, getspf
        if f > 0.0 and ia.afreq > 0.0:
            ia.tmul = f / ia.afreq
        else:
            sf = sampfreq(None) if f > 0.0 else 0.0
            if f > 0.0 and sf > 0.0:
                ia.tmul = f * getspf() / sf
            else:
                ia.tmul = 1.0
        ia.ann.time = _round_to_time(ia.ann_tt * ia.tmul)
        ia.pann.time = _round_to_time(ia.pann_tt * ia.tmul)
        ia.prev_time = _round_to_time(ia.prev_tt * ia.tmul)


def getiafreq(n):
    """Return the frequency (Hz) of the times returned by input annotator n.

    Returns -2.0 if n is not an open input annotator.

    Translation of the C function getiafreq() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    iad = _a.iad
    if 0 <= n < len(iad) and iad[n] is not None:
        ia = iad[n]
        if ia.afreq > 0.0:
            return ia.afreq * ia.tmul
        from ._signal import sampfreq, getspf
        return sampfreq(None) * ia.tmul / getspf()
    return -2.0


def getiaorigfreq(n):
    """Return the time resolution recorded in the file of input annotator n.

    Returns 0.0 if the file does not record one, or -2.0 if n is not an
    open input annotator.

    Translation of the C function getiaorigfreq() (lib/annot.c, WFDB 10.7.0):
    same arguments and results.
    """
    iad = _a.iad
    if 0 <= n < len(iad) and iad[n] is not None:
        return iad[n].afreq
    return -2.0


def iannclose(n):
    """Close input annotator n.

    Input annotators with higher numbers are renumbered down by one.

    Translation of the C function iannclose() (lib/annot.c, WFDB 10.7.0): same
    arguments and results.
    """
    iad = _a.iad
    if 0 <= n < len(iad) and iad[n] is not None and iad[n].file is not None:
        iad[n].file.close()
        del iad[n]


def _run_sortann(rname, aname):
    # WFDB-x: the child runs with --legacy (as the original program), and,
    # with an output directory, in that directory (where the file is)
    cmd = [sys.executable, "-m", "wfdbx.apps.sortann", "--legacy", "-r.",
           rname, "-a", aname]
    # Let the child import this same wfdbx package even when it is not
    # installed (e.g. found through a sys.path entry added at run time).
    pkgroot = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = dict(os.environ)
    env["PYTHONPATH"] = os.pathsep.join(
        [pkgroot] + ([env["PYTHONPATH"]] if env.get("PYTHONPATH") else []))
    try:
        sys.stdout.flush()
    except (OSError, ValueError):
        pass
    try:
        return subprocess.call(cmd, env=env,
                               cwd=wio.wfdbx_get_output_dir() or None)
    except OSError:
        return -1


# ---------------------------------------------------------------------------
# WFDB-x: in-process sorting of an output annotation file

class _Node:
    __slots__ = ("next", "prev", "ann")

    def __init__(self, ann=None):
        self.next = None
        self.prev = None
        self.ann = ann


class _AnnList:
    """The doubly-linked annotation list of sortann.c (same algorithm; used
    by the sortann tool and by _sort_ann_file).

    WFDB-x: unless legacy is true, the head is never compared with an
    annotation: sortann.c compared it, and took an out-of-order annotation
    at time 0 (num 0, chan 0) for a duplicate of it, linking it where the
    output never reaches it (losing it, and the annotations later inserted
    after it); here such an annotation is inserted at the beginning."""

    def __init__(self, legacy=False):
        # 'annlist' (a static sentinel whose annotation is all zeros, and
        # which takes part in comparisons as in sortann.c only if legacy)
        self.head = _Node(Annotation())
        self.lastp = self.head
        self.in_order = 1
        self.legacy = legacy

    def insert(self, pa):
        head = self.head
        newp = _Node(pa.copy())
        last = self.lastp
        la = last.ann
        if last is head or pa.time > la.time or \
                (pa.time == la.time and pa.num > la.num) or \
                (pa.time == la.time and pa.num == la.num and
                 pa.chan > la.chan):
            newp.prev = last
            last.next = newp
            self.lastp = newp
            newp.next = None
            return
        self.in_order = 0
        ap = last
        while ap is not None:
            if ap is head and not self.legacy:      # WFDB-x (see above)
                ap = None
                break
            aa = ap.ann
            if pa.time > aa.time or \
                    (pa.time == aa.time and pa.num > aa.num) or \
                    (pa.time == aa.time and pa.num == aa.num and
                     pa.chan >= aa.chan):
                break
            ap = ap.prev
        if ap is None:
            newp.prev = None
            newp.next = head.next
            head.next = newp
            newp.next.prev = newp
        elif pa.time == ap.ann.time and \
                pa.num == ap.ann.num and pa.chan == ap.ann.chan:
            newp.prev = ap.prev
            if newp.prev is not None:
                newp.prev.next = newp
            newp.next = ap.next
            if newp.next is not None:
                newp.next.prev = newp
            else:
                self.lastp = newp
            # If ap was the first entry of the list but its 'prev' link
            # does not lead back to the list head (an entry inserted at the
            # beginning gets a null link, and one whose predecessor replaced
            # the head is detached), C leaves the head pointing to the freed
            # entry (undefined behavior): here the head is updated, so that
            # the duplicate is replaced (see docs/KNOWN_C_BEHAVIORS.md).
            if head.next is ap:
                head.next = newp
        else:
            newp.prev = ap
            newp.next = ap.next
            ap.next = newp
            newp.next.prev = newp

    def __iter__(self):
        p = self.head.next
        while p is not None:
            yield p.ann
            p = p.next


def _sort_ann_file(fname, aname):
    """Rearrange the annotations of the (closed) annotation file fname of
    annotator aname in the canonical order (WFDB-x).

    The result is identical, byte for byte, to that of the sortann program
    (the WFDB-x one; the original lost an out-of-order annotation at time
    0, see _AnnList) as the C library ran it ("sortann -r. RECORD -a
    ANNOTATOR", see oannclose), but the header of the record is not looked
    up.  As sortann
    does, the file is read (with any time resolution and annotation type
    definitions it contains), its annotations at nonnegative times are
    inserted in an _AnnList (insert_ann in sortann.c), and, unless they were
    already in order, the file is rewritten in MIT format, with the time
    resolution of the input file (if any) and without the NOTQRS
    annotations.  Its own reader, writer, and definition table are used (the
    library's annotators and tables are not changed).  Returns 0 on success,
    or -1 if the file cannot be read or written.
    """
    defs = _AnnDefs(list(_DEFAULT_MNEMONICS), list(_DEFAULT_DESCRIPTIONS),
                    [0] * (ACMAX + 1))
    ia = _IAData()
    ia.file = wio.wfdb_fopen(fname, "rb")
    if ia.file is None:
        return -1
    ia.info.name = aname
    ia.info.stat = _ann_file_format(ia)
    _read_ann_table(ia, defs)
    alist = _AnnList()
    annot = Annotation()
    while True:
        stat = _getann_ia(ia, annot)
        if stat != 0:
            break
        if annot.time >= 0:     # (sortann's -f time is 0)
            alist.insert(annot)
    ia.file.close()
    if stat != -1:              # -1: the logical end of the file
        return -1
    if alist.in_order:
        return 0
    oa = _OAData()
    oa.info.name = aname
    oa.info.stat = WFDB_WRITE
    oa.file = wio.wfdb_fopen(fname, "wb")
    if oa.file is None:
        return -1
    ok = True
    for ann in alist:
        if ann.anntyp == NOTQRS:
            continue
        if not oa.table_written:
            oa.table_written = 1
            ok = _put_ann_table(oa, 0, ia.afreq, defs) == 0
        if not ok or _put_ann_word(oa, 0, ann) < 0:
            ok = False
            break
    oa.file.p16(0)
    if oa.file.ferror():
        ok = False
    if oa.file.close():
        ok = False
    return 0 if ok else -1


def oannclose(n):
    """Close output annotator n, completing its file.

    If the annotations were not written in canonical order, the file is
    rearranged (in this process; in legacy mode, by running the sortann
    tool), unless the WFDBANNSORT environment variable is 0.  Output
    annotators with higher numbers are renumbered down by one.

    Translation of the C function oannclose() (lib/annot.c, WFDB 10.7.0): same
    arguments and results. Differences: an out-of-order file is sorted in this
    process, without losing annotations, instead of by running sortann; see
    docs/DIVERGENCES.md.
    """
    oad = _a.oad
    if not (0 <= n < len(oad) and oad[n] is not None and
            oad[n].file is not None):
        return
    oa = oad[n]
    f = oa.file
    if oa.info.stat == WFDB_WRITE:
        f.p16(0)
    elif oa.info.stat == WFDB_AHA_WRITE:
        i = ABLKSIZ - (f.tell() & 0xFFFFFFFF) % ABLKSIZ
        f.write(bytes((EOAF,)) * i)
    errflag = f.ferror()
    if f.close():
        errflag = True
    if errflag:
        wfdb_error("oannclose: write error on annotation file %s\n",
                   oa.info.name)
        _a.annclose_error = -7
    if oa.out_of_order:
        dosort = DEFWFDBANNSORT
        p = os.environ.get("WFDBANNSORT")
        if p is not None:
            dosort = strtol(p)[0]
        if _a.sort_override is not None:    # WFDB-x: write_annotations(sort)
            dosort = 1 if _a.sort_override else 0
        if dosort:
            wfdb_error("Rearranging annotations for output annotator %s ...",
                       oa.info.name)
            # WFDB-x: the file is sorted in this process; the C library ran
            # the sortann program, as legacy mode does.
            from ._signal import wfdbx_get_legacy
            if wfdbx_get_legacy():
                sorted_ok = _run_sortann(oa.rname, oa.info.name) == 0
            else:
                sorted_ok = _sort_ann_file(oa.fname, oa.info.name) == 0
            if sorted_ok:
                wfdb_error("done!\n")
                oa.out_of_order = 0
            else:
                wfdb_error("\nAnnotations still need to be rearranged.\n")
            if _a.annclose_error == 0:
                _a.annclose_error = -6
    # WFDB-x: no advice to run sortann when the caller chose not to sort
    # (write_annotations(sort=False)); WFDBANNSORT=0 still gives it.
    if oa.out_of_order and _a.sort_override is not False:
        wfdb_error("Use the command:\n  sortann -r %s -a %s\n",
                   oa.rname, oa.info.name)
        wfdb_error("to rearrange annotations in the correct order.\n")
    if oa.out_of_order:
        if _a.annclose_error == 0:
            _a.annclose_error = -6
    del oad[n]


def _wfdb_oaflush():
    for oa in _a.oad:
        oa.file.flush()


def _wfdb_anclose():
    for an in range(len(_a.iad), 0, -1):
        iannclose(an - 1)
    for an in range(len(_a.oad), 0, -1):
        oannclose(an - 1)
