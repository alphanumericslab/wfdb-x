"""Signal I/O for the WFDB library (port of lib/signal.c).

This module reads and writes WFDB header (.hea) files and signal files in
all WFDB storage formats, and provides the time/date conversion functions
(timstr, strtim, ...) and unit conversions (aduphys, physadu, ...).

The implementation follows the C library closely, including its global
(per-process) state: a WFDB application opens one input record and any
number of output signals at a time, exactly as with the C library.

Copyright (C) 1989-2013 George B. Moody (original C implementation,
lib/signal.c; revised 2011-2022 by Benjamin Moody, including FLAC support,
2020).
Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
Design decision (Reza Sameni, Oct 2026): the signal files named in a header,
and the segments named in the header of a multi-segment record, are in the
directory of that header (on disk or at its URL) or below it; a name that
is absolute, begins with '~', is a URL or contains a ".." component is
refused ("~" as a segment, a null segment, and "-" as a signal file remain).
Nothing is searched: a search can silently open the wrong file, and a header
must not make the library read other local files or contact other servers.
The original behavior remains available with --legacy (see
docs/DIVERGENCES.md).
Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency, gain,
ADC resolution or units. Values that the record or the user does not give are
never assumed (the original package assumed 250 Hz, 200 adu/mV, 12 bits and
millivolts), because a silently assumed value corrupts every result derived
from it. See docs/DIVERGENCES.md. The original behavior remains available
with --legacy (see docs/DIVERGENCES.md).
This library is free software; you can redistribute it and/or modify it under
the terms of the GNU Library General Public License as published by the Free
Software Foundation; either version 2 of the License, or (at your option) any
later version.
"""

import math
import os
import re
import time as _time

from ._cstd import (LONG_MIN, LONG_MAX, INT_MAX, INT_MIN, UINT_MAX, strtol,
                    strtod, Strtok, cdiv, cmod, int16, int32, sprintf, d2l,
                    fdiv as _fdiv)
from . import _flac
from . import _wfdbio as wio
from ._wfdbio import wfdb_error, wfdb_open, WFDB_READ, WFDB_WRITE, \
    WFDB_APPEND, WFDB_LOCAL, WFDB_MAXRNL

__all__ = [
    "Siginfo", "Seginfo",
    "WFDB_INVALID_SAMPLE", "WFDB_DEFFREQ", "WFDB_DEFGAIN", "WFDB_DEFRES",
    "WFDB_LOWRES", "WFDB_HIGHRES", "WFDB_GVPAD", "WFDB_MAXRNL",
    "WFDB_MAXUSL", "WFDB_MAXDSL", "WFDB_FMT_LIST",
    "isigopen", "osigopen", "osigfopen", "findsig", "getspf", "setgvmode",
    "getgvmode", "setifreq", "getifreq", "getvec", "getframe", "putvec",
    "isigsettime", "isgsettime", "tnextvec", "setibsize", "setobsize",
    "newheader", "setheader", "setmsheader", "getseginfo", "wfdbgetskew",
    "wfdbsetiskew", "wfdbsetskew", "wfdbgetstart", "wfdbsetstart",
    "wfdbputprolog", "setinfo", "putinfo", "getinfo", "sampfreq",
    "setsampfreq", "setbasetime", "timstr", "mstimstr", "getcfreq",
    "wfdbx_time_needs_freq", "wfdbx_set_legacy", "wfdbx_get_legacy",
    "wfdbx_legacy_args",
    "setcfreq", "getbasecount", "setbasecount", "strtim", "datstr",
    "strdat", "adumuv", "muvadu", "aduphys", "physadu", "sample",
    "sample_valid", "wfdb_freeinfo",
]

# Constants of wfdb.h and wfdblib.h.
WFDB_INVALID_SAMPLE = -32768    # value of an invalid (missing) sample
WFDB_SAMPLE_MIN = INT_MIN
WFDB_SAMPLE_MAX = INT_MAX
WFDB_TIME_MIN = LONG_MIN
WFDB_TIME_MAX = LONG_MAX
WFDB_MAXUSL = 50        # maximum length of a Siginfo units string
WFDB_MAXDSL = 100       # maximum length of a Siginfo desc string
WFDB_FMT_LIST = (0, 8, 16, 61, 80, 160, 212, 310, 311, 24, 32, 508, 516, 524)
WFDB_DEFFREQ = 250.0    # C default sampling frequency (Hz); legacy mode
WFDB_DEFGAIN = 200.0    # C default gain (adu/physical unit); legacy mode
WFDB_DEFRES = 12        # C default ADC resolution (bits); legacy mode
WFDB_LOWRES = 0         # getvec mode: one sample per signal per frame
WFDB_HIGHRES = 1        # getvec mode: each sample of oversampled signals
WFDB_GVPAD = 2          # getvec mode: replace invalid samples by previous ones
DEFWFDBGVMODE = WFDB_LOWRES
BUFSIZ = 8192           # default I/O buffer size (glibc's stdio BUFSIZ)
BUFLN = 4096            # sample() buffer length in frames (a power of 2)


class Siginfo:
    """Signal specification (WFDB_Siginfo), one per signal.

    Attributes:
      fname     name of the signal file
      desc      signal description (e.g. "MLII"), or None
      units     physical units (e.g. "mV"), or None (not specified)
      gain      ADC units per physical unit (0: uncalibrated)
      initval   value of the first sample
      group     signal group number (signals in one group share one file)
      fmt       storage format (e.g. 16, 212, 516)
      spf       samples per frame (> 1 for oversampled signals)
      bsize     block size in bytes (0 for ordinary files)
      adcres    ADC resolution in bits (0: not specified)
      adczero   ADC output for a 0 V input
      baseline  ADC value corresponding to 0 physical units
      nsamp     number of samples (0 if unknown)
      cksum     16-bit checksum of the samples
    """

    __slots__ = ("fname", "desc", "units", "gain", "initval", "group", "fmt",
                 "spf", "bsize", "adcres", "adczero", "baseline", "nsamp",
                 "cksum")

    def __init__(self, fname=None, desc=None, units=None, gain=0.0,
                 initval=0, group=0, fmt=0, spf=1, bsize=0, adcres=0,
                 adczero=0, baseline=0, nsamp=0, cksum=0):
        self.fname = fname
        self.desc = desc
        self.units = units
        self.gain = gain
        self.initval = initval
        self.group = group
        self.fmt = fmt
        self.spf = spf
        self.bsize = bsize
        self.adcres = adcres
        self.adczero = adczero
        self.baseline = baseline
        self.nsamp = nsamp
        self.cksum = cksum

    def copy(self):
        """Return a copy of this Siginfo."""
        c = Siginfo.__new__(Siginfo)
        for k in Siginfo.__slots__:
            setattr(c, k, getattr(self, k))
        return c

    def __repr__(self):
        return "Siginfo(%s)" % ", ".join(
            "%s=%r" % (k, getattr(self, k)) for k in Siginfo.__slots__)


class Seginfo:
    """A segment of a multi-segment record (WFDB_Seginfo).

    Attributes:
      recname   name of the segment (a single-segment record)
      nsamp     number of samples in the segment
      samp0     sample number of the first sample of the segment
    """

    __slots__ = ("recname", "nsamp", "samp0")

    def __init__(self, recname="", nsamp=0, samp0=0):
        self.recname = recname
        self.nsamp = nsamp
        self.samp0 = samp0

    def __repr__(self):
        return "Seginfo(recname=%r, nsamp=%d, samp0=%d)" % (
            self.recname, self.nsamp, self.samp0)


class _HSData:
    __slots__ = ("info", "start", "skew")

    def __init__(self):
        self.info = Siginfo()
        self.start = 0
        self.skew = 0


class _ISData:
    __slots__ = ("info", "samp", "skew", "gvindex", "gvcount")

    def __init__(self):
        self.info = Siginfo()
        self.samp = 0
        self.skew = 0
        self.gvindex = 0
        self.gvcount = 0


class _OSData:
    __slots__ = ("info", "samp", "skew")

    def __init__(self):
        self.info = Siginfo()
        self.samp = 0
        self.skew = 0


class _SigMapInfo:
    __slots__ = ("desc", "gain", "scale", "offset", "sample_offset",
                 "baseline", "index", "spf")

    def __init__(self):
        self.desc = None
        self.gain = 0.0
        self.scale = 0.0
        self.offset = 0.0
        self.sample_offset = 0
        self.baseline = 0
        self.index = 0
        self.spf = 0

    def copy(self):
        c = _SigMapInfo()
        for k in _SigMapInfo.__slots__:
            setattr(c, k, getattr(self, k))
        return c


class _IGData:
    """State shared by all signals in an input group (one signal file)."""

    __slots__ = ("data", "datb", "fp", "start", "bsize", "buf", "bp", "be",
                 "count", "seek", "initial_skip", "stat", "flac", "ahead")

    def __init__(self):
        self.data = 0
        self.datb = 0
        self.fp = None
        self.start = 0
        self.bsize = 0
        self.buf = b""
        self.bp = 0
        self.be = 0
        self.count = 0
        self.seek = 0
        self.initial_skip = 0
        self.stat = 0
        self.flac = None
        # wfdb-x: blocks read from fp by the bulk reader (_bulk_read) but
        # not yet reached; fill() takes its next block from them first
        self.ahead = b""

    # Low-level input routines (r8, r16, ...), as in signal.c.  r8 returns
    # a signed byte (char is signed on the reference platform).
    def fill(self):
        n = self.bsize if self.bsize > 0 else _s.ibsize
        if self.ahead:
            b = self.ahead[:n]
            self.ahead = self.ahead[n:]
        else:
            b = self.fp.read(n) if self.fp is not None else b""
        self.stat = len(b)
        if b:
            self.buf = b
        self.bp = 0
        self.be = len(b)

    def r8(self):
        if self.bp >= self.be:
            self.fill()
        bp = self.bp
        buf = self.buf
        v = buf[bp] if bp < len(buf) else 0
        self.bp = bp + 1
        return v - 256 if v > 127 else v

    def r16(self):
        bp = self.bp
        if bp + 2 <= self.be:
            b = self.buf
            self.bp = bp + 2
            v = b[bp] | (b[bp + 1] << 8)
            return v - 65536 if v & 0x8000 else v
        lo = self.r8()
        hi = self.r8()
        return int16((hi << 8) | (lo & 0xFF))

    def r61(self):
        bp = self.bp
        if bp + 2 <= self.be:
            b = self.buf
            self.bp = bp + 2
            v = (b[bp] << 8) | b[bp + 1]
            return v - 65536 if v & 0x8000 else v
        hi = self.r8()
        lo = self.r8()
        return int16((lo & 0xFF) | (hi << 8))

    def r24(self):
        bp = self.bp
        if bp + 3 <= self.be:
            b = self.buf
            self.bp = bp + 3
            v = b[bp] | (b[bp + 1] << 8) | (b[bp + 2] << 16)
            return v - 0x1000000 if v & 0x800000 else v
        lw = self.r16()
        h = self.r8()
        return int32((h << 16) | (lw & 0xFFFF))

    def r32(self):
        bp = self.bp
        if bp + 4 <= self.be:
            b = self.buf
            self.bp = bp + 4
            v = b[bp] | (b[bp + 1] << 8) | (b[bp + 2] << 16) | (b[bp + 3] << 24)
            return v - 0x100000000 if v & 0x80000000 else v
        lw = self.r16()
        h = self.r16()
        return int32((h << 16) | (lw & 0xFFFF))

    # Offset-binary formats 80 and 160 (stored value = sample + 2^(bits-1)).
    def r80(self):
        return (self.r8() & 0xFF) - (1 << 7)

    def r160(self):
        return (self.r16() & 0xFFFF) - (1 << 15)

    def r212(self):
        c = self.count
        self.count = c + 1
        if c == 0:
            v = self.data = self.r16()
        else:
            self.count = 0
            v = ((self.data >> 4) & 0xF00) | (self.r8() & 0xFF)
        if v & 0x800:
            v |= ~0xFFF
        else:
            v &= 0xFFF
        return v

    def r310(self):
        c = self.count
        self.count = c + 1
        if c == 0:
            self.data = self.r16()
            v = self.data >> 1
        elif c == 1:
            self.datb = self.r16()
            v = self.datb >> 1
        else:
            self.count = 0
            v = ((self.data & 0xF800) >> 11) | ((self.datb & 0xF800) >> 6)
        if v & 0x200:
            v |= ~0x3FF
        else:
            v &= 0x3FF
        return v

    def r311(self):
        c = self.count
        self.count = c + 1
        if c == 0:
            v = self.data = self.r16()
        elif c == 1:
            self.datb = self.r8() & 0xFF
            v = ((self.data & 0xFC00) >> 10) | ((self.datb & 0xF) << 6)
        else:
            self.count = 0
            self.datb |= self.r8() << 8
            v = self.datb >> 4
        if v & 0x200:
            v |= ~0x3FF
        else:
            v &= 0x3FF
        return v


class _OGData:
    """State shared by all signals in an output group (one signal file)."""

    __slots__ = ("data", "datb", "fp", "start", "bsize", "buf", "obuflen",
                 "count", "seek", "force_flush", "nrewind", "flac")

    def __init__(self):
        self.data = 0
        self.datb = 0
        self.fp = None
        self.start = 0
        self.bsize = 0
        self.buf = bytearray()
        self.obuflen = 0
        self.count = 0
        self.seek = 0
        self.force_flush = 0
        self.nrewind = 0
        self.flac = None

    def w8(self, v):
        self.buf.append(v & 0xFF)
        if len(self.buf) >= self.obuflen:
            if self.fp is not None:
                self.fp.write(bytes(self.buf))
            self.buf = bytearray()

    def w16(self, v):
        self.w8(v)
        self.w8(v >> 8)

    def w61(self, v):
        self.w8(v >> 8)
        self.w8(v)

    def w24(self, v):
        self.w16(v)
        self.w8(v >> 16)

    def w32(self, v):
        self.w16(v)
        self.w16(v >> 16)

    def w80(self, v):
        self.w8((v & 0xFF) + (1 << 7))

    def w160(self, v):
        self.w16((v & 0xFFFF) + (1 << 15))

    def w212(self, v):
        c = self.count
        self.count = c + 1
        if c == 0:
            self.data = v & 0xFFF
        else:
            self.count = 0
            self.data |= (v << 4) & 0xF000
            self.w16(self.data)
            self.w8(v)

    def f212(self):
        if self.count == 1:
            self.w16(self.data)
            self.nrewind = 2

    def w310(self, v):
        c = self.count
        self.count = c + 1
        if c == 0:
            self.data = (v << 1) & 0x7FE
        elif c == 1:
            self.datb = (v << 1) & 0x7FE
        else:
            self.count = 0
            self.data |= (v << 11)
            self.w16(self.data)
            self.datb |= ((v << 6) & ~0x7FE)
            self.w16(self.datb)

    def f310(self):
        if self.count == 0:
            return
        if self.count == 1:
            self.w16(self.data)
            self.nrewind = 2
        else:
            self.w16(self.data)
            self.w16(self.datb)
            self.nrewind = 4

    def w311(self, v):
        c = self.count
        self.count = c + 1
        if c == 0:
            self.data = v & 0x3FF
        elif c == 1:
            self.data |= (v << 10)
            self.w16(self.data)
            self.datb = (v >> 6) & 0xF
        else:
            self.count = 0
            self.datb |= (v << 4)
            self.datb &= 0x3FFF
            self.w16(self.datb)

    def f311(self):
        if self.count == 0:
            return
        if self.count == 1:
            self.w16(self.data)
            self.nrewind = 2
        else:
            self.w16(self.datb)
            self.nrewind = 2


class _SigState:
    """All of the file-scope ('static') variables of signal.c."""

    def __init__(self):
        # header data
        self.hsd = []
        self.hheader = None
        # wfdb-x: the directory of the header read last (see wio._dirname;
        # None if unknown: the standard input), and the directory and name
        # of the header of the current multi-segment record (msrec_name is
        # None if there is none); user_segments while setmsheader reads the
        # headers of the segments it was given
        self.hdr_dir = None
        self.msrec_dir = None
        self.msrec_name = None
        self.user_segments = False
        # timing
        self.ffreq = 0.0
        self.ifreq = 0.0
        self.sfreq = 0.0
        self.cfreq = 0.0
        self.spfmax = 0
        self.btime = 0          # base time (ms after midnight)
        self.bdate = 0          # base date (Julian date)
        self.nsamples = 0
        self.bcount = 0.0
        self.prolog_bytes = 0
        # multi-segment records
        self.segments = 0
        self.in_msrec = 0
        self.msbtime = 0
        self.msbdate = 0
        self.msnsamples = 0
        self.segarray = None
        self.segp = 0          # index into segarray
        self.segend = 0
        # input signals
        self.isd = []
        self.igd = []
        self.nisig = 0
        self.nigroup = 0
        self.ispfmax = 0
        self.tvector = []
        self.uvector = []
        self.vvector = []
        self.tuvlen = 0
        self.istime = 0
        self.ibsize = 0
        self.skewmax = 0
        self.dsbuf = None
        self.dsbi = -1
        self.dsblen = 0
        self.framelen = 0
        self.gvmode = DEFWFDBGVMODE
        self.gvc = 0
        self.isedf = 0
        self.sbuf = None
        self.sample_vflag = 0
        self.sample_tt = -1
        # output signals
        self.osd = []
        self.ogd = []
        self.nosig = 0
        self.nogroup = 0
        self.oheader = None
        self.outinfo = None
        self.ostime = 0
        self.obsize = 0
        # info strings
        self.pinfo = None
        self.ninfo = 0
        self.info_i = 0
        # variable-layout (sigmap)
        self.need_sigmap = 0
        # wfdb-x: 1 while a high-level reader reads (getvec's checksum
        # message is then not printed: the reader warns instead)
        self.cksum_quiet = 0
        self.nvsig = 0
        self.tspf = 0
        self.vspfmax = 0
        self.vsd = []
        self.ovec = None
        self.smi = []
        # getvec resampling
        self.mticks = 0
        self.nticks = 0
        self.mnticks = 0
        self.rgvstat = 0
        self.rgvtime = 0
        self.gvtime = 0
        self.gv0 = None
        self.gv1 = None
        self.rgetvec_stat = 0
        # time/date strings
        self.date_string = ""
        self.time_string = ""
        self.pdays = -1


