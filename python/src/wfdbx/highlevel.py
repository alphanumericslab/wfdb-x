"""High-level functions that read and write WFDB records as NumPy arrays.

Functions:

  read_record        read the signals of a record (returns a Record)
  read_header        read the header of a record (returns a Header)
  read_annotations   read an annotation file (returns an Annotations)
  write_record       write a header and a signal file
  write_annotations  write an annotation file

Where files are read and written: a full path, a ~ path or a URL is used
as given. Any other name is read from the input directory and written to
the output directory. Both are the current directory unless you set them
with ``wfdbx_set_input_dir`` and ``wfdbx_set_output_dir``. URLs are read
only when network access is on (``wfdbx_set_network``). The readers also
take ``input_dir=`` and ``network=``, and the writers take ``dir=``, for
one call. The signal files that a header names are read from the header's
directory.

Signal parameters: no sampling frequency, gain, ADC resolution or units is
ever assumed. Where one is needed and the record does not give it, you
must give it. A record whose header gives no frequency has ``fs = 0``.

Legacy mode: with ``legacy=True``, a function behaves as in the original
WFDB package. See
https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md#legacy-mode

These functions call ``wfdbquit()``, which closes anything opened with
the WFDB library functions.

Example, with the sample record 100s, included with WFDB-x (the first minute
of record 100 of the MIT-BIH Arrhythmia Database, in the directory
``wfdbx.sample_data_dir()``)::

    import wfdbx
    wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())
    rec = wfdbx.read_record("100s", sampto=1000, physical=True)
    rec.signals.shape            # (1000, 2)
    ann = wfdbx.read_annotations("100s", "atr")
    ann.symbols[:3]              # ['+', 'N', 'N']

Reading record 100 of the MIT-BIH Arrhythmia Database from PhysioNet (the
input directory is its PhysioNet URL, and network access is on)::

    rec = wfdbx.read_record(
        "100", input_dir="https://physionet.org/files/mitdb/1.0.0/",
        network=True)

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This library is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

# Developer notes (moved from the module docstring).
# WFDB-x: no built-in sampling frequency, gain, ADC resolution or units.
# Values that the record or the user does not give are never assumed (the
# original package assumed 250 Hz, 200 adu/mV, 12 bits and millivolts),
# because a silently assumed value corrupts every result derived from it. See
# docs/DIVERGENCES.md. The original behavior remains available with --legacy.
# WFDB-x: files are found by explicit names (the input directory, the output
# directory, or a full path or URL), not by a search of the WFDB path, and
# PhysioNet (or any server) is accessed only if asked for (network=True): a
# search can silently open the wrong file, fails in ways nobody notices, and
# sent local paths and record names to physionet.org. The original behavior
# remains available with --legacy.
# WFDB-x: the writers take a dir argument (the files are created in that
# directory, and the record opens from there under its plain name), and
# write_record encodes the samples of the common formats with NumPy, byte for
# byte as putvec (calling putvec once per frame was 10-30 times slower than
# reading).
# WFDB-x: a checksum error (getvec status -4: the samples are complete, their
# sum does not match the header's checksums) is not an error of read_record
# but a RuntimeWarning (checksum_warning=False: none); the data are returned.
# Legacy mode (legacy=True): the library's legacy mode (wfdbx_set_legacy)
# is on for the duration of the call; the defaults are those of the
# original package (200 adu/mV, an ADC resolution based on the format in
# write_record, 250 Hz for a record without a header or a frequency, a gain
# of 200 for uncalibrated signals in physical units).

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
# WFDB-x: legacy mode only: the ADC resolution (bits) that write_record
# wrote when adcres was not given (the sample width of the format, or 16).
_LEGACY_DEFRES = {80: 8, 508: 8, 212: 12, 310: 10, 311: 10, 24: 24, 524: 24,
                  32: 32}


class Record:
    """A record, or part of one, as returned by read_record().

    Attributes:
      name          record name, as given to read_record
      fs            sampling frequency in Hz, or 0 if the header gives none.
                    With highres=True, the highest sampling frequency of a
                    multi-frequency record.
      signals       NumPy array with one row per sample and one column per
                    signal. It holds int32 ADC units, or float64 physical
                    units if you read with physical=True. Invalid samples are
                    WFDB_INVALID_SAMPLE, or NaN in physical units.
      siginfo       list of Siginfo objects, one per signal. A signal's
                    ``adcres`` is 0 if the header does not give it, and its
                    ``desc`` has no white space at either end.
      names         description of each signal, such as "MLII", without the
                    white space that a header may put at either end of it
      units         physical units of each signal, or None if the header
                    gives none
      gains         gain of each signal, in ADC units per physical unit.
                    0 means the signal is uncalibrated.
      baselines     ADC value of each signal that corresponds to 0 physical
                    units
      base_time     start time and date as text, to the second, such as
                    "[14:00:03 21/06/2024]", or None if the header gives none
      base_time_ms  start time in milliseconds after midnight, such as
                    50403500 for 14:00:03.500, or None if base_time is None
      base_date     start date as (year, month, day), or None if the header
                    gives none
      sampfrom      number of the first sample returned
      comments      list of the info strings of the header
      checksum_ok   False if the data do not match the header's checksums.
                    Checksums are only checked when a read reaches the end of
                    the record, so a shorter read gives True.
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
      fs            sampling frequency in Hz, or 0 if the header gives none
      counter_freq  counter frequency, as getcfreq() returns it
      base_counter  base counter value, as getbasecount() returns it
      nsamples      number of samples per signal, or 0 if the header does not
                    give it
      nsig          number of signals
      siginfo       list of Siginfo objects, one per signal. A signal's
                    ``adcres`` is 0 if the header does not give it, and its
                    ``desc`` has no white space at either end.
      base_time     start time and date as text, such as
                    "[08:45:00 01/01/2001]", or None if the header gives none
      base_time_ms  start time in milliseconds after midnight, or None if
                    base_time is None
      base_date     start date as (year, month, day), or None if the header
                    gives none
      comments      list of the info strings of the header
    """

    def __init__(self, **kw):
        self.__dict__.update(kw)

    def __repr__(self):
        return "Header(name=%r, fs=%g, nsig=%d, nsamples=%d)" % (
            self.name, self.fs, self.nsig, self.nsamples)


class Annotations:
    """The annotations of one file, as returned by read_annotations().

    ``len(ann)`` is the number of annotations. They are in file order.

    Attributes:
      record     record name
      annotator  annotator name, such as "atr"
      samples    annotation times, in samples (int64 array)
      codes      annotation codes (int64 array), such as wfdbx.NORMAL or
                 wfdbx.PVC
      symbols    list of mnemonics, such as "N", "V" or "+"
      subtypes   subtype of each annotation (int64 array)
      chans      channel number of each annotation (int64 array)
      nums       annotator number of each annotation (int64 array)
      aux        list of the auxiliary text of each annotation, or None
      fs         frequency in which ``samples`` are counted, normally the
                 sampling frequency of the record. It is 0 if neither the
                 record nor the ``fs`` argument of read_annotations gives one.
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
    """Decorator for the legacy keyword argument (WFDB-x): with
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
    """Decorator for the dir keyword argument of the writers (WFDB-x): with
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
    readers (WFDB-x): if given (not None), the library's input directory
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


