"""Signal I/O tests: every storage format round-trips exactly.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
tests WFDB-x; it has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import os

import numpy as np
import pytest

import wfdbx as w

RANGES = {8: 1000, 16: 32767, 61: 32767, 80: 127, 160: 32767, 212: 2047,
          310: 511, 311: 511, 24: 8388607, 32: 2147483647, 508: 127,
          516: 32767, 524: 8388607}
# ADC resolutions written with each format (wfdb-x: write_record requires
# them)
RES = {8: 12, 16: 16, 61: 16, 80: 8, 160: 16, 212: 12, 310: 10, 311: 10,
       24: 24, 32: 32, 508: 8, 516: 16, 524: 24}


@pytest.mark.parametrize("fmt", sorted(RANGES))
@pytest.mark.parametrize("nsig", [1, 2, 3])
def test_roundtrip(datadir, fmt, nsig):
    rng = np.random.default_rng(fmt * 10 + nsig)
    hi = RANGES[fmt]
    n = 5003 if fmt >= 500 else 1001
    if fmt == 8:
        x = np.cumsum(rng.integers(-60, 61, size=(n, nsig)), axis=0)
    else:
        x = rng.integers(-hi + 1, hi + 1, size=(n, nsig))
    w.write_record("rt", x, 250, fmt=fmt, gains=200, adcres=RES[fmt],
                   units="mV")
    r = w.read_record("rt")
    y = r.signals
    if fmt in (310, 311) and (n * nsig) % 3 == 2:
        # A final group of two samples is written in 4 bytes, so the file
        # appears to contain an extra (zero) sample, as with the C library.
        assert y[-1].tolist() == [0] * nsig
        y = y[:-1]
    assert np.array_equal(y, x)
    # random access with the per-sample interface
    w.isigopen("rt", None, nsig)
    for t in (n - 1, 0, n // 2, 3, n - 2):
        assert [w.sample(s, t) for s in range(nsig)] == list(x[t])
    w.wfdbquit()


def test_bulk_equals_getvec(datadir):
    for rec in ["fmt212", "fmt310", "fmt311", "fmt8", "twog", "100s"]:
        n = w.isigopen(rec, None, 0)
        w.isigopen(rec, [], n)
        v = [0] * n
        ref = []
        while w.getvec(v) >= 0:
            ref.append(list(v))
        w.wfdbquit()
        w.wfdbquiet()
        r = w.read_record(rec)
        w.wfdbverbose()
        assert r.signals.tolist() == ref


def test_physical_units(datadir):
    r = w.read_record("100s", sampto=3, physical=True)
    assert np.allclose(r.signals, [[-0.145, -0.065]] * 3)


def test_multifrequency(datadir):
    lo = w.read_record("mfreq", sampto=10)
    hi = w.read_record("mfreq", sampto=20, highres=True)
    assert lo.signals.shape == (10, 3) and hi.signals.shape == (20, 3)
    assert hi.fs == 400 and lo.fs == 100


def test_variable_layout(datadir):
    w.wfdbquiet()
    r = w.read_record("vlay", sampfrom=1498, sampto=1502)
    w.wfdbverbose()
    assert r.signals[2].tolist() == [w.WFDB_INVALID_SAMPLE] * 3


def test_header_writing(datadir):
    x = np.zeros((10, 2), np.int64)
    w.write_record("hw", x, 125.5, fmt=16, gains=[100, 0], adcres=16,
                   units=["mV", "uV"],
                   names=["lead I", "pressure"],
                   base_time="12:00:00 01/02/2003", comments=["c1"])
    text = open("hw.hea", "rb").read()
    assert text.startswith(b"hw 2 125.5 10 12:00:00 01/02/2003\r\n")
    assert b"hw.dat 16 100/mV 16 0 0 0 0 lead I\r\n" in text
    assert text.endswith(b"#c1\r\n")


# wfdb-x: no default sampling frequency, gain, ADC resolution or units (see
# docs/DIVERGENCES.md)

def test_write_record_requires_gains_and_frequency(datadir):
    x = np.zeros((10, 2), np.int64)
    with pytest.raises(ValueError, match="gains must be specified"):
        w.write_record("nd", x, 250, adcres=16, units="mV")
    with pytest.raises(ValueError, match="gains must be specified"):
        w.write_record("nd", x, 250, gains=[200, None], adcres=16,
                       units="mV")
    for fs in (0, -1.0):
        with pytest.raises(ValueError, match="sampling frequency"):
            w.write_record("nd", x, fs, gains=200, adcres=16, units="mV")
    with pytest.raises(ValueError, match="signal 1 is uncalibrated"):
        w.write_record("nd", x.astype(float), 250, gains=[200, 0],
                       adcres=16, units="mV", physical=True)
    # a gain of 0 (uncalibrated) is allowed for samples in ADC units, and
    # such a signal needs no units
    w.write_record("nd", x, 250, gains=[200, 0], adcres=16,
                   units=["mV", None])
    r = w.read_record("nd")
    assert r.gains == [200, 0] and r.units == ["mV", None]


def test_write_record_requires_resolution_and_units(datadir):
    x = np.zeros((10, 2), np.int64)
    for res in (None, [16, None], [16], 0, [16, 0]):
        with pytest.raises(ValueError,
                           match="ADC resolution\\(s\\) must be specified"):
            w.write_record("nd", x, 250, gains=200, adcres=res, units="mV")
    for u in (None, ["mV", None], ["mV", ""], ["mV"]):
        with pytest.raises(ValueError, match="units must be specified"):
            w.write_record("nd", x, 250, gains=200, adcres=12, units=u)
    w.write_record("nd", x, 250, fmt=212, gains=[200, 100], adcres=[11, 12],
                   units=["mV", "uV"])
    r = w.read_record("nd")
    assert [s.adcres for s in r.siginfo] == [11, 12]
    assert r.units == ["mV", "uV"]


def test_read_record_unspecified_resolution_and_units(datadir):
    with open("nr.hea", "w") as f:
        f.write("nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n")
    r = w.read_record("nr", sampto=10)
    assert [s.adcres for s in r.siginfo] == [0, 0]
    assert r.units == [None, None]


def _write_nofreq_record():
    with open("nf.hea", "w") as f:
        f.write("nf 2\n100s.dat 212 200 11 1024 995 21537 0 MLII\n"
                "100s.dat 212 0 11 1024 1011 -3962 0 V5\n")


def test_read_record_without_frequency(datadir):
    _write_nofreq_record()
    r = w.read_record("nf", sampfrom="s1", sampto="s4")
    assert r.fs == 0 and r.base_time is None
    assert r.signals.tolist() == \
        w.read_record("100s", sampfrom=1, sampto=4).signals.tolist()
    assert len(w.read_record("nf", sampto="e").signals) == 0
    for frm, to in (("0:1", None), (0, "1:0"), ("[10:00:00]", None),
                    ("f3", None)):
        with pytest.raises(ValueError, match="sampling frequency of record "
                           "nf is not specified"):
            w.read_record("nf", sampfrom=frm, sampto=to)


def test_read_record_uncalibrated(datadir):
    _write_nofreq_record()
    r = w.read_record("nf", channels=[0], sampto=3, physical=True)
    assert np.allclose(r.signals[:, 0], [-0.145] * 3)
    with pytest.raises(ValueError, match="signal 1 of record nf is "
                       "uncalibrated"):
        w.read_record("nf", sampto=3, physical=True)
    assert w.read_record("nf", sampto=3).gains == [200, 0]


# wfdb-x: legacy mode (the original package's defaults, on request; see
# docs/DIVERGENCES.md)

def test_write_record_legacy(datadir):
    x = np.arange(20, dtype=np.int64).reshape(10, 2)
    w.write_record("lg", x, 250, fmt=212, legacy=True)
    assert w.wfdbx_get_legacy() == 0
    r = w.read_record("lg")
    assert r.gains == [200, 200] and r.units == [None, None]
    assert [s.adcres for s in r.siginfo] == [12, 12]
    assert r.signals.tolist() == x.tolist()
    # physical units, gain 0: the default gain
    w.write_record("lg", [[1.0], [-0.5]], 360, gains=0, physical=True,
                   legacy=True)
    r = w.read_record("lg")
    assert r.signals[:, 0].tolist() == [200, -100]
    assert [s.adcres for s in r.siginfo] == [16]
    # without legacy, the same calls fail
    with pytest.raises(ValueError, match="gains must be specified"):
        w.write_record("lg", x, 250, fmt=212)


def test_read_record_legacy(datadir):
    _write_nofreq_record()
    r = w.read_record("nf", sampto="0:0.012", physical=True, legacy=True)
    assert w.wfdbx_get_legacy() == 0
    assert r.fs == 250 and len(r.signals) == 3
    # signal 1 is uncalibrated: gain 200
    assert np.allclose(r.signals[:, 0], [-0.145] * 3)
    assert np.allclose(r.signals[:, 1], (np.array(
        w.read_record("nf", sampto=3).signals[:, 1]) - 1024) / 200.0)
    assert r.gains == [200, 0]
    # the uncalibrated record null (its samples are all invalid: NaN)
    r = w.read_record("null", sampto=4, physical=True, legacy=True)
    assert r.gains == [0, 0] and np.isnan(r.signals).all()
    # the previous setting is restored, also on errors
    with pytest.raises(ValueError):
        w.read_record("nf", channels=[9], legacy=True)
    assert w.wfdbx_get_legacy() == 0
    w.wfdbx_set_legacy(1)
    try:
        w.read_record("nf", sampto=1, legacy=True)
        assert w.wfdbx_get_legacy() == 1
    finally:
        w.wfdbx_set_legacy(0)
    with pytest.raises(ValueError, match="uncalibrated"):
        w.read_record("null", sampto=4, physical=True)


def test_read_header_legacy(datadir):
    with open("nr.hea", "w") as f:
        f.write("nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n")
    assert [s.adcres for s in w.read_header("nr").siginfo] == [0, 0]
    assert [s.adcres for s in
            w.read_header("nr", legacy=True).siginfo] == [12, 12]


# ---------------------------------------------------------------------------
# The vectorized write_record (WFDB-x): byte for byte as putvec

FAST_FMTS = [8, 16, 24, 32, 61, 80, 160, 212, 310, 311]
MIN = {8: -(1 << 31), 16: -32768, 61: -32768, 160: -32768, 80: -128,
       212: -2048, 310: -512, 311: -512, 24: -(1 << 23), 32: -(1 << 31)}


def _write_both(monkeypatch, x, fmt, spf=None):
    """Write x with write_record into fast/ and (with putvec for each frame,
    as before) into slow/; return the bytes of both signal files and
    headers, and the number of putvec calls of the fast path."""
    import wfdbx._signal as sig
    calls = [0]
    putvec = sig.putvec

    def counting_putvec(v):
        calls[0] += 1
        return putvec(v)

    def slow(xx):
        for row in xx.tolist():
            putvec(row)

    out = []
    for d, frames in (("fast", None), ("slow", slow)):
        os.makedirs(d, exist_ok=True)
        with monkeypatch.context() as m:
            m.setattr(sig, "putvec", counting_putvec)
            if frames:
                m.setattr(sig, "_putframes", frames)
            w.write_record("r", x, 360, fmt=fmt, gains=200,
                           adcres=RES[fmt], units="mV",
                           samps_per_frame=spf, dir=d)
        out.append((open(d + "/r.dat", "rb").read(),
                    open(d + "/r.hea", "rb").read()))
        if d == "fast":
            fast_calls = calls[0]
    return out[0], out[1], fast_calls


@pytest.mark.parametrize("fmt", FAST_FMTS)
@pytest.mark.parametrize("nsig", [1, 2, 3])
@pytest.mark.parametrize("n", [1, 2, 3, 7, 1000])
def test_fast_write_identical(datadir, monkeypatch, fmt, nsig, n):
    rng = np.random.default_rng(fmt + 7 * nsig + n)
    lo = MIN[fmt]
    hi = -lo - 1
    if fmt == 8:     # first differences within -128..127
        d = rng.integers(-128, 128, size=(n, nsig))
        d[0] = rng.integers(-1000, 1000, size=nsig)     # (the initial values)
        x = np.cumsum(d, axis=0)
    else:
        x = rng.integers(lo, hi + 1, size=(n, nsig))
        x.flat[::5] = lo       # edge values (lo is the invalid value) ...
        x.flat[1::7] = hi
        x.flat[2::11] = w.WFDB_INVALID_SAMPLE   # ... and invalid samples
    fast, slow, calls = _write_both(monkeypatch, x, fmt)
    assert fast == slow
    unit = {212: 2, 310: 3, 311: 3}.get(fmt, 1)
    assert calls < unit     # (only frames that do not complete a group)


@pytest.mark.parametrize("fmt", [16, 212, 310, 8])
def test_fast_write_multifrequency(datadir, monkeypatch, fmt):
    rng = np.random.default_rng(fmt)
    # signal 0 (2 samples per frame), then signal 1, in each frame
    s0 = np.cumsum(rng.integers(-50, 51, size=202)).reshape(101, 2)
    s1 = np.cumsum(rng.integers(-50, 51, size=(101, 1)), axis=0)
    x = np.clip(np.hstack([s0, s1]), -500, 500)     # (formats 310 and 311)
    fast, slow, calls = _write_both(monkeypatch, x, fmt, spf=[2, 1])
    assert fast == slow and calls < 3


@pytest.mark.parametrize("fmt", [8, 16, 212])
def test_fast_write_fallback(datadir, monkeypatch, fmt):
    # samples out of the range of the format (or, for format 8, too large
    # differences): every frame is written by putvec
    x = np.array([[0, 1], [40000, -5], [3, 2], [-70000, 9]])
    fast, slow, calls = _write_both(monkeypatch, x, fmt)
    assert fast == slow and calls == len(x)


# ---------------------------------------------------------------------------
# write_record(..., dir=...) (WFDB-x)

def test_write_record_dir(datadir):
    x = np.arange(20).reshape(10, 2)
    os.mkdir("out")
    prev = w.wfdbx_set_output_dir("elsewhere")
    try:
        w.write_record("rec", x, 360, gains=200, adcres=12, units="mV",
                       dir="out")
        assert w.wfdbx_get_output_dir() == "elsewhere"     # restored
    finally:
        w.wfdbx_set_output_dir(prev)
    assert sorted(os.listdir("out")) == ["rec.dat", "rec.hea"]
    assert not os.path.exists("rec.hea") and not os.path.exists("rec.dat")
    hea = open("out/rec.hea").read().splitlines()
    assert hea[0] == "rec 2 360 10"
    assert hea[1].startswith("rec.dat 16 ")
    w.setwfdb("out")
    assert np.array_equal(w.read_record("rec").signals, x)
    w.setwfdb(".")
    assert np.array_equal(w.read_record("out/rec").signals, x)
    assert w.wfdbx_get_output_dir() is None
    with pytest.raises(FileNotFoundError):
        w.write_record("rec", x, 360, gains=200, adcres=12, units="mV",
                       dir="nosuch")
    with pytest.raises(ValueError, match="must not contain a directory"):
        w.write_record("sub/rec", x, 360, gains=200, adcres=12, units="mV",
                       dir="out")
    # restored after an error, too
    with pytest.raises(ValueError):
        w.write_record("rec", x, 360, dir="out")    # (no gains)
    assert w.wfdbx_get_output_dir() is None
    assert not os.path.exists("nosuch")
    # the same in legacy mode
    w.write_record("leg", x, 360, dir="out", legacy=True)
    assert open("out/leg.hea").read().startswith("leg 2 360 10")


def test_dir_checks_first(datadir):
    # the dir checks come before any other validation (WFDB-x)
    x = np.arange(4).reshape(2, 2)
    os.mkdir("out")
    with pytest.raises(ValueError) as e:
        w.write_record("sub/rec", x, 0, dir="out")     # (no gains, fs 0)
    assert str(e.value) == ("record name must not contain a directory when "
                            "dir is given")
    with pytest.raises(FileNotFoundError) as e:
        w.write_record("rec", x, 0, dir="nosuch")
    assert str(e.value) == "directory nosuch does not exist"
    with pytest.raises(ValueError, match="gains must be specified"):
        w.write_record("rec", x, 360, dir="out")


def _write_truncated_record():
    """Records tr (its .dat truncated to 2 of its 4 frames) and ok."""
    x = np.array([[1, 2], [3, 4], [5, 6], [7, 8]])
    for name in ("tr", "ok"):
        w.write_record(name, x, 100, gains=100, adcres=16, units="mV")
    with open("tr.dat", "r+b") as f:
        f.truncate(8)              # 2 frames of 2 format-16 samples
    return x


@pytest.mark.parametrize("legacy", [False, True])
def test_read_record_truncated_signal_file(datadir, legacy):
    x = _write_truncated_record()
    # (1) unexpected EOF (getvec status -3) is an error, not the end of data
    for phys in (False, True):
        with pytest.raises(IOError) as e:
            w.read_record("tr", physical=phys, legacy=legacy)
        assert str(e.value) == \
            "can't read signal data of record tr (getvec status -3)"
        # the library is left usable: a good record reads normally
        assert (w.read_record("ok", legacy=legacy).signals == x).all()
    # reading only what the file holds is not an error
    assert (w.read_record("tr", sampto=2, legacy=legacy).signals ==
            x[:2]).all()
    # (2) complete reads, sub-intervals, and sampto past the end of a
    # record whose header gives its length (what there is, no error)
    assert (w.read_record("ok", legacy=legacy).signals == x).all()
    assert (w.read_record("ok", sampfrom=1, sampto=3,
                          legacy=legacy).signals == x[1:3]).all()
    assert (w.read_record("ok", sampto=10, legacy=legacy).signals ==
            x).all()
    # (3) the low-level API is unchanged: getframes returns the frames read
    # and the status, getvec returns -3 at the end of the truncated file
    w.wfdbquit()
    assert w.isigopen("tr", None, 2) == 2
    arr, stat = w.getframes(10)
    assert stat == -3 and (arr == x[:2]).all()
    w.wfdbquit()
    w.isigopen("tr", [], 2)
    v = [0, 0]
    assert [w.getvec(v) for _ in range(3)] == [2, 2, -3]
    w.wfdbquit()
    w.isigopen("ok", [], 2)
    arr, stat = w.getframes(10)
    assert stat == -1 and (arr == x).all()
    w.wfdbquit()


_CKSUM_MSG = ("checksum error in record ck: the signal data do not match the "
              "checksums in its header")


@pytest.mark.parametrize("legacy", [False, True])
def test_read_record_checksum_warning(datadir, legacy, capfd):
    """A checksum error (getvec status -4) is a warning of read_record (the
    data, all of them, are returned), not an error; checksum_warning=False
    turns it off.  The library's getvec message is not printed then."""
    import warnings
    x = np.array([[1, 2], [3, 4], [5, 6], [7, 8]])
    w.write_record("ck", x, 100, gains=100, adcres=16, units="mV")
    with open("ck.dat", "r+b") as f:     # sample (1, 0): 3 -> 9
        f.seek(4)
        f.write(bytes([9, 0]))
    y = x.copy()
    y[1, 0] = 9
    # (the same samples with correct checksums: every frame, the last one
    # included, is returned in both cases)
    w.write_record("good", y, 100, gains=100, adcres=16, units="mV")
    good = w.read_record("good", legacy=legacy).signals
    capfd.readouterr()
    for phys in (False, True):
        with pytest.warns(RuntimeWarning) as rec:
            r = w.read_record("ck", physical=phys, legacy=legacy)
        assert [str(m.message) for m in rec] == [_CKSUM_MSG]
        assert rec[0].filename == __file__     # (points at the caller)
        expect = y / 100.0 if phys else y
        assert r.signals.shape == (4, 2) and (r.signals == expect).all()
        assert len(r.signals) == len(good)
        assert "checksum" not in capfd.readouterr().err
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        r = w.read_record("ck", checksum_warning=False, legacy=legacy)
        assert r.signals.shape == good.shape and (r.signals == good).all()
        # not read to the end: no checksum is verified
        assert (w.read_record("ck", sampto=3, legacy=legacy).signals ==
                y[:3]).all()
        assert (w.read_record("ck", sampfrom=1, sampto="e",
                              checksum_warning=False,
                              legacy=legacy).signals == y[1:]).all()
    assert capfd.readouterr().err == ""
    # the truncated case is still an error
    _write_truncated_record()
    with pytest.raises(IOError, match=r"getvec status -3"):
        w.read_record("tr", legacy=legacy)
    # the low-level API is unchanged: getvec returns -4 for the last frame
    # (filled), getframes stops before it, and the message is printed
    w.wfdbquit()
    capfd.readouterr()
    w.isigopen("ck", [], 2)
    v = [0, 0]
    assert [w.getvec(v) for _ in range(4)] == [2, 2, 2, -4]
    assert v == [7, 8]
    w.wfdbquit()
    w.isigopen("ck", [], 2)
    arr, stat = w.getframes(10)
    assert stat == -4 and (arr == y[:3]).all()
    w.wfdbquit()
    assert capfd.readouterr().err == \
        "getvec: checksum error in signal 0\n" * 2