_s = _SigState()

# wfdb-x: legacy mode.  By default, the library has no built-in signal
# parameters (see docs/DIVERGENCES.md).  In legacy mode (wfdbx_set_legacy(1),
# or --legacy as the first argument of an application, see wfdbx_legacy_args),
# it behaves exactly as the original WFDB library 10.7.0, with its built-in
# defaults: WFDB_DEFFREQ for a header without a sampling frequency, an ADC
# resolution inferred from the format or WFDB_DEFRES, 1 sample per second in
# the time conversion functions, and WFDB_DEFGAIN (and a baseline of 0 for
# invalid signal numbers) in the unit conversion functions.  It exists for
# compatibility only.
_legacy_mode = 0


def wfdbx_set_legacy(on):
    """Turn legacy mode on (if ``on`` is true) or off.

    A wfdb-x addition (see docs/DIVERGENCES.md): returns the previous
    setting (1: on, 0: off).
    """
    global _legacy_mode
    previous = _legacy_mode
    _legacy_mode = 1 if on else 0
    return previous


def wfdbx_get_legacy():
    """Return 1 if legacy mode is on, 0 otherwise (a wfdb-x addition)."""
    return _legacy_mode


def wfdbx_legacy_args(argv):
    """Recognize --legacy as the first argument of an application.

    A wfdb-x addition: ``argv`` is the argument list, program name first.
    If argv[1] is exactly "--legacy", it is removed (in place), legacy mode
    is turned on, and 1 is returned; otherwise nothing changes and 0 is
    returned.
    """
    if len(argv) < 2 or argv[1] != "--legacy":
        return 0
    del argv[1]
    wfdbx_set_legacy(1)
    return 1


def _legacy_adcres(fmt):
    # The original inference of a missing ADC resolution (legacy mode).
    return {80: 8, 160: 16, 212: 12, 310: 10, 311: 10}.get(fmt, WFDB_DEFRES)


def _isfmt(f):
    return f in WFDB_FMT_LIST


def _isflacfmt(f):
    # FLAC formats are 500 + bits per sample (508, 516, 524 are defined).
    return 500 <= f <= 532


# ---------------------------------------------------------------------------
# Variable-layout multi-segment records

def _sigmap_cleanup():
    _s.need_sigmap = _s.nvsig = _s.tspf = _s.vspfmax = 0
    _s.ovec = None
    _s.smi = []
    _s.vsd = []


def _make_vsd():
    if _s.nvsig != _s.nisig:
        wfdb_error("make_vsd: oops! nvsig = %d, nisig = %d\n",
                   _s.nvsig, _s.nisig)
        return -1
    vsd = []
    for i in range(_s.nvsig):
        v = _ISData()
        v.info = _s.isd[i].info.copy()
        v.skew = _s.isd[i].skew
        vsd.append(v)
    _s.vsd = vsd
    return _s.nvsig


def _sigmap_init(first_segment):
    s_ = _s
    if s_.in_msrec and first_segment and s_.segarray and \
            s_.segarray[0].nsamp == 0:
        s_.need_sigmap = 1
        s_.nvsig = s_.nisig
        s_.vspfmax = s_.ispfmax
        s_.tspf = 0
        for s in range(s_.nisig):
            s_.tspf += s_.isd[s].info.spf
        smi = []
        for i in range(s_.nisig):
            m = _SigMapInfo()
            m.desc = s_.isd[i].info.desc
            m.gain = s_.isd[i].info.gain
            m.baseline = s_.isd[i].info.baseline
            k = m.spf = s_.isd[i].info.spf
            smi.append(m)
            for j in range(1, k):
                smi.append(m.copy())
        s_.smi = smi
        s_.ovec = [0] * s_.tspf
        return _make_vsd()
    elif s_.need_sigmap:
        smi = s_.smi
        for s in range(s_.tspf):
            smi[s].index = 0
            smi[s].scale = 0.0
            smi[s].offset = 0.0
            smi[s].sample_offset = WFDB_INVALID_SAMPLE
        s_.ispfmax = s_.vspfmax
        if s_.isd[0].info.fmt == 0 and s_.nisig == 1:
            return 0
        j = 0
        for i in range(s_.nisig):
            isi = s_.isd[i].info
            s = 0
            while s < s_.tspf:
                if smi[s].desc == isi.desc:
                    kmax = smi[s].spf
                    if kmax != isi.spf:
                        wfdb_error("sigmap_init: unexpected spf for signal "
                                   "%d in segment %s\n", i,
                                   s_.segarray[s_.segp].recname)
                        if kmax > isi.spf:
                            kmax = isi.spf
                    for k in range(kmax):
                        ps = smi[s + k]
                        ps.index = j + k
                        ps.scale = ps.gain / isi.gain if isi.gain != 0 else \
                            (float("inf") if ps.gain > 0 else
                             (float("-inf") if ps.gain < 0 else float("nan")))
                        if ps.scale < 1.0:
                            wfdb_error("sigmap_init: loss of precision in "
                                       "signal %d in segment %s\n", i,
                                       s_.segarray[s_.segp].recname)
                        ps.offset = ps.baseline - ps.scale * isi.baseline + 0.5
                        f = isi.fmt
                        if f in (508, 80):
                            ivmin, ivmax = -0x80, 0x7f
                        elif f in (310, 311):
                            ivmin, ivmax = -0x200, 0x1ff
                        elif f == 212:
                            ivmin, ivmax = -0x800, 0x7ff
                        elif f in (16, 61, 516, 160):
                            ivmin, ivmax = -0x8000, 0x7fff
                        elif f in (524, 24):
                            ivmin, ivmax = -0x800000, 0x7fffff
                        else:
                            ivmin, ivmax = WFDB_SAMPLE_MIN, WFDB_SAMPLE_MAX
                        ovmin = ivmin * ps.scale + ps.offset
                        ovmax = ivmax * ps.scale + ps.offset
                        if ovmin < ovmax and ovmin >= WFDB_SAMPLE_MIN + 1 and \
                                ovmax <= WFDB_SAMPLE_MAX and \
                                ovmax - ovmin + 1 < WFDB_SAMPLE_MAX:
                            ps.sample_offset = int(ovmin - 1)
                            ps.offset -= ps.sample_offset
                        else:
                            ps.sample_offset = 0
                    break
                s += smi[s].spf
            j += isi.spf
        if j > s_.tspf:
            wfdb_error("sigmap_init: frame size too large in segment %s\n",
                       s_.segarray[s_.segp].recname)
            return -1
    elif s_.in_msrec and not first_segment and s_.framelen == 0:
        s_.ispfmax = s_.vspfmax
        if s_.nisig > s_.nvsig:
            wfdb_error("sigmap_init: wrong number of signals in segment %s\n",
                       s_.segarray[s_.segp].recname)
            return -1
        for i in range(s_.nisig):
            if s_.isd[i].info.spf != s_.vsd[i].info.spf:
                wfdb_error("sigmap_init: wrong spf for signal %d in segment "
                           "%s\n", i, s_.segarray[s_.segp].recname)
                return -1
    else:
        s_.nvsig = s_.nisig
        s_.vspfmax = s_.ispfmax
        s_.tspf = 0
        for s in range(s_.nisig):
            s_.tspf += s_.isd[s].info.spf
        return _make_vsd()
    return 0


def _sigmap(vector, ivec):
    smi = _s.smi
    for i in range(_s.tspf):
        m = smi[i]
        x = ivec[m.index]
        if x == WFDB_INVALID_SAMPLE:
            vector[i] = WFDB_INVALID_SAMPLE
        else:
            v = x * m.scale + m.offset
            if m.sample_offset:
                vector[i] = int32(int(v) + m.sample_offset)
            else:
                if v >= 0:
                    vector[i] = int(v) if v <= WFDB_SAMPLE_MAX else \
                        WFDB_SAMPLE_MAX
                else:
                    if v >= WFDB_SAMPLE_MIN:
                        r = int(v)
                        if r > v:
                            r -= 1
                        vector[i] = r
                    else:
                        vector[i] = WFDB_SAMPLE_MIN
    return _s.tspf


# ---------------------------------------------------------------------------
# Header parsing

def _read_edf_str(f, size):
    b = f.read(size)
    if len(b) != size:
        return ""
    s = b.decode("latin-1")
    i = s.find("\0")
    if i >= 0:
        s = s[:i]
    return s.rstrip(" ")


def _scan_ints(s, n):
    """sscanf(s, "%d%*c%d%*c%d") -- returns up to n ints (None if missing)."""
    out = []
    pos = 0
    for k in range(n):
        v, end = strtol(s, 10, pos)
        if end == pos:
            break
        out.append(int32(v))
        pos = end
        if k < n - 1:
            if pos >= len(s):
                break
            pos += 1
    while len(out) < n:
        out.append(None)
    return out


def _edfparse(ifile):
    s_ = _s
    edf_fname = wio.get_filename()
    magic = ifile.read(8).decode("latin-1")
    if magic[:8] == "0       ":
        fmt = 16
    elif magic[1:8] == "BIOSEMI":
        fmt = 24
    else:
        wfdb_error("init: '%s' is not EDF or EDF+\n", edf_fname)
        return -2
    # The fixed-size section of the header (field widths in bytes, as in
    # the EDF specification).
    _read_edf_str(ifile, 80)                    # patient ID (ignored)
    _read_edf_str(ifile, 80)                    # recording ID (ignored)
    day, month, year = _scan_ints(_read_edf_str(ifile, 8), 3)
    day = day or 0
    month = month or 0
    year = (year or 0) + 1900                   # EDF has two-digit years
    if year < 1985:
        year += 100
    hour, minute, second = _scan_ints(_read_edf_str(ifile, 8), 3)
    hour = hour or 0
    minute = minute or 0
    second = second or 0
    offset = _scan_ints(_read_edf_str(ifile, 8), 1)[0] or 0   # header size
    _read_edf_str(ifile, 44)                    # reserved (ignored)
    nframes = strtol(_read_edf_str(ifile, 8))[0]    # number of data records
    if nframes < 0:
        nframes = 0
    s_.nsamples = nframes
    spr = strtod(_read_edf_str(ifile, 8))[0]    # data record duration (s)
    if spr <= 0.0:
        spr = 1.0
    nsig = _scan_ints(ifile.read(4).decode("latin-1"), 1)[0] or 0
    # The header has 256 bytes, plus 256 bytes per signal.
    if nsig < 1 or (nsig + 1) * 256 != offset:
        wfdb_error("init: '%s' is not EDF or EDF+\n", edf_fname)
        return -2
    while len(s_.hsd) < nsig:
        s_.hsd.append(_HSData())
    # strip any path info from the EDF file name
    p = len(edf_fname) - 4
    base = 0
    p -= 1
    while p > 0:
        if edf_fname[p] == "/":
            base = p + 1
            break
        p -= 1
    fname = edf_fname[base:]
    pmin = [0.0] * nsig
    pmax = [0.0] * nsig
    dmin = [0] * nsig
    dmax = [0] * nsig
    for s in range(nsig):
        h = s_.hsd[s]
        h.start = offset
        h.skew = 0
        h.info.fname = fname
        h.info.group = h.info.bsize = h.info.cksum = 0
        h.info.fmt = fmt
        h.info.nsamp = nframes
        h.info.desc = _read_edf_str(ifile, 16)      # signal type
    for s in range(nsig):
        _read_edf_str(ifile, 80)        # transducer type (ignored)
    for s in range(nsig):
        s_.hsd[s].info.units = _read_edf_str(ifile, 8)
    for s in range(nsig):
        pmin[s] = strtod(_read_edf_str(ifile, 8))[0]
    for s in range(nsig):
        pmax[s] = strtod(_read_edf_str(ifile, 8))[0]
    for s in range(nsig):
        dmin[s] = strtol(_read_edf_str(ifile, 8))[0]
    for s in range(nsig):
        dmax[s] = strtol(_read_edf_str(ifile, 8))[0]
        h = s_.hsd[s]
        h.info.initval = h.info.adczero = int32(cdiv(dmax[s] + 1 + dmin[s], 2))
        adcrange = dmax[s] - dmin[s]
        i = 0
        while adcrange > 0:
            adcrange = cdiv(adcrange, 2)
            i += 1
        h.info.adcres = i
        if pmax[s] != pmin[s]:
            h.info.gain = (dmax[s] - dmin[s]) / (pmax[s] - pmin[s])
            baseline = dmax[s] - pmax[s] * h.info.gain
            if baseline >= 0.0:
                h.info.baseline = int(baseline + 0.5)
            else:
                h.info.baseline = int(baseline - 0.5)
        else:
            h.info.gain = 0.0
            h.info.baseline = 0
    for s in range(nsig):
        _read_edf_str(ifile, 80)        # filtering information (ignored)
    for s in range(nsig):
        n = _scan_ints(_read_edf_str(ifile, 8), 1)[0] or 0  # samples/record
        s_.hsd[s].info.spf = n
        if n > s_.spfmax:
            s_.spfmax = n
    ifile.close()
    s_.hheader = None
    s_.ffreq = 1.0 / spr
    s_.cfreq = s_.ffreq
    s_.sfreq = s_.ffreq * s_.spfmax
    from ._annot import getafreq, setafreq
    if getafreq() == 0.0:
        setafreq(s_.sfreq)
    s_.gvmode |= WFDB_HIGHRES
    setbasetime("%02d:%02d:%02d %02d/%02d/%04d" % (
        hour, minute, second, day, month, year))
    s_.isedf = 1
    return nsig


def _open_header(s, record):
    """Open the header (of type s: "hea", or None for a file name) of a
    record, or of a segment named in the header of the current multi-segment
    record (wfdb-x: in that header's directory), and note its directory."""
    s_ = _s
    if wfdbx_get_legacy():
        return wfdb_open(s, record, WFDB_READ)
    if not s_.in_msrec:
        s_.msrec_dir = s_.msrec_name = None
    if s_.in_msrec and s_.msrec_name is not None and not s_.user_segments:
        f = wio._open_in(s_.msrec_dir, s, record, s_.msrec_name)
    else:
        f = wfdb_open(s, record, WFDB_READ)
    s_.hdr_dir = None
    if f is not None and not f.is_std:
        s_.hdr_dir = wio._dirname(wio.get_filename())
    return f


