"""Signal I/O tests: every storage format round-trips exactly.

Part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
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
    assert [s.adcres for s in w.read_header("nr")] == [0, 0]
    assert [s.adcres for s in w.read_header("nr", legacy=True)] == [12, 12]


# ---------------------------------------------------------------------------
# The vectorized write_record (wfdb-x): byte for byte as putvec

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
# write_record(..., dir=...) (wfdb-x)

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
    # the dir checks come before any other validation (wfdb-x)
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