# ---------------------------------------------------------------------------
# read_header, base time and date, checksum_ok, int32 samples

def _set_record_line(name, line):
    with open(name + ".hea") as f:
        rest = f.read().split("\n", 1)[1]
    with open(name + ".hea", "w") as f:
        f.write(line + "\n" + rest)


@pytest.mark.parametrize("legacy", [False, True])
def test_read_header_fields(datadir, legacy):
    x = np.arange(20).reshape(10, 2)
    w.write_record("bt", x, 250, gains=200, adcres=16, units="mV",
                   comments=["first", "second"])
    for line, ms, date, text in (
            ("bt 2 250/1000(7) 10 14:00:03.500 21/06/2024", 50403500,
             (2024, 6, 21), "[14:00:03 21/06/2024]"),
            ("bt 2 250/1000(7) 10 14:00:03", 50403000, None, "[14:00:03]"),
            ("bt 2 250/1000(7) 10", None, None, None)):
        _set_record_line("bt", line)
        h = w.read_header("bt", legacy=legacy)
        assert isinstance(h, w.Header)
        assert (h.name, h.fs, h.counter_freq, h.base_counter, h.nsamples,
                h.nsig) == ("bt", 250.0, 1000.0, 7.0, 10, 2)
        assert [s.desc for s in h.siginfo] == ["record bt, signal 0",
                                               "record bt, signal 1"]
        assert h.siginfo[0].gain == 200.0 and h.siginfo[1].initval == 1
        assert (h.base_time, h.base_time_ms, h.base_date) == (text, ms, date)
        assert isinstance(h.base_time_ms, (int, type(None)))
        assert h.comments == ["first", "second"]
        assert repr(h) == "Header(name='bt', fs=250, nsig=2, nsamples=10)"
        r = w.read_record("bt", legacy=legacy)
        assert (r.base_time, r.base_time_ms, r.base_date) == (text, ms, date)
        assert r.comments == h.comments
    # no frequency, no length: fs 0 (legacy: 250) and nsamples 0
    _set_record_line("bt", "bt 2")
    h = w.read_header("bt", legacy=legacy)
    assert (h.fs, h.counter_freq, h.nsamples) == \
        ((250.0, 250.0, 0) if legacy else (0.0, 0.0, 0))
    assert (h.base_time, h.base_time_ms, h.base_date) == (None, None, None)
    with pytest.raises(IOError, match="can't read header for record nx"):
        w.read_header("nx", legacy=legacy)