def _readheader(record):
    s_ = _s
    sep = " \t\n\r"
    if s_.hheader is not None:
        s_.hheader.close()
        s_.hheader = None
    s_.spfmax = 1
    s_.sfreq = s_.ffreq
    s_.isedf = 0
    if record == "~":
        if s_.in_msrec and s_.vsd:
            h = _HSData()
            h.info.desc = "~"
            h.info.spf = 1
            h.info.fmt = 0
            h.info.nsamp = s_.nsamples = s_.segarray[s_.segp].nsamp
            s_.hsd = [h]
            return 1
        return 0
    q = len(record) - 1
    while q > 0 and record[q] not in "./:\\":
        q -= 1
    if q >= 0 and record[q:q + 1] == ".":
        s_.hheader = _open_header(None, record)
        if s_.hheader is None:
            wfdb_error("init: can't open %s\n", record)
            return -1
        elif record[q + 1:] != "hea":
            return _edfparse(s_.hheader)
    else:
        s_.hheader = _open_header("hea", record)
        if s_.hheader is None:
            wfdb_error("init: can't open header for record %s\n", record)
            return -1
    hh = s_.hheader
    line = hh.getline()
    if line == "":
        wfdb_error("init: record %s header is empty\n", record)
        return -2
    if line.startswith("#wfdb"):
        vals = []
        pos = 5         # just past "#wfdb"
        for k in range(3):
            v, end = strtol(line, 10, pos)
            if end == pos:
                break
            vals.append(v)
            pos = end
            if k < 2:
                if line[pos:pos + 1] != ".":
                    break
                pos += 1
        i = len(vals)
        major = vals[0] if i > 0 else 0
        minor = vals[1] if i > 1 else 0
        release = vals[2] if i > 2 else 0
        if (i > 0 and major > wio.WFDB_MAJOR) or \
                (i > 1 and major == wio.WFDB_MAJOR and
                 minor > wio.WFDB_MINOR) or \
                (i > 2 and major == wio.WFDB_MAJOR and
                 minor == wio.WFDB_MINOR and release > wio.WFDB_RELEASE):
            wfdb_error("init: reading record %s requires WFDB library "
                       "version %d.%d.%d or later\n"
                       "  (the most recent version is always available from "
                       "http://physionet.org)\n",
                       record, major, minor, release)
            return -1
    tok = Strtok(line)
    p = tok.next(sep)
    while p is None or p.startswith("#"):
        line = hh.getline()
        if line == "":
            wfdb_error("init: can't find record name in record %s header\n",
                       record)
            return -2
        tok = Strtok(line)
        p = tok.next(sep)
    slash = p.find("/", 1)
    if slash >= 1:
        if s_.in_msrec:
            wfdb_error("init: record %s cannot be nested in another "
                       "multi-segment record\n", record)
            return -2
        s_.segments = int32(strtol(p, 10, slash + 1)[0])
        p = p[:slash]
    if hh.type == WFDB_LOCAL and not hh.is_std and \
            record[:len(p)] != p:
        r = record
        sidx = len(r) - 1
        q2 = sidx
        while sidx != 0:
            if r[sidx] in "/\\:":
                break
            sidx -= 1
        if q2 > sidx and (0 > sidx or p != r[sidx + 1:]):
            wfdb_error("init: record name in record %s header is incorrect\n",
                       record)
            return -2
    p = tok.next(sep)
    if p is None:
        wfdb_error("init: obsolete format in record %s header\n", record)
        return -2
    nsig = strtol(p)[0] & 0xFFFFFFFF
    p = tok.next(sep)
    if p is not None:
        f = strtod(p)[0]
        if f <= 0.0:
            wfdb_error("init: sampling frequency in record %s header is "
                       "incorrect\n", record)
            return -2
        if s_.ffreq > 0.0 and f != s_.ffreq:
            wfdb_error("warning (init):\n")
            wfdb_error(" record %s sampling frequency differs", record)
            wfdb_error(" from that of previously opened record\n")
        else:
            s_.ffreq = f
    # wfdb-x: no default sampling frequency (C assumed WFDB_DEFFREQ, 250 Hz):
    # if neither the header nor setsampfreq() gives one, it remains 0.
    elif _legacy_mode and s_.ffreq == 0.0:
        s_.ffreq = WFDB_DEFFREQ     # wfdb-x: legacy mode (original behavior)
    s_.sfreq = s_.ffreq
    s_.cfreq = s_.bcount = 0.0
    if p is not None:
        k = p.find("/")
        if k >= 0:
            s_.cfreq = strtod(p, k + 1)[0]
            k2 = p.find("(", k + 1)
            if k2 >= 0:
                s_.bcount = strtod(p, k2 + 1)[0]
    if s_.cfreq <= 0.0:
        s_.cfreq = s_.ffreq
    p = tok.next(sep)
    if p is not None:
        ns = strtol(p)[0]
        if ns < 0:
            wfdb_error("init: number of samples in record %s header is "
                       "incorrect\n", record)
            return -2
        if s_.nsamples == 0:
            s_.nsamples = ns
        elif ns > 0 and ns != s_.nsamples and not s_.in_msrec:
            wfdb_error("warning (init):\n")
            wfdb_error(" record %s duration differs", record)
            wfdb_error(" from that of previously opened record\n")
            if s_.nsamples > ns:
                s_.nsamples = ns
    else:
        ns = 0
    p = tok.next("\n\r")
    if p is not None and s_.btime == 0 and setbasetime(p) < 0:
        return -2
    # master header of a multi-segment record
    if s_.segments and not s_.in_msrec:
        if not wfdbx_get_legacy():   # wfdb-x: the segments are next to it
            s_.msrec_dir = s_.hdr_dir
            s_.msrec_name = record
        s_.msbtime = s_.btime
        s_.msbdate = s_.bdate
        s_.msnsamples = s_.nsamples
        segarray = []
        ns = 0
        for i in range(s_.segments):
            while True:
                line = hh.getline()
                if line == "":
                    wfdb_error("init: unexpected EOF in header file for "
                               "record %s\n", record)
                    s_.segarray = None
                    s_.segments = 0
                    return -2
                tok = Strtok(line)
                p = tok.next(sep)
                if p is not None and not p.startswith("#"):
                    break
            if p.startswith("+"):
                wfdb_error("init: `%s' is not a valid segment name in record "
                           "%s\n", p, record)
                s_.segarray = None
                s_.segments = 0
                return -2
            if len(p) > WFDB_MAXRNL:
                wfdb_error("init: `%s' is too long for a segment name in "
                           "record %s\n", p, record)
                s_.segarray = None
                s_.segments = 0
                return -2
            seg = Seginfo(p)
            p = tok.next(sep)
            if p is not None:
                seg.nsamp = strtol(p)[0]
            if p is None or seg.nsamp < 0:
                wfdb_error("init: length must be specified for segment %s in "
                           "record %s\n", seg.recname, record)
                s_.segarray = None
                s_.segments = 0
                return -2
            seg.samp0 = ns
            ns += seg.nsamp
            segarray.append(seg)
        s_.segarray = segarray
        s_.segend = len(segarray) - 1
        s_.segp = 0
        if s_.msnsamples == 0:
            s_.msnsamples = ns
        elif ns != s_.msnsamples:
            wfdb_error("warning (init): in record %s, stated record length "
                       "(%d)\n", record, s_.msnsamples)
            wfdb_error(" does not match sum of segment lengths (%d)\n", ns)
        return 0
    while len(s_.hsd) < nsig:
        s_.hsd.append(_HSData())
    s = 0
    while s < nsig:
        hs = s_.hsd[s]
        hp = s_.hsd[s - 1] if s else None
        while True:
            line = hh.getline()
            if line == "":
                wfdb_error("init: unexpected EOF in header file for record "
                           "%s\n", record)
                return -2
            tok = Strtok(line)
            p = tok.next(sep)
            if p is not None and not p.startswith("#"):
                break
        if s == 0 or p != hp.info.fname:
            hs.info.group = 0 if s == 0 else hp.info.group + 1
            hs.info.fname = p
        else:
            hs.info.group = hp.info.group
            hs.info.fname = hp.info.fname
        p = tok.next(sep)
        if p is not None:
            hs.info.fmt = int32(strtol(p)[0])
        if p is None or not _isfmt(hs.info.fmt):
            wfdb_error("init: illegal format for signal %d, record %s\n",
                       s, record)
            return -2
        hs.info.spf = 1
        hs.skew = 0
        hs.start = 0
        k = 0
        n = len(p)
        # Parse the optional "xSPF", ":SKEW", and "+START" suffixes.
        while True:
            k += 1
            if k >= n:
                break
            if p[k] == "x":
                k += 1
                if k < n:
                    hs.info.spf = int32(strtol(p, 10, k)[0])
                    if hs.info.spf < 1:
                        hs.info.spf = 1
            if k < n and p[k] == ":":
                k += 1
                if k < n:
                    hs.skew = int32(strtol(p, 10, k)[0])
                    if hs.skew < 0:
                        hs.skew = 0
            if k < n and p[k] == "+":
                k += 1
                if k < n:
                    hs.start = strtol(p, 10, k)[0]
                    if hs.start < 0:
                        hs.start = 0
            if k >= n:
                break
        if hs.info.spf > s_.spfmax:
            s_.spfmax = hs.info.spf
        hs.skew = int(float(hs.skew) / hs.info.spf + 0.5)
        p = tok.next(sep)
        if p is not None:
            hs.info.gain = strtod(p)[0]
        else:
            hs.info.gain = 0.0
        nobaseline = 1
        units = None
        if p is not None:
            k = 0
            n = len(p)
            while k < n and p[k] not in "(/":
                k += 1
            if k < n and p[k] == "(":
                k += 1
                hs.info.baseline = int32(strtol(p, 10, k)[0])
                nobaseline = 0
            while k < n:
                c = p[k]
                k += 1
                if c == "/" and k < n:
                    break
            if k < n:
                units = p[k:k + WFDB_MAXUSL]
        hs.info.units = units
        p = tok.next(sep)
        if p is not None:
            i = strtol(p)[0] & 0xFFFFFFFF
        else:
            # wfdb-x: a missing ADC resolution is unspecified (0); the C
            # library inferred it from the format or assumed WFDB_DEFRES, as
            # legacy mode does.
            i = _legacy_adcres(hs.info.fmt) if _legacy_mode else 0
        hs.info.adcres = int32(i)
        p = tok.next(sep)
        hs.info.adczero = int32(strtol(p)[0]) if p is not None else 0
        if nobaseline:
            hs.info.baseline = hs.info.adczero
        p = tok.next(sep)
        hs.info.initval = int32(strtol(p)[0]) if p is not None else \
            hs.info.adczero
        p = tok.next(sep)
        if p is not None:
            hs.info.cksum = int32(strtol(p)[0])
            hs.info.nsamp = 0 if ns > LONG_MAX else ns
        else:
            hs.info.cksum = 0
            hs.info.nsamp = 0
        p = tok.next(sep)
        hs.info.bsize = int32(strtol(p)[0]) if p is not None else 0
        if s and (hs.info.group == hp.info.group and
                  (hs.info.fmt != hp.info.fmt or
                   hs.info.bsize != hp.info.bsize)):
            wfdb_error("init: error in specification of signal %d or %d\n",
                       s - 1, s)
            return -2
        p = tok.next("\n\r")
        if p is not None:
            hs.info.desc = p[:WFDB_MAXDSL]
        else:
            hs.info.desc = "record %s, signal %d" % (record, s)
        s += 1
    setgvmode(s_.gvmode)
    return s


def _hsdfree():
    _s.hsd = []


# ---------------------------------------------------------------------------
# Opening and closing signals

def _isigclose():
    s_ = _s
    if s_.sbuf is not None and not s_.in_msrec:
        s_.sbuf = None
        s_.sample_vflag = 0
    s_.isd = []
    s_.nisig = 0
    s_.framelen = 0
    for ig in s_.igd:
        if ig.flac is not None:
            _flac.isclose(ig)
        if ig.fp is not None:
            ig.fp.close()
    s_.igd = []
    s_.nigroup = 0
    s_.istime = 0
    s_.gvc = s_.ispfmax = 1
    if s_.hheader is not None:
        s_.hheader.close()
        s_.hheader = None
    if s_.nosig == 0 and s_.hsd:
        _hsdfree()


def _osigclose():
    s_ = _s
    stat = 0
    for og in s_.ogd[:s_.nogroup]:
        og.force_flush = 1
    _wfdb_osflush()
    s_.osd = []
    s_.nosig = 0
    g = len(s_.ogd)
    for og in reversed(s_.ogd):
        g -= 1
        if og.fp is not None:
            flac = og.flac is not None
            if flac:
                _flac.osclose(og)
            if og.bsize and not flac:
                while len(og.buf) < og.obuflen:
                    og.buf.append(0)
            if og.buf:
                og.fp.write(bytes(og.buf))
                og.buf = bytearray()
            if og.fp.is_std:
                og.fp.flush()
            errflag = og.fp.ferror()
            if not og.fp.is_std:
                if og.fp.close():
                    errflag = True
                og.fp = None
            if errflag:
                wfdb_error("osigclose: write error in signal group %d\n", g)
                stat = -4
    s_.ogd = []
    s_.nogroup = 0
    s_.ostime = 0
    if s_.oheader is not None:
        errflag = s_.oheader.ferror()
        if s_.oheader.close():
            errflag = True
        if errflag:
            wfdb_error("osigclose: write error in header file\n")
            stat = -4
        if s_.outinfo is s_.oheader:
            s_.outinfo = None
        s_.oheader = None
    if s_.nisig == 0 and s_.hsd:
        _hsdfree()
    return stat


# ---------------------------------------------------------------------------
# Input positioning

def _isgsetframe(g, t):
    s_ = _s
    trem = 0
    d = 1
    # (C reads igd[g] even if g is not a signal group number: undefined
    # behavior, here the group number is then reported as incorrect)
    if s_.nigroup < 2 and s_.istime == t and s_.gvc == s_.ispfmax and \
            0 <= g < len(s_.igd) and s_.igd[g].start == 0:
        return 0
    s = 0
    while s < s_.nisig and g != s_.isd[s].info.group:
        s += 1
    if s == s_.nisig:
        wfdb_error("isgsettime: incorrect signal group number %d\n", g)
        return -2
    if s_.in_msrec:
        if t >= s_.msnsamples:
            wfdb_error("isigsettime: improper seek on signal group %d\n", g)
            return -1
        tseg = s_.segp
        seg = s_.segarray
        while t < seg[tseg].samp0:
            tseg -= 1
        while t >= seg[tseg].samp0 + seg[tseg].nsamp and tseg < s_.segend:
            tseg += 1
        if s_.segp != tseg:
            s_.segp = tseg
            if isigopen(seg[tseg].recname, None, s_.nvsig) <= 0:
                wfdb_error("isigsettime: can't open segment %s\n",
                           seg[tseg].recname)
                return -1
            for h in range(1, s_.nigroup):
                i = _isgsetframe(h, t)
                if i:
                    return i
            if g == 0:
                return _isgsetframe(0, t)
            return 0
        t -= seg[s_.segp].samp0
    ig = s_.igd[g]
    ig.initial_skip = 0
    n = nn = 0
    while s + n < s_.nisig and s_.isd[s + n].info.group == g:
        nn += s_.isd[s + n].info.spf
        n += 1
    fmt = s_.isd[s].info.fmt
    if fmt == 0:
        if t < s_.nsamples:
            s_.gvc = s_.ispfmax
            if s == 0:
                s_.istime = t + s_.segarray[s_.segp].samp0 if s_.in_msrec \
                    else t
            s_.isd[s].info.nsamp = s_.nsamples - t
            ig.stat = 1
            return 0
        else:
            if s == 0:
                s_.istime = s_.msnsamples if s_.in_msrec else s_.nsamples
            s_.isd[s].info.nsamp = 0
            return -1
    elif fmt in (508, 516, 524):
        if _flac.isseek(ig, t) < 0:
            wfdb_error("isigsettime: improper seek on signal group %d\n", g)
            return -1
        s_.gvc = s_.ispfmax
        if s == 0:
            s_.istime = t + s_.segarray[s_.segp].samp0 if s_.in_msrec else t
        while n:
            n -= 1
            s_.isd[s + n].info.nsamp = 0
        return 0
    elif fmt in (16, 61, 160):
        if nn > UINT_MAX // 2:
            wfdb_error("isigsettime: overflow in signal group %d\n", g)
            return -1
        b = 2 * nn
    elif fmt == 212:
        if nn > UINT_MAX // 3:
            wfdb_error("isigsettime: overflow in signal group %d\n", g)
            return -1
        ig.count = 0
        if (nn & 1) and (t & 1):
            if s_.in_msrec:
                t += s_.segarray[s_.segp].samp0
            i = _isgsetframe(g, t - 1)
            if i:
                return i
            for j in range(nn):
                ig.r212()
            s_.istime += 1
            n = 0
            while s + n < s_.nisig and s_.isd[s + n].info.group == g:
                s_.isd[s + n].info.nsamp = 0
                n += 1
            return 0
        b = 3 * nn
        d = 2
    elif fmt in (310, 311):
        if nn > UINT_MAX // 4:
            wfdb_error("isigsettime: overflow in signal group %d\n", g)
            return -1
        ig.count = 0
        trem = cmod(t, 3)
        if (nn % 3) and trem:
            if s_.in_msrec:
                t += s_.segarray[s_.segp].samp0
            i = _isgsetframe(g, t - trem)
            if i:
                return i
            rd = ig.r310 if fmt == 310 else ig.r311
            for j in range(nn * trem):
                rd()
            s_.istime += trem
            n = 0
            while s + n < s_.nisig and s_.isd[s + n].info.group == g:
                s_.isd[s + n].info.nsamp = 0
                n += 1
            return 0
        b = 4 * nn
        d = 3
    elif fmt == 24:
        if nn > UINT_MAX // 3:
            wfdb_error("isigsettime: overflow in signal group %d\n", g)
            return -1
        b = 3 * nn
    elif fmt == 32:
        if nn > UINT_MAX // 4:
            wfdb_error("isigsettime: overflow in signal group %d\n", g)
            return -1
        b = 4 * nn
    else:   # 8, 80, and default
        b = nn
    if b == 0 or t > cdiv(LONG_MAX, b) or \
            cdiv(t * b, d) > (LONG_MAX - ig.start):
        wfdb_error("isigsettime: improper seek on signal group %d\n", g)
        return -1
    if ig.seek:
        tt = t * b
        nb = cdiv(tt, d) + ig.start
        i = ig.bsize if ig.bsize != 0 else s_.ibsize
        tt = cdiv(nb, i)
        ig.ahead = b""      # (wfdb-x: the bulk reader's blocks)
        if ig.fp is None or ig.fp.seek(tt * i, 0):
            wfdb_error("isigsettime: improper seek on signal group %d\n", g)
            return -1
        nb = cmod(nb, i)
    else:
        t0 = s_.istime - cdiv(ig.bp, b)
        t1 = t0 + cdiv(ig.be, b)
        if t < t0:
            if ig.fp.seek(0, 0):
                wfdb_error("isigsettime: improper seek on signal group %d\n",
                           g)
                return -1
            tt = t * b
            nb = cdiv(tt, d) + ig.start
        elif t < t1:
            tt = (t - t0) * b
            ig.bp = cdiv(tt, d)
            return 0
        else:
            tt = (t - t1) * b
            nb = cdiv(tt, d)
        while nb > ig.bsize and not ig.fp.feof():
            nb -= len(ig.fp.read(ig.bsize))
    ig.bp = ig.be = 0
    ig.stat = 1
    while nb > 0 and ig.stat > 0:
        nb -= 1
        ig.r8()
    if ig.stat <= 0:
        return -1
    s_.gvc = s_.ispfmax
    if s == 0:
        s_.istime = t + s_.segarray[s_.segp].samp0 if s_.in_msrec else t
    while n:
        n -= 1
        s_.isd[s + n].info.nsamp = 0
    return 0


