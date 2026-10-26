"""High-level functions for reading and writing WFDB records with NumPy.

These functions are built on the C-compatible API of wfdb-x (``isigopen``,
``getvec``, ``getann``, ``putvec``, ``putann``, ...), so they read and
write exactly what the WFDB library and applications do.

Finding files: every relative name is read under the input directory and
written under the output directory -- whatever is set as the input
directory, a local directory or a URL, prefixes it; a name given as a full
path (/Users/...), a ~ path or a URL is used as given; nothing else is
searched.  The readers take ``input_dir=`` (the input directory for the
call) and ``network=`` (allow URLs for the call), the writers ``dir=`` (the
output directory); see also ``wfdbx_set_input_dir``,
``wfdbx_set_output_dir`` and ``wfdbx_set_network``.  The signal files of a
record are in the directory of its header.  Example (PhysioNet)::

    rec = wfdbx.read_record(
        "100", input_dir="https://physionet.org/files/mitdb/1.0.0/",
        network=True)

These functions call ``wfdbquit()``, so they close any record or
annotation file previously opened with the C-compatible API.

wfdb-x never assumes a sampling frequency, a gain, an ADC resolution or
units (the C library assumed 250 Hz, 200 adu/mV, 12 bits and millivolts):
``write_record`` requires the gains, the ADC resolutions and the units of
calibrated signals; ``read_record`` reports fs = 0 for a record whose
header gives no frequency, an ADC resolution of 0 (``siginfo[k].adcres``)
and units None where the header gives none; and conversions that need a
missing value raise ValueError (see docs/DIVERGENCES.md).

Legacy mode: with ``legacy=True``, each function behaves as in the
original package (the default gain of 200 adu/mV and ADC resolution based
on the format in ``write_record``, 250 Hz for a record without a header or
a frequency, a gain of 200 for uncalibrated signals in physical units, and
so on), with the library's legacy mode (``wfdbx_set_legacy``) on for the
duration of the call.  It is kept for compatibility only: the values it
assumes are exactly the silent defaults this project removed, so results
produced with it carry the same risks.

Example::

    import wfdbx
    rec = wfdbx.read_record("100s", sampto=1000, physical=True)
    rec.signals.shape            # (1000, 2)
    ann = wfdbx.read_annotations("100s", "atr")
    ann.symbols[:3], ann.samples[:3]

Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency, gain,
ADC resolution or units. Values that the record or the user does not give are
never assumed (the original package assumed 250 Hz, 200 adu/mV, 12 bits and
millivolts), because a silently assumed value corrupts every result derived
from it. See docs/DIVERGENCES.md. The original behavior remains available
with --legacy (see docs/DIVERGENCES.md).
Design decision (Reza Sameni, Oct 2026): files are found by explicit names
(the input directory, the output directory, or a full path or URL), not by a
search of the WFDB path, and PhysioNet (or any server) is accessed only if
asked for (network=True): a search can silently open the wrong file, fails in
ways nobody notices, and sent local paths and record names to physionet.org.
The original behavior remains available with --legacy (see
docs/DIVERGENCES.md).
Design decision (Reza Sameni, after a code review, Oct 2026): the writers
take a dir argument (the files are created in that directory, and the record
opens from there under its plain name), and write_record encodes the samples
of the common formats with NumPy, byte for byte as putvec (calling putvec
once per frame was 10-30 times slower than reading).
Design decision (Reza Sameni, Oct 2026): a checksum error (getvec status -4:
the samples are complete, their sum does not match the header's checksums)
is not an error of read_record but a RuntimeWarning (checksum_warning=False:
none); the data are returned.
This library is free software; you can redistribute it and/or modify it under
the terms of the GNU Library General Public License as published by the Free
Software Foundation; either version 2 of the License, or (at your option) any
later version.
"""

import functools
import os
import sys
import warnings

from . import _signal as sig
from . import _annot as ann
from . import _wfdbinit as init
from . import _wfdbio as wio
from ._wfdbio import WFDB_READ, WFDB_WRITE

__all__ = ["Record", "Header", "Annotations", "read_record",
           "read_annotations", "write_record", "write_annotations",
           "read_header"]

_CHUNK_SAMPLES = 1 << 21    # samples (frames x signals) read per chunk
_MAXAUX = 255           # maximum length of an aux string (one length byte)
# wfdb-x: legacy mode only: the ADC resolution (bits) that write_record
# wrote when adcres was not given (the sample width of the format, or 16).
_LEGACY_DEFRES = {80: 8, 508: 8, 212: 12, 310: 10, 311: 10, 24: 24, 524: 24,
                  32: 32}


