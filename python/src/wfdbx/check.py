"""Check a WFDB record: its header, its signal files and its annotation files.

``check_record`` reads a record with the library's functions and reports
every problem that it finds, each with a severity:

  error    the record is damaged or does not follow the WFDB format;
           programs will read wrong data or fail
  warning  the record can be read, but something is missing or unusual,
           and may give wrong results
  info     a fact worth knowing, such as invalid (missing) samples

Example, with the sample record 100s, included with WFDB-x (the first minute
of record 100 of the MIT-BIH Arrhythmia Database, in the directory
``wfdbx.sample_data_dir()``)::

    import wfdbx
    wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())
    report = wfdbx.check_record("100s", ["atr"])
    print(report)           # one line per problem, or "no problems found"
    report.ok               # True if there is no error

It checks for problems similar to those found by Benjamin Moody's
wfdbcheck (https://github.com/bemoody/wfdbcheck).

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This library is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

# Developer notes.  check_record is a WFDB-x addition, specified in the same
# way for the seven languages (the messages, their order and the formatting of
# numbers are identical); the Python implementation is the reference.  The
# checks were designed for WFDB-x; no code or text of wfdbcheck was used.
# The record is read with the library's functions (isigopen, getvec in bulk,
# getseginfo, annopen, getann, annstr); the header file's text is read only
# for the checks of its lines and of the record name.

import os

from . import _signal as sig
from . import _annot as ann
from . import _wfdbinit as init
from . import _wfdbio as wio
from ._wfdbio import WFDB_READ
from .highlevel import _input_options

__all__ = ["CheckReport", "Issue", "check_record"]

_INT32_MAX = 2147483647
# Bits that each storage format can store (formats 8 and 0: no limit).
_CAPACITY = {80: 8, 508: 8, 310: 10, 311: 10, 212: 12, 16: 16, 61: 16,
             160: 16, 516: 16, 24: 24, 524: 24, 32: 32}
_FILE_CHARS = frozenset("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
                        "0123456789_-./")
_CHUNK_SAMPLES = 1 << 20    # samples (frames x signals) read at a time


class Issue:
    """A problem found by check_record.

    Attributes:
      severity  "error", "warning" or "info"
      code      a stable identifier, such as "checksum" or "gain_missing"
      where     "" (the record), "signal N", "segment SEG",
                "segment SEG, signal N" or "annotator ANN"
      message   the description of the problem
    """

    __slots__ = ("severity", "code", "where", "message")

    def __init__(self, severity, code, where, message):
        self.severity = severity
        self.code = code
        self.where = where
        self.message = message

    def __str__(self):
        if self.where:
            return "%s: %s: %s" % (self.severity, self.where, self.message)
        return "%s: %s" % (self.severity, self.message)

    def __repr__(self):
        return "Issue(%r, %r, %r, %r)" % (self.severity, self.code,
                                          self.where, self.message)

    def __eq__(self, other):
        return isinstance(other, Issue) and \
            (self.severity, self.code, self.where, self.message) == \
            (other.severity, other.code, other.where, other.message)


class CheckReport:
    """The result of check_record.

    Attributes:
      record  the record name, as given
      ok      True if no issue has the severity "error"
      issues  list of Issue objects, in the order of the checks

    ``str(report)`` is the text form: one line per issue,
    "SEVERITY: WHERE: MESSAGE" (without "WHERE: " for the record itself),
    or "no problems found". ``report.lines()`` returns the lines as a list.
    """

    def __init__(self, record, issues):
        self.record = record
        self.issues = list(issues)
        self.ok = not any(i.severity == "error" for i in self.issues)

    def lines(self):
        """The text form of the report, as a list of lines."""
        if not self.issues:
            return ["no problems found"]
        return [str(i) for i in self.issues]

    def __str__(self):
        return "\n".join(self.lines())

    def __repr__(self):
        return "CheckReport(record=%r, ok=%r, issues=%d)" % (
            self.record, self.ok, len(self.issues))


# ---------------------------------------------------------------------------
# Text of the messages

def _q(name):
    """A name quoted for a message: in double quotes, with each byte below
    32 or above 126 shown as \\xHH (lowercase hex)."""
    out = []
    for c in name or "":
        o = ord(c)
        if o < 32 or o > 126:
            out.append("\\x%02x" % (o & 0xFF))
        else:
            out.append(c)
    return '"' + "".join(out) + '"'


def _n(k, word):
    # "1 frame", "2 frames"
    return "%d %s%s" % (k, word, "" if k == 1 else "s")


def _count(k, noun, verb_one, verb_many, what, one, first):
    """A message about k items: "1 NOUN VERB WHAT: ONE" or "K NOUNs VERB
    WHAT; the first is FIRST"."""
    if k == 1:
        return "1 %s %s %s: %s" % (noun, verb_one, what, one)
    return "%d %ss %s %s; the first is %s" % (k, noun, verb_many, what, first)