def _getskewedframe(vector, vstart=0):
    """Read one frame (without deskewing) into vector[vstart:]."""
    s_ = _s
    stat = s_.nisig
    if stat == 0:
        return -1 if s_.nvsig > 0 else 0
    isd = s_.isd
    igd = s_.igd
    if s_.istime == 0:
        for s in range(s_.nisig):
            isd[s].samp = isd[s].info.initval
    g = s_.nigroup
    while g:
        g -= 1
        if igd[g].initial_skip:
            _isgsetframe(g, s_.segarray[s_.segp].samp0 if s_.in_msrec else 0)
    if s_.need_sigmap:
        vec = s_.ovec
        vi = 0
    else:
        vec = vector
        vi = vstart
    pad = s_.gvmode & WFDB_GVPAD
    for s in range(s_.nisig):
        is_ = isd[s]
        info = is_.info
        ig = igd[info.group]
        fmt = info.fmt
        cks = info.cksum
        for c in range(info.spf):
            if fmt == 0:
                v = is_.samp if pad else WFDB_INVALID_SAMPLE
                vec[vi] = v
                if info.nsamp == 0:
                    ig.stat = -1
            elif fmt == 212:
                v = ig.r212()
                if v == -1 << 11:
                    vec[vi] = is_.samp if pad else WFDB_INVALID_SAMPLE
                else:
                    vec[vi] = is_.samp = v
            elif fmt == 16:
                v = ig.r16()
                if v == -1 << 15:
                    vec[vi] = is_.samp if pad else WFDB_INVALID_SAMPLE
                else:
                    vec[vi] = is_.samp = v
            elif fmt == 61:
                v = ig.r61()
                if v == -1 << 15:
                    vec[vi] = is_.samp if pad else WFDB_INVALID_SAMPLE
                else:
                    vec[vi] = is_.samp = v
            elif fmt == 80:
                v = ig.r80()
                if v == -1 << 7:
                    vec[vi] = is_.samp if pad else WFDB_INVALID_SAMPLE
                else:
                    vec[vi] = is_.samp = v
            elif fmt == 160:
                v = ig.r160()
                if v == -1 << 15:
                    vec[vi] = is_.samp if pad else WFDB_INVALID_SAMPLE
                else:
                    vec[vi] = is_.samp = v
            elif fmt == 310:
                v = ig.r310()
                if v == -1 << 9:
                    vec[vi] = is_.samp if pad else WFDB_INVALID_SAMPLE
                else:
                    vec[vi] = is_.samp = v
            elif fmt == 311:
                v = ig.r311()
                if v == -1 << 9:
                    vec[vi] = is_.samp if pad else WFDB_INVALID_SAMPLE
                else:
                    vec[vi] = is_.samp = v
            elif fmt == 24:
                v = ig.r24()
                if v == -1 << 23:
                    vec[vi] = is_.samp if pad else WFDB_INVALID_SAMPLE
                else:
                    vec[vi] = is_.samp = v
            elif fmt == 32:
                v = ig.r32()
                if v == -1 << 31:
                    vec[vi] = is_.samp if pad else WFDB_INVALID_SAMPLE
                else:
                    vec[vi] = is_.samp = v
            elif fmt in (508, 516, 524):
                v = _flac.getsamp(ig)
                if v == _INVALID_BY_FMT[fmt]:
                    vec[vi] = is_.samp if pad else WFDB_INVALID_SAMPLE
                else:
                    vec[vi] = is_.samp = v
            else:   # format 8 (first differences), and default
                v = is_.samp = int32(is_.samp + ig.r8())
                vec[vi] = v
            vi += 1
            if ig.stat <= 0:
                ig.count = 0
                if ig.stat == -2:
                    stat = -3
                elif info.nsamp > 0:
                    wfdb_error("getvec: unexpected EOF in signal %d\n", s)
                    stat = -3
                elif s_.in_msrec and s_.segarray is not None and \
                        s_.segp < s_.segend:
                    s_.segp += 1
                    if isigopen(s_.segarray[s_.segp].recname, None,
                                s_.nvsig) <= 0:
                        wfdb_error("getvec: error opening segment %s\n",
                                   s_.segarray[s_.segp].recname)
                        stat = -3
                        return stat
                    else:
                        s_.istime = s_.segarray[s_.segp].samp0
                        return _getskewedframe(vector, vstart)
                else:
                    stat = -1
            cks -= v
        info.cksum = int32(cks)
        if info.nsamp >= 0:
            info.nsamp -= 1
            # The checksum in the header is the low 16 bits of the sum.
            if info.nsamp == 0 and (info.cksum & 0xFFFF) and \
                    not s_.in_msrec and not s_.isedf and fmt != 0:
                # wfdb-x: not printed during a high-level read (which
                # warns instead), but recorded for wfdberror
                pr = wio._io.error_print
                if s_.cksum_quiet:
                    wio._io.error_print = False
                wfdb_error("getvec: checksum error in signal %d\n", s)
                wio._io.error_print = pr
                stat = -4
    if s_.need_sigmap:
        out = [0] * s_.tspf
        _sigmap(out, s_.ovec)
        vector[vstart:vstart + s_.tspf] = out
    elif s_.framelen != s_.tspf:
        for s in range(s_.framelen, s_.tspf):
            vector[vstart + s] = WFDB_INVALID_SAMPLE
    return stat


def _meansamp(sv, n):
    total = n // 2
    for x in sv[:n]:
        if x == WFDB_INVALID_SAMPLE:
            return WFDB_INVALID_SAMPLE
        total += x
    neg = 1 if total < 0 else 0
    if n & (n - 1):
        return cdiv(total + neg, n) - neg
    while True:
        n = cdiv(n, 2)
        if n == 0:
            break
        total = cdiv(total - (1 if total < 0 else 0), 2)
    return total


def _rgetvec(vector):
    s_ = _s
    if s_.ispfmax < 2:
        return getframe(vector)
    if (s_.gvmode & WFDB_HIGHRES) != WFDB_HIGHRES:
        stat = s_.rgetvec_stat = getframe(s_.tvector)
        tp = 0
        tv = s_.tvector
        for s in range(s_.nvsig):
            sf = s_.vsd[s].info.spf
            vector[s] = _meansamp(tv[tp:tp + sf], sf)
            tp += sf
    else:
        if s_.gvc >= s_.ispfmax:
            s_.rgetvec_stat = getframe(s_.tvector)
            s_.gvc = 0
        stat = s_.rgetvec_stat
        tp = 0
        tv = s_.tvector
        for s in range(s_.nvsig):
            vs = s_.vsd[s]
            sf = vs.info.spf
            if s_.gvc == 0:
                vs.gvindex = 0
                vs.gvcount = -s_.ispfmax
            else:
                vs.gvcount += sf
                if vs.gvcount >= 0:
                    vs.gvindex += 1
                    vs.gvcount -= s_.ispfmax
            vector[s] = tv[tp + vs.gvindex]
            tp += sf
        s_.gvc += 1
    return stat


# ---------------------------------------------------------------------------
# Public functions

def isigopen(record, siarray=None, nsig=0):
    """Open the input signals of a record.

    Any input signals already open are closed first, unless ``record``
    begins with '+' (then the new signals are added to them).

    Arguments:
      record    record name
      siarray   a list, filled with one Siginfo object per signal opened
                (or described); may be None
      nsig      number of signals to open (default 0).  If ``nsig`` <= 0,
                no signals are opened: the header is read and, if
                ``siarray`` is a list, it receives the Siginfo objects of
                the first -nsig signals.

    Returns:
      >0  the number of signals opened (if nsig > 0), or the number of
          signals in the record (if nsig <= 0)
       0  the record has no signals, or none of them could be opened
      -1  the header cannot be read (probably an incorrect record name)
      -2  incorrect header format
      -3  internal limits exceeded (all signal files are closed)
    """
    s_ = _s
    first_segment = 0
    if record.startswith("+"):
        record = record[1:]
    else:
        _isigclose()
    record = wio.wfdb_striphea(record)
    if not s_.in_msrec:
        wio.wfdb_setirec(record)
    navail = _readheader(record)
    if navail <= 0:
        if navail == 0 and s_.segments:
            s_.in_msrec = 1
            first_segment = 1
            if s_.segarray:
                navail = _readheader(s_.segarray[s_.segp].recname)
                if navail >= 0:
                    if s_.msbtime == 0:
                        s_.msbtime = s_.btime
                    if s_.msbdate == 0:
                        s_.msbdate = s_.bdate
            if nsig <= 0:
                s_.in_msrec = 0
        if navail == 0 and nsig:
            wfdb_error("isigopen: record %s has no signals\n", record)
        if navail <= 0:
            return navail
    if nsig <= 0:
        nsig = -nsig
        if navail < nsig:
            nsig = navail
        if siarray is not None:
            del siarray[:]
            for s in range(nsig):
                siarray.append(s_.hsd[s].info.copy())
        s_.in_msrec = 0
        return navail
    if nsig > navail:
        nsig = navail
    if s_.ibsize <= 0:
        s_.ibsize = BUFSIZ
    nisig0 = s_.nisig
    nigroup0 = s_.nigroup
    new_isd = []
    new_igd = []
    si = s = 0
    hsd = s_.hsd
    while si < navail and s < nsig:
        hs = hsd[si]
        sj = si + 1
        while sj < navail and hsd[sj].info.group == hs.info.group:
            sj += 1
        if sj - si > nsig - s:
            si = sj
            continue
        ig = _IGData()
        if hs.info.bsize < 0:
            ig.bsize = hs.info.bsize = -hs.info.bsize
            ig.seek = 0
        else:
            ig.bsize = hs.info.bsize
            if ig.bsize == 0:
                ig.bsize = s_.ibsize
            ig.seek = 1
        if hs.info.fmt == 0:
            ig.fp = None
        else:
            # wfdb-x: in the directory of the header
            ig.fp = wfdb_open(hs.info.fname, None, WFDB_READ) \
                if wfdbx_get_legacy() else \
                wio._open_in(s_.hdr_dir, None, hs.info.fname, record)
            if ig.fp is None:
                si = sj
                continue
        if _isflacfmt(hs.info.fmt):
            if _flac.isopen(ig, hsd[si:sj], sj - si) < 0:
                ig.fp.close()
                si = sj
                continue
        ig.bp = ig.be = 0
        ig.start = hs.start
        ig.initial_skip = 1 if ig.start > 0 else 0
        ig.stat = 1
        gnum = nigroup0 + len(new_igd)
        while si < sj and s < nsig:
            is_ = _ISData()
            is_.info = hs.info.copy()
            is_.info.group = gnum
            is_.skew = hs.skew
            new_isd.append(is_)
            s += 1
            si += 1
            if si < sj:
                hs = hsd[si]
        new_igd.append(ig)
        si = sj
    if s == 0 and nsig:
        wfdb_error("isigopen: none of the signals for record %s is "
                   "readable\n", record)
    spflimit = INT_MAX - s_.framelen
    for is_ in new_isd:
        spflimit -= is_.info.spf
        if spflimit < 0:
            wfdb_error("isigopen: total frame size too large in record %s\n",
                       record)
            _isigclose()
            return -3
    s_.isd = s_.isd[:nisig0] + new_isd
    s_.igd = s_.igd[:nigroup0] + new_igd
    if siarray is not None:
        del siarray[:]
    for is_ in new_isd:
        if siarray is not None:
            siarray.append(is_.info.copy())
        is_.samp = is_.info.initval
        if s_.ispfmax < is_.info.spf:
            s_.ispfmax = is_.info.spf
        if s_.skewmax < is_.skew:
            s_.skewmax = is_.skew
    s_.nisig += s
    s_.nigroup += len(new_igd)
    if _sigmap_init(first_segment) < 0:
        _isigclose()
        return -3
    s_.spfmax = s_.ispfmax
    setgvmode(s_.gvmode)
    s_.gvc = s_.ispfmax
    s_.framelen = 0
    for i in range(s_.nisig):
        s_.framelen += s_.isd[i].info.spf
    if s_.tspf > s_.tuvlen:
        s_.tvector = [0] * s_.tspf
        s_.uvector = [0] * s_.tspf
        s_.vvector = [0] * s_.tspf
        s_.tuvlen = s_.tspf
    if s_.skewmax != 0 and (not s_.in_msrec or s_.dsbuf is None):
        if s_.tspf > INT_MAX // (s_.skewmax + 1):
            wfdb_error("isigopen: maximum skew too large in record %s\n",
                       record)
            _isigclose()
            return -3
        s_.dsbi = -1
        s_.dsblen = s_.tspf * (s_.skewmax + 1)
        s_.dsbuf = [0] * s_.dsblen
    return s


# wfdb-x: an output signal file is never one of the input files.  In normal
# mode, _openosig refuses to create (and so to truncate) an output signal
# file that is the same file as a signal file of the open input record: a
# signal file open for input, or a signal file of any segment of the open
# multi-segment record (read from the segment's header; segments are opened
# later, as they are reached).  "The same file" is decided by the files, not
# by their names: device and inode numbers (os.fstat; on MS-Windows, the
# volume serial number and file index).  Decided by Reza Sameni, Oct 2026:
# e.g., "xform -i vlay -o fmt16", fmt16 being a segment of vlay, truncated
# fmt16.dat while reading it, with a platform-dependent result and the input
# destroyed.  Legacy mode: no check (the original behavior).
def _file_id(f):
    """The identity (device, inode) of the open local WFDBFile f (not the
    standard input or output, not a URL), or None."""
    if f is None or f.type != WFDB_LOCAL or f.is_std:
        return None
    try:
        st = os.fstat(f.fp.fileno())
    except (OSError, ValueError, AttributeError):
        return None
    return (st.st_dev, st.st_ino)


def _segment_has_file(seg, fid):
    """True if one of the signal files named in the header of segment seg
    (of the open multi-segment record) is the file fid.  The header and the
    signal files are located as isigopen locates them in normal mode; one
    that cannot be found (or is at a URL) is not fid.  No message."""
    s_ = _s
    if seg == "~" or not wio._in_header_dir(seg) or \
            (s_.msrec_dir and wio._is_url(s_.msrec_dir)):
        return False
    if s_.msrec_name is not None:
        hf = wio._open_in(s_.msrec_dir, "hea", seg, s_.msrec_name)
    else:
        hf = wfdb_open("hea", seg, WFDB_READ)
    if hf is None:
        return False
    d = None
    if hf.type == WFDB_LOCAL and not hf.is_std:
        d = wio._dirname(wio.get_filename())
    found = False
    nsig = -1
    try:
        while not found and nsig != 0:
            line = hf.getline()
            if not line:
                break
            tok = [t for t in re.split("[ \t\n\r]+", line) if t]
            if not tok or tok[0].startswith("#"):
                continue
            if nsig < 0:            # the record line
                if "/" in tok[0] or len(tok) < 2:
                    break
                nsig = strtol(tok[1])[0]
                if nsig <= 0:
                    break
                continue
            nsig -= 1               # a signal line: file name, format, ...
            name = tok[0]
            if len(tok) < 2 or strtol(tok[1])[0] == 0 or name == "-" or \
                    not wio._in_header_dir(name) or d is None or \
                    wio._is_url(d):
                continue
            sf = wio._open_in(d, None, name, seg)
            if sf is not None:
                found = _file_id(sf) == fid
                sf.close()
    finally:
        hf.close()
    return found


def _is_input_file(fname):
    """True if the output signal file fname (as named in an output signal
    specification, created by wfdb_open(fname, None, WFDB_WRITE)) exists and
    is one of the signal files of the open input record (see above)."""
    s_ = _s
    path = wio._output_file(fname)
    if path is None:
        return False
    try:
        st = os.stat(path)
    except (OSError, ValueError):
        return False        # it does not exist: it is not an input file
    fid = (st.st_dev, st.st_ino)
    for g in range(min(s_.nigroup, len(s_.igd))):
        if _file_id(s_.igd[g].fp) == fid:
            return True
    if s_.in_msrec and s_.segarray:
        for seg in s_.segarray[:s_.segend + 1]:
            if _segment_has_file(seg.recname, fid):
                return True
    return False


def _openosig(func, si_out, si_in, nsig):
    s_ = _s
    if s_.obsize <= 0:
        s_.obsize = BUFSIZ
    ga = s_.nogroup
    while len(s_.ogd) < s_.nogroup + si_in[nsig - 1].group + 1:
        s_.ogd.append(_OGData())
    op = None
    for s in range(nsig):
        sin = si_in[s]
        os_ = _OSData()
        os_.info = sin.copy()
        if os_.info.spf < 1:
            os_.info.spf = 1
        os_.info.cksum = 0
        os_.info.nsamp = 0
        os_.info.group += ga
        s_.osd.append(os_)
        s_.nosig += 1
        if si_out is not None:
            si_out.append(os_.info.copy())
        if s == 0 or os_.info.group != op.info.group:
            og = s_.ogd[os_.info.group]
            og.bsize = os_.info.bsize
            if _isflacfmt(os_.info.fmt):
                ns = 1
                while s + ns < nsig and si_in[s + ns].group == sin.group:
                    ns += 1
                if _flac.osinit(og, si_in[s:s + ns], ns) < 0:
                    _osigclose()
                    return -3
            og.obuflen = og.bsize if og.bsize else s_.obsize
            og.buf = bytearray()
            if os_.info.fmt == 0:
                if os_.info.fname is None or os_.info.fname == "~":
                    og.fp = None
                else:
                    os_.info.fmt = 16
            if os_.info.fmt != 0:
                # wfdb-x: never an input file (see _is_input_file)
                if not _legacy_mode and _is_input_file(os_.info.fname):
                    wfdb_error("%s: output file %s is also an input file\n",
                               func, os_.info.fname)
                    _osigclose()
                    return -3
                og.fp = wfdb_open(os_.info.fname, None, WFDB_WRITE)
                if og.fp is None:
                    wfdb_error("%s: can't open %s\n", func, os_.info.fname)
                    _osigclose()
                    return -3
            if _isflacfmt(os_.info.fmt):
                if _flac.osopen(og) < 0:
                    _osigclose()
                    return -3
            s_.nogroup += 1
        else:
            if os_.info.fmt != op.info.fmt or os_.info.bsize != op.info.bsize:
                wfdb_error("%s: error in specification of signal %d or %d\n",
                           func, s - 1, s)
                return -2
        op = os_
    return nsig