def test_read_header_no_signals(datadir):
    with open("ns.hea", "w") as f:
        f.write("ns 0 100 1000 08:00:00 01/02/2003\n#note\n")
    h = w.read_header("ns")
    assert (h.nsig, h.siginfo, h.fs, h.nsamples) == (0, [], 100.0, 1000)
    assert (h.base_time_ms, h.base_date) == (28800000, (2003, 2, 1))
    assert h.comments == ["note"]


def test_read_record_dtype_and_checksum_ok(datadir):
    x = np.array([[1, 2], [3, 4], [5, 6], [7, 8]])
    w.write_record("ck", x, 100, gains=100, adcres=16, units="mV")
    r = w.read_record("ck")
    assert r.signals.dtype == np.int32 and r.checksum_ok is True
    assert w.read_record("ck", physical=True).signals.dtype == np.float64
    assert w.read_record("ck", sampto=0).signals.shape == (0, 2)
    assert w.read_record("ck", channels=[1]).signals.dtype == np.int32
    with open("ck.dat", "r+b") as f:     # (the checksums no longer match)
        f.seek(4)
        f.write(bytes([9, 0]))
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        assert w.read_record("ck").checksum_ok is False
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        assert w.read_record("ck", checksum_warning=False).checksum_ok \
            is False
        assert w.read_record("ck", physical=True,
                             checksum_warning=False).checksum_ok is False
        # (not read to the end: no checksum is verified)
        assert w.read_record("ck", sampto=3).checksum_ok is True