class Record:
    """A record (or part of one), as returned by read_record().

    Attributes:
      name        record name
      fs          sampling frequency of the returned samples (samples per
                  second per signal; the highest frequency of a
                  multi-frequency record read with highres=True), or 0 if
                  the header does not specify it
      signals     array of shape (nsamples, nsignals): int32 ADC units, or
                  float64 physical units if read with physical=True.
                  Invalid samples are WFDB_INVALID_SAMPLE (NaN in physical
                  units).
      siginfo     list of Siginfo objects, one per returned signal (their
                  ``adcres`` is 0 if the header does not specify the ADC
                  resolution)
      names       signal descriptions (e.g. "MLII"), one per signal
      units       physical units, one per signal (None if the header does
                  not specify them; never assumed to be millivolts)
      gains       ADC units per physical unit, one per signal (0 means the
                  signal is uncalibrated)
      baselines   ADC value corresponding to 0 physical units, per signal
      base_time   start time and date of the record, as timstr(0) gives
                  it (e.g. "[08:45:00 01/01/2001]", without milliseconds),
                  or None if the header gives no start time
      base_time_ms
                  the start time as an int, in milliseconds after midnight
                  (milliseconds included: "14:00:03.500" gives 50403500);
                  None exactly when base_time is None
      base_date   the start date as a tuple (year, month, day) of ints, or
                  None if the header gives no date
      sampfrom    sample number of the first returned sample
      comments    list of info strings (header comment lines, without the
                  leading '#'), followed by those of a .info file if any
      checksum_ok False if the signal data were found not to match the
                  checksums in the header (getvec status -4; see the
                  checksum_warning argument of read_record), True
                  otherwise.  The checksums are verified only when the read
                  reaches the end of the record, so a read that stops
                  before it gives True
    """

    def __init__(self, **kw):
        self.__dict__.update(kw)

    def __repr__(self):
        return "Record(name=%r, fs=%g, signals=%s, names=%r)" % (
            self.name, self.fs, getattr(self.signals, "shape", None),
            self.names)


class Header:
    """The header of a record, as returned by read_header().

    Attributes:
      name          record name, as given to read_header
      fs            sampling frequency (as sampfreq() gives it after opening
                    the header: 0 if the header does not specify it; 250
                    in legacy mode)
      counter_freq  counter frequency (as getcfreq() gives it)
      base_counter  base counter value (as getbasecount() gives it)
      nsamples      number of samples per signal, from the header's record
                    line (0 if the header does not give it)
      nsig          number of signals
      siginfo       list of Siginfo objects, one per signal (empty for a
                    record with no signals; their ``adcres`` is 0 if the
                    header does not specify the ADC resolution)
      base_time     start time and date of the record, as timstr(0) gives
                    it (e.g. "[08:45:00 01/01/2001]"), or None
      base_time_ms  the start time in milliseconds after midnight (int), or
                    None exactly when base_time is None
      base_date     the start date as a tuple (year, month, day), or None if
                    the header gives no date
      comments      list of info strings (header comment lines, without the
                    leading '#'), followed by those of a .info file if any
    """

    def __init__(self, **kw):
        self.__dict__.update(kw)

    def __repr__(self):
        return "Header(name=%r, fs=%g, nsig=%d, nsamples=%d)" % (
            self.name, self.fs, self.nsig, self.nsamples)


class Annotations:
    """The annotations of one annotator, as returned by read_annotations().

    ``len(ann)`` is the number of annotations.

    Attributes:
      record     record name
      annotator  annotator name (e.g. "atr")
      samples    annotation times, in sample intervals (int64 array)
      codes      annotation type codes (int64 array; see ``wfdbx.NORMAL``,
                 ``wfdbx.PVC``, ...)
      symbols    list of mnemonics (e.g. 'N', 'V', '+'), as annstr() gives
      subtypes   annotation subtypes (int64 array)
      chans      channel numbers (int64 array)
      nums       annotator numbers (int64 array)
      aux        list of auxiliary strings (None where absent)
      fs         frequency in which ``samples`` are expressed (ticks per
                 second), as getiafreq() reports it: normally the
                 sampling frequency of the record (0 if neither the
                 record nor the ``fs`` argument of read_annotations
                 specifies one)
    """

    def __init__(self, **kw):
        self.__dict__.update(kw)

    def __len__(self):
        return len(self.samples)

    def __repr__(self):
        return "Annotations(record=%r, annotator=%r, n=%d)" % (
            self.record, self.annotator, len(self))


def _time(t):
    """Convert a time argument (int sample number or strtim() string) to a
    sample number; absolute times ("[hh:mm:ss]") are made positive."""
    if t is None:
        return None
    if isinstance(t, str):
        x = sig.strtim(t)
        return -x if x < 0 else x
    return int(t)