def osigopen(record, siarray=None, nsig=0):
    """Open output signals as specified by the header of an existing record.

    The first ``nsig`` signals described in the header of ``record`` are
    opened for writing (overwriting their signal files).  Output signals
    already open are closed first, unless ``record`` begins with '+'.
    ``siarray``, if a list, receives the Siginfo objects of the signals.

    Returns the number of output signals opened, or -1 (header cannot be
    read), -2 (incorrect header format or signal specification), or -3
    (cannot open the output signals, or the record has fewer than nsig
    signals).
    """
    if record.startswith("+"):
        record = record[1:]
    else:
        _osigclose()
    record = wio.wfdb_striphea(record)
    n = _readheader(record)
    if n < 0:
        return n
    if n < nsig:
        wfdb_error("osigopen: record %s has fewer signals than needed\n",
                   record)
        return -3
    hsi = [_s.hsd[s].info.copy() for s in range(nsig)]
    if siarray is not None:
        del siarray[:]
    return _openosig("osigopen", siarray, hsi, nsig)


def osigfopen(siarray, nsig=None):
    """Open output signals as specified by a list of Siginfo objects.

    Output signals already open are closed first.  ``siarray`` lists the
    signals to create (nsig defaults to its length); signals in the same
    group must have the same ``fname``, and group numbers must start at 0
    and increase by 1 with each new file.

    Returns the number of output signals opened, or -2 (error in a signal
    specification: name too long, illegal fmt or bsize, or wrong group),
    -3 (cannot open a signal file), or -4 (write error while closing the
    previous output signals, only if nsig is 0).
    """
    stat = _osigclose()
    if nsig is None:
        nsig = len(siarray) if siarray else 0
    if not siarray or nsig == 0:
        return stat
    if _s.obsize <= 0:
        _s.obsize = BUFSIZ
    for s in range(nsig):
        si = siarray[s]
        # As in C: fname and desc together may have at most 200 characters.
        if len(si.fname or "") + len(si.desc or "") > 200 or \
                si.bsize < 0 or not _isfmt(si.fmt):
            wfdb_error("osigfopen: error in specification of signal %d\n", s)
            return -2
        if not ((s == 0 and si.group == 0) or
                (s and si.group == siarray[s - 1].group and
                 si.fname == siarray[s - 1].fname) or
                (s and si.group == siarray[s - 1].group + 1 and
                 si.fname != siarray[s - 1].fname)):
            wfdb_error("osigfopen: incorrect file name or group for signal "
                       "%d\n", s)
            return -2
    return _openosig("osigfopen", None, siarray, nsig)


def findsig(p):
    """Return the number of the input signal described by p, or -1.

    ``p`` is either a signal number written in decimal ("0", "1", ...) or a
    signal description (e.g. "MLII"), which must match exactly.
    """
    s_ = _s
    if all("0" <= c <= "9" for c in p):    # all digits (or empty)
        s = int32(strtol(p)[0])
        if s < s_.nisig or s < s_.nvsig:
            return s
    if s_.need_sigmap:
        for s in range(s_.nvsig):
            q = s_.vsd[s].info.desc
            if q is not None and q == p:
                return s
    else:
        for s in range(s_.nisig):
            q = s_.isd[s].info.desc
            if q is not None and q == p:
                return s
    return -1


def getspf():
    """Return the number of samples per signal returned by getvec() per frame.

    This is 1, except in WFDB_HIGHRES mode, where it is the largest number
    of samples per frame of any input signal.
    """
    s_ = _s
    return int(s_.sfreq / s_.ffreq + 0.5) if s_.sfreq != s_.ffreq else 1


def setgvmode(mode):
    """Set the getvec() operating mode.

    ``mode`` is WFDB_LOWRES (0) or WFDB_HIGHRES (1), optionally OR-ed with
    WFDB_GVPAD (2).  WFDB_LOWRES returns one sample per signal per frame
    (averaging oversampled signals); WFDB_HIGHRES returns every sample of
    oversampled signals, repeating the samples of the others.  WFDB_GVPAD
    replaces invalid samples with the previous valid sample.  A negative
    mode uses the WFDBGVMODE environment variable (default WFDB_LOWRES).
    """
    s_ = _s
    if mode < 0:
        p = os.environ.get("WFDBGVMODE")
        mode = int32(strtol(p)[0]) if p is not None else DEFWFDBGVMODE
    s_.gvmode = mode & (WFDB_HIGHRES | WFDB_GVPAD)
    if (mode & WFDB_HIGHRES) == WFDB_HIGHRES:
        if s_.spfmax == 0:
            s_.spfmax = 1
        s_.sfreq = s_.ffreq * s_.spfmax
    else:
        s_.sfreq = s_.ffreq


def getgvmode():
    """Return the getvec() mode (see setgvmode)."""
    return _s.gvmode


def setifreq(f):
    """Set the sampling frequency at which getvec() returns samples.

    Signals are resampled (by linear interpolation) to frequency ``f``.
    ``f`` also becomes the frequency used by strtim() and timstr(), the
    unit of the times of input annotators opened afterwards, and the time
    resolution of new output annotators (see setafreq).  Returns 0 on
    success, or -1 if no record is open, if the sampling frequency of the
    open record is not specified (wfdb-x), or if ``f`` is not positive.
    """
    s_ = _s
    g = s_.sfreq
    if g <= 0.0:
        s_.ifreq = 0.0
        if s_.nisig > 0 and not _legacy_mode:   # wfdb-x: no frequency
            wfdb_error("setifreq: sampling frequency is not specified\n")
        else:
            wfdb_error("setifreq: no open input record\n")
        return -1
    if f > 0.0:
        n = max(s_.nvsig, 1)
        s_.gv0 = [0] * n
        s_.gv1 = [0] * n
        from ._annot import setafreq
        s_.ifreq = f
        setafreq(f)
        # Euclid's algorithm for the GCD of the two frequencies, which are
        # treated as multiples of 0.005 Hz (the tolerable resampling error).
        while True:
            error = f - g
            if not (error > 0.005 or error < -0.005):
                break
            if f > g:
                f -= g
            else:
                g -= f
        s_.mticks = int(s_.sfreq / f + 0.5)
        s_.nticks = int(s_.ifreq / f + 0.5)
        s_.mnticks = s_.mticks * s_.nticks
        s_.gvtime = 0
        s_.rgvstat = _rgetvec(s_.gv0)
        s_.rgvstat = _rgetvec(s_.gv1)
        s_.rgvtime = s_.nticks
        return 0
    s_.ifreq = 0.0
    wfdb_error("setifreq: improper frequency %g (must be > 0)\n", f)
    return -1


def getifreq():
    """Return the frequency at which getvec() returns samples.

    This is the value set by setifreq(), or the record's sampling frequency
    if setifreq() was not called.
    """
    s_ = _s
    return s_.ifreq if s_.ifreq > 0 else s_.sfreq


def getvec(vector):
    """Read the next sample of each input signal into the list ``vector``.

    ``vector`` must have room for one value per input signal (see
    isigopen); its first entries are replaced.  Invalid samples are
    WFDB_INVALID_SAMPLE.

    Returns:
      >0  success: the number of input signals
       0  no input signals are open
      -1  end of data (the contents of vector are not valid)
      -3  unexpected physical end of file
      -4  checksum error (detected only at the end of the file)
    """
    s_ = _s
    if s_.ifreq == 0.0 or s_.ifreq == s_.sfreq:
        return _rgetvec(vector)
    if s_.rgvtime > s_.mnticks:
        s_.rgvtime -= s_.mnticks
        s_.gvtime -= s_.mnticks
    nsig = s_.nvsig if s_.nvsig > s_.nisig else s_.nisig
    gv0 = s_.gv0
    gv1 = s_.gv1
    while s_.gvtime > s_.rgvtime:
        gv0[:nsig] = gv1[:nsig]
        s_.rgvstat = _rgetvec(gv1)
        s_.rgvtime += s_.nticks
    nt = s_.nticks
    gm = cmod(s_.gvtime, nt)
    for i in range(nsig):
        vector[i] = int32(gv0[i] + cdiv(gm * (gv1[i] - gv0[i]), nt))
        gv0[i] = gv1[i]
    s_.gvtime += s_.mticks
    return s_.rgvstat


def getframe(vector):
    """Read the next complete frame of the input signals into ``vector``.

    Unlike getvec(), all samples of oversampled signals are returned: the
    spf samples of signal 0, then those of signal 1, and so on.  Returns
    the same values as getvec().
    """
    s_ = _s
    stat = -1
    if s_.dsbuf is not None:
        dsbuf = s_.dsbuf
        tspf = s_.tspf
        if s_.dsbi < 0:
            s_.dsbi = i = 0
            while i < s_.dsblen:
                stat = _getskewedframe(dsbuf, i)
                if stat < 0:
                    break
                i += tspf
                s_.dsbi = i
            s_.dsbi = 0
        else:
            stat = _getskewedframe(dsbuf, s_.dsbi)
            s_.dsbi += tspf
            if s_.dsbi >= s_.dsblen:
                s_.dsbi = 0
        j = 0
        for s in range(s_.nvsig):
            vs = s_.vsd[s]
            i = j + s_.dsbi + vs.skew * tspf
            if i >= s_.dsblen:
                i %= s_.dsblen
            for c in range(vs.info.spf):
                vector[j] = dsbuf[i]
                j += 1
                i += 1
    else:
        stat = _getskewedframe(vector, 0)
    s_.istime += 1
    return stat


# The value that marks an invalid sample in a signal file: the most negative
# value that the storage format can represent.
_INVALID_BY_FMT = {8: -1 << 15, 16: -1 << 15, 61: -1 << 15, 160: -1 << 15,
                   80: -1 << 7, 212: -1 << 11, 310: -1 << 9, 311: -1 << 9,
                   24: -1 << 23, 32: -1 << 31,
                   508: -1 << 7, 516: -1 << 15, 524: -1 << 23}


def putvec(vector):
    """Write one sample of each output signal from the list ``vector``.

    For signals with more than one sample per frame, ``vector`` holds a
    complete frame (the spf samples of signal 0, then of signal 1, ...).

    Returns the number of output signals on success, 0 if the slew rate
    was too high for a signal in format 8 (difference format), or -1 on a
    write error.
    """
    s_ = _s
    stat = s_.nosig
    vi = 0
    for s in range(s_.nosig):
        os_ = s_.osd[s]
        info = os_.info
        og = s_.ogd[info.group]
        fmt = info.fmt
        if info.nsamp == 0:
            info.initval = os_.samp = vector[vi]
        info.nsamp += 1
        cks = info.cksum
        for c in range(info.spf):
            samp = vector[vi]
            vi += 1
            if samp == WFDB_INVALID_SAMPLE:
                samp = _INVALID_BY_FMT.get(fmt, WFDB_INVALID_SAMPLE)
            if fmt == 0:
                os_.samp = samp
            elif fmt == 212:
                og.w212(samp)
                os_.samp = samp
            elif fmt == 16:
                og.w16(samp)
                os_.samp = samp
            elif fmt == 61:
                og.w61(samp)
                os_.samp = samp
            elif fmt == 80:
                og.w80(samp)
                os_.samp = samp
            elif fmt == 160:
                og.w160(samp)
                os_.samp = samp
            elif fmt == 310:
                og.w310(samp)
                os_.samp = samp
            elif fmt == 311:
                og.w311(samp)
                os_.samp = samp
            elif fmt == 24:
                og.w24(samp)
                os_.samp = samp
            elif fmt == 32:
                og.w32(samp)
                os_.samp = samp
            elif fmt in (508, 516, 524):
                if _flac.putsamp(samp, fmt, og) < 0:
                    stat = -1
                os_.samp = samp
            else:   # format 8 and default
                dif = int32(samp - os_.samp)
                if dif < -128:
                    dif = -128
                    stat = 0
                elif dif > 127:
                    dif = 127
                    stat = 0
                os_.samp = int32(os_.samp + dif)
                og.w8(dif)
            if og.fp is not None and og.fp.ferror():
                wfdb_error("putvec: write error in signal %d\n", s)
                stat = -1
            else:
                cks += os_.samp
        info.cksum = int32(cks)
    s_.ostime += 1
    return stat


# wfdb-x: a vectorized putvec, for write_record.  For each format below: the
# range of the samples (after an invalid sample is replaced by the invalid
# value of the format, as putvec does), and the number of samples encoded
# together (2 for format 212, 3 for formats 310 and 311).
_FAST_FMTS = {8: (INT_MIN, INT_MAX, 1), 16: (-1 << 15, (1 << 15) - 1, 1),
              61: (-1 << 15, (1 << 15) - 1, 1),
              24: (-1 << 23, (1 << 23) - 1, 1), 32: (INT_MIN, INT_MAX, 1),
              80: (-1 << 7, (1 << 7) - 1, 1),
              160: (-1 << 15, (1 << 15) - 1, 1),
              212: (-1 << 11, (1 << 11) - 1, 2),
              310: (-1 << 9, (1 << 9) - 1, 3), 311: (-1 << 9, (1 << 9) - 1, 3)}


def _encode(fmt, v):
    """The bytes written by putvec for the sample stream v (an int64 array;
    for format 8, the first differences), whose length is a multiple of
    the number of samples encoded together."""
    import numpy as np
    if fmt == 8:
        return (v & 0xFF).astype(np.uint8).tobytes()
    if fmt == 80:
        return ((v + (1 << 7)) & 0xFF).astype(np.uint8).tobytes()
    if fmt in (16, 61):
        return (v & 0xFFFF).astype("<u2" if fmt == 16 else ">u2").tobytes()
    if fmt == 160:
        return ((v + (1 << 15)) & 0xFFFF).astype("<u2").tobytes()
    if fmt == 32:
        return (v & 0xFFFFFFFF).astype("<u4").tobytes()
    if fmt == 24:
        b = np.stack([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF], axis=1)
        return b.astype(np.uint8).tobytes()
    if fmt == 212:
        a, b = v[0::2], v[1::2]
        data = (a & 0xFFF) | ((b << 4) & 0xF000)
        out = np.stack([data & 0xFF, data >> 8, b & 0xFF], axis=1)
        return out.astype(np.uint8).tobytes()
    a, b, c = v[0::3], v[1::3], v[2::3]
    if fmt == 310:
        data = ((a << 1) & 0x7FE) | ((c << 11) & 0xF800)
        datb = ((b << 1) & 0x7FE) | ((c << 6) & 0xF800)
    else:   # 311
        data = (a & 0x3FF) | ((b << 10) & 0xFC00)
        datb = ((b >> 6) & 0xF) | ((c << 4) & 0x3FF0)
    out = np.stack([data & 0xFF, data >> 8, datb & 0xFF, datb >> 8], axis=1)
    return out.astype(np.uint8).tobytes()


def _putframes(x):
    """Write the frames of the 2-D array x (one frame per row, as a vector
    of putvec) to the output signals, with the same result as putvec
    called for each row (wfdb-x).

    The frames are encoded together (with NumPy) if all output signals are
    in one signal file whose format is one of _FAST_FMTS, x is an integer
    array whose samples are within the range of the format (for format 8,
    whose first differences are within -128..127), and the signal file has
    no pending samples; the last frames that do not complete a group of
    samples encoded together (formats 212, 310 and 311) are written by
    putvec.  Otherwise, every frame is written by putvec.
    """
    import numpy as np
    s_ = _s
    nf = len(x)
    osd = s_.osd[:s_.nosig]
    fmt = osd[0].info.fmt if osd else None
    spf = [os_.info.spf for os_ in osd]
    fast = (nf > 0 and s_.nogroup == 1 and fmt in _FAST_FMTS and
            all(os_.info.fmt == fmt and os_.info.group == 0 for os_ in osd) and
            x.ndim == 2 and x.shape[1] == sum(spf) and x.dtype.kind in "iu" and
            s_.ogd[0].count == 0 and s_.ogd[0].fp is not None)
    if fast:
        lo, hi, unit = _FAST_FMTS[fmt]
        if x.dtype.kind == "u" and x.size and int(x.max()) > hi:
            fast = False
    if fast:
        v = x.astype(np.int64)
        inv = _INVALID_BY_FMT.get(fmt, WFDB_INVALID_SAMPLE)
        v[v == WFDB_INVALID_SAMPLE] = inv
        fast = v.size == 0 or (int(v.min()) >= lo and int(v.max()) <= hi)
    if fast and fmt == 8:
        # the first differences of each signal's samples (putvec clamps a
        # difference outside -128..127, which is left to putvec)
        d = np.empty_like(v)
        c = 0
        for k, os_ in enumerate(osd):
            prev = int(x[0, c]) if os_.info.nsamp == 0 else os_.samp
            seq = v[:, c:c + spf[k]].reshape(-1)
            dk = np.diff(seq, prepend=prev)
            d[:, c:c + spf[k]] = dk.reshape(nf, spf[k])
            c += spf[k]
        fast = int(d.min()) >= -128 and int(d.max()) <= 127
    if not fast:
        stat = 0
        for row in x.tolist():
            stat = putvec(row)
        return stat
    # Frames encoded together: all but the last ones that do not complete a
    # group of samples (for formats 212, 310 and 311).
    nbulk = nf
    while (nbulk * v.shape[1]) % unit:
        nbulk -= 1
    og = s_.ogd[0]
    stream = (d if fmt == 8 else v)[:nbulk].reshape(-1)
    buf = og.buf + _encode(fmt, stream)
    n = og.obuflen
    i = 0
    while len(buf) - i >= n:    # written as w8 writes, obuflen bytes at once
        og.fp.write(bytes(buf[i:i + n]))
        i += n
    og.buf = bytearray(buf[i:])
    stat = s_.nosig
    if og.fp.ferror():
        wfdb_error("putvec: write error in signal %d\n", 0)
        stat = -1
    c = 0
    for k, os_ in enumerate(osd):
        info = os_.info
        if nbulk:
            if info.nsamp == 0:
                info.initval = int(x[0, c])
            info.nsamp += nbulk
            block = v[:nbulk, c:c + spf[k]]
            info.cksum = int32(info.cksum + int(block.sum()))
            os_.samp = int(block[-1, -1])
        c += spf[k]
    s_.ostime += nbulk
    for row in x[nbulk:].tolist():
        stat = putvec(row)
    return stat