def _g(x):
    return "%g" % x


def _int16(x):
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def _has_control(s):
    return any(ord(c) < 32 or ord(c) == 127 for c in s)


def _is_number(s):
    """True if s is only a number: an optional sign, digits with at most one
    '.', and at least one digit."""
    if s[:1] in ("+", "-"):
        s = s[1:]
    if s.count(".") > 1:
        return False
    digits = s.replace(".", "")
    return digits != "" and all("0" <= c <= "9" for c in digits)


class _Report:
    def __init__(self):
        self.issues = []

    def add(self, severity, code, where, message):
        self.issues.append(Issue(severity, code, where, message))


def _at(prefix, sub):
    # "segment s1" + "signal 0" -> "segment s1, signal 0"
    if prefix and sub:
        return prefix + ", " + sub
    return prefix or sub


# ---------------------------------------------------------------------------
# The header file

def _header_text(name):
    """The bytes of the header file that the library reads for record
    `name`, and the record name that its file name gives (the file name
    without directory and ".hea"); None if there is none (no such file, or
    a record read from another format, such as EDF)."""
    q = len(name) - 1
    while q > 0 and name[q] not in "./:\\":
        q -= 1
    if q >= 0 and name[q:q + 1] == ".":
        if name[q + 1:] != "hea":
            return None             # (EDF: no WFDB header)
        f = wio.wfdb_open(None, name, WFDB_READ)
    else:
        f = wio.wfdb_open("hea", name, WFDB_READ)
    if f is None:
        return None
    path = wio.get_filename() or name
    chunks = []
    while True:
        b = f.read(1 << 16)
        if not b:
            break
        chunks.append(b)
    f.close()
    base = path[len(wio._dirname(path)):]
    if base.endswith(".hea"):
        base = base[:-4]
    elif base.startswith("hea."):
        base = base[4:]
    return b"".join(chunks), base, path


def _fields(line):
    # The fields of a header line, separated by spaces, tabs and CRs.
    return [f for f in line.replace("\t", " ").replace("\r", " ").split(" ")
            if f]


def _record_line(text):
    """The fields of the record line of a header (the first line whose
    first field does not begin with '#'), or None."""
    for line in text.split(b"\n"):
        fields = _fields(line.decode("latin-1"))
        if fields and not fields[0].startswith("#"):
            return fields
    return None


def _check_text(hdr, where, rep):
    """Checks 1.5-1.7: the lines of the header file and its record name."""
    text, base, _ = hdr
    lines = text.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()                 # (after the final newline)
    for k, line in enumerate(lines):
        if line.endswith(b"\r"):
            line = line[:-1]
        if len(line) > 255:
            rep.add("error", "header_line_long", where,
                    "line %d of the header is longer than 255 characters" %
                    (k + 1))
    for k, line in enumerate(lines):
        if any(b > 127 for b in line):
            rep.add("warning", "header_not_ascii", where,
                    "line %d of the header contains non-ASCII characters" %
                    (k + 1))
            break
    fields = _record_line(text)
    if fields:
        x = fields[0][:1] + fields[0][1:].split("/", 1)[0]
        if x != base:
            rep.add("warning", "header_name", where,
                    "the header names the record %s, but its file name is %s"
                    % (_q(x), _q(base)))


def _header_length(text):
    # The length (number of samples) on the record line: 0 if not given.
    fields = _record_line(text) if text is not None else None
    if not fields or len(fields) < 4:
        return 0
    v = fields[3]
    k = 0
    while k < len(v) and "0" <= v[k] <= "9":
        k += 1
    return int(v[:k]) if k else 0