def _legacy_option(func):
    """Decorator for the legacy keyword argument (wfdb-x): with
    legacy=True, the library's legacy mode is on for the duration of the
    call, and the previous setting is restored afterwards (also on
    errors).  With legacy=False (the default), the current setting (off
    unless wfdbx_set_legacy turned it on) applies."""
    @functools.wraps(func)
    def wrapper(*args, **kw):
        if not kw.get("legacy"):
            return func(*args, **kw)
        previous = sig.wfdbx_set_legacy(1)
        try:
            return func(*args, **kw)
        finally:
            sig.wfdbx_set_legacy(previous)
    return wrapper


def _output_dir_option(func):
    """Decorator for the dir keyword argument of the writers (wfdb-x): with
    a directory, the files are created in it (it must exist), and the
    record is named without the directory (so that it can be opened from
    that directory under its plain name); the library's output directory
    (wfdbx_set_output_dir) is set for the duration of the call, and the
    previous one is restored afterwards (also on errors)."""
    @functools.wraps(func)
    def wrapper(record, *args, **kw):
        d = kw.get("dir")
        if not d:
            return func(record, *args, **kw)
        if "/" in record or os.sep in record or \
                (os.altsep and os.altsep in record):
            raise ValueError("record name must not contain a directory when "
                             "dir is given")
        if not os.path.isdir(d):
            raise FileNotFoundError("directory %s does not exist" % d)
        previous = wio.wfdbx_set_output_dir(d)
        try:
            return func(record, *args, **kw)
        finally:
            wio.wfdbx_set_output_dir(previous)
    return wrapper


def _input_options(func):
    """Decorator for the input_dir and network keyword arguments of the
    readers (wfdb-x): if given (not None), the library's input directory
    (wfdbx_set_input_dir) and network permission (wfdbx_set_network) are set
    for the duration of the call, and the previous values are restored
    afterwards (also on errors)."""
    @functools.wraps(func)
    def wrapper(*args, **kw):
        d, net = kw.get("input_dir"), kw.get("network")
        previous_dir = wio.wfdbx_set_input_dir(d) if d is not None else None
        previous_net = wio.wfdbx_set_network(net) if net is not None \
            else None
        try:
            return func(*args, **kw)
        finally:
            if net is not None:
                wio.wfdbx_set_network(previous_net)
            if d is not None:
                wio.wfdbx_set_input_dir(previous_dir)
    return wrapper


def _warn_level():
    """The stacklevel for warnings.warn called by a function of this module
    so that the warning points at the caller of the module (past the
    decorators' wrappers)."""
    f = sys._getframe(1)
    level = 1
    while f is not None and f.f_globals.get("__name__") == __name__:
        f = f.f_back
        level += 1
    return level


def _legacy():
    # True in legacy mode (the original behavior; see _legacy_option).
    return sig.wfdbx_get_legacy() != 0


def _check_time_freq(record, *times):
    """Raise ValueError if the sampling frequency is not specified and one
    of the time strings needs it (wfdb-x: no default sampling frequency;
    C assumed 250 Hz).  Closes the record first.  Legacy mode: no check."""
    if _legacy() or sig.sampfreq(None) > 0.0:
        return
    for t in times:
        if isinstance(t, str) and sig.wfdbx_time_needs_freq(t):
            init.wfdbquit()
            raise ValueError("sampling frequency of record %s is not "
                             "specified" % record)


def _base_time_fields():
    """(base_time, base_time_ms, base_date) of the open record: the text as
    timstr(0) gives it (None if the record has no start time, or no
    sampling frequency outside legacy mode: a header without a frequency
    cannot give a base time), the library's base time (btime, in ms after
    midnight) when the text is given, and the base date (bdate) as
    (year, month, day) when the header gives one."""
    s_ = sig._s
    text = sig.timstr(0) if sig.sampfreq(None) > 0.0 or _legacy() else ""
    if not text.startswith("["):
        text = None
    ms = int(s_.btime) if text is not None else None
    date = sig._julian_ymd(s_.bdate) if s_.bdate != 0 else None
    return text, ms, date


def _info_strings(record):
    # The info strings of the record (getinfo).
    comments = []
    c = sig.getinfo(record)
    while c is not None:
        comments.append(c)
        c = sig.getinfo(None)
    return comments