def isigsettime(t):
    """Seek all input signals to sample number t.

    The next getvec() returns the samples at time t.  Returns 0 on
    success, or a negative value at the end of the data or on an improper
    seek.
    """
    s_ = _s
    stat = 0
    if s_.nisig == 0:
        return 0
    if s_.ifreq <= 0:
        if not (s_.gvmode & WFDB_HIGHRES) or s_.ispfmax < 2:
            curtime = s_.istime
        else:
            curtime = (s_.istime - 1) * s_.ispfmax + s_.gvc
        if t == curtime:
            return 0
    for g in range(1, s_.nigroup):
        stat = isgsettime(g, t)
        if stat < 0:
            break
    if stat == 0:
        stat = isgsettime(0, t)
    return stat


def isgsettime(g, t):
    """Seek the input signals of group g to sample number t.

    Signals in other groups are unaffected.  Returns 0 on success, or a
    negative value at the end of the data or on an improper seek.
    """
    s_ = _s
    trem = 0
    if t < 0:
        if t < -WFDB_TIME_MAX:
            wfdb_error("isigsettime: improper seek on signal group %d\n", g)
            return -1
        t = -t
    if s_.ifreq > 0:
        tt = t * s_.sfreq / s_.ifreq
        if tt > WFDB_TIME_MAX:
            wfdb_error("isigsettime: improper seek on signal group %d\n", g)
            return -1
        t = int(tt)
    if s_.gvmode & WFDB_HIGHRES:
        trem = cmod(t, s_.ispfmax)
        t = cdiv(t, s_.ispfmax)
    s_.dsbi = -1
    stat = _isgsetframe(g, t)
    if stat == 0 and g == 0:
        while trem > 0:
            trem -= 1
            if _rgetvec(s_.uvector) < 0:
                wfdb_error("isigsettime: improper seek on signal group %d\n",
                           g)
                return -1
        if s_.ifreq > 0 and s_.ifreq != s_.sfreq:
            s_.gvtime = 0
            s_.rgvstat = _rgetvec(s_.gv0)
            s_.rgvstat = _rgetvec(s_.gv1)
            s_.rgvtime = s_.nticks
    return stat


def tnextvec(s, t):
    """Return the time of the next valid sample of signal s at or after t.

    The input signals are left positioned at that time.  Returns -1 at
    the end of the data, on an improper seek, or if s is not an input
    signal.
    """
    s_ = _s
    stat = 0
    if s_.in_msrec and s_.need_sigmap:
        if s >= s_.nvsig:
            wfdb_error("nextvect: illegal signal number %d\n", s)
            return -1
        if t != s_.istime and isigsettime(t) < 0:
            return -1
        while stat >= 0:
            p = s_.vsd[s].info.desc
            seg = s_.segarray[s_.segp]
            tf = seg.samp0 + seg.nsamp
            ss = 0
            while ss < s_.nisig:
                q = s_.isd[ss].info.desc
                if q is not None and p == q:
                    break
                ss += 1
            if ss < s_.nisig:
                while t <= tf:
                    stat = getvec(s_.vvector)
                    if stat <= 0:
                        break
                    if s_.vvector[s] != WFDB_INVALID_SAMPLE:
                        isigsettime(t)
                        return t
                    t += 1
                if stat < 0:
                    return -1
            if t != tf:
                t = tf
                stat = isigsettime(t)
    else:
        if t != s_.istime and isigsettime(t) < 0:
            return -1
        if s >= s_.nisig:
            wfdb_error("nextvect: illegal signal number %d\n", s)
            return -1
        while True:
            stat = getvec(s_.vvector)
            if stat <= 0:
                break
            if s_.vvector[s] != WFDB_INVALID_SAMPLE:
                isigsettime(t)
                return t
            t += 1
    return stat


def setibsize(n):
    """Set the size of the input buffers, in bytes (0: the default, BUFSIZ).

    Must be called before isigopen().  Returns the new buffer size, -1 if
    input signals are already open, or -2 if n is negative.
    """
    s_ = _s
    if s_.nisig:
        wfdb_error("setibsize: can't change buffer size after isigopen\n")
        return -1
    if n < 0:
        wfdb_error("setibsize: illegal buffer size %d\n", n)
        return -2
    if n == 0:
        n = BUFSIZ
    s_.ibsize = n
    return n


def setobsize(n):
    """Set the size of the output buffers, in bytes (0: the default, BUFSIZ).

    Must be called before osigopen()/osigfopen().  Returns the new buffer
    size, -1 if output signals are already open, or -2 if n is negative.
    """
    s_ = _s
    if s_.nosig:
        wfdb_error("setobsize: can't change buffer size after osig[f]open\n")
        return -1
    if n < 0:
        wfdb_error("setobsize: illegal buffer size %d\n", n)
        return -2
    if n == 0:
        n = BUFSIZ
    s_.obsize = n
    return n


def newheader(record):
    """Create a header file for the currently open output signals.

    Usually called after all samples have been written with putvec(), so
    that the header records their number and checksums.  Returns 0 on
    success, or -1 if the header cannot be created (or the record name is
    illegal).
    """
    record = wio.wfdb_striphea(record)
    osi = [_s.osd[s].info.copy() for s in range(_s.nosig)]
    return setheader(record, osi, _s.nosig)


def _strtok_inplace(string, delims):
    """First strtok() token of string, and the string as strtok leaves it."""
    i = 0
    n = len(string)
    while i < n and string[i] in delims:
        i += 1
    if i >= n:
        return None, string
    j = i
    while j < n and string[j] not in delims:
        j += 1
    return string[i:j], string[:j]


def _fmt_g12(x):
    return sprintf("%.12g", x)


def setheader(record, siarray, nsig=None):
    """Create or rewrite the header file of a record from Siginfo objects.

    ``siarray`` describes the signals (nsig defaults to its length); the
    sampling frequency, base time and counter frequency are those set by
    setsampfreq(), setbasetime() and setcfreq().  As in C, a ``units`` or
    ``desc`` string of a Siginfo object is truncated at its first
    whitespace (units) or newline (desc).  Returns 0 on success, or -1 if
    the header cannot be created.
    """
    s_ = _s
    if nsig is None:
        nsig = len(siarray)
    if s_.oheader is not None:
        s_.oheader.close()
        if s_.outinfo is s_.oheader:
            s_.outinfo = None
        s_.oheader = None
    record = wio.wfdb_striphea(record)
    if wio.wfdb_checkname(record, "record"):
        return -1
    s_.oheader = wfdb_open("hea", record, WFDB_WRITE)
    if s_.oheader is None:
        wfdb_error("newheader: can't create header for record %s\n", record)
        return -1
    out = []
    out.append("%s %d %s" % (record, nsig, _fmt_g12(s_.ffreq)))
    if (s_.cfreq > 0.0 and s_.cfreq != s_.ffreq) or s_.bcount != 0.0:
        out.append("/%s" % _fmt_g12(s_.cfreq))
        if s_.bcount != 0.0:
            out.append("(%s)" % _fmt_g12(s_.bcount))
    out.append(" %d" % (siarray[0].nsamp if nsig > 0 else 0))
    if s_.btime != 0 or s_.bdate != 0:
        if s_.btime == 0:
            out.append(" 0:00")
        elif s_.btime % 1000 == 0:
            out.append(" %s" % _ftimstr(s_.btime, 1000.0))
        else:
            out.append(" %s" % _fmstimstr(s_.btime, 1000.0))
    if s_.bdate:
        out.append(datstr(s_.bdate))
    out.append("\r\n")
    for s in range(nsig):
        si = siarray[s]
        out.append("%s %d" % (si.fname, si.fmt))
        if si.spf > 1:
            out.append("x%d" % si.spf)
        if s_.osd and s < len(s_.osd) and s_.osd[s].skew:
            out.append(":%d" % (s_.osd[s].skew * si.spf))
        if s_.ogd and s < len(s_.osd) and s_.ogd[s_.osd[s].info.group].start:
            out.append("+%d" % s_.ogd[s_.osd[s].info.group].start)
        elif s_.prolog_bytes:
            out.append("+%d" % s_.prolog_bytes)
        out.append(" %s" % _fmt_g12(si.gain))
        if si.baseline != si.adczero:
            out.append("(%d)" % si.baseline)
        if si.units:
            # strtok() truncates the caller's string in place.
            p, si.units = _strtok_inplace(si.units, " \t\n\r")
            if p is not None:
                out.append("/%s" % p)
        out.append(" %d %d %d %d %d" % (si.adcres, si.adczero, si.initval,
                                        int16(si.cksum & 0xFFFF), si.bsize))
        if si.desc:
            p, si.desc = _strtok_inplace(si.desc, "\n\r")
            if p is not None:
                out.append(" %s" % p)
        out.append("\r\n")
    s_.oheader.write("".join(out).encode("latin-1"))
    s_.prolog_bytes = 0
    s_.oheader.flush()
    return 0


def getseginfo():
    """Return the list of Seginfo objects of the open multi-segment record.

    The list is empty if the open record is not a multi-segment record.
    """
    return _s.segarray if _s.segarray is not None else []


def setmsheader(record, segment_name, nsegments=None):
    """Create the header of a multi-segment record from its segment names.

    ``segment_name`` lists the existing records that form the segments
    (nsegments defaults to its length).  Returns 0 on success, or -1
    (illegal record name, no segments, or header not writable), -2
    (segment name too long), -3 (nested multi-segment record or unreadable
    segment header), or -4 (segment length unspecified, or segments whose
    numbers of signals or sampling frequencies differ).
    """
    s_ = _s
    if nsegments is None:
        nsegments = len(segment_name)
    msfreq = mscfreq = 0.0
    msbcount = 0.0
    nsig = 0
    old_in_msrec = s_.in_msrec
    _isigclose()
    if s_.oheader is not None:
        s_.oheader.close()
        if s_.outinfo is s_.oheader:
            s_.outinfo = None
        s_.oheader = None
    record = wio.wfdb_striphea(record)
    if wio.wfdb_checkname(record, "record"):
        return -1
    if nsegments < 1:
        wfdb_error("setmsheader: record must contain at least one segment\n")
        return -1
    ns = [0] * nsegments
    for i in range(nsegments):
        if len(segment_name[i]) > WFDB_MAXRNL:
            wfdb_error("setmsheader: `%s' is too long for a segment name in "
                       "record %s\n", segment_name[i], record)
            return -2
        s_.in_msrec = 1
        s_.nsamples = 0
        s_.user_segments = True     # wfdb-x: names given by the caller
        n = _readheader(segment_name[i])
        s_.user_segments = False
        s_.in_msrec = old_in_msrec
        if n < 0:
            wfdb_error("setmsheader: can't read segment %s header\n",
                       segment_name[i])
            return -3
        ns[i] = s_.nsamples
        if ns[i] <= 0:
            wfdb_error("setmsheader: length of segment %s must be "
                       "specified\n", segment_name[i])
            return -4
        if i == 0:
            nsig = n
            msfreq = s_.ffreq
            mscfreq = s_.cfreq
            msbcount = s_.bcount
            s_.msbtime = s_.btime
            s_.msbdate = s_.bdate
            s_.msnsamples = ns[i]
        else:
            if nsig != n:
                wfdb_error("setmsheader: incorrect number of signals in "
                           "segment %s\n", segment_name[i])
                return -4
            if msfreq != s_.ffreq:
                wfdb_error("setmsheader: incorrect sampling frequency in "
                           "segment %s\n", segment_name[i])
                return -4
            s_.msnsamples += ns[i]
    s_.oheader = wfdb_open("hea", record, WFDB_WRITE)
    if s_.oheader is None:
        wfdb_error("setmsheader: can't create header file for record %s\n",
                   record)
        return -1
    out = ["%s/%d %d %s" % (record, nsegments, nsig, _fmt_g12(msfreq))]
    if (mscfreq > 0.0 and mscfreq != msfreq) or msbcount != 0.0:
        out.append("/%s" % _fmt_g12(mscfreq))
        if msbcount != 0.0:
            out.append("(%s)" % _fmt_g12(msbcount))
    out.append(" %d" % s_.msnsamples)
    if s_.msbtime != 0 or s_.msbdate != 0:
        if s_.msbtime % 1000 == 0:
            out.append(" %s" % _ftimstr(s_.msbtime, 1000.0))
        else:
            out.append(" %s" % _fmstimstr(s_.msbtime, 1000.0))
    if s_.msbdate:
        out.append(datstr(s_.msbdate))
    out.append("\r\n")
    for i in range(nsegments):
        out.append("%s %d\r\n" % (segment_name[i], ns[i]))
    s_.oheader.write("".join(out).encode("latin-1"))
    return 0


def wfdbgetskew(s):
    """Return the skew (in frames) of input signal s (0 if s is not open)."""
    if s < _s.nvsig:
        return _s.vsd[s].skew
    return 0


def wfdbsetiskew(s, skew):
    """Set the skew (in frames) applied when reading input signal s.

    The value is ignored unless it is within the range allowed by the
    skews in the header of the open record.
    """
    s_ = _s
    if s < s_.nvsig and skew >= 0 and s_.tspf and \
            skew < s_.dsblen // s_.tspf:
        s_.vsd[s].skew = skew


def wfdbsetskew(s, skew):
    """Set the skew (in frames) that setheader() writes for output signal s."""
    if s < _s.nosig:
        _s.osd[s].skew = skew


def wfdbgetstart(s):
    """Return the prolog length (bytes) of the signal file of signal s."""
    s_ = _s
    if s < s_.nisig:
        return s_.igd[s_.vsd[s].info.group].start
    elif s == 0 and s_.hsd:
        return s_.hsd[0].start
    return 0


def wfdbsetstart(s, nbytes):
    """Set the prolog length (bytes) that setheader() writes for signal s."""
    s_ = _s
    if s < s_.nosig:
        s_.ogd[s_.osd[s].info.group].start = nbytes
    s_.prolog_bytes = nbytes


def wfdbputprolog(buf, size, s):
    """Write a prolog to the signal file of output signal s.

    ``buf`` (bytes, or a str encoded as ISO-8859-1) is written, up to
    ``size`` bytes, before any samples, and its length is recorded for
    setheader().  Returns 0 on success, or -1 if fewer than size bytes were
    written.
    """
    s_ = _s
    g = s_.osd[s].info.group
    if isinstance(buf, str):
        buf = buf.encode("latin-1")
    n = s_.ogd[g].fp.write(bytes(buf[:size]))
    wfdbsetstart(s, n)
    if n != size:
        wfdb_error("wfdbputprolog: only %d of %d bytes written\n", n, size)
    return 0 if n == size else -1


def setinfo(record):
    """Open the .info file of a record for appending info strings.

    Any .info file opened by a previous setinfo() call is closed first;
    ``setinfo(None)`` just closes it.  Returns 0 on success, or -1 if the
    record name is illegal or the file cannot be opened.
    """
    stat = _wfdb_oinfoclose()
    if record is None:
        return stat
    record = wio.wfdb_striphea(record)
    if wio.wfdb_checkname(record, "record"):
        return -1
    _s.outinfo = wfdb_open("info", record, WFDB_APPEND)
    if _s.outinfo is None:
        wfdb_error("setinfo: can't create info file for record %s\n", record)
        return -1
    return 0


def putinfo(s):
    """Write an info string to the open .info file or output header.

    The string is written as a comment line ('#' + s).  If setinfo() has
    not been called, it is appended to the header created by the last
    newheader()/setheader() call.  Returns 0 on success, or -1 if neither
    is open.
    """
    s_ = _s
    if s_.outinfo is None:
        if s_.oheader is not None:
            s_.outinfo = s_.oheader
        else:
            wfdb_error("putinfo: caller has not specified a record name\n")
            return -1
    s_.outinfo.write(("#%s\r\n" % s).encode("latin-1"))
    s_.outinfo.flush()
    return 0


def _strip_info(buf):
    if buf.endswith("\n"):
        buf = buf[:-1]
        if buf.endswith("\r"):
            buf = buf[:-1]
    elif buf.endswith("\r"):
        buf = buf[:-1]
    return buf