_SPACE = " \t\n\v\f\r"      # white space (C isspace)


def _strip_desc(si):
    """The Siginfo objects si with the white space at both ends of each
    description removed.  WFDB-x: the high-level readers give the signal
    names without the spaces that some headers end them with (C keeps
    them, as the C-style functions do)."""
    for s in si:
        if s.desc:
            s.desc = s.desc.strip(_SPACE)
    return si


def _check_time_freq(record, *times):
    """Raise ValueError if the sampling frequency is not specified and one
    of the time strings needs it (WFDB-x: no default sampling frequency;
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

    The signal files are not opened.

    Arguments:
      record     record name: a name in the input directory, or a full path,
                 ~ path or URL
      input_dir  input directory for this call only: a local directory, a
                 ~ path or a URL. Default: the current setting (see
                 wfdbx_set_input_dir).
      network    True to allow reading URLs for this call only, False to
                 forbid it. Default: the current setting (see
                 wfdbx_set_network).
      legacy     True to read the header as the original WFDB package does
                 (see the module help)

    Returns:
      a Header object (see Header)

    Raises:
      IOError    if the header cannot be found or read

    Example (100s is the sample record included with WFDB-x: the first
    minute of record 100 of the MIT-BIH Arrhythmia Database, in the
    directory wfdbx.sample_data_dir())::

        wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())
        hdr = wfdbx.read_header("100s")
        print(hdr.fs, hdr.nsamples)          # 360.0 21600
        for s in hdr.siginfo:
            print(s.desc, s.fmt, s.gain, s.units)

    Part of WFDB-x; not in the original WFDB package.
    """
    init.wfdbquit()
    n = sig.isigopen(record, None, 0)
    if n < 0:
        init.wfdbquit()
        raise IOError("can't read header for record %s" % record)
    si = []
    sig.isigopen(record, si, -n)
    _strip_desc(si)
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
    """Read the signals of a record, or part of it, into a NumPy array.

    Arguments:
      record     record name: a name in the input directory, or a full path,
                 ~ path or URL
      channels   list of the signals to read, by number (int) or name (str,
                 as in Record.names), in the order you want them. Default:
                 all signals.
      sampfrom   first sample to read: a sample number or a time string.
                 Default: 0.
      sampto     the sample after the last one to read: a sample number or a
                 time string. Default: the end of the record.
      physical   False (the default) to return ADC units (int32), True to
                 return physical units (float64). Physical units are
                 (adc - baseline) / gain, and every signal you read must have
                 a gain.
      highres    True to read every sample of a multi-frequency record, at its
                 highest sampling frequency. By default, faster signals are
                 averaged to one sample per frame.
      pad        True to replace each invalid sample by the previous valid
                 sample of the same signal
      input_dir  input directory for this call only: a local directory, a
                 ~ path or a URL. Default: the current setting (see
                 wfdbx_set_input_dir).
      network    True to allow reading URLs for this call only, False to
                 forbid it. Default: the current setting (see
                 wfdbx_set_network).
      legacy     True to behave as the original WFDB package (see the module
                 help)
      checksum_warning
                 True (the default) to issue a RuntimeWarning when the data
                 do not match the header's checksums. The data are returned
                 either way, and ``checksum_ok`` of the result is False.

    A time string is a WFDB time such as "0:10" (10 seconds), "1:02:03.5",
    "s3600" (sample 3600) or "e" (the end of the record). A time in seconds
    needs the sampling frequency.

    Returns:
      a Record object (see Record). ``rec.signals`` has one row per sample
      and one column per signal.

    Raises:
      IOError     if the header or a signal file cannot be read, if the
                  record has no signals, if sampfrom is beyond the end of the
                  record, or if a signal file is shorter than its header says
                  ("can't read signal data of record REC (getvec status -3)")
      ValueError  if a channel is not in the record, if a time string needs
                  the sampling frequency and the header gives none, or if
                  physical=True and a signal you read has no gain

    Warns:
      RuntimeWarning  "checksum error in record REC: the signal data do not
                  match the checksums in its header" (see checksum_warning)

    Example (100s is the sample record included with WFDB-x: the first
    minute of record 100 of the MIT-BIH Arrhythmia Database, in the
    directory wfdbx.sample_data_dir())::

        wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())
        rec = wfdbx.read_record("100s", channels=["MLII"],
                                sampfrom="0:10", sampto="0:20",
                                physical=True)
        rec.signals.shape            # (3600, 1): 10 s of lead MLII, in mV

    Part of WFDB-x; not in the original WFDB package.
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
    _strip_desc(si)
    if channels is None:
        cols = list(range(nsig))
    else:
        cols = []
        names = [s.desc for s in si]
        for c in channels:
            if isinstance(c, int):
                k = c
            elif str(c).strip(_SPACE) in names:
                k = names.index(str(c).strip(_SPACE))
            else:
                k = sig.findsig(str(c))
            if k < 0 or k >= nsig:
                init.wfdbquit()
                raise ValueError("record %s has no signal %r" % (record, c))
            cols.append(k)
    if physical and not _legacy():
        # WFDB-x: no default gain (C, legacy mode: 200 adu/mV)
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
    # (whole frames, and a multiple of 6 of them, so that formats 212, 310
    # and 311 end each chunk on a whole packed unit: the frames are then
    # read in blocks)
    unit = 6 * (max(sig._s.ispfmax, 1) if highres else 1)
    chunk -= chunk % unit
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
            # WFDB-x: -4, a checksum error: the samples are valid, only
            # their sum does not match the header: a warning (see below),
            # not an error. In high-resolution mode getvec returns -4 for
            # each sample vector of the last frame, so reading continues
            # until -1 (or sampto).
            if stat == -4:
                cksum_error = True
                continue
            if m < n:
                # WFDB-x: a status below -1 (e.g. -3, unexpected EOF: the
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
        # (in place: (data - b) / g without temporary arrays)
        out = np.subtract(data, b, dtype=np.float64)
        np.divide(out, g, out=out)
        inv = data == sig.WFDB_INVALID_SAMPLE
        if inv.any():
            out[inv] = np.nan
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
    """Read an annotation file into NumPy arrays.

    Arguments:
      record     record name. Its header, if there is one, gives the sampling
                 frequency.
      annotator  annotator name: the suffix of the annotation file. "atr"
                 reads the file record.atr.
      sampfrom   first time to read: a sample number or a time string (see
                 read_record). Default: 0.
      sampto     time at which to stop. Annotations at or after it are not
                 read. Default: the end of the file.
      fs         sampling frequency (> 0) to use when the record has no
                 header, or its header gives none. It is ignored otherwise.
      input_dir  input directory for this call only (see read_record)
      network    True to allow reading URLs for this call only (see
                 read_record)
      legacy     True to behave as the original WFDB package (see the module
                 help)

    Returns:
      an Annotations object (see Annotations), in file order. Its ``fs`` is
      0 if neither the record nor the fs argument gives a sampling frequency.

    Raises:
      IOError     if the annotation file cannot be opened or read, or if it
                  ends before its end-of-file marker ("can't read annotation
                  file ANN of record REC (getann status -3)")
      ValueError  if fs is given and is not > 0, or if a time string needs
                  the sampling frequency and none is known

    Example (100s is the sample record included with WFDB-x: the first
    minute of record 100 of the MIT-BIH Arrhythmia Database, in the
    directory wfdbx.sample_data_dir())::

        wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())
        ann = wfdbx.read_annotations("100s", "atr", sampto="0:30")
        qrs = [bool(wfdbx.isqrs(c)) for c in ann.codes]
        beats = ann.samples[qrs]     # times of the beats, in samples

    Part of WFDB-x; not in the original WFDB package.
    """
    import numpy as np
    if fs is not None and not fs > 0:
        raise ValueError("fs must be > 0")
    init.wfdbquit()
    # WFDB-x: no default sampling frequency (C assumed 250 Hz if the record
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
    while True:
        stat = ann.getann(0, a)
        if stat != 0:
            break
        if to is not None and a.time >= to:
            break
        t.append(a.time)
        c.append(a.anntyp)
        s.append(a.subtyp)
        ch.append(a.chan)
        nm.append(a.num)
        aux.append(a.aux_string())
    # WFDB-x: a status other than 0 and -1 (e.g. -3, unexpected EOF: the
    # file is truncated) is an error, not the end of the file
    if stat not in (0, -1):
        init.wfdbquit()
        raise IOError("can't read annotation file %s of record %s "
                      "(getann status %d)" % (annotator, record, stat))
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
    """Write signals as a new record: a header and one signal file.

    The files are named ``record + ".hea"`` and ``record + ".dat"``. All
    signals go into the one signal file, so they must share one format.
    Existing files with these names are overwritten.

    You must give the sampling frequency, the gain and ADC resolution of each
    signal, and the units of each calibrated signal. There are no defaults.
    The per-signal arguments (fmt, gains, baselines, adczeros, adcres, units,
    names) take one value for all signals, or a list with one value per
    signal.

    Arguments:
      record     record name
      signals    array with one row per sample and one column per signal.
                 A 1-D array is one signal. The values are integer ADC units,
                 or physical units if physical=True.
      fs         sampling frequency in Hz (> 0)
      fmt        storage format, such as 16, 212, 24 or 516 (FLAC).
                 Default: 16.
      gains      gain in ADC units per physical unit. 0 marks a signal as
                 uncalibrated, which is only allowed for ADC units.
      baselines  ADC value that corresponds to 0 physical units. Default:
                 the ADC zero.
      adczeros   ADC value at the middle of the ADC range. Default: 0.
      adcres     ADC resolution in bits (>= 1)
      units      physical units, such as "mV". Required for each signal with
                 a gain other than 0.
      names      signal descriptions. Default: none.
      base_time  start time, with an optional date: "hh:mm:ss dd/mm/yyyy".
                 Default: none.
      comments   list of info strings, written to the header
      physical   True if ``signals`` are in physical units. They are
                 converted to ADC units as round(x * gain) + baseline, and
                 NaN becomes an invalid sample.
      samps_per_frame
                 samples per frame of each signal, for a multi-frequency
                 record. ``signals`` then has sum(samps_per_frame) columns,
                 and each row holds one frame: the samples of signal 0, then
                 those of signal 1, and so on.
      dir        directory in which to create the files. It must exist, and
                 ``record`` must then be a plain name. The record opens from
                 that directory under its plain name.
      legacy     True to behave as the original WFDB package (see the module
                 help)

    Returns:
      None

    Raises:
      ValueError         if fs, a gain, an ADC resolution or the units of a
                         calibrated signal is missing or invalid, if a signal
                         in physical units has a gain of 0, if the signals do
                         not all have the same format, if a samps_per_frame
                         value is not an integer >= 1 or the number of columns
                         of signals is not their sum, or if record contains a
                         directory and dir is given
      FileNotFoundError  if dir does not exist
      IOError            if the signal file or the header cannot be created,
                         or cannot be written completely (for example, when
                         the disk is full: "write error on record R")

    Example (writes a record of random numbers, rand, in the output
    directory: the files rand.hea and rand.dat)::

        import numpy as np
        x = np.random.randn(3600, 2)
        wfdbx.write_record("rand", x, fs=360, fmt=16, physical=True,
                           gains=1000, adcres=16, units="mV",
                           names=["A", "B"])

    Part of WFDB-x; not in the original WFDB package.
    """
    import numpy as np
    x = np.asarray(signals)
    if x.ndim == 1:
        x = x[:, None]
    nsig = x.shape[1] if samps_per_frame is None else len(samps_per_frame)
    spf = [1] * nsig if samps_per_frame is None else list(samps_per_frame)
    # Each frame holds spf[k] >= 1 samples of signal k, and each row of
    # signals is one frame.
    if any(not (n >= 1 and n == int(n)) for n in spf):
        raise ValueError("samps_per_frame must hold integers >= 1")
    spf = [int(n) for n in spf]
    if x.shape[1] != sum(spf):
        raise ValueError("signals has %d columns, but samps_per_frame adds "
                         "up to %d" % (x.shape[1], sum(spf)))

    def per(v, default=None):
        if v is None:
            return [default] * nsig
        if isinstance(v, (list, tuple, np.ndarray)):
            return list(v)
        return [v] * nsig

    # WFDB-x: the gains, the ADC resolutions, the units of calibrated
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
    errors = wio.wfdbx_write_errors()
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
    if wio.wfdbx_write_errors() > errors:
        raise IOError("write error on record %s" % record)


@_legacy_option
@_output_dir_option
def write_annotations(record, annotator, samples, symbols=None, codes=None,
                      subtypes=0, chans=0, nums=0, aux=None, fs=None, *,
                      sort=None, dir=None, legacy=False):
    """Write an annotation file.

    Give the annotation types as ``symbols`` or as ``codes``. If the
    annotations are not in time order, the file is sorted when it is
    written. ``sort`` controls this for one call. Without ``sort``, the
    WFDBANNSORT environment variable decides: sorting is on unless it is 0.

    Arguments:
      record     record name
      annotator  annotator name: the suffix of the file. An existing file is
                 overwritten.
      samples    annotation times, in samples
      symbols    mnemonics such as "N" or "V". An unknown mnemonic becomes
                 code 0 (NOTQRS).
      codes      annotation codes, used instead of ``symbols``
      subtypes, chans, nums
                 subtype, channel and annotator number: one value for all
                 annotations, or one per annotation. Default: 0.
      aux        list of auxiliary texts, with None where there is none.
                 Texts longer than 255 bytes are cut. Default: none.
      fs         if given, written to the file as the frequency in which the
                 times are counted
      sort       True to always sort, False to keep the order you gave
                 (without the library's advice to run sortann), None (the
                 default) to follow WFDBANNSORT
      dir        directory in which to create the file. It must exist, and
                 ``record`` must then be a plain name.
      legacy     True to behave as the original WFDB package (see the module
                 help)

    Returns:
      None

    Raises:
      ValueError         if neither symbols nor codes is given, or if record
                         contains a directory and dir is given
      FileNotFoundError  if dir does not exist
      IOError            if the annotation file cannot be created, or cannot
                         be written completely ("write error on annotator A
                         for record R")

    Example (writes the annotation file rand.test, for the record rand
    written in the example of write_record, in the output directory)::

        wfdbx.write_annotations("rand", "test", [100, 460, 820],
                                symbols=["N", "V", "N"],
                                aux=[None, "(VT", None])

    Part of WFDB-x; not in the original WFDB package.
    """
    import numpy as np
    n = len(samples)
    if codes is None:
        if symbols is None:
            raise ValueError("symbols or codes must be given")
        codes = [ann.strann(s) for s in symbols]

    def ints(v):
        # v (a sequence, or a scalar for all annotations): an integer NumPy
        # array as it is, else a list of n Python ints
        if isinstance(v, np.ndarray) and v.dtype.kind in "iu":
            return v
        if isinstance(v, (list, tuple, np.ndarray)):
            return [int(x) for x in v]
        x = int(v)
        if -(1 << 63) <= x < (1 << 63):
            return np.full(n, x, np.int64)
        return [x] * n

    times = ints(samples)
    codes, subtypes, chans, nums = ints(codes), ints(subtypes), \
        ints(chans), ints(nums)
    # aux: the texts one after the other, as bytes, and the length of each
    # (0: none; cut to _MAXAUX bytes by _putanns)
    if aux is None:
        texts = [""] * n
    elif isinstance(aux, (list, tuple, np.ndarray)):
        texts = list(aux[:n])
        if None in texts:
            texts = ["" if x is None else x for x in texts]
    else:
        texts = [aux] * n
    auxes = ("".join(texts).encode("latin-1"),
             np.fromiter(map(len, texts), np.int64, len(texts)))
    init.wfdbquit()
    errors = wio.wfdbx_write_errors()
    if fs is not None:
        ann.setafreq(float(fs))
    if ann.annopen(record, [ann.Anninfo(annotator, WFDB_WRITE)], 1) < 0:
        init.wfdbquit()
        raise IOError("can't create annotator %s for record %s" %
                      (annotator, record))
    # (as putann for each annotation, but encoded at once)
    ann._putanns(0, times[:n], codes[:n], subtypes[:n], chans[:n], nums[:n],
                 auxes, packed_aux=True)
    ann._a.sort_override = None if sort is None else bool(sort)
    try:
        init.wfdbquit()
    finally:
        ann._a.sort_override = None
    if fs is not None:
        ann.setafreq(0.0)
    if wio.wfdbx_write_errors() > errors:
        raise IOError("write error on annotator %s for record %s" %
                      (annotator, record))
