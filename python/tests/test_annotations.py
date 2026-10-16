"""Annotation I/O tests.

Part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import wfdbx as w


def test_read(datadir):
    a = w.read_annotations("100s", "atr")
    assert len(a) == 75
    assert a.symbols[:3] == ["+", "N", "N"]
    assert a.aux[0] == "(N"


def test_roundtrip(datadir):
    samples = [0, 5, 5, 5, 300, 70000, 70001, 5000000000, 5000000000]
    codes = [w.NOTE, w.NORMAL, w.NORMAL, w.NORMAL, w.PVC, w.ARFCT,
             w.RHYTHM, w.NORMAL, w.NOISE]
    chans = [0, 0, 1, 1, 0, 3, 0, 0, 2]
    nums = [0, 0, 0, 2, 0, -1, 0, 0, 1]
    sub = [0, 0, 0, 0, 3, 0, 0, 0, -1]
    aux = ["start", None, None, None, None, None, "(AFIB", None, "x" * 200]
    w.write_annotations("100s", "rt", samples, codes=codes, chans=chans,
                        nums=nums, subtypes=sub, aux=aux)
    w.wfdbquiet()
    a = w.read_annotations("100s", "rt")
    w.wfdbverbose()
    # (the NOTE at time 0 is consumed as a modification label by annopen)
    assert a.samples.tolist() == samples[1:]
    assert a.codes.tolist() == codes[1:]
    assert a.chans.tolist() == chans[1:]
    assert a.nums.tolist() == nums[1:]
    assert a.subtypes.tolist() == sub[1:]
    assert a.aux == aux[1:]


def test_mnemonics():
    assert w.annstr(w.NORMAL) == "N"
    assert w.strann("V") == w.PVC
    assert w.anndesc(w.PVC) == "Premature ventricular contraction"
    assert w.ecgstr(99) == "[99]"
    assert w.isqrs(w.NORMAL) and not w.isqrs(w.NOTE)
    assert w.map1(w.APC) == w.NORMAL and w.map2(w.APC) == w.SVPB


# wfdb-x: no default sampling frequency (see docs/DIVERGENCES.md)

def test_read_without_frequency(datadir):
    import shutil
    import pytest
    shutil.copy("100s.atr", "nohea.atr")       # a record without a header
    w.wfdbquiet()
    try:
        a = w.read_annotations("nohea", "atr")
        assert a.fs == 0 and len(a) == 75
        assert w.read_annotations("nohea", "atr", sampto="s1000").samples \
            .tolist() == a.samples[a.samples < 1000].tolist()
        with pytest.raises(ValueError, match="sampling frequency of record "
                           "nohea is not specified"):
            w.read_annotations("nohea", "atr", sampto="0:10")
        b = w.read_annotations("nohea", "atr", sampto="0:10", fs=360)
        assert b.fs == 360
        assert b.samples.tolist() == a.samples[a.samples < 3600].tolist()
        # the frequency of the header takes precedence over fs
        assert w.read_annotations("100s", "atr", fs=100).fs == 360
        with pytest.raises(ValueError, match="fs must be > 0"):
            w.read_annotations("nohea", "atr", fs=0)
    finally:
        w.wfdbverbose()


def test_read_legacy(datadir):
    import shutil
    shutil.copy("100s.atr", "nohea.atr")       # a record without a header
    w.wfdbquiet()
    try:
        a = w.read_annotations("nohea", "atr", sampto="0:10", legacy=True)
        assert a.fs == 250 and w.wfdbx_get_legacy() == 0
        b = w.read_annotations("nohea", "atr")
        assert a.samples.tolist() == b.samples[b.samples < 2500].tolist()
    finally:
        w.wfdbverbose()