def getinfo(record=None):
    """Return the next info string of a record, or None when there are no more.

    Info strings are the comment lines of the header (without the leading
    '#') followed by those of the record's .info file, if any.  Passing a
    record name starts again from the first string of that record; passing
    None continues with the record most recently opened or named.
    """
    s_ = _s
    if record is not None:
        _wfdb_freeinfo()
    if s_.pinfo is None:
        if record is None:
            record = wio.wfdb_getirec()
            if record is None:
                wfdb_error("getinfo: caller did not specify record name\n")
                return None
        s_.ninfo = 0
        s_.info_i = 0
        s_.pinfo = []
        if not s_.isedf:
            record = wio.wfdb_striphea(record)
            ifile = wfdb_open("hea", record, WFDB_READ)
            if ifile is not None:
                # As in wfdb_getline(), the buffer keeps its previous
                # contents when the end of the file is reached.
                buf = ""
                while True:
                    line = ifile.getline()
                    if line == "":
                        break
                    buf = line
                    if not buf.startswith("#"):
                        break
                while True:
                    line = ifile.getline()
                    if line == "":
                        break
                    buf = line
                    if buf.startswith("#"):
                        break
                while buf != "":
                    if buf.startswith("#"):
                        s_.pinfo.append(_strip_info(buf)[1:])
                    line = ifile.getline()
                    if line == "":
                        break
                    buf = line
                ifile.close()
        ifile = wfdb_open("info", record, WFDB_READ)
        if ifile is not None:
            while True:
                buf = ifile.getline()
                if buf == "":
                    break
                if buf.startswith("#"):
                    s_.pinfo.append(_strip_info(buf)[1:])
            ifile.close()
        s_.ninfo = len(s_.pinfo)
    if s_.info_i < s_.ninfo:
        r = s_.pinfo[s_.info_i]
        s_.info_i += 1
        return r
    return None


def sampfreq(record):
    """Return the sampling frequency of a record, in Hz.

    If ``record`` is None, the frequency of the currently open record is
    returned (in WFDB_HIGHRES mode, the frequency of the most oversampled
    signal).  Otherwise the header of ``record`` is read; the result is
    negative (-1: header cannot be read, -2: incorrect header format) on
    failure.
    wfdb-x: the result is 0 if the header does not specify the sampling
    frequency (C assumed 250 Hz).
    """
    s_ = _s
    record = wio.wfdb_striphea(record)
    if record is not None:
        wio.wfdb_setirec(record)
        setsampfreq(0.0)
        n = _readheader(record)
        if n < 0:
            return float(n)
    return s_.sfreq


def setsampfreq(freq):
    """Set the sampling frequency (for output and for time conversions).

    Returns 0 on success, or -1 if freq is negative.
    """
    s_ = _s
    if freq >= 0.0:
        s_.sfreq = s_.ffreq = freq
        if s_.spfmax == 0:
            s_.spfmax = 1
        if (s_.gvmode & WFDB_HIGHRES) == WFDB_HIGHRES:
            s_.sfreq *= s_.spfmax
        return 0
    wfdb_error("setsampfreq: sampling frequency must not be negative\n")
    return -1


def setbasetime(string):
    """Set the base time (and date) of the record.

    ``string`` has the form "hh:mm:ss" or "hh:mm:ss dd/mm/yyyy"; an empty
    string or None uses the current local time and date.  Returns 0 on
    success, or -1 if the string cannot be parsed.
    """
    s_ = _s
    s_.pdays = -1
    if string is None or string == "":
        now = _time.localtime()
        s_.date_string = "%02d/%02d/%d" % (now.tm_mday, now.tm_mon,
                                           now.tm_year)
        s_.bdate = strdat(s_.date_string)
        s_.time_string = "%d:%d:%d" % (now.tm_hour, now.tm_min, now.tm_sec)
        s_.btime = _fstrtim(s_.time_string, 1000.0)
        return 0
    string = string.lstrip(" ")
    k = string.find(" ")
    if k >= 0:
        tpart = string[:k]
        dpart = string[k + 1:]
    else:
        tpart = string
        dpart = None
    s_.btime = _fstrtim(tpart, 1000.0)
    s_.bdate = strdat(dpart) if dpart is not None else 0
    if s_.btime == 0 and s_.bdate == 0 and not tpart.startswith("["):
        wfdb_error("setbasetime: incorrect time format, '%s'\n", string)
        return -1
    return 0


def _ftimstr(t, f):
    s_ = _s
    p = _fmstimstr(t, f)
    k = p.find(".")
    if k >= 0:
        p = p[:k]
    if t <= 0 and (s_.btime != 0 or s_.bdate != 0):
        p = p + s_.date_string + "]"
    return p


# wfdb-x: the time conversion functions need a sampling frequency; the C
# library used 1 sample per second when none was specified.  Without one,
# timstr and mstimstr report an error and return the time as a sample number
# ("s" followed by the number, a valid strtim argument), and strtim reports
# an error and returns 0 for time strings that need a frequency.
def _nofreq_timstr(fn, t):
    wfdb_error("%s: sampling frequency is not specified\n", fn)
    return "s%d" % (-t if t < 0 else t)


def wfdbx_time_needs_freq(string):
    """Return 1 if strtim() needs a sampling frequency to convert string.

    A wfdb-x addition (see docs/DIVERGENCES.md): returns 0 if the string
    (after leading spaces, tabs, newlines and carriage returns) begins with
    "e", "i", "o" or "s", or with "c" while no counter frequency is
    defined; 1 otherwise.
    """
    c = string.lstrip(" \t\n\r")[:1]
    if c in ("e", "i", "o", "s"):
        return 0
    if c == "c":
        return 1 if _s.cfreq > 0.0 else 0
    return 1


def timstr(t):
    """Convert a time in sample intervals to a string.

    A positive t is converted to an elapsed time, "hh:mm:ss" (or "mm:ss"
    right-aligned, under one hour).  If t <= 0 and the base time is
    defined, -t is taken as an elapsed time from the start of the record
    and converted to the time of day, "[hh:mm:ss dd/mm/yyyy]" (the date
    only if defined).  The time is truncated to whole seconds.

    wfdb-x: if no sampling frequency is specified, reports an error and
    returns the time as a sample number, "s" followed by |t| (C used 1
    sample per second); see docs/DIVERGENCES.md.
    """
    s_ = _s
    if s_.ifreq > 0.0:
        f = s_.ifreq
    elif s_.sfreq > 0.0:
        f = s_.sfreq
    elif _legacy_mode:
        f = 1.0     # wfdb-x: legacy mode (original behavior)
    else:
        return _nofreq_timstr("timstr", t)
    return _ftimstr(t, f)


def _fmstimstr(t, f):
    s_ = _s
    if t > 0 or (s_.btime == 0 and s_.bdate == 0):
        if t < 0:
            t = -t
        sec = int(t / f)
        msec = int((t - sec * f) * 1000 / f + 0.5)
        if msec == 1000:
            msec = 0
            sec += 1
        t = sec
        seconds = t % 60
        t //= 60
        minutes = t % 60
        hours = t // 60
        if hours > 0:
            s_.time_string = "%2d:%02d:%02d.%03d" % (hours, minutes, seconds,
                                                    msec)
        else:
            s_.time_string = "   %2d:%02d.%03d" % (minutes, seconds, msec)
    else:
        tms = s_.btime - (t * 1000.0 / f)
        sec = int(tms / 1000.0)
        msec = int((tms - sec * 1000.0) + 0.5)
        if msec == 1000:
            msec = 0
            sec += 1
        t = sec
        seconds = cmod(t, 60)
        t = cdiv(t, 60)
        minutes = cmod(t, 60)
        t = cdiv(t, 60)
        hours = cmod(t, 24)
        days = cdiv(t, 24)
        if days != s_.pdays:
            if s_.bdate > 0:
                datstr(days + s_.bdate)
            elif days == 0:
                s_.date_string = ""
            else:
                s_.date_string = " %d" % days
            s_.pdays = days
        s_.time_string = "[%02d:%02d:%02d.%03d%s]" % (
            hours, minutes, seconds, msec, s_.date_string)
    return s_.time_string


def mstimstr(t):
    """Convert a time in sample intervals to a string with milliseconds.

    Like timstr(), but the result includes milliseconds ("hh:mm:ss.sss",
    or "[hh:mm:ss.sss dd/mm/yyyy]" for a time of day).

    wfdb-x: without a sampling frequency, behaves as timstr() does.
    """
    s_ = _s
    if s_.ifreq > 0.0:
        f = s_.ifreq
    elif s_.sfreq > 0.0:
        f = s_.sfreq
    elif _legacy_mode:
        f = 1.0     # wfdb-x: legacy mode (original behavior)
    else:
        return _nofreq_timstr("mstimstr", t)
    return _fmstimstr(t, f)


def getcfreq():
    """Return the counter frequency in Hz (the frame frequency if not set)."""
    s_ = _s
    return s_.cfreq if s_.cfreq > 0.0 else s_.ffreq


def setcfreq(freq):
    """Set the counter frequency in Hz (0 or less: no counter frequency)."""
    _s.cfreq = freq


def getbasecount():
    """Return the base counter value (the counter value at sample 0)."""
    return _s.bcount


def setbasecount(counter):
    """Set the base counter value (the counter value at sample 0)."""
    _s.bcount = counter


def _fstrtim(string, f):
    s_ = _s
    i = 0
    n = len(string)
    while i < n and string[i] in " \t\n\r":
        i += 1
    string = string[i:]
    c = string[:1]
    if c == "c":
        if s_.cfreq > 0.0:
            return d2l((strtod(string, 1)[0] - s_.bcount) * f / s_.cfreq)
        return strtol(string, 10, 1)[0]
    if c == "e":
        return (s_.msnsamples if s_.in_msrec else s_.nsamples) * \
            (s_.spfmax if (s_.gvmode & WFDB_HIGHRES) == WFDB_HIGHRES else 1)
    if c == "f":
        return d2l(_fdiv(strtol(string, 10, 1)[0] * f, s_.ffreq))
    if c == "i":
        return d2l(s_.istime *
                   (_fdiv(s_.ifreq, s_.sfreq) if s_.ifreq > 0.0 else 1.0) *
                   (s_.ispfmax if (s_.gvmode & WFDB_HIGHRES) == WFDB_HIGHRES
                    else 1))
    if c == "o":
        return s_.ostime
    if c == "s":
        return strtol(string, 10, 1)[0]
    if c == "[":
        string = string[1:]
        q = string.find("]")
        if q < 0:
            return 0
        p = string.find(" ")
        if p < 0 or p > q:
            days = 0
        else:
            r = string.find("/", p + 1)
            if r < 0 or r > q:
                days = strtol(string, 10, p + 1)[0]
            else:
                days = strdat(string[p + 1:]) - s_.bdate
        # in milliseconds (a WFDB_Time difference, which wraps around in C)
        x = float((_fstrtim(string, 1000.0) - s_.btime + 2 ** 63) % 2 ** 64
                  - 2 ** 63)
        if days > 0:
            x += days * (24 * 60 * 60 * 1000.0)
        t = d2l(x * f / 1000.0 + 0.5)
        return -t if t != LONG_MIN else LONG_MIN    # (-LONG_MIN in C)
    x = strtod(string)[0]
    p = string.find(":")
    if p < 0:
        return d2l(x * f + 0.5)
    y = strtod(string, p + 1)[0]
    p2 = string.find(":", p + 1)
    if p2 < 0:
        return d2l((60.0 * x + y) * f + 0.5)
    z = strtod(string, p2 + 1)[0]
    return d2l((3600.0 * x + 60.0 * y + z) * f + 0.5)


def strtim(string):
    """Convert a time string to a time in sample intervals.

    Accepted forms include elapsed times ("h:m:s", "m:s", "s", with
    optional decimals), times of day in brackets ("[hh:mm:ss dd/mm/yyyy]"),
    sample numbers ("s12345"), the end of the record ("e"), counter values
    ("c123") and frame numbers ("f100").

    Returns a positive number of sample intervals for an elapsed time, the
    negated elapsed time from the start of the record for a time of day,
    or 0 (which is also the error value for an unrecognized string).

    wfdb-x: if no sampling frequency is specified and the string needs one
    (see wfdbx_time_needs_freq), reports an error and returns 0 (C used 1
    sample per second).
    """
    s_ = _s
    if s_.ifreq > 0.0:
        f = s_.ifreq
    elif s_.sfreq > 0.0:
        f = s_.sfreq
    elif not _legacy_mode and wfdbx_time_needs_freq(string):
        wfdb_error("strtim: sampling frequency is not specified\n")
        return 0
    else:
        f = 1.0     # legacy mode (original behavior); otherwise not used
    return _fstrtim(string, f)


# datstr and strdat convert between Julian dates (used internally; they begin
# at midnight local time) and dd/mm/yyyy dates.  As in C, they are based on
# the functions of chapter 1 of "Numerical Recipes" by Press, Flannery,
# Teukolsky and Vetterling (Cambridge U. Press, 1986).

def _julian_ymd(date):
    """The (year, month, day) of a Julian date, computed as datstr() does
    (wfdb-x: for the high-level readers' base_date)."""
    if date >= 2299161:     # Gregorian calendar correction
        gcorr = int(((date - 1867216) - 0.25) / 36524.25)
        date += 1 + gcorr - int(0.25 * gcorr)
    date += 1524
    jy = int(6680 + ((date - 2439870) - 122.1) / 365.25)
    jd = int(365 * jy + (0.25 * jy))
    jm = int((date - jd) / 30.6001)
    d = date - jd - int(30.6001 * jm)
    m = jm - 1
    if m > 12:
        m -= 12
    y = jy - 4715
    if m > 2:
        y -= 1
    if y <= 0:
        y -= 1
    return y, m, d


def datstr(date):
    """Convert a Julian date to a string " dd/mm/yyyy" (leading space)."""
    y, m, d = _julian_ymd(date)
    _s.date_string = " %02d/%02d/%d" % (d, m, y)
    _s.pdays = -1
    return _s.date_string


def strdat(string):
    """Convert a date string ("dd/mm/yyyy") to a Julian date (0 if invalid)."""
    mp = string.find("/")
    if mp < 0:
        return 0
    yp = string.find("/", mp + 1)
    if yp < 0:
        return 0
    d = int32(strtol(string)[0])
    if d < 1 or d > 31:
        return 0
    m = int32(strtol(string, 10, mp + 1)[0])
    if m < 1 or m > 12:
        return 0
    y = int32(strtol(string, 10, yp + 1)[0])
    if y == 0:
        return 0
    if m > 2:
        jy = y
        jm = m + 1
    else:
        jy = y - 1
        jm = m + 13
    if jy > 0:
        date = int(365.25 * jy)
    else:
        date = -int(-365.25 * (jy + 0.25))
    date += int(30.6001 * jm) + d + 1720995
    if d + 31 * (m + 12 * y) >= (15 + 31 * (10 + 12 * 1582)):  # 15/10/1582
        gcorr = int(0.01 * jy)      # Gregorian calendar correction
        date += 2 - gcorr + int(0.25 * gcorr)
    return date


# wfdb-x: the unit conversion functions need the gain of the signal; the C
# library assumed WFDB_DEFGAIN (200 adu per physical unit) for uncalibrated
# signals (gain 0) and invalid signal numbers (with a baseline of 0), as
# legacy mode does.  Otherwise they report an error and return
# WFDB_INVALID_SAMPLE (aduphys returns NaN).
def _conversion_gain(fn, s):
    s_ = _s
    if _legacy_mode:
        g = s_.vsd[s].info.gain if 0 <= s < s_.nvsig else WFDB_DEFGAIN
        return WFDB_DEFGAIN if g == 0.0 else g
    if s < 0 or s >= s_.nvsig:
        # (C prints the signal number as unsigned)
        wfdb_error("%s: invalid signal number %u\n", fn, s & 0xFFFFFFFF)
        return 0.0
    g = s_.vsd[s].info.gain
    if g == 0.0:
        wfdb_error("%s: signal %u is uncalibrated\n", fn, s)
    return g


def _conversion_baseline(s):
    # The baseline of signal s, or 0 (legacy mode) for an invalid number.
    return _s.vsd[s].info.baseline if 0 <= s < _s.nvsig else 0


def adumuv(s, a):
    """Convert a from ADC units to microvolts, with the gain of signal s.

    wfdb-x: returns WFDB_INVALID_SAMPLE (and reports an error) if s is not
    an input signal or is uncalibrated (C assumed a gain of 200).
    """
    g = _conversion_gain("adumuv", s)
    if g == 0.0:
        return WFDB_INVALID_SAMPLE
    x = a * 1000.0 / g
    return int(x + 0.5) if x >= 0.0 else int(x - 0.5)


def muvadu(s, v):
    """Convert v from microvolts to ADC units, with the gain of signal s.

    wfdb-x: returns WFDB_INVALID_SAMPLE (and reports an error) if s is not
    an input signal or is uncalibrated (C assumed a gain of 200).
    """
    g = _conversion_gain("muvadu", s)
    if g == 0.0:
        return WFDB_INVALID_SAMPLE
    x = g * v * 0.001
    return int(x + 0.5) if x >= 0.0 else int(x - 0.5)


def aduphys(s, a):
    """Convert a from ADC units to physical units: (a - baseline) / gain.

    The baseline and gain are those of input signal s.  wfdb-x: returns
    NaN (and reports an error) if s is not an input signal or is
    uncalibrated (C assumed a gain of 200).
    """
    g = _conversion_gain("aduphys", s)
    if g == 0.0:
        return float("nan")
    return (a - _conversion_baseline(s)) / g


def physadu(s, v):
    """Convert v from physical units to ADC units (rounded to an integer).

    This is the inverse of aduphys(), with the baseline and gain of input
    signal s.  wfdb-x: returns WFDB_INVALID_SAMPLE (and reports an error)
    if s is not an input signal or is uncalibrated.
    """
    g = _conversion_gain("physadu", s)
    if g == 0.0:
        return WFDB_INVALID_SAMPLE
    b = _conversion_baseline(s)
    v *= g
    if v >= 0:
        return int32(int(v + 0.5) + b)
    return int32(int(v - 0.5) + b)


