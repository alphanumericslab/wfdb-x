"""The corpus of records for check_record: one broken record for each issue
code, a clean record, records of tests/data and annotation files.

Run as a script, it writes the corpus into a directory, the list of cases
(cases.txt: one case per line, the record name then the annotator names,
separated by spaces) and the report of the Python implementation for each
case (expected.txt: a line "== RECORD ANN..." then the lines of the report),
so that the seven languages can be compared line by line:

    python check_corpus.py DIR [TESTS_DATA_DIR]

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import math
import os
import shutil
import struct
import sys

# ---------------------------------------------------------------------------
# Signal files, written byte by byte (no library needed)

N = 1000            # frames of the records of the corpus
FS = 250


def _samples(n=N, nsig=2):
    """n frames of nsig signals: smooth integer waveforms within +-1000."""
    return [[int(round(900 * math.sin(2 * math.pi * (s + 1) * t / 250.0)))
             for s in range(nsig)] for t in range(n)]


def _dat16(frames):
    return b"".join(struct.pack("<%dh" % len(f), *f) for f in frames)


def _dat212(frames):
    flat = [v for f in frames for v in f]
    out = bytearray()
    for k in range(0, len(flat) - 1, 2):
        a, b = flat[k] & 0xFFF, flat[k + 1] & 0xFFF
        out += bytes((a & 0xFF, (a >> 8) | ((b >> 8) << 4), b & 0xFF))
    if len(flat) % 2:
        a = flat[-1] & 0xFFF
        out += bytes((a & 0xFF, a >> 8))
    return bytes(out)


def _dat8(frames, initvals):
    out = bytearray()
    prev = list(initvals)
    for f in frames:
        for s, v in enumerate(f):
            d = v - prev[s]
            assert -128 <= d <= 127
            out.append(d & 0xFF)
            prev[s] = v
    return bytes(out)


def _cksum(frames, s):
    x = sum(f[s] for f in frames) & 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def _write(d, name, data):
    mode = "wb" if isinstance(data, bytes) else "w"
    kw = {} if mode == "wb" else {"newline": "\n", "encoding": "latin-1"}
    with open(os.path.join(d, name), mode, **kw) as f:
        f.write(data)


def _record(d, name, frames=None, fmt=16, nsig=2, fs=FS, length=None,
            descs=("ECG I", "ECG II"), gain="200/mV", adcres=12, adczero=0,
            cksums=None, fname=None, header_name=None, comments=(),
            sig_lines=None, data=None):
    """Write the header (and signal file) of a record.  length None: the
    number of frames; "" for none.  sig_lines: the signal lines as given."""
    if frames is None:
        frames = _samples(nsig=nsig)
    fname = fname or name + ".dat"
    if data is None:
        if fmt == 16:
            data = _dat16(frames)
        elif fmt == 212:
            data = _dat212(frames)
        elif fmt == 8:
            data = _dat8(frames, frames[0])
    if data is not False:
        _write(d, fname, data)
    if length is None:
        length = len(frames)
    rec_line = "%s %d" % (header_name or name, nsig)
    if fs is not None:
        rec_line += " %s" % fs
        if length != "":
            rec_line += " %s" % length
    lines = [rec_line]
    if sig_lines is not None:
        lines += sig_lines
    else:
        for s in range(nsig):
            ck = cksums[s] if cksums else _cksum(frames, s)
            g = gain[s] if isinstance(gain, (list, tuple)) else gain
            desc = descs[s] if descs and s < len(descs) else None
            line = "%s %d %s %d %d %d %d 0" % (
                fname, fmt, g, adcres, adczero, frames[0][s], ck)
            if desc is not None:
                line += " " + desc
            lines.append(line)
    lines += list(comments)
    _write(d, name + ".hea", "\n".join(lines) + "\n")


def _multi(d, name, segments, nsig=2, fs=FS, length=None):
    if length is None:
        length = sum(n for _, n in segments)
    lines = ["%s/%d %d %s %s" % (name, len(segments), nsig, fs, length)]
    lines += ["%s %d" % s for s in segments]
    _write(d, name + ".hea", "\n".join(lines) + "\n")


# ---------------------------------------------------------------------------
# Annotation files (MIT format), word by word

def _ann_words(anns):
    """The bytes of an MIT annotation file: anns is a list of (time, code,
    aux); times may go backwards (written with SKIPs)."""
    out = bytearray()

    def w16(x):
        out.extend(struct.pack("<H", x & 0xFFFF))

    prev = 0
    for t, code, aux in anns:
        delta = t - prev
        if delta < 0 or delta > 1023:
            w16(59 << 10)
            w16((delta >> 16) & 0xFFFF)
            w16(delta & 0xFFFF)
            delta = 0
        w16((code << 10) | delta)
        if aux:
            b = aux.encode("latin-1")
            w16((63 << 10) | len(b))
            out.extend(b + b"\0" * (len(b) & 1))
        prev = t
    w16(0)
    return bytes(out)


GOOD_ANNS = [(18, 28, "(N"), (77, 1, None), (370, 1, None), (660, 5, None),
             (950, 1, None)]


# ---------------------------------------------------------------------------
# The corpus

def make_corpus(d, data_dir=None):
    """Write the corpus into the directory d (created if needed) and return
    the list of cases (record, [annotators])."""
    os.makedirs(d, exist_ok=True)
    cases = []
    fr = _samples()

    def case(record, *anns):
        cases.append((record, list(anns)))

    # A clean record, with good and broken annotation files
    _record(d, "clean", fr)
    _write(d, "clean.atr", _ann_words(GOOD_ANNS))
    _write(d, "clean.123", _ann_words(GOOD_ANNS))
    _write(d, "clean.trunc", _ann_words(GOOD_ANNS)[:-4])
    _write(d, "clean.ooo", _ann_words([(100, 1, None), (50, 1, None),
                                       (200, 1, None), (150, 5, None),
                                       (120, 1, None)]))
    _write(d, "clean.badc", _ann_words([(10, 1, None), (20, 55, None),
                                        (30, 52, None)]))
    _write(d, "clean.nulc", _ann_words([(10, 1, None), (20, 0, None)]))
    _write(d, "clean.undef", _ann_words([(10, 42, None), (20, 15, None),
                                         (30, 1, None)]))
    _write(d, "clean.late", _ann_words([(10, 1, None), (999, 1, None),
                                        (1000, 1, None), (5000, 1, None)]))
    case("clean")
    case("clean", "atr")
    case("clean", "atr", "123", "nofile", "trunc", "ooo", "badc", "nulc",
         "undef", "late")

    # Section 1: the header
    _write(d, "h_unread.hea", "h_unread 1 250 1000\nh_unread.dat 999 200/mV "
           "12 0 0 0 0 x\n")
    _write(d, "h_unread.atr", _ann_words(GOOD_ANNS))
    case("h_unread", "atr")
    case("missing")
    _write(d, "nosig.hea", "nosig 0 250 1000\n")
    case("nosig")
    _record(d, "nofs", fr, fs=None)
    case("nofs")
    _record(d, "nolen", fr, length="")
    case("nolen")
    _record(d, "h_long", fr, comments=["# " + "x" * 300, "# short",
                                       "# " + "y" * 254])
    case("h_long")
    _record(d, "h_ascii", fr, comments=["# ok", "# caf\xe9", "# na\xefve"])
    case("h_ascii")
    _record(d, "hname", fr, header_name="hnam")
    case("hname")
    _record(d, "h_wrong", fr, header_name="other",
            comments=["# " + "z" * 260])
    case("h_wrong")
    _record(d, "h_large", fr, length=3000000000)
    case("h_large")

    # Section 2: the signal specifications
    _record(d, "s_desc", fr, descs=None)
    case("s_desc")
    _record(d, "s_descnum", fr, descs=("2", "-1.5"))
    case("s_descnum")
    _record(d, "s_descctl", fr, descs=("ECG\tI", "ECG II"))
    case("s_descctl")
    _record(d, "s_fmt8", fr, fmt=8)
    case("s_fmt8")
    _record(d, "s_gain0", fr, gain="0")
    case("s_gain0")
    _record(d, "s_gainneg", fr, gain=("-200.5/mV", "200/mV"))
    case("s_gainneg")
    _record(d, "s_units", fr, gain="200")
    case("s_units")
    _record(d, "s_unitsctl", fr, gain=("200/m\x01V", "200/mV"))
    case("s_unitsctl")
    _record(d, "s_nores", fr, sig_lines=["s_nores.dat 16 200/mV",
                                         "s_nores.dat 16 200/mV"])
    case("s_nores")
    _record(d, "s_bigres", fr, fmt=212, adcres=16)
    case("s_bigres")
    _record(d, "s_range", fr, adcres=16, adczero=100)
    case("s_range")
    _record(d, "s_fname", fr, fname="s_f@name.dat")
    case("s_fname")
    _record(d, "s_dup", _samples(nsig=3), nsig=3,
            descs=("ECG", "ECG", "ECG"))
    case("s_dup")

    # Section 3: the signal data
    _record(d, "d_nofile", fr, fname="d_nofile_missing.dat", data=False)
    case("d_nofile")
    big = [list(f) for f in fr]
    big[10][0] = 3000
    big[20][0] = -2049
    big[30][1] = 2048
    _record(d, "d_range", big)
    case("d_range")
    inv = [list(f) for f in fr]
    for t in (5, 6, 7, 500):
        inv[t][1] = -32768
    _record(d, "d_invalid", inv)
    case("d_invalid")
    _record(d, "d_cksum", fr, cksums=(_cksum(fr, 0), _cksum(fr, 1) + 1))
    case("d_cksum")
    _record(d, "d_short", fr, data=_dat16(fr[:900]))
    case("d_short")
    _record(d, "d_long", fr[:900], data=_dat16(fr))
    case("d_long")

    # a skewed signal (getvec returns 997 frames; the files hold 1000)
    _record(d, "d_skew", fr)
    p = os.path.join(d, "d_skew.hea")
    with open(p) as f:
        lines = f.read().split("\n")
    lines[2] = lines[2].replace(" 16 ", " 16:3 ", 1)
    _write(d, "d_skew.hea", "\n".join(lines))
    case("d_skew")
    _record(d, "d_skewlong", fr[:900], data=_dat16(fr))
    p = os.path.join(d, "d_skewlong.hea")
    with open(p) as f:
        lines = f.read().split("\n")
    lines[1] = lines[1].replace(" 16 ", " 16:2 ", 1)
    _write(d, "d_skewlong.hea", "\n".join(lines))
    case("d_skewlong")

    # Section 3.9: a read error (a damaged FLAC file, no length given)
    _flac_record(d, fr)
    case("d_flac")

    # Section 4: multi-segment records
    _record(d, "seg_a", fr[:500], data=_dat16(fr[:500]))
    _record(d, "seg_b", fr[500:], data=_dat16(fr[500:]))
    _record(d, "seg_fs", fr[:500], fs=500)
    _record(d, "seg_gain", fr[:500], gain=("200/mV", "100/mV"),
            descs=("ECG I", "ECG 2"))
    _record(d, "seg_one", _samples(500, 1), nsig=1)
    _multi(d, "m_ok", [("seg_a", 500), ("seg_b", 500)])
    case("m_ok")
    _multi(d, "m_inner", [("seg_a", 500), ("seg_b", 500)])
    _multi(d, "m_nest", [("seg_a", 500), ("m_inner", 1000)])
    case("m_nest")
    _multi(d, "m_unread", [("seg_a", 500), ("seg_missing", 500),
                           ("~", 100)])
    case("m_unread")
    _multi(d, "m_fs", [("seg_a", 500), ("seg_fs", 500)])
    case("m_fs")
    _multi(d, "m_layout", [("seg_a", 500), ("seg_gain", 500),
                           ("seg_one", 500)])
    case("m_layout")
    _write(d, "v_layout.hea", "v_layout 2 250 0\n"
           "~ 0 200/mV 12 0 0 0 0 ECG I\n~ 0 200/mV 12 0 0 0 0 ECG II\n")
    _multi(d, "m_var", [("v_layout", 0), ("seg_a", 500), ("seg_gain", 500),
                        ("~", 100)])
    case("m_var")
    _multi(d, "m_len", [("seg_a", 500), ("seg_b", 500)], length=1500)
    case("m_len", "atr")
    _write(d, "m_len.atr", _ann_words(GOOD_ANNS + [(1200, 1, None)]))

    # Records of tests/data
    if data_dir and os.path.isdir(data_dir):
        for f in ("100s.hea", "100s.dat", "100s.atr", "fms.hea", "fmt16.hea",
                  "fmt16.dat", "fmt212.hea", "fmt212.dat", "multi.hea",
                  "null.hea", "vlay.hea", "vlay_0.hea"):
            shutil.copy(os.path.join(data_dir, f), os.path.join(d, f))
        case("100s", "atr")
        case("fms")
        case("multi")
        case("vlay")
    return cases


def _wfdbx():
    """The wfdbx package: the one importable, or that of python/src next to
    this file (in the repository)."""
    try:
        import wfdbx
    except ImportError:
        sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
            os.path.abspath(__file__))), "src"))
        import wfdbx
    return wfdbx


def _flac_record(d, fr):
    """d_flac: a FLAC (format 516) record whose file is damaged, and whose
    header gives no length (written with wfdbx)."""
    import numpy as np
    wfdbx = _wfdbx()
    wfdbx.write_record("d_flac", np.array(fr), fs=FS, fmt=516, gains=200,
                       adcres=12, units="mV", names=["ECG I", "ECG II"],
                       dir=d)
    p = os.path.join(d, "d_flac.dat")
    with open(p, "rb") as f:
        data = bytearray(f.read())
    data[200:260] = b"\xff" * 60
    with open(p, "wb") as f:
        f.write(bytes(data))
    p = os.path.join(d, "d_flac.hea")
    with open(p) as f:
        lines = f.read().split("\n")
    lines[0] = "d_flac 2 %d" % FS
    with open(p, "w", newline="\n") as f:
        f.write("\n".join(lines))


def write_expected(d, cases):
    """Write cases.txt and expected.txt (the Python reports) into d."""
    wfdbx = _wfdbx()
    with open(os.path.join(d, "cases.txt"), "w", newline="\n") as f:
        for rec, anns in cases:
            f.write(" ".join([rec] + anns) + "\n")
    with open(os.path.join(d, "expected.txt"), "w", newline="\n",
              encoding="ascii") as f:
        for rec, anns in cases:
            f.write("== " + " ".join([rec] + anns) + "\n")
            report = wfdbx.check_record(rec, anns, input_dir=d)
            for line in report.lines():
                f.write(line + "\n")


def main(argv):
    if len(argv) < 2:
        print("usage: check_corpus.py DIR [TESTS_DATA_DIR]", file=sys.stderr)
        return 2
    d = os.path.abspath(argv[1])
    here = os.path.dirname(os.path.abspath(__file__))
    data = argv[2] if len(argv) > 2 else \
        os.path.join(os.path.dirname(os.path.dirname(here)), "tests", "data")
    if not os.path.isdir(data):
        data = os.path.join("tests", "data")
    cases = make_corpus(d, data)
    write_expected(d, cases)
    print("%d cases written to %s" % (len(cases), d))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