@_legacy_option
@_input_options
def read_header(record, *, input_dir=None, network=None, legacy=False):
    """Read the header of a record.

    No signal files are opened or read.

    Arguments:
      record    record name: relative to the input directory, or a full
                path, ~ path or URL
      input_dir the input directory for this call (a local directory, a
                ~ name or a URL; see wfdbx_set_input_dir); default: the
                current setting (by default, the current directory)
      network   True to allow reading URLs for this call (False to forbid
                it; see wfdbx_set_network); default: the current setting
                (by default, not allowed)
      legacy    if True, read the header as the original package did
                (missing ADC resolutions inferred from the format; see
                the module documentation)

    Returns:
      a Header object (see Header): the sampling and counter frequencies,
      the number of samples and of signals, the signal specifications
      (``siginfo``, a list of Siginfo objects), the base time and date,
      and the info strings

    Raises:
      IOError   if the header cannot be found or read

    Example::

        hdr = wfdbx.read_header("100s")
        print(hdr.fs, hdr.nsamples, hdr.base_time)
        for s in hdr.siginfo:
            print(s.desc, s.fmt, s.gain, s.units)
    """
    init.wfdbquit()
    n = sig.isigopen(record, None, 0)
    if n < 0:
        init.wfdbquit()
        raise IOError("can't read header for record %s" % record)
    si = []
    sig.isigopen(record, si, -n)
    s_ = sig._s
    base_time, base_time_ms, base_date = _base_time_fields()
    hdr = Header(name=record, fs=sig.sampfreq(None),
                 counter_freq=sig.getcfreq(), base_counter=sig.getbasecount(),
                 nsamples=s_.msnsamples if s_.in_msrec else s_.nsamples,
                 nsig=len(si), siginfo=si, base_time=base_time,
                 base_time_ms=base_time_ms, base_date=base_date,
                 comments=_info_strings(record))
    init.wfdbquit()
    return hdr