def sample(s, t):
    """Return the value (in ADC units) of sample t of input signal s.

    Unlike getvec(), sample() gives random access to the input signals,
    using a buffer of recent samples.  If the sample cannot be read, the
    result is WFDB_INVALID_SAMPLE or the last sample read; call
    sample_valid() to tell which.
    """
    s_ = _s
    nsig = s_.nvsig if s_.nvsig > s_.nisig else s_.nisig
    if s_.sbuf is None:
        s_.sbuf = [[0] * max(nsig, 1) for _ in range(BUFLN)]
        s_.sample_tt = -1
    if s < 0 or s >= nsig:
        s_.sample_vflag = -1
        return WFDB_INVALID_SAMPLE
    if t < 0:
        t = 0
    tt = s_.sample_tt
    if t <= tt - BUFLN or t > tt + BUFLN:
        tt = t - BUFLN
        if tt < 0:
            tt = -1
        s_.sample_tt = tt
        if isigsettime(tt + 1) < 0:
            s_.sample_vflag = 0
            return WFDB_INVALID_SAMPLE
    while t > tt:
        tt += 1
        s_.sample_tt = tt
        if getvec(s_.sbuf[tt & (BUFLN - 1)]) < 0:
            tt -= 1
            s_.sample_tt = tt
            s_.sample_vflag = 0
            return s_.sbuf[tt & (BUFLN - 1)][s]
    v = s_.sbuf[t & (BUFLN - 1)][s]
    s_.sample_vflag = -1 if v == WFDB_INVALID_SAMPLE else 1
    return v


def sample_valid():
    """Return the status of the most recent sample() call.

    1 if the value was valid, -1 if it was invalid (signal not available at
    that time, or illegal signal number), 0 if the time was past the end of
    the record.
    """
    return _s.sample_vflag


# ---------------------------------------------------------------------------
# Private functions used by wfdbquit / wfdbflush

def _wfdb_sampquit():
    if _s.sbuf is not None:
        _s.sbuf = None
        _s.sample_vflag = 0


def _wfdb_sigclose():
    s_ = _s
    _isigclose()
    _osigclose()
    s_.btime = s_.bdate = s_.nsamples = 0
    s_.msbtime = s_.msbdate = s_.msnsamples = 0
    s_.sfreq = s_.ifreq = s_.ffreq = 0.0
    s_.pdays = -1
    s_.segments = s_.in_msrec = s_.skewmax = 0
    s_.hdr_dir = s_.msrec_dir = s_.msrec_name = None    # wfdb-x
    if s_.dsbuf is not None:
        s_.dsbuf = None
        s_.dsbi = -1
    if s_.segarray is not None:
        s_.segarray = None
        s_.segp = s_.segend = 0
    s_.gv0 = s_.gv1 = None
    s_.tvector = []
    s_.uvector = []
    s_.vvector = []
    s_.tuvlen = 0
    _sigmap_cleanup()


def _wfdb_osflush():
    s_ = _s
    if not s_.osd or not s_.ogd:
        return
    for s in range(s_.nosig):
        os_ = s_.osd[s]
        og = s_.ogd[os_.info.group]
        if og.nrewind == 0:
            if not og.force_flush and og.seek == 0:
                if og.bsize == 0 and og.fp is not None and \
                        og.fp.seek(0, 1) == 0:
                    og.seek = 1
                else:
                    og.seek = -1
            if og.force_flush or og.seek > 0:
                f = os_.info.fmt
                if f == 212:
                    og.f212()
                elif f == 310:
                    og.f310()
                elif f == 311:
                    og.f311()
    for g in range(s_.nogroup):
        og = s_.ogd[g]
        if og.bsize == 0 and og.buf:
            if og.fp is not None:
                og.fp.write(bytes(og.buf))
            og.buf = bytearray()
        if og.fp is not None:
            og.fp.flush()
            if not og.force_flush and og.nrewind != 0:
                og.fp.seek(-og.nrewind, 1)
                og.nrewind = 0


def wfdb_freeinfo():
    """Discard the info strings read by getinfo().

    The next getinfo(None) starts again from the first info string of the
    current record (the record name survives wfdbquit(), as in C).
    """
    _s.pinfo = None
    _s.ninfo = 0
    _s.info_i = 0


_wfdb_freeinfo = wfdb_freeinfo     # (internal name used by the library)


def _wfdb_oinfoclose():
    s_ = _s
    stat = 0
    if s_.outinfo is not None and s_.outinfo is not s_.oheader:
        errflag = s_.outinfo.ferror()
        if s_.outinfo.close():
            errflag = True
        if errflag:
            wfdb_error("setinfo: write error in info file\n")
            stat = -2
    s_.outinfo = None
    return stat


# ---------------------------------------------------------------------------
# Bulk (vectorized) frame reading
#
# _bulk_frames() decodes up to n complete frames at once using NumPy.  It is
# exactly equivalent to n consecutive calls of getframe() in the situations
# where it is used, and it declines (returning fewer frames, possibly none)
# whenever a frame would require special handling: end of file, a frame at
# which a checksum is verified, a segment boundary, deskewing, resampling,
# or a partially consumed bit-packed group.  Callers then use getvec() for
# the next frame, which reproduces the C library's behavior exactly.  The
# signal files are read in whole blocks, as fill() reads them, and the
# input buffers are left as fill() would leave them (_bulk_read,
# _bulk_consume), so that getvec() continues exactly as after per-frame
# reading (even the stale bytes it reads at the end of a truncated file).
# The frames are decoded straight into the caller's array (int32 for
# read_record), with NumPy views of the bytes read where the format allows.

# Formats handled by the bulk reader: (bytes, samples) per packed unit.
_BULK_FMTS = {8: (1, 1), 80: (1, 1), 16: (2, 1), 61: (2, 1), 160: (2, 1),
              24: (3, 1), 32: (4, 1), 212: (3, 2), 310: (4, 3), 311: (4, 3)}


def _decode_stream(fmt, data, nsamp):
    """Decode nsamp samples of the given format from data (a bytes-like
    object, aligned on a packed unit).  Returns a 1-D NumPy integer array:
    a view of data (int8, int16 or int32) for formats 8, 16, 61 and 32,
    a new int32 array otherwise.  (Format 8 gives the first differences.)"""
    import numpy as np
    if fmt == 16:
        return np.frombuffer(data, "<i2", nsamp)
    if fmt == 61:
        return np.frombuffer(data, ">i2", nsamp)
    if fmt == 8:
        return np.frombuffer(data, "i1", nsamp)
    if fmt == 32:
        return np.frombuffer(data, "<i4", nsamp)
    if fmt == 80:
        return np.frombuffer(data, "u1", nsamp).astype(np.int32) - (1 << 7)
    if fmt == 160:
        return np.frombuffer(data, "<u2", nsamp).astype(np.int32) - (1 << 15)
    if fmt == 24:
        b = np.frombuffer(data, "u1", 3 * nsamp).reshape(-1, 3)
        v = b[:, 0].astype(np.int32)
        v |= b[:, 1].astype(np.int32) << 8
        v |= b[:, 2].astype(np.int32) << 16
        return v - ((v & 0x800000) << 1)
    if fmt == 212:
        npair = (nsamp + 1) // 2
        b = np.frombuffer(data, "u1", 3 * npair).reshape(-1, 3)
        b1 = b[:, 1].astype(np.int32)
        out = np.empty(2 * npair, np.int32)
        out[0::2] = b[:, 0] | ((b1 & 0x0F) << 8)
        out[1::2] = b[:, 2] | ((b1 & 0xF0) << 4)
        out = out[:nsamp]
        return out - ((out & 0x800) << 1)
    if fmt in (310, 311):
        ntrip = (nsamp + 2) // 3
        b = np.frombuffer(data, "u1", 4 * ntrip).astype(np.int32)
        b = b.reshape(-1, 4)
        out = np.empty(3 * ntrip, np.int32)
        if fmt == 310:
            w0 = b[:, 0] | (b[:, 1] << 8)
            w1 = b[:, 2] | (b[:, 3] << 8)
            out[0::3] = (w0 >> 1) & 0x3FF
            out[1::3] = (w1 >> 1) & 0x3FF
            out[2::3] = ((w0 & 0xF800) >> 11) | ((w1 & 0xF800) >> 6)
        else:
            w0 = b[:, 0] | (b[:, 1] << 8)
            out[0::3] = w0 & 0x3FF
            out[1::3] = ((w0 & 0xFC00) >> 10) | ((b[:, 2] & 0xF) << 6)
            out[2::3] = ((b[:, 2] | (b[:, 3] << 8)) >> 4) & 0x3FF
        out = out[:nsamp]
        return out - ((out & 0x200) << 1)
    raise ValueError(fmt)


def _bulk_eligible():
    s_ = _s
    if s_.nisig == 0 or s_.need_sigmap or s_.dsbuf is not None or \
            s_.nvsig != s_.nisig or s_.ispfmax != 1 or \
            not (s_.ifreq == 0.0 or s_.ifreq == s_.sfreq):
        return False
    for ig in s_.igd:
        if ig.seek != 1 or ig.fp is None or ig.initial_skip or ig.count or \
                ig.flac is not None:
            return False
    for is_ in s_.isd:
        if is_.info.fmt not in _BULK_FMTS or is_.info.spf != 1:
            return False
    return True


def _bulk_read(ig, need):
    """The next need bytes of input group ig (fewer at the end of the file):
    the bytes left in its buffer, then those of the blocks read ahead, then
    bytes read from its file, in whole blocks (as fill() reads them).
    Returns (data, have): a bytes-like object (no copy if the buffered
    bytes suffice), and the number of bytes of data that come from the
    buffer (the blocks begin there).  See _bulk_consume."""
    have = max(ig.be - ig.bp, 0)    # (bp > be after a fill at the end)
    if have >= need:
        return memoryview(ig.buf)[ig.bp:ig.be], have
    bsize = ig.bsize if ig.bsize > 0 else _s.ibsize
    ahead = len(ig.ahead)
    nblocks = -(-(need - have - ahead) // bsize) if need > have + ahead \
        else 0
    data = bytearray(have + ahead + nblocks * bsize)
    view = memoryview(data)
    view[:have] = memoryview(ig.buf)[ig.bp:ig.be]
    view[have:have + ahead] = ig.ahead
    got = ig.fp.readinto(view[have + ahead:]) if nblocks else 0
    return view[:have + ahead + got], have


def _bulk_consume(ig, data, have, used):
    """Leave input group ig as fill() and the r* routines would after
    consuming the first used bytes of data (from _bulk_read(ig, ...): its
    buffered bytes, then whole blocks): the buffer is the block holding
    the last byte consumed (as the C library's buffer would be: its stale
    bytes matter when a later fill() finds the end of the file), the
    blocks after it are kept for fill() (ig.ahead)."""
    if used <= have:
        # (still in the buffer; data begins at ig.bp)
        ig.bp += used
        if len(data) > have:
            ig.ahead = data[have:]
        return
    bsize = ig.bsize if ig.bsize > 0 else _s.ibsize
    start = have + (used - have - 1) // bsize * bsize
    block = data[start:start + bsize]
    ig.buf = block
    ig.bp = used - start
    ig.be = len(block)
    ig.stat = len(block)
    ig.ahead = data[start + bsize:]


def _bulk_frames(n, out, row=0, cols=None):
    """Read up to n frames at once into the rows out[row:row + m] of the
    NumPy array out (an integer array with one column per entry of cols:
    out[:, j] receives signal cols[j]; cols None: all signals, in order).
    Returns m, the number of frames read (possibly 0), or None if the bulk
    path cannot be used at all.  The samples are computed in int32 (with
    the wrap-around of the C library's int sums); the checksum sums in
    Python integers, then wrapped to int32 as in getvec."""
    import numpy as np
    s_ = _s
    if n <= 0 or not _bulk_eligible():
        return None
    isd = s_.isd
    nisig = s_.nisig
    # Signals of each group, and the alignment period (in frames).
    groups = {}
    for s in range(nisig):
        groups.setdefault(isd[s].info.group, []).append(s)
    period = 1
    for g, sl in groups.items():
        fmt = isd[sl[0]].info.fmt
        nb, ns = _BULK_FMTS[fmt]
        nn = len(sl)
        if ns == 2 and nn % 2:
            period = period * 2 // math.gcd(period, 2)
        elif ns == 3 and nn % 3:
            period = period * 3 // math.gcd(period, 3)
    # Do not include a frame at which a checksum would be verified.
    for is_ in isd:
        ns_ = is_.info.nsamp
        if ns_ > 0 and n >= ns_:
            n = ns_ - 1
    n -= n % period
    if n <= 0:
        return 0
    # Read the bytes needed by each group.
    bufs = {}
    for g, sl in groups.items():
        ig = s_.igd[g]
        fmt = isd[sl[0]].info.fmt
        nb, ns = _BULK_FMTS[fmt]
        bufs[g] = _bulk_read(ig, n * len(sl) * nb // ns)
        data = bufs[g][0]
        unit = period * len(sl) * nb // ns
        avail = (len(data) // unit) * period
        if avail < n:
            n = avail
    # Output columns of each signal (a signal may be selected twice).
    if cols is None:
        dest = [[s] for s in range(nisig)]
    else:
        dest = [[] for s in range(nisig)]
        for j, s in enumerate(cols):
            dest[s].append(j)
    rows = out[row:row + n]
    pad = s_.gvmode & WFDB_GVPAD
    if s_.istime == 0:
        for s in range(nisig):
            isd[s].samp = isd[s].info.initval
    for g, sl in groups.items():
        ig = s_.igd[g]
        data, have = bufs[g]
        fmt = isd[sl[0]].info.fmt
        nb, ns = _BULK_FMTS[fmt]
        nn = len(sl)
        used = n * nn * nb // ns
        if n:
            raw = _decode_stream(fmt, data, n * nn).reshape(n, nn)
        # Leave the unused bytes buffered, as the C library would.
        _bulk_consume(ig, data, have, used)
        if n == 0:
            continue
        for k, s in enumerate(sl):
            is_ = isd[s]
            col = raw[:, k]
            if fmt == 8:
                # (differences: cumulative sum in int64, wrapped to int32)
                v = np.cumsum(col, dtype=np.int64) + is_.samp
                v = ((v + 0x80000000) & 0xFFFFFFFF) - 0x80000000
                res = v
                is_.samp = int(v[-1])
                cks = int(v.sum())
            else:
                inv = col == _INVALID_BY_FMT[fmt]
                cks = int(col.sum(dtype=np.int64))
                res = col
                if inv.any():
                    col = col.astype(np.int32)
                    if pad:
                        idx = np.where(~inv, np.arange(n), -1)
                        idx = np.maximum.accumulate(idx)
                        res = np.where(idx >= 0, col[np.maximum(idx, 0)],
                                       np.int32(is_.samp))
                    else:
                        res = np.where(inv, np.int32(WFDB_INVALID_SAMPLE),
                                       col)
                    valid = np.nonzero(~inv)[0]
                    if len(valid):
                        is_.samp = int(col[valid[-1]])
                else:
                    is_.samp = int(col[-1])
            for j in dest[s]:
                rows[:, j] = res
            is_.info.cksum = int32(is_.info.cksum - cks)
            if is_.info.nsamp > 0:
                is_.info.nsamp -= n
            elif is_.info.nsamp == 0:
                is_.info.nsamp = -1
    s_.istime += n
    return n


def _getframes_into(out, row, n, cols=None, keep_checksum_frame=False):
    """Read up to n frames (getvec() semantics) into the rows
    out[row:row + n] of the NumPy integer array out (one column per entry
    of cols, the signal numbers of getvec()'s vector; cols None: every
    signal, in order).  Returns (m, stat): the number of frames read and
    the getvec() status of the first frame that could not be read (or the
    number of signals if all n frames were read).  With
    keep_checksum_frame (wfdb-x, for the high-level reader), the frame for
    which getvec() returns -4 (a checksum error: the frame was read
    completely, it is the last one of the record) is included, and stat is
    -4."""
    s_ = _s
    nsig = s_.nvsig if s_.nvsig > s_.nisig else s_.nisig
    stat = nsig
    v = [0] * max(nsig, 1)
    got = 0
    while got < n:
        m = _bulk_frames(n - got, out, row + got, cols)
        if m:
            got += m
            continue
        stat = getvec(v)
        if stat < 0 and not (stat == -4 and keep_checksum_frame):
            break
        out[row + got] = v[:nsig] if cols is None else [v[c] for c in cols]
        got += 1
        if stat < 0:
            break
    return got, stat


_GETFRAMES_BLOCK = 65536    # rows allocated at a time by getframes()


def getframes(n):
    """Read up to n frames (getvec() semantics) into a NumPy array.

    Returns ``(array, stat)``: ``array`` (int64) has one row per frame read
    and one column per signal returned by getvec(); ``stat`` is the getvec()
    status of the first frame that could not be read (or the number of
    signals if all n frames were read).  This is equivalent to calling
    getvec() up to n times, stopping at the first negative return value.
    """
    import numpy as np
    s_ = _s
    nsig = s_.nvsig if s_.nvsig > s_.nisig else s_.nisig
    blocks = []
    total = 0
    stat = nsig
    while total < n:
        k = min(n - total, _GETFRAMES_BLOCK)
        out = np.empty((k, nsig), np.int64)
        got, stat = _getframes_into(out, 0, k)
        blocks.append(out[:got])
        total += got
        if got < k:
            break
    if not blocks:
        return np.empty((0, nsig), np.int64), stat
    if len(blocks) == 1:
        return blocks[0], stat
    return np.concatenate(blocks), stat


def _record_length():
    """The number of frames of the open record according to its header (0
    if unknown), in the current getvec mode (as strtim("e"))."""
    s_ = _s
    return (s_.msnsamples if s_.in_msrec else s_.nsamples) * \
        (s_.spfmax if (s_.gvmode & WFDB_HIGHRES) == WFDB_HIGHRES else 1)