# ---------------------------------------------------------------------------
# Signal specifications (section 2)

def _check_specs(si, opened_as, prefix, rep, skip_null):
    """Checks 2.1-2.13 of the signals si of a record opened under the name
    opened_as.  skip_null: signals of format 0 are not checked (a segment
    of a multi-segment record).  Returns nothing."""
    descs = []                  # (description, order) of the signals checked
    for s, info in enumerate(si):
        null = info.fmt == 0
        if null and skip_null:
            continue
        where = _at(prefix, "signal %d" % s)
        desc = info.desc
        if desc is None or desc == "" or \
                desc == "record %s, signal %d" % (opened_as, s):
            rep.add("warning", "desc_missing", where,
                    "the signal has no description")
        else:
            descs.append(desc)
            if _is_number(desc):
                rep.add("warning", "desc_number", where,
                        "the description %s is only a number" % _q(desc))
            if _has_control(desc):
                rep.add("error", "desc_control", where,
                        "the description %s contains control characters" %
                        _q(desc))
        if info.fmt == 8:
            rep.add("warning", "format_difference", where,
                    "format 8 stores first differences, which cannot follow "
                    "steep slopes")
        if info.gain == 0:
            rep.add("warning", "gain_missing", where,
                    "the signal is uncalibrated (no gain is given)")
        elif info.gain < 0:
            rep.add("info", "gain_negative", where,
                    "the gain is negative (%s)" % _g(info.gain))
        if info.gain != 0 and not info.units:
            rep.add("warning", "units_missing", where,
                    "the units are not specified")
        if info.units and _has_control(info.units):
            rep.add("error", "units_control", where,
                    "the units %s contain control characters" %
                    _q(info.units))
        b = info.adcres
        cap = None if null else _CAPACITY.get(info.fmt)
        if b == 0:
            rep.add("warning", "adcres_missing", where,
                    "the ADC resolution is not specified")
        elif cap is not None and b > cap:
            rep.add("error", "adcres_too_large", where,
                    "the ADC resolution (%d bits) exceeds what format %d can "
                    "store (%d bits)" % (b, info.fmt, cap))
        elif cap is not None and b >= 1:
            lo, hi = _adc_range(info)
            fmin, fmax = -(1 << (cap - 1)), (1 << (cap - 1)) - 1
            if lo < fmin or hi > fmax:
                rep.add("error", "adc_range", where,
                        "the ADC range (%d to %d) does not fit in format %d "
                        "(%d to %d)" % (lo, hi, info.fmt, fmin, fmax))
        fname = info.fname or ""
        if not null and fname not in ("-", "~") and \
                not set(fname) <= _FILE_CHARS:
            rep.add("warning", "filename", where,
                    "the signal file name %s contains characters other than "
                    "letters, digits, '_', '-' and '.'" % _q(fname))
    seen = {}
    for d in descs:
        seen[d] = seen.get(d, 0) + 1
    for d, k in seen.items():
        if k > 1:
            rep.add("warning", "desc_duplicate", prefix,
                    "%d signals have the description %s" % (k, _q(d)))


def _adc_range(info):
    b = info.adcres
    return info.adczero - (1 << (b - 1)), info.adczero + (1 << (b - 1)) - 1


# ---------------------------------------------------------------------------
# Signal data (section 3)