# ---------------------------------------------------------------------------
# High-resolution reads of a record with a checksum error: getvec returns -4
# for each sample vector of the last frame, and read_record returns them all

def _write_mf(name, spf, nframes, bad=None):
    """Write a format 16 record of nframes frames with samples per frame
    spf (a list, one entry per signal), samples 1, 2, 3, ...  With bad =
    (frame, signal), that sample is set to 99 in the signal file only (the
    header's checksums no longer match).  Returns the frames written to the
    file."""
    width = sum(spf)
    x = np.arange(1, nframes * width + 1).reshape(nframes, width)
    w.write_record(name, x, 100, samps_per_frame=spf, gains=100, adcres=16,
                   units="mV")
    if bad is not None:
        frame, signal = bad
        k = frame * width + sum(spf[:signal])
        with open(name + ".dat", "r+b") as f:
            f.seek(2 * k)
            f.write(bytes([99, 0]))
        x = x.copy()
        x[frame, k - frame * width] = 99
    return x


def _read_quiet(*args, **kw):
    import warnings
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        return w.read_record(*args, checksum_warning=False, **kw)


@pytest.mark.parametrize("spf", [[2], [3], [1, 2], [2, 3]])
@pytest.mark.parametrize("where", ["first", "last"])
def test_read_record_highres_checksum_error(datadir, spf, where):
    nframes = 4
    bad = (0 if where == "first" else nframes - 1, len(spf) - 1)
    x = _write_mf("mf", spf, nframes, bad)
    w.write_record("good", x, 100, samps_per_frame=spf, gains=100,
                   adcres=16, units="mV")
    n = nframes * max(spf)
    for chans in (None, [len(spf) - 1], list(range(len(spf)))[::-1]):
        good = w.read_record("good", channels=chans, highres=True)
        assert good.checksum_ok is True and len(good.signals) == n
        r = _read_quiet("mf", channels=chans, highres=True)
        assert r.checksum_ok is False
        assert r.signals.shape == good.signals.shape
        assert (r.signals == good.signals).all()
        with pytest.warns(RuntimeWarning) as rec:
            r = w.read_record("mf", channels=chans, highres=True)
        assert [str(m.message) for m in rec] == \
            [_CKSUM_MSG.replace(" ck:", " mf:")]
        assert r.checksum_ok is False and (r.signals == good.signals).all()
        # physical units, and the low-resolution read (one vector per frame)
        r = _read_quiet("mf", channels=chans, highres=True, physical=True)
        assert (r.signals == good.signals / 100.0).all()
        lo = w.read_record("good", channels=chans)
        r = _read_quiet("mf", channels=chans)
        assert r.checksum_ok is False and len(r.signals) == nframes
        assert (r.signals == lo.signals).all()
    # a read ending before the last frame verifies no checksum; one ending
    # in the last frame returns all the samples requested
    good = w.read_record("good", highres=True).signals
    for sampto in (n - max(spf), n - max(spf) // 2 - 1, n - 1):
        r = _read_quiet("mf", highres=True, sampto=sampto)
        assert (r.signals == good[:sampto]).all()
        if sampto <= n - max(spf):
            assert r.checksum_ok is True
    # (a read from a later sample: the samples to the end)
    r = _read_quiet("mf", highres=True, sampfrom=n - max(spf) - 1)
    assert (r.signals == good[n - max(spf) - 1:]).all()


def test_read_record_highres_checksum_error_example(datadir):
    """The example of the specification: spf 2, the first sample is 99."""
    frames = np.arange(1, 9).reshape(4, 2)
    w.write_record("mf", frames, fs=100, samps_per_frame=[2], gains=100,
                   adcres=16, units="mV")
    with open("mf.dat", "r+b") as f:
        f.write(bytes([99, 0]))
    r = _read_quiet("mf", highres=True)
    assert r.signals[:, 0].tolist() == [99, 2, 3, 4, 5, 6, 7, 8]
    assert r.checksum_ok is False
    # the low-level API is unchanged: -4 for each vector of the last frame
    w.wfdbquit()
    w.isigopen("mf", [], 1)
    w.setgvmode(w.WFDB_HIGHRES)
    v = [0]
    out = []
    stats = []
    for _ in range(9):
        stats.append(w.getvec(v))
        out.append(v[0])
    w.wfdbquit()
    assert stats == [1] * 6 + [-4, -4, -1]
    assert out[:8] == [99, 2, 3, 4, 5, 6, 7, 8]


# ---------------------------------------------------------------------------
# The bulk reader (_bulk_frames, decoding into the output array) gives the
# same samples and statuses as the per-frame path (getvec)

_BULK_FMTS = [8, 80, 16, 61, 160, 24, 32, 212, 310, 311]


def _random_record(name, rng, fmt, nsig, n, invalid=True):
    hi = min(RANGES[fmt], 30000) if fmt == 8 else RANGES[fmt]
    if fmt == 8:
        x = np.cumsum(rng.integers(-60, 61, size=(n, nsig)), axis=0)
    else:
        x = rng.integers(-hi + 1, hi + 1, size=(n, nsig))
        if invalid:
            x[rng.random((n, nsig)) < 0.01] = w.WFDB_INVALID_SAMPLE
            x[:3, 0] = w.WFDB_INVALID_SAMPLE    # (invalid at the start)
    w.write_record(name, x, 250, fmt=fmt, gains=200, adcres=RES[fmt],
                   units="mV")
    return x


def _merge_groups(name, parts):
    """A record name whose signals are those of the records parts, one
    signal group (file) per part."""
    lines, nsig, n = [], 0, None
    for p in parts:
        with open(p + ".hea") as f:
            hl = [s for s in f.read().splitlines() if s and s[0] != "#"]
        first = hl[0].split()
        nsig += int(first[1])
        n = first[3]
        lines += hl[1:]
    with open(name + ".hea", "w") as f:
        f.write("%s %d 250 %s\n" % (name, nsig, n) + "\n".join(lines) + "\n")


def _read_both(monkeypatch, *args, **kw):
    """read_record with the bulk path, and with the per-frame path only."""
    import wfdbx._signal as s
    a = w.read_record(*args, **kw)
    with monkeypatch.context() as m:
        m.setattr(s, "_bulk_eligible", lambda: False)
        b = w.read_record(*args, **kw)
    return a, b


def _same(a, b):
    assert a.signals.dtype == b.signals.dtype
    assert a.signals.shape == b.signals.shape
    assert np.array_equal(a.signals, b.signals, equal_nan=True)
    assert a.checksum_ok == b.checksum_ok


@pytest.mark.parametrize("fmt", _BULK_FMTS)
def test_bulk_read_equals_per_frame(datadir, monkeypatch, fmt):
    import warnings
    import wfdbx.highlevel as hl
    rng = np.random.default_rng(fmt)
    # (small chunks: records end in the middle of a chunk and of a buffer)
    monkeypatch.setattr(hl, "_CHUNK_SAMPLES", 4096 * 3 + 5)
    for nsig in (1, 2, 3, 4):
        n = int(rng.integers(5000, 30000))
        x = _random_record("r", rng, fmt, nsig, n)
        for kw in ({}, {"pad": True}, {"physical": True},
                   {"sampfrom": 1234}, {"sampfrom": 7, "sampto": n - 9},
                   {"sampto": n + 50}, {"channels": [nsig - 1, 0, 0]}):
            a, b = _read_both(monkeypatch, "r", **kw)
            _same(a, b)
            if not kw:
                y = a.signals
                if fmt in (310, 311) and (n * nsig) % 3 == 2:
                    y = y[:-1]
                assert np.array_equal(y, x)
        # the checksum frame: a wrong checksum is seen on both paths
        with open("r.dat", "r+b") as f:
            f.seek(0)
            b0 = f.read(1)
            f.seek(0)
            f.write(bytes([b0[0] ^ 0x10]))
        with pytest.warns(RuntimeWarning):
            a, b = _read_both(monkeypatch, "r")
        _same(a, b)
        assert a.checksum_ok is False
        # truncated files: the same error (or, cut in the last frame,
        # checksum error) on both paths
        size = os.path.getsize("r.dat")
        for cut in (size // 2 + 1, size - 1):
            with open("r.dat", "r+b") as f:
                f.truncate(cut)
            out = []
            for bulk in (True, False):
                with monkeypatch.context() as m:
                    if not bulk:
                        import wfdbx._signal as s
                        m.setattr(s, "_bulk_eligible", lambda: False)
                    try:
                        with warnings.catch_warnings():
                            warnings.simplefilter("ignore")
                            r = w.read_record("r")
                        out.append((r.signals.tolist(), r.checksum_ok))
                    except IOError as e:
                        out.append(str(e))
            assert out[0] == out[1]
            if cut == size // 2 + 1:
                assert "getvec status -3" in out[0]


def test_bulk_read_multiple_groups(datadir, monkeypatch):
    import wfdbx.highlevel as hl
    rng = np.random.default_rng(42)
    monkeypatch.setattr(hl, "_CHUNK_SAMPLES", 10007)
    n = 20011
    xs = [_random_record("g%d" % k, rng, fmt, nsig, n)
          for k, (fmt, nsig) in enumerate([(212, 3), (310, 2), (16, 1),
                                           (8, 2)])]
    _merge_groups("mg", ["g0", "g1", "g2", "g3"])
    for kw in ({}, {"pad": True}, {"sampfrom": 999, "sampto": 15000},
               {"channels": [7, 3, 0]}):
        a, b = _read_both(monkeypatch, "mg", **kw)
        _same(a, b)
    a = w.read_record("mg", sampto=n - 1)
    assert np.array_equal(a.signals, np.hstack(xs)[:n - 1])
    # getframes (C-style, int64) == getvec, with a seek
    w.isigopen("mg", [], 8)
    w.setgvmode(w.WFDB_LOWRES | w.WFDB_GVPAD)
    assert w.isigsettime(17) == 0
    arr, stat = w.getframes(100000)
    w.wfdbquit()
    w.isigopen("mg", [], 8)
    w.setgvmode(w.WFDB_LOWRES | w.WFDB_GVPAD)
    assert w.isigsettime(17) == 0
    v, ref = [0] * 8, []
    while True:
        st = w.getvec(v)
        if st < 0:
            break
        ref.append(list(v))
    w.wfdbquit()
    assert arr.dtype == np.int64 and stat == st
    assert arr.tolist() == ref


def _state(nsig):
    import wfdbx._signal as s
    st = s._s
    return (st.istime, [(i.samp, i.info.cksum, i.info.nsamp)
                        for i in st.isd[:nsig]])


def test_bulk_interleaved_with_getvec(datadir, monkeypatch):
    # getframes (bulk) mixed with getvec and isigsettime, and ending in the
    # middle of a buffer or at the checksum frame: the same frames,
    # statuses and library state as getvec alone
    import wfdbx._signal as s
    rng = np.random.default_rng(7)
    n = 23456
    _random_record("g0", rng, 212, 3, n)
    _random_record("g1", rng, 16, 2, n)
    _merge_groups("mg", ["g0", "g1"])
    with open("g1.dat", "r+b") as f:     # (a checksum error)
        f.seek(100)
        f.write(b"\x01\x02")
    # (without a seek, the checksums are verified at the last frame)
    results = []
    for steps in ([("f", 1000), ("v", 3), ("f", 4095), ("f", 9001),
                   ("v", 1), ("f", 9354), ("v", 2), ("f", 10)],
                  [("f", 1000), ("v", 3), ("t", 17), ("f", 9001), ("v", 1),
                   ("t", 20000), ("f", 3455), ("v", 2), ("t", 5),
                   ("f", 30000)]):
        out = []
        for bulk in (True, False):
            with monkeypatch.context() as m:
                if not bulk:
                    m.setattr(s, "_bulk_eligible", lambda: False)
                w.wfdbquiet()
                assert w.isigopen("mg", [], 5) == 5
                got = []
                for op, k in steps:
                    if op == "f":
                        arr, stat = w.getframes(k)
                        got.append((arr.tolist(), stat))
                    elif op == "v":
                        v = [0] * 5
                        got.append([(w.getvec(v), list(v))
                                    for _ in range(k)])
                    else:
                        got.append(w.isigsettime(k))
                    got.append(_state(5))
                w.wfdbquit()
                w.wfdbverbose()
            out.append(got)
        assert out[0] == out[1]
        results.append(out[0])
    assert [st for st, v in results[0][12]] == [5, -4]     # (step "v", 2)
    assert results[0][14] == ([], -1)
    assert results[1][-2][1] == -1          # (no checksum after a seek)


_FULL = "/dev/full"     # a device on which every write fails (ENOSPC)
needs_full = pytest.mark.skipif(not os.path.exists(_FULL),
                                reason="no /dev/full on this system")


@needs_full
@pytest.mark.parametrize("target", ["full.dat", "full.hea"])
@pytest.mark.parametrize("n", [10, 100000])
@pytest.mark.parametrize("legacy", [False, True])
def test_write_record_write_error(datadir, capfd, target, n, legacy):
    # A signal file or header that cannot be written raises an error, in
    # both modes, after the library's messages.
    os.symlink(_FULL, target)
    before = w.wfdbx_write_errors()
    with pytest.raises(OSError, match="write error on record full"):
        w.write_record("full", np.zeros((n, 2), int), 250, gains=200,
                       adcres=16, units="mV", legacy=legacy)
    assert w.wfdbx_write_errors() > before
    assert "osigclose: write error" in capfd.readouterr().err


def test_write_record_frame_checks(datadir):
    # The columns of signals must add up to a whole frame, and each signal
    # has at least one sample per frame; nothing is written otherwise.
    x = np.arange(8).reshape(4, 2)
    kw = dict(gains=200, adcres=16, units="mV")
    for spf, msg in [([1], "signals has 2 columns, but samps_per_frame adds "
                           "up to 1"),
                     ([3], "adds up to 3"), ([1, 2], "adds up to 3"),
                     ([0, 2], "integers >= 1"), ([2, 0], "integers >= 1"),
                     ([-1, 3], "integers >= 1"), ([1.5, 0.5], "integers")]:
        for legacy in (False, True):
            with pytest.raises(ValueError, match=msg):
                w.write_record("bad", x, 250, samps_per_frame=spf,
                               legacy=legacy, **kw)
            assert not os.path.exists("bad.hea")
            assert not os.path.exists("bad.dat")
    w.write_record("good", x, 250, samps_per_frame=[2], **kw)
    assert w.read_record("good").signals.shape == (4, 1)
    w.write_record("good", x, 250, samps_per_frame=[1, 1], **kw)
    assert np.array_equal(w.read_record("good").signals, x)


def _mf_record(name, rng, fmt, spf, n, gains=None, names=None, invalid=True):
    """A random multi-frequency record (spf: samples per frame of each
    signal; n frames), with invalid samples; returns its frames."""
    hi = min(RANGES[fmt], 30000) if fmt == 8 else RANGES[fmt]
    cols = sum(spf)
    if fmt == 8:
        x = np.cumsum(rng.integers(-60, 61, size=(n, cols)), axis=0)
    else:
        x = rng.integers(-hi + 1, hi + 1, size=(n, cols))
        if invalid:
            x[rng.random((n, cols)) < 0.01] = w.WFDB_INVALID_SAMPLE
            x[:2, 0] = w.WFDB_INVALID_SAMPLE
    w.write_record(name, x, 250, fmt=fmt, gains=gains or 200,
                   adcres=RES[fmt], units="mV", samps_per_frame=spf,
                   names=names)
    return x


_MF_MODES = ({}, {"pad": True}, {"highres": True},
             {"highres": True, "pad": True}, {"physical": True},
             {"sampfrom": 1234}, {"sampfrom": 7, "sampto": 15000},
             {"highres": True, "sampfrom": 3, "sampto": 9001},
             {"channels": [1, 0, 1]})


@pytest.mark.parametrize("fmt", _BULK_FMTS)
def test_bulk_read_multifrequency(datadir, monkeypatch, fmt):
    # Records of several sampling frequencies are read in blocks: the same
    # samples as frame by frame, in low- and high-resolution modes.
    import wfdbx.highlevel as hl
    rng = np.random.default_rng(fmt + 1)
    monkeypatch.setattr(hl, "_CHUNK_SAMPLES", 4096 * 3 + 5)
    for spf in ([4, 1, 1, 1], [2, 3], [1, 2], [8, 1], [3, 3, 1]):
        n = int(rng.integers(16000, 24000))
        _mf_record("m", rng, fmt, spf, n)
        for kw in _MF_MODES:
            a, b = _read_both(monkeypatch, "m", **kw)
            _same(a, b)
        # (all but the frames near the end are read in blocks)
        rows, bulk = _bulk_rows(monkeypatch, "m", highres=True)
        assert rows - bulk <= 4 * max(spf)


def _bulk_rows(monkeypatch, *args, **kw):
    """(rows read by read_record, rows of them read in blocks)"""
    import wfdbx._signal as s
    orig = s._bulk_frames
    count = [0]

    def counted(*a, **k):
        r = orig(*a, **k)
        count[0] += r or 0
        return r

    with monkeypatch.context() as m:
        m.setattr(s, "_bulk_frames", counted)
        r = w.read_record(*args, **kw)
    return len(r.signals), count[0]


def _write_segments(name, rng, fmt, spf, lens, **kw):
    segs = []
    for k, n in enumerate(lens):
        seg = "%s_%d" % (name, k + 1)
        _mf_record(seg, rng, fmt, spf, n, **kw)
        segs.append((seg, n))
    return segs


def test_bulk_read_multisegment(datadir, monkeypatch):
    # Multi-segment records, of fixed and of variable layout (with signals
    # missing from some segments, other gains, and null segments), are read
    # in blocks: the same samples as frame by frame.
    import wfdbx.highlevel as hl
    rng = np.random.default_rng(11)
    monkeypatch.setattr(hl, "_CHUNK_SAMPLES", 4096 * 3 + 5)
    names = ["ECG", "ABP", "RESP"]
    # fixed layout
    segs = _write_segments("fx", rng, 212, [4, 1, 1], [9000, 7001, 12000],
                           names=names)
    with open("fx.hea", "w") as f:
        f.write("fx/3 3 250 %d\n" % sum(n for _, n in segs))
        f.writelines("%s %d\n" % s for s in segs)
    for kw in _MF_MODES + ({"sampfrom": 8999, "sampto": 16002},):
        a, b = _read_both(monkeypatch, "fx", **kw)
        _same(a, b)
    a = w.read_record("fx")
    assert a.signals.shape == (28001, 3)
    rows, bulk = _bulk_rows(monkeypatch, "fx")
    assert rows - bulk <= 2 * 3
    # variable layout
    with open("vl_0.hea", "w") as f:
        f.write("vl_0 3 250 0\n"
                "~ 0x4 400(10)/mV 12 0 0 0 0 ECG\n"
                "~ 0 100/mV 16 0 0 0 0 ABP\n"
                "~ 0 50/mV 16 0 0 0 0 RESP\n")
    s1 = _write_segments("va", rng, 16, [4, 1, 1], [5000], names=names,
                         gains=[400, 100, 50])
    s2 = _write_segments("vb", rng, 16, [1, 4], [6003], names=["RESP", "ECG"],
                         gains=[25, 200])
    s3 = _write_segments("vc", rng, 212, [1], [4000], names=["ABP"],
                         gains=[100])
    segs = [("vl_0", 0)] + s1 + [("~", 2500)] + s2 + s3
    with open("vl.hea", "w") as f:
        f.write("vl/%d 3 250 %d\n" % (len(segs), sum(n for _, n in segs)))
        f.writelines("%s %d\n" % s for s in segs)
    w.wfdbquiet()
    for kw in _MF_MODES + ({"sampfrom": 4990, "sampto": 9000},):
        a, b = _read_both(monkeypatch, "vl", **kw)
        _same(a, b)
    rows, bulk = _bulk_rows(monkeypatch, "vl")
    assert rows - bulk <= 2 * 6
    w.wfdbverbose()
    a = w.read_record("vl", physical=True)
    assert a.signals.shape == (17503, 3)
    assert np.isnan(a.signals[5000:7500]).all()     # (the null segment)


def test_bulk_read_test_records(datadir, monkeypatch):
    # Every test record of the repository: the same samples in blocks as
    # frame by frame, in every reading mode.
    import glob
    w.wfdbquiet()
    for h in sorted(glob.glob("*.hea")):
        rec = h[:-4]
        for kw in ({}, {"pad": True}, {"highres": True},
                   {"highres": True, "pad": True}, {"sampfrom": 3}):
            try:
                a, b = _read_both(monkeypatch, rec, **kw)
            except (IOError, ValueError) as e:
                with pytest.raises(type(e)):
                    _read_both(monkeypatch, rec, **kw)
                continue
            _same(a, b)
    w.wfdbverbose()


@pytest.mark.parametrize("hr", [False, True])
def test_bulk_multifrequency_interleaved(datadir, monkeypatch, hr):
    # getframes (bulk) mixed with getvec and isigsettime on a
    # multi-frequency record, in high resolution also from the middle of a
    # frame: the same vectors, statuses and library state as getvec alone.
    import wfdbx._signal as s
    rng = np.random.default_rng(5)
    _mf_record("mf", rng, 212, [4, 1, 3], 20001)
    mode = (w.WFDB_HIGHRES if hr else w.WFDB_LOWRES) | w.WFDB_GVPAD
    steps = [("f", 999), ("v", 3), ("f", 4097), ("t", 17), ("v", 1),
             ("f", 9001), ("v", 2), ("t", 30), ("f", 200000)]
    out = []
    for bulk in (True, False):
        with monkeypatch.context() as m:
            if not bulk:
                m.setattr(s, "_bulk_eligible", lambda: False)
            assert w.isigopen("mf", [], 3) == 3
            w.setgvmode(mode)
            got = []
            for op, k in steps:
                if op == "f":
                    arr, stat = w.getframes(k)
                    got.append((arr.tolist(), stat))
                elif op == "v":
                    v = [0] * 3
                    got.append([(w.getvec(v), list(v)) for _ in range(k)])
                else:
                    got.append(w.isigsettime(k))
                got.append((_state(3), s._s.gvc))
            w.wfdbquit()
        out.append(got)
    assert out[0] == out[1]


def test_names_without_spaces(datadir):
    # Descriptions that end (or begin) with white space in the header are
    # given without it by the high-level readers, and found by that name;
    # the C-style functions keep it, as in C.
    with open("sp.hea", "w") as f:
        f.write("sp 3 250 4\n"
                "fmt16.dat 16 200/mV 16 0 0 0 0 III \n"
                "fmt16.dat 16 200/mV 16 0 0 0 0 ABP\t \n"
                "fmt16.dat 16 200/mV 16 0 0 0 0 PLETH\n")
    for legacy in (False, True):
        r = w.read_record("sp", legacy=legacy)
        assert r.names == ["III", "ABP", "PLETH"]
        assert [s.desc for s in r.siginfo] == ["III", "ABP", "PLETH"]
        h = w.read_header("sp", legacy=legacy)
        assert [s.desc for s in h.siginfo] == ["III", "ABP", "PLETH"]
        r2 = w.read_record("sp", channels=["ABP", "III ", 2])
        assert r2.names == ["ABP", "III", "PLETH"]
        assert np.array_equal(r2.signals, r.signals[:, [1, 0, 2]])
    si = []
    assert w.isigopen("sp", si, 3) == 3
    assert [s.desc for s in si] == ["III ", "ABP\t ", "PLETH"]
    w.wfdbquit()