@_legacy_option
@_input_options
def read_record(record, channels=None, sampfrom=0, sampto=None,
                physical=False, highres=False, pad=False, *, input_dir=None,
                network=None, legacy=False, checksum_warning=True):
    """Read the signals of a record (or part of it) into a NumPy array.

    Arguments:
      record    record name: relative to the input directory, or a full
                path, ~ path or URL (as for rdsamp)
      channels  list of signal numbers (int) or names (str), in the order
                wanted (default: all signals)
      sampfrom  first sample to read: a sample number, or a time string
                as accepted by strtim() (e.g. "0:10" for 10 seconds,
                "s3600" for sample 3600); default 0.  Time strings other
                than sample numbers ("s..."), "e", "i" and "o" need the
                sampling frequency (see wfdbx_time_needs_freq)
      sampto    end of the excerpt, exclusive (sample number or time
                string, e.g. "e" for the end); default: end of the record
      physical  if False (the default), return ADC units (int32); if
                True, return physical units (float64, computed as
                (adc - baseline) / gain; invalid samples become NaN).
                Every selected signal must be calibrated (gain != 0):
                there is no default gain
      highres   if True, read every sample of oversampled signals of a
                multi-frequency record (WFDB_HIGHRES mode); by default
                such signals are averaged to one sample per frame
      pad       if True, replace each invalid sample by the previous valid
                sample of the same signal (WFDB_GVPAD mode)
      input_dir the input directory for this call (a local directory, a
                ~ name or a URL; see wfdbx_set_input_dir); default: the
                current setting (by default, the current directory)
      network   True to allow reading URLs for this call (False to forbid
                it; see wfdbx_set_network); default: the current setting
                (by default, not allowed)
      legacy    if True, behave as the original package (250 Hz for a
                header without a frequency, a gain of 200 for uncalibrated
                signals in physical units; see the module documentation)
      checksum_warning
                if True (the default), warn (RuntimeWarning: "checksum
                error in record REC: the signal data do not match the
                checksums in its header") when the samples read to the end
                of the record do not match the checksums in its header;
                the data are returned either way (False: no warning)

    Returns:
      a Record object (see Record); ``rec.signals`` has one row per
      sample and one column per selected signal

    Raises:
      IOError     if the header or the signal files cannot be read, or the
                  record has no signals, or sampfrom is beyond the end;
                  also if reading stops with a getvec status below -1
                  (e.g. -3: a signal file shorter than its header says,
                  or a read or decoding error), with the message "can't
                  read signal data of record REC (getvec status S)"
                  (also in legacy mode); reaching the end of the record
                  before sampto is not an error, nor is a checksum error
                  (-4: see checksum_warning)
      ValueError  if a channel number or name is not in the record, if
                  sampfrom or sampto is a time string that needs the
                  sampling frequency and the header does not specify it,
                  or if physical=True and a selected signal is
                  uncalibrated

    Example::

        rec = wfdbx.read_record("100s", channels=["MLII"],
                                sampfrom="0:10", sampto="0:20",
                                physical=True)
        rec.signals[:, 0]        # 10 s of lead MLII, in mV
    """
    import numpy as np
    init.wfdbquit()
    nsig = sig.isigopen(record, None, 0)
    if nsig <= 0:
        init.wfdbquit()
        raise IOError("can't read record %s" % record)
    si = []
    nsig = sig.isigopen(record, si, nsig)
    if nsig <= 0:
        init.wfdbquit()
        raise IOError("can't open signals of record %s" % record)
    mode = (sig.WFDB_HIGHRES if highres else sig.WFDB_LOWRES) | \
        (sig.WFDB_GVPAD if pad else 0)
    sig.setgvmode(mode)
    fs = sig.sampfreq(None)
    _check_time_freq(record, sampfrom, sampto)
    frm = _time(sampfrom) or 0
    to = _time(sampto)
    if channels is None:
        cols = list(range(nsig))
    else:
        cols = []
        for c in channels:
            k = sig.findsig(str(c)) if not isinstance(c, int) else c
            if k < 0 or k >= nsig:
                init.wfdbquit()
                raise ValueError("record %s has no signal %r" % (record, c))
            cols.append(k)
    if physical and not _legacy():
        # wfdb-x: no default gain (C, legacy mode: 200 adu/mV)
        for k in cols:
            if si[k].gain == 0.0:
                init.wfdbquit()
                raise ValueError("signal %d of record %s is uncalibrated" %
                                 (k, record))
    base_time, base_time_ms, base_date = _base_time_fields()
    if sig.isigsettime(frm) < 0:
        init.wfdbquit()
        raise IOError("can't seek to sample %d of record %s" % (frm, record))
    want = None if to is None else max(to - frm, 0)
    # The output array is allocated once, for the number of frames to be
    # read according to the header (or sampto), and grown only if the
    # record turns out to be longer (or its length is not given); each
    # chunk is decoded straight into its rows.
    chunk = max(4096, _CHUNK_SAMPLES // max(nsig, 1))
    length = sig._record_length()
    expected = length - frm if length > frm else None
    if want is not None and (expected is None or want < expected):
        expected = want
    size = expected if expected is not None else chunk
    data = np.empty((size, len(cols)), np.int32)
    probe = np.empty((1, len(cols)), np.int32)
    sel_cols = None if cols == list(range(nsig)) else cols
    nread = 0
    cksum_error = False
    sig._s.cksum_quiet = 1
    try:
        while want is None or nread < want:
            n = chunk if want is None else min(chunk, want - nread)
            if nread < len(data):
                n = min(n, len(data) - nread)
                m, stat = sig._getframes_into(data, nread, n, sel_cols,
                                              keep_checksum_frame=True)
            else:
                # The array is full: read one frame before growing it.
                n = 1
                m, stat = sig._getframes_into(probe, 0, 1, sel_cols,
                                              keep_checksum_frame=True)
                if m:
                    grown = max(nread + chunk, 2 * len(data))
                    if want is not None:
                        grown = min(grown, want)
                    bigger = np.empty((grown, len(cols)), np.int32)
                    bigger[:nread] = data[:nread]
                    bigger[nread] = probe[0]
                    data = bigger
            nread += m
            # wfdb-x: -4, a checksum error: the frames are complete (the
            # last one included), only their sum does not match the header:
            # a warning (see below), not an error
            if stat == -4:
                cksum_error = True
                break
            if m < n:
                # wfdb-x: a status below -1 (e.g. -3, unexpected EOF: the
                # signal file is shorter than its header says, or a decoder
                # or I/O error) is an error, not the end of the data (-1)
                if stat < -1:
                    init.wfdbquit()
                    raise IOError("can't read signal data of record %s "
                                  "(getvec status %d)" % (record, stat))
                break
    finally:
        sig._s.cksum_quiet = 0
    if cksum_error and checksum_warning:
        warnings.warn("checksum error in record %s: the signal data do not "
                      "match the checksums in its header" % record,
                      RuntimeWarning, stacklevel=_warn_level())
    if nread < len(data):
        # (a view if most of the array is used, else a copy that frees it)
        data = data[:nread] if 2 * nread >= len(data) else data[:nread].copy()
    sel = [si[k] for k in cols]
    comments = _info_strings(record)
    if physical:
        # (legacy mode: the default gain for uncalibrated signals)
        g = np.array([s.gain if s.gain != 0 or not _legacy() else
                      sig.WFDB_DEFGAIN for s in sel])
        b = np.array([float(s.baseline) for s in sel])
        out = (data.astype(np.float64) - b) / g
        out[data == sig.WFDB_INVALID_SAMPLE] = np.nan
        data = out
    rec = Record(name=record, fs=fs, signals=data, siginfo=sel,
                 names=[s.desc for s in sel], units=[s.units for s in sel],
                 gains=[s.gain for s in sel],
                 baselines=[s.baseline for s in sel], base_time=base_time,
                 base_time_ms=base_time_ms, base_date=base_date,
                 sampfrom=frm, comments=comments,
                 checksum_ok=not cksum_error)
    init.wfdbquit()
    return rec


@_legacy_option
@_input_options
def read_annotations(record, annotator, sampfrom=0, sampto=None, fs=None, *,
                     input_dir=None, network=None, legacy=False):
    """Read an annotation file into NumPy arrays (as rdann reads it).

    Arguments:
      record     record name (the header, if any, gives the sampling
                 frequency)
      annotator  annotator name, i.e. the file name suffix (e.g. "atr")
      sampfrom   skip annotations before this time (sample number or
                 strtim() time string); default 0
      sampto     stop before the first annotation at or after this time
                 (exclusive); default: read to the end of the file
      fs         sampling frequency (> 0) to use if the record has no
                 header or its header does not specify one (like the -F
                 option of rdann); ignored otherwise.  There is no default
                 (C assumed 250 Hz): without a frequency, ``fs`` of the
                 result is 0, and time strings that need the frequency
                 (see wfdbx_time_needs_freq) raise ValueError
      input_dir  the input directory for this call (see read_record)
      network    True to allow reading URLs for this call (see read_record)
      legacy     if True, behave as the original package (250 Hz if the
                 record has no header, or if its header gives no frequency,
                 and fs is not given; see the module documentation)

    Returns:
      an Annotations object (see Annotations), with one entry per
      annotation, in file order

    Raises:
      IOError    if the annotation file cannot be opened or read
      ValueError if fs is given and not > 0, or if sampfrom or sampto
                 needs the sampling frequency and none is specified

    Example::

        ann = wfdbx.read_annotations("100s", "atr", sampto="1:00")
        qrs = [bool(wfdbx.isqrs(c)) for c in ann.codes]
        beats = ann.samples[qrs]     # times of the QRS annotations
    """
    import numpy as np
    if fs is not None and not fs > 0:
        raise ValueError("fs must be > 0")
    init.wfdbquit()
    # wfdb-x: no default sampling frequency (C assumed 250 Hz if the record
    # had no header); the fs argument specifies one.
    sps = sig.sampfreq(record)
    if sps <= 0 and fs is not None:
        sig.setsampfreq(float(fs))
    elif sps < 0 and _legacy():
        sig.setsampfreq(sig.WFDB_DEFFREQ)   # legacy mode (original behavior)
    _check_time_freq(record, sampfrom, sampto)
    if ann.annopen(record, [ann.Anninfo(annotator, WFDB_READ)], 1) < 0:
        init.wfdbquit()
        raise IOError("can't read annotator %s for record %s" %
                      (annotator, record))
    frm = _time(sampfrom) or 0
    to = _time(sampto)
    if frm and ann.iannsettime(frm) < 0:
        init.wfdbquit()
        raise IOError("can't seek in annotator %s" % annotator)
    a = ann.Annotation()
    t, c, s, ch, nm, aux = [], [], [], [], [], []
    while ann.getann(0, a) == 0:
        if to is not None and a.time >= to:
            break
        t.append(a.time)
        c.append(a.anntyp)
        s.append(a.subtyp)
        ch.append(a.chan)
        nm.append(a.num)
        aux.append(a.aux_string())
    afs = ann.getiafreq(0)
    res = Annotations(record=record, annotator=annotator,
                      samples=np.array(t, np.int64),
                      codes=np.array(c, np.int64),
                      symbols=[ann.annstr(x) for x in c],
                      subtypes=np.array(s, np.int64),
                      chans=np.array(ch, np.int64),
                      nums=np.array(nm, np.int64), aux=aux, fs=afs)
    init.wfdbquit()
    return res


@_legacy_option
@_output_dir_option
def write_record(record, signals, fs, fmt=16, gains=None,
                 baselines=None, adczeros=0, adcres=None, units=None,
                 names=None, base_time=None, comments=None, physical=False,
                 samps_per_frame=None, *, dir=None, legacy=False):
    """Write signals as a new WFDB record (a header and one signal file).

    The signal file is named ``record + ".dat"`` and all signals are
    written to it (in a single group, so they must share one format).  Any
    existing files with these names are overwritten.

    Arguments:
      record     record name
      signals    array of shape (nsamples, nsignals) (a 1-D array is one
                 signal): integer ADC units, or physical units if
                 physical=True
      fs         sampling frequency (samples per second per signal; > 0)
      fmt        storage format (e.g. 16, 212, 24, 516; default 16)
      gains      ADC units per physical unit (required: there is no
                 default gain; 0 means uncalibrated, which is allowed
                 only for signals given in ADC units)
      baselines  ADC value corresponding to 0 physical units (default:
                 the ADC zero)
      adczeros   ADC value at the middle of the ADC range (default 0)
      adcres     ADC resolution in bits (required, >= 1: there is no
                 default, and none is inferred from the format)
      units      physical units (e.g. "mV"; required for every signal
                 whose gain is not 0: there is no default unit)
      names      signal descriptions (default: none)
      base_time  start time and optional date, "hh:mm:ss dd/mm/yyyy"
                 (default: none)
      comments   list of info strings, written to the header as '#' lines
      physical   if True, ``signals`` are in physical units, and are
                 converted to ADC units as physadu() does
                 (round(x * gain) + baseline); NaN becomes an invalid
                 sample
      samps_per_frame  samples per frame of each signal, to write a
                 multi-frequency record; ``signals`` then has
                 sum(samps_per_frame) columns, each row holding one frame
                 (the samples of signal 0, then of signal 1, ...)
      dir        if given, the directory (which must exist) in which the
                 files are created; the header then names the record and
                 its signal file without the directory, so that the record
                 opens from that directory under its plain name (record
                 must not contain a directory)
      legacy     if True, behave as the original package: the gains
                 default to 200 (also for physical signals of gain 0), the
                 ADC resolutions to the sample width of the format (8 for
                 formats 80 and 508, 10 for 310 and 311, 12 for 212, 24
                 for 24 and 524, 32 for 32, and 16 otherwise), and no
                 units or frequency are required (see the module
                 documentation)

    The per-signal arguments (fmt, gains, baselines, adczeros, adcres,
    units, names) accept a scalar, applied to every signal, or a list with
    one value per signal.

    Returns:
      None

    Raises:
      ValueError  if the gains or the ADC resolutions are not given (or a
                  resolution is < 1), if the units of a signal whose gain
                  is not 0 are not given, if fs is not > 0, if a signal
                  given in physical units is uncalibrated (gain 0), if
                  the signals do not all have the same format, or if
                  record contains a directory and dir is given
      IOError     if the signal file or the header cannot be created (a
                  FileNotFoundError if dir does not exist)

    Example::

        import numpy as np
        x = np.random.randn(3600, 2)
        wfdbx.write_record("rand", x, fs=360, fmt=16, physical=True,
                           gains=1000, adcres=16, units="mV",
                           names=["A", "B"])
    """
    import numpy as np
    x = np.asarray(signals)
    if x.ndim == 1:
        x = x[:, None]
    nsig = x.shape[1] if samps_per_frame is None else len(samps_per_frame)
    spf = [1] * nsig if samps_per_frame is None else list(samps_per_frame)

    def per(v, default=None):
        if v is None:
            return [default] * nsig
        if isinstance(v, (list, tuple, np.ndarray)):
            return list(v)
        return [v] * nsig

    # wfdb-x: the gains, the ADC resolutions, the units of calibrated
    # signals and the sampling frequency must be specified (no defaults; C
    # assumed 200 adu/mV, a resolution based on the format, millivolts and
    # 250 Hz, as legacy mode does).
    fmts = per(fmt)
    gains_ = per(gains)
    res = per(adcres)
    units_ = per(units)
    if _legacy():
        gains_ = [sig.WFDB_DEFGAIN if g is None else g for g in gains_]
        res = [_LEGACY_DEFRES.get(fmts[k], 16) if res[k] is None else res[k]
               for k in range(nsig)]
    else:
        if gains is None or any(g is None for g in gains_):
            raise ValueError("gains must be specified")
        if adcres is None or len(res) < nsig or \
                any(r is None or not int(r) >= 1 for r in res):
            raise ValueError("ADC resolution(s) must be specified")
        for k in range(nsig):
            if gains_[k] != 0 and (k >= len(units_) or not units_[k]):
                raise ValueError("units must be specified")
        if not float(fs) > 0:
            raise ValueError("sampling frequency must be > 0")
        if physical:
            for k in range(nsig):
                if gains_[k] == 0:
                    raise ValueError("signal %d is uncalibrated" % k)
    res = [int(r) for r in res]
    zeros = per(adczeros, 0)
    bases = per(baselines)
    bases = [zeros[k] if bases[k] is None else bases[k] for k in range(nsig)]
    names_ = per(names)
    if physical:
        cols = []
        for k in range(nsig):
            g = gains_[k] or sig.WFDB_DEFGAIN     # (gain 0: legacy mode)
            for j in range(spf[k]):
                cols.append((k, g, bases[k]))
        y = np.empty(x.shape, np.int64)
        for c, (k, g, b) in enumerate(cols):
            v = x[:, c].astype(np.float64) * g
            r = np.where(v >= 0, np.trunc(v + 0.5), np.trunc(v - 0.5)) + b
            r[np.isnan(v)] = sig.WFDB_INVALID_SAMPLE
            y[:, c] = r.astype(np.int64)
        x = y
    si = []
    for k in range(nsig):
        si.append(sig.Siginfo(
            fname="%s.dat" % record, desc=names_[k] if names_[k] is not None
            else "", units=units_[k], gain=float(gains_[k]), initval=0,
            group=0, fmt=fmts[k], spf=spf[k], bsize=0, adcres=res[k],
            adczero=zeros[k], baseline=bases[k]))
    if len(set(fmts)) > 1:
        raise ValueError("all signals of a record written by write_record "
                         "must have the same format")
    init.wfdbquit()
    if sig.osigfopen(si, nsig) != nsig:
        init.wfdbquit()
        raise IOError("can't create signal file for record %s" % record)
    sig.setsampfreq(float(fs))
    # The counter frequency and base count survive wfdbquit() (as in the C
    # library); a new record written here has neither.
    sig.setcfreq(0.0)
    sig.setbasecount(0.0)
    if base_time is not None:
        sig.setbasetime(base_time)
    sig._putframes(x)       # (as putvec for each frame, but faster)
    if sig.newheader(record) < 0:
        init.wfdbquit()
        raise IOError("can't create header for record %s" % record)
    for c in comments or []:
        sig.putinfo(c)
    init.wfdbquit()


@_legacy_option
@_output_dir_option
def write_annotations(record, annotator, samples, symbols=None, codes=None,
                      subtypes=0, chans=0, nums=0, aux=None, fs=None, *,
                      sort=None, dir=None, legacy=False):
    """Write an annotation file (as wrann does).

    The annotations are written in the order given.  If they are not in
    canonical (time) order, the file is rearranged when it is closed (as
    the sortann tool does; wfdb-x: in this process, whereas the C library,
    as legacy mode, runs sortann), unless the WFDBANNSORT environment
    variable is 0 or sort is False (the library reports this on the
    standard error output, unless wfdbquiet() is in effect).

    Arguments:
      record     record name
      annotator  annotator name, i.e. the file name suffix (e.g. "atr");
                 an existing file is overwritten
      samples    annotation times (sample numbers)
      symbols    mnemonics such as 'N' or 'V', converted by strann()
                 (an unknown mnemonic becomes code 0, NOTQRS)
      codes      annotation type codes, used instead of ``symbols``
      subtypes, chans, nums
                 subtype, channel and annotator number (a scalar for all
                 annotations, or one value per annotation; default 0)
      aux        list of auxiliary strings, or None entries (strings
                 longer than 255 bytes are truncated); default: none
      fs         if given, recorded in the file as its time resolution
                 (ticks per second)
      sort       None (the default): an out-of-order file is rearranged
                 unless the WFDBANNSORT environment variable is 0; True:
                 it is rearranged, False: it is left in the order given,
                 for this call only, whatever WFDBANNSORT says (the
                 environment is not changed; in legacy mode too, where
                 True runs sortann)
      dir        if given, the directory (which must exist) in which the
                 file is created (record must not contain a directory)
      legacy     if True, the library's legacy mode is on during the call
                 (this function has no other legacy behavior)

    Returns:
      None

    Raises:
      ValueError  if neither symbols nor codes is given, or if record
                  contains a directory and dir is given
      IOError     if the annotation file cannot be created (a
                  FileNotFoundError if dir does not exist)

    Example::

        wfdbx.write_annotations("rand", "test", [100, 460, 820],
                                symbols=["N", "V", "N"],
                                aux=[None, "(VT", None])
    """
    import numpy as np
    n = len(samples)
    if codes is None:
        if symbols is None:
            raise ValueError("symbols or codes must be given")
        codes = [ann.strann(s) for s in symbols]

    def ints(v):
        # v (a sequence, or a scalar for all annotations) as a list of n
        # Python ints
        if isinstance(v, np.ndarray) and v.dtype.kind in "iu":
            return v.tolist()
        if isinstance(v, (list, tuple, np.ndarray)):
            return [int(x) for x in v]
        return [int(v)] * n

    def aux_bytes(x):
        if x is None:
            return None
        b = x.encode("latin-1")[:_MAXAUX]
        return bytes((len(b),)) + b

    times = ints(samples)
    codes, subtypes, chans, nums = ints(codes), ints(subtypes), \
        ints(chans), ints(nums)
    if aux is None:
        auxes = [None] * n
    elif isinstance(aux, (list, tuple, np.ndarray)):
        auxes = [aux_bytes(x) for x in aux]
    else:
        auxes = [aux_bytes(aux)] * n
    init.wfdbquit()
    if fs is not None:
        ann.setafreq(float(fs))
    if ann.annopen(record, [ann.Anninfo(annotator, WFDB_WRITE)], 1) < 0:
        init.wfdbquit()
        raise IOError("can't create annotator %s for record %s" %
                      (annotator, record))
    # (as putann for each annotation, but encoded at once)
    ann._putanns(0, times[:n], codes[:n], subtypes[:n], chans[:n], nums[:n],
                 auxes[:n])
    ann._a.sort_override = None if sort is None else bool(sort)
    try:
        init.wfdbquit()
    finally:
        ann._a.sort_override = None
    if fs is not None:
        ann.setafreq(0.0)