def _check_data(name, si, prefix, ns, length_missing, rep):
    """Checks 3.1-3.9: read the signals of the record opened as `name`
    (header signals si, header length ns)."""
    import numpy as np
    n = len(si)
    if n == 0:
        return
    if any(s.fname == "-" and s.fmt != 0 for s in si):
        return                  # (the standard input: not read)
    init.wfdbquit()
    opened = []
    k = sig.isigopen(name, opened, n)
    if k < n:
        have = set(s.fname for s in opened)
        reported = []
        for s in si:
            if s.fmt != 0 and s.fname not in have and \
                    s.fname not in reported:
                reported.append(s.fname)
                rep.add("error", "file_unreadable", prefix,
                        "the signal file %s cannot be read" % _q(s.fname))
        if not reported:
            rep.add("error", "file_unreadable", prefix,
                    "the signal file %s cannot be read" % _q(si[0].fname))
        init.wfdbquit()
        return
    s_ = sig._s
    for g, ig in enumerate(s_.igd):
        size = _file_size(ig)
        if size is not None and size > _INT32_MAX:
            fname = next(s.fname for s in si if s.group == g)
            rep.add("warning", "file_large", prefix,
                    "the signal file %s has more than 2147483647 bytes, which "
                    "32-bit applications cannot handle" % _q(fname))
    sig.setgvmode(sig.WFDB_LOWRES)
    inv = sig.WFDB_INVALID_SAMPLE
    ranges = []
    for info in si:
        b = info.adcres
        ranges.append(_adc_range(info) if 1 <= b <= 32 and info.fmt != 0
                      else None)
    n_out = [0] * n
    first_out = [None] * n
    n_inv = [0] * n
    first_inv = [None] * n
    rows = max(1024, _CHUNK_SAMPLES // n)
    buf = np.empty((rows, n), np.int64)
    m = 0                       # frames read
    stat = n
    residual = None             # checksum residuals after ns frames
    # (the checksums: not for EDF, nor for a record with skewed signals,
    # whose samples the library reads ahead)
    checked = ns > 0 and not s_.isedf and \
        all(sig.wfdbgetskew(s) == 0 for s in range(n))

    s_.cksum_quiet = 1
    try:
        while True:
            want = rows
            if checked and residual is None:
                want = min(rows, ns - m)
            got, stat = sig._getframes_into(buf, 0, want,
                                            keep_checksum_frame=True)
            if got:
                block = buf[:got]
                for s in range(n):
                    if si[s].fmt == 0:
                        continue        # (a null signal: no data)
                    col = block[:, s]
                    bad = col == inv
                    if bad.any():
                        if first_inv[s] is None:
                            first_inv[s] = m + int(np.argmax(bad))
                        n_inv[s] += int(bad.sum())
                    if ranges[s] is not None:
                        lo, hi = ranges[s]
                        out = ~bad & ((col < lo) | (col > hi))
                        if out.any():
                            if first_out[s] is None:
                                j = int(np.argmax(out))
                                first_out[s] = (m + j, int(col[j]))
                            n_out[s] += int(out.sum())
                m += got
            if checked and residual is None and m >= ns:
                residual = [s_.isd[s].info.cksum for s in range(n)]
            if stat == -4:
                continue
            if got < want:
                break
    finally:
        s_.cksum_quiet = 0
    # (with skewed signals, getvec returns the frames of the files less the
    # largest skew)
    skew = max(sig.wfdbgetskew(s) for s in range(n))
    init.wfdbquit()
    if skew and m > 0:
        m += skew
    for s in range(n):
        where = _at(prefix, "signal %d" % s)
        if n_out[s]:
            lo, hi = ranges[s]
            j, v = first_out[s]
            rep.add("error", "sample_range", where, _count(
                n_out[s], "sample", "is", "are",
                "outside the ADC range (%d to %d)" % (lo, hi),
                "sample %d (value %d)" % (j, v),
                "sample %d (value %d)" % (j, v)))
        if n_inv[s]:
            j = first_inv[s]
            rep.add("info", "invalid_samples", where, _count(
                n_inv[s], "sample", "is", "are", "invalid (missing data)",
                "sample %d" % j, "sample %d" % j))
    if residual is not None:
        for s, info in enumerate(si):
            if info.nsamp > 0 and info.fmt != 0 and residual[s] & 0xFFFF:
                rep.add("error", "checksum", _at(prefix, "signal %d" % s),
                        "the checksum does not match: the header gives %d, "
                        "the samples sum to %d" %
                        (_int16(info.cksum),
                         _int16(info.cksum - residual[s])))
    end_ok = stat == -1 or stat >= 0
    short = ns > 0 and m < ns and (stat == -1 or stat == -3)
    if short:
        rep.add("error", "length_short", prefix,
                "the signal files end after %s, before the %d given in the "
                "header" % (_n(m, "frame"), ns))
    if ns > 0 and m > ns:
        rep.add("warning", "length_long", prefix,
                "the signal files hold %s, more than the %d given in the "
                "header" % (_n(m, "frame"), ns))
    if length_missing and end_ok:
        rep.add("info", "length_unspecified_frames", prefix,
                "the signal files hold %s" % _n(m, "frame"))
    if not end_ok and not short:
        rep.add("error", "read_error", prefix,
                "the signal data cannot be read after %s (getvec status %d)"
                % (_n(m, "frame"), stat))


def _file_size(ig):
    # The size of the local file of signal group ig, or None.
    f = ig.fp
    if f is None or f.is_std or f.type != wio.WFDB_LOCAL:
        return None
    try:
        return os.fstat(f.fp.fileno()).st_size
    except (AttributeError, OSError, ValueError):
        return None


# ---------------------------------------------------------------------------
# A record (sections 1-4)

def _open_header(name):
    """Open the header of record `name` (wfdbquit first).  Returns (nsig,
    siginfo list, fs, nsamples, segments) or None if the header cannot be
    read."""
    init.wfdbquit()
    n = sig.isigopen(name, None, 0)
    if n < 0:
        init.wfdbquit()
        return None
    si = []
    if n > 0:
        sig.isigopen(name, si, -n)
    s_ = sig._s
    segs = [(x.recname, x.nsamp) for x in sig.getseginfo()]
    nsamples = s_.msnsamples if s_.in_msrec or segs else s_.nsamples
    fs = sig.sampfreq(None)
    init.wfdbquit()
    return n, si, fs, nsamples, segs


def _check_single(record, info, hdr, rep):
    """Sections 1.2-1.8 and 2 for a single-segment record.  Returns True if
    the header gives no length (length_missing)."""
    n, si, fs, nsamples, _ = info
    if n == 0:
        rep.add("info", "no_signals", "", "the record has no signals")
    if fs == 0:
        rep.add("warning", "fs_missing", "",
                "the sampling frequency is not specified")
    if nsamples == 0:
        rep.add("warning", "length_missing", "",
                "the record length is not specified")
    if hdr is not None:
        _check_text(hdr, "", rep)
    if nsamples > _INT32_MAX:
        rep.add("info", "length_large", "",
                "the record has more than 2147483647 samples, which 32-bit "
                "applications cannot handle")
    if n > 0:
        _check_specs(si, record, "", rep, False)
    return nsamples == 0


def _check_record_signals(record, rep):
    """Sections 1-4.  Returns the record length in samples for the
    annotation checks (0 if unknown), or None if the header cannot be
    read."""
    hdr = _header_text(record)
    info = _open_header(record)
    if info is None:
        rep.add("error", "header_unreadable", "", "the header cannot be read")
        if hdr is not None:
            _check_text(hdr, "", rep)
        return None
    n, si, fs, nsamples, segs = info
    if not segs:
        length_missing = _check_single(record, info, hdr, rep)
        if n > 0:
            _check_data(record, si, "", nsamples, length_missing, rep)
        return nsamples
    # A multi-segment record: the master header
    if n == 0:
        rep.add("info", "no_signals", "", "the record has no signals")
    if fs == 0:
        rep.add("warning", "fs_missing", "",
                "the sampling frequency is not specified")
    given = _header_length(hdr[0]) if hdr is not None else nsamples
    if given == 0:
        rep.add("warning", "length_missing", "",
                "the record length is not specified")
    if hdr is not None:
        _check_text(hdr, "", rep)
    if nsamples > _INT32_MAX:
        rep.add("info", "length_large", "",
                "the record has more than 2147483647 samples, which 32-bit "
                "applications cannot handle")
    # The segments, next to the master header
    hpath = hdr[2] if hdr is not None else (wio.wfdbfile("hea", record) or "")
    d = wio._dirname(hpath)
    if d and not wio._is_url(d) and not os.path.isabs(d):
        d = os.path.abspath(d) + os.sep
    elif not d:
        d = os.path.abspath(".") + os.sep
    variable = segs[0][1] == 0
    layout_descs = None
    done = set()
    for k, (seg, seg_len) in enumerate(segs):
        if seg == "~" or seg in done:
            continue
        done.add(seg)
        prefix = "segment %s" % seg
        is_layout = variable and k == 0
        if not wio._in_header_dir(seg):
            rep.add("error", "segment_unreadable", prefix,
                    "the segment cannot be read")
            continue
        path = d + seg
        seg_hdr = _header_text(path)
        sinfo = _open_header(path)
        if sinfo is not None and sinfo[4]:
            rep.add("error", "nested", prefix,
                    "the segment is itself a multi-segment record")
            continue
        if sinfo is None:
            rep.add("error", "segment_unreadable", prefix,
                    "the segment cannot be read")
            continue
        sn, ssi, sfs, sns, _ = sinfo
        if sfs > 0 and fs > 0 and sfs != fs:
            rep.add("error", "segment_fs", prefix,
                    "the segment's sampling frequency (%s) differs from the "
                    "record's (%s)" % (_g(sfs), _g(fs)))
        if sn == 0:
            rep.add("info", "no_signals", prefix, "the record has no signals")
        if seg_hdr is not None:
            _check_text(seg_hdr, prefix, rep)
        if sns > _INT32_MAX:
            rep.add("info", "length_large", prefix,
                    "the record has more than 2147483647 samples, which "
                    "32-bit applications cannot handle")
        if sn > 0:
            _check_specs(ssi, path, prefix, rep, not is_layout)
        if is_layout:
            layout_descs = set(s.desc for s in ssi)
            continue
        if variable:
            for s, x in enumerate(ssi):
                if x.fmt != 0 and x.desc not in (layout_descs or ()):
                    rep.add("error", "layout_missing_signal",
                            _at(prefix, "signal %d" % s),
                            "the signal %s is not in the layout" %
                            _q(x.desc))
        else:
            _check_layout(ssi, si, prefix, rep)
        if sn > 0:
            _check_data(path, ssi, prefix, sns, False, rep)
    total = sum(x[1] for x in segs)
    if given > 0 and total != given:
        rep.add("warning", "segment_lengths", "",
                "the segment lengths add up to %s, but the master header "
                "gives %d" % (_n(total, "sample"), given))
    return total            # (the end of the signals)


def _check_layout(ssi, si, prefix, rep):
    """Check 4.4: the signals of a segment of a fixed-layout record match
    the record's signals."""
    if len(ssi) != len(si):
        rep.add("error", "layout_signals", prefix,
                "the segment has %s, but the record has %d" %
                (_n(len(ssi), "signal"), len(si)))
    for s in range(min(len(ssi), len(si))):
        a, b = ssi[s], si[s]
        if a.fmt == 0:
            continue
        where = _at(prefix, "signal %d" % s)
        for field, x, y in (
                ("description", _q(a.desc), _q(b.desc)),
                ("units", _q(a.units), _q(b.units)),
                ("gain", _g(a.gain), _g(b.gain)),
                ("baseline", "%d" % a.baseline, "%d" % b.baseline),
                ("samples per frame", "%d" % a.spf, "%d" % b.spf)):
            if x != y:
                rep.add("error", "layout_mismatch", where,
                        "the signal differs from the record's signal %d in "
                        "its %s (%s, expected %s)" % (s, field, x, y))


# ---------------------------------------------------------------------------
# Annotators (section 5)

def _check_annotator(record, an, length, rep):
    where = "annotator %s" % an
    if an != "" and all("0" <= c <= "9" for c in an):
        rep.add("warning", "annotator_name", where,
                "the annotator name consists only of digits")
    init.wfdbquit()
    if length is not None:
        sig.sampfreq(record)    # (the record's frequency, for getann)
    saved = (list(ann._astring), list(ann._tstring), list(ann._a.modified))
    try:
        if ann.annopen(record, [ann.Anninfo(an, WFDB_READ)], 1) < 0:
            rep.add("error", "annotations_unreadable", where,
                    "the annotation file cannot be read")
            return
        a = ann.Annotation()
        count = 0
        prev = None
        order = [0, None]
        code = [0, None]
        null = [0, None]
        undef = [0, None]
        after = [0, None]
        while True:
            stat = ann.getann(0, a)
            if stat != 0:
                break
            count += 1
            t, c = a.time, a.anntyp
            if prev is not None and t < prev:
                order[0] += 1
                if order[1] is None:
                    order[1] = (t, prev)
            prev = t
            if c > ann.ACMAX:
                code[0] += 1
                if code[1] is None:
                    code[1] = (t, c)
            elif c == 0:
                null[0] += 1
                if null[1] is None:
                    null[1] = t
            elif ann.annstr(c) == "[%d]" % c:
                undef[0] += 1
                if undef[1] is None:
                    undef[1] = (t, c)
            if length and t >= length:
                after[0] += 1
                if after[1] is None:
                    after[1] = t
    finally:
        init.wfdbquit()
        ann._astring[:], ann._tstring[:], ann._a.modified[:] = saved
    if stat != -1:
        rep.add("error", "annotations_truncated", where,
                "the annotation file ends unexpectedly after %s" %
                _n(count, "annotation"))
    if order[0]:
        s, p = order[1]
        x = "at sample %d, after sample %d" % (s, p)
        rep.add("error", "annotations_order", where, _count(
            order[0], "annotation", "is", "are", "out of order", x, x))
    if code[0]:
        x = "at sample %d (code %d)" % code[1]
        rep.add("error", "annotation_code", where, _count(
            code[0], "annotation", "has", "have", "an invalid code", x, x))
    if null[0]:
        x = "at sample %d" % null[1]
        rep.add("warning", "annotation_null", where, _count(
            null[0], "annotation", "has", "have", "code 0 (NOTQRS)", x, x))
    if undef[0]:
        x = "at sample %d (code %d)" % undef[1]
        if undef[0] == 1:
            msg = "1 annotation uses a code without a mnemonic: " + x
        else:
            msg = "%d annotations use codes without a mnemonic; the first " \
                "is %s" % (undef[0], x)
        rep.add("warning", "annotation_undefined", where, msg)
    if after[0]:
        x = "at sample %d" % after[1]
        rep.add("warning", "annotations_after_end", where, _count(
            after[0], "annotation", "is", "are",
            "after the end of the record (%s)" % _n(length, "sample"), x, x))


# ---------------------------------------------------------------------------

@_input_options
def check_record(record, annotators=(), *, input_dir=None, network=None):
    """Check a record and its annotation files, and report every problem.

    The header, the signal specifications, the signal files (all samples
    are read) and the given annotation files are checked. Problems in the
    record never raise an exception: they are reported.

    Arguments:
      record      record name: a name in the input directory, or a full
                  path, ~ path or URL (as for read_record)
      annotators  annotator names to check, such as ["atr"] (one name may
                  be given as a string). Default: none.
      input_dir   input directory for this call only (see read_record)
      network     True to allow reading URLs for this call only (see
                  read_record)

    Returns:
      a CheckReport. ``report.ok`` is True if there is no error;
      ``report.issues`` lists the problems (Issue objects, with severity,
      code, where and message); ``print(report)`` prints one line per
      problem, such as::

          error: signal 1: the checksum does not match: the header gives 12, the samples sum to 13

      or "no problems found".

    Severities: "error" (the record is damaged or does not follow the WFDB
    format), "warning" (something is missing or unusual, and may give wrong
    results) and "info" (a fact worth knowing). The checks run in normal
    mode, even if legacy mode is on, and the library prints no messages
    during the call.

    Raises:
      TypeError   if record is not a string, or an annotator name is not a
                  string
      ValueError  if record is empty

    Example (100s is the sample record included with WFDB-x: the first
    minute of record 100 of the MIT-BIH Arrhythmia Database, in the
    directory wfdbx.sample_data_dir())::

        wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())
        report = wfdbx.check_record("100s", ["atr"])
        print(report)
        if not report.ok:
            ...

    It checks for problems similar to those found by Benjamin Moody's
    wfdbcheck (https://github.com/bemoody/wfdbcheck).

    Part of WFDB-x; not in the original WFDB package.
    """
    if not isinstance(record, str):
        raise TypeError("record must be a string")
    if not record:
        raise ValueError("record must not be empty")
    if isinstance(annotators, str):
        annotators = [annotators]
    annotators = list(annotators)
    for a in annotators:
        if not isinstance(a, str):
            raise TypeError("annotator names must be strings")
    rep = _Report()
    legacy = sig.wfdbx_set_legacy(0)
    printing = wio._io.error_print
    wio._io.error_print = False
    try:
        init.wfdbquit()
        length = _check_record_signals(record, rep)
        for a in annotators:
            _check_annotator(record, a, length, rep)
    finally:
        init.wfdbquit()
        wio._io.error_print = printing
        sig.wfdbx_set_legacy(legacy)
    return CheckReport(record, rep.issues)
