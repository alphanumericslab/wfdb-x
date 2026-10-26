"""Annotation I/O tests.

Part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import os

import pytest

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


# ---------------------------------------------------------------------------
# Out-of-order output annotations: sorted when the file is closed (wfdb-x: in
# the same process; in legacy mode, by running sortann, as the C library)

# ties in time, num and chan, duplicates (the last one is kept), NOTQRS
# (dropped), aux strings, and a time 0 annotation that follows later ones
# (lost by the original sortann, as in legacy mode; see
# docs/KNOWN_C_BEHAVIORS.md)
TRICKY = [  # time, code, subtype, chan, num, aux
    (100, w.NORMAL, 0, 0, 0, None), (50, w.PVC, 0, 0, 0, "(VT"),
    (100, w.APC, 0, 1, 0, None), (100, w.NORMAL, 0, 0, 1, "num 1"),
    (100, w.PVC, 0, 0, 0, "replaces N"), (75, w.NOTQRS, 0, 2, 0, None),
    (75, w.NORMAL, 1, 2, 0, "odd"), (10, w.NOTQRS, 0, 0, 0, None),
    (200, w.RHYTHM, 0, 0, 0, "(AFIB"), (150, w.NOISE, 0, 3, -1, None),
    (150, w.NOISE, 0, 3, 0, None), (20, w.NORMAL, 0, 0, 0, "x" * 101),
    (0, w.NORMAL, 0, 0, 0, None), (5, w.NORMAL, 0, 1, 0, None),
    (5000, w.NORMAL, 0, 0, 0, None)]


def _write_tricky(name, legacy=False, **kw):
    t, c, s, ch, n, aux = zip(*TRICKY)
    w.write_annotations("100s", name, t, codes=c, subtypes=s, chans=ch,
                        nums=n, aux=aux, legacy=legacy, **kw)
    return open("100s." + name, "rb").read()


def _read_ticks(name):
    """(time in ticks of 1000 Hz, anntyp, chan, num) of 100s.NAME."""
    w.annopen("100s", [w.Anninfo(name, w.WFDB_READ)])
    w.setiafreq(0, 1000.0)      # (times in ticks of the time resolution)
    a, got = w.Annotation(), []
    while w.getann(0, a) == 0:
        got.append((a.time, a.anntyp, a.chan, a.num))
    w.wfdbquit()
    return got


def test_sort_in_process(datadir, monkeypatch, capfd):
    from wfdbx import _annot
    from wfdbx.apps import sortann
    w.setannstr(42, "Z")    # (a definition table in the file)
    try:
        w.setafreq(1000.0)    # (a time resolution)
        _write_tricky("leg", legacy=True)
        w.setafreq(1000.0)
        with monkeypatch.context() as m:
            def no_subprocess(*args, **kw):
                raise AssertionError("sortann run in modern mode")
            m.setattr(_annot, "_run_sortann", no_subprocess)
            m.setattr(_annot.subprocess, "call", no_subprocess)
            modern = _write_tricky("mod")
        # (the library's settings and tables are unchanged)
        assert w.getafreq() == 1000.0 and w.annstr(42) == "Z"
        assert [c for c, f in enumerate(_annot._a.modified) if f] == [42]
        err = capfd.readouterr().err
        assert err.count("Rearranging annotations for output annotator "
                         "leg ...done!\n") == 1
        assert err.count("Rearranging annotations for output annotator "
                         "mod ...done!\n") == 1
        # the in-process sort and the sortann tool (wfdb-x) give the same
        # bytes
        monkeypatch.setenv("WFDBANNSORT", "0")
        _write_tricky("uns")
        w.setafreq(0.0)
        assert sortann.main(["sortann", "-r", "100s", "-a", "uns"]) == 0
        assert open("100s.uns", "rb").read() == modern
        w.setafreq(0.0)
        assert w.annstr(42) == "Z"
        legacy_got = _read_ticks("leg")
        modern_got = _read_ticks("mod")
    finally:
        w.setafreq(0.0)
        w.setannstr(-42, "[42]")
        _annot._a.modified[42] = 0
    # legacy mode (the original sortann): the annotation at time 0 is lost,
    # and so is the one at time 5 inserted after it
    rest = [(20, w.NORMAL, 0, 0), (50, w.PVC, 0, 0),
            (75, w.NORMAL, 2, 0), (100, w.PVC, 0, 0),
            (100, w.APC, 1, 0), (100, w.NORMAL, 0, 1),
            (150, w.NOISE, 3, -1), (150, w.NOISE, 3, 0),
            (200, w.RHYTHM, 0, 0), (5000, w.NORMAL, 0, 0)]
    assert legacy_got == rest
    # wfdb-x: nothing is lost
    assert modern_got == [(0, w.NORMAL, 0, 0), (5, w.NORMAL, 1, 0)] + rest


def test_annlist_time0():
    from wfdbx._annot import _AnnList
    for legacy, want in ((False, [0, 3, 5]), (True, [5])):
        lst = _AnnList(legacy)
        for t in (5, 0, 3):
            lst.insert(w.Annotation(t, w.NORMAL))
        assert [a.time for a in lst] == want and lst.in_order == 0
    # a later annotation at time 0 replaces a real one (both modes), and
    # an annotation at time 0 on another channel is kept (both modes)
    for legacy in (False, True):
        lst = _AnnList(legacy)
        for t, c, typ in ((0, 0, w.NORMAL), (7, 0, w.NORMAL),
                          (0, 1, w.APC), (0, 0, w.PVC)):
            lst.insert(w.Annotation(t, typ, 0, c))
        assert [(a.time, a.chan, a.anntyp) for a in lst] == [
            (0, 0, w.PVC), (0, 1, w.APC), (7, 0, w.NORMAL)]


def test_legacy_sort_in_output_dir(datadir, capfd):
    # legacy mode: the sortann program runs in the output directory (where
    # the file is), with --legacy; the result is that of the modern sort
    os.mkdir("out")
    t, s = [300, 100, 200, 100, 50], ["N", "V", "N", "A", "N"]
    w.write_annotations("rec", "leg", t, symbols=s, dir="out", legacy=True)
    w.write_annotations("rec", "mod", t, symbols=s, dir="out")
    err = capfd.readouterr().err
    # (the child looks for the header of rec, as the original does)
    assert err == ("Rearranging annotations for output annotator leg ..."
                   "init: can't open header for record rec\ndone!\n"
                   "Rearranging annotations for output annotator mod "
                   "...done!\n")
    assert sorted(os.listdir("out")) == ["rec.leg", "rec.mod"]
    assert open("out/rec.leg", "rb").read() == \
        open("out/rec.mod", "rb").read()
    a = w.read_annotations("out/rec", "leg", fs=360)
    assert a.samples.tolist() == [50, 100, 200, 300] and a.symbols[1] == "A"


def test_sort_disabled(datadir, monkeypatch, capfd):
    monkeypatch.setenv("WFDBANNSORT", "0")
    data = _write_tricky("ns")
    assert capfd.readouterr().err == (
        "Use the command:\n  sortann -r 100s -a ns\nto rearrange "
        "annotations in the correct order.\n")
    monkeypatch.delenv("WFDBANNSORT")
    w.wfdbquiet()
    w.annopen("100s", [w.Anninfo("ns", w.WFDB_READ)])
    a, times = w.Annotation(), []
    while w.getann(0, a) == 0:
        times.append(a.time)
    w.wfdbquit()
    w.wfdbverbose()
    assert times == [t for t, *_ in TRICKY] and len(data) > 0


def test_sort_keeps_other_annotators(datadir):
    # an input annotator and the signals stay open while an output annotator
    # is closed and sorted
    assert w.isigopen("100s", [], 2) == 2
    ai = [w.Anninfo("atr", w.WFDB_READ), w.Anninfo("o1", w.WFDB_WRITE),
          w.Anninfo("o2", w.WFDB_WRITE)]
    assert w.annopen("100s", ai) == 0
    first = w.Annotation()
    w.getann(0, first)
    for t in (30, 10, 20):
        w.putann(0, w.Annotation(t, w.NORMAL))
        w.putann(1, w.Annotation(t, w.PVC))
    w.wfdbquiet()
    w.oannclose(0)      # sorted now; o2 becomes output annotator 0
    w.wfdbverbose()
    a = w.Annotation()
    assert w.getann(0, a) == 0 and a.time == 77 and first.time == 18
    v = [0, 0]
    assert w.getvec(v) == 2 and v == [995, 1011]
    w.putann(0, w.Annotation(40, w.PVC))
    w.wfdbquiet()
    w.wfdbquit()
    w.wfdbverbose()
    o1 = w.read_annotations("100s", "o1")
    o2 = w.read_annotations("100s", "o2")
    assert o1.samples.tolist() == [10, 20, 30] and set(o1.symbols) == {"N"}
    assert o2.samples.tolist() == [10, 20, 30, 40]


def test_write_annotations_dir(datadir):
    os.mkdir("out")
    w.wfdbquiet()
    w.write_annotations("rec", "atr", [30, 10, 20], symbols=["N", "V", "N"],
                        dir="out")
    w.wfdbverbose()
    assert os.listdir("out") == ["rec.atr"]
    assert w.wfdbx_get_output_dir() is None
    a = w.read_annotations("out/rec", "atr")       # sorted in place
    assert a.samples.tolist() == [10, 20, 30] and a.symbols[0] == "V"
    with pytest.raises(FileNotFoundError):
        w.write_annotations("rec", "atr", [1], symbols=["N"], dir="nosuch")
    with pytest.raises(ValueError, match="must not contain a directory"):
        w.write_annotations("x/rec", "atr", [1], symbols=["N"], dir="out")


def test_write_annotations_dir_checks_first(datadir):
    os.mkdir("out")
    with pytest.raises(ValueError) as e:     # (neither symbols nor codes)
        w.write_annotations("x/rec", "atr", [1], dir="out")
    assert str(e.value) == ("record name must not contain a directory when "
                            "dir is given")
    with pytest.raises(FileNotFoundError) as e:
        w.write_annotations("rec", "atr", [1], dir="nosuch")
    assert str(e.value) == "directory nosuch does not exist"
    with pytest.raises(ValueError, match="symbols or codes must be given"):
        w.write_annotations("rec", "atr", [1], dir="out")


# ---------------------------------------------------------------------------
# write_annotations(sort=...): per-call choice, whatever WFDBANNSORT says

@pytest.mark.parametrize("legacy", [False, True])
def test_write_annotations_sort_option(datadir, monkeypatch, capfd, legacy):
    t, s = [300, 100, 200], ["N", "V", "N"]
    w.wfdbquiet()
    try:
        # sort=False: the file stays in the given order (WFDBANNSORT unset)
        monkeypatch.delenv("WFDBANNSORT", raising=False)
        w.write_annotations("rec", "uns", t, symbols=s, sort=False,
                            legacy=legacy)
        assert w.read_annotations("rec", "uns", fs=360).samples.tolist() \
            == t
        # sort=True: sorted although WFDBANNSORT is 0, which is unchanged
        monkeypatch.setenv("WFDBANNSORT", "0")
        w.write_annotations("rec", "srt", t, symbols=s, sort=True,
                            legacy=legacy)
        assert os.environ["WFDBANNSORT"] == "0"
        assert w.read_annotations("rec", "srt", fs=360).samples.tolist() \
            == [100, 200, 300]
        # unset: WFDBANNSORT decides (0: not sorted; 1: sorted)
        w.write_annotations("rec", "env0", t, symbols=s, legacy=legacy)
        assert w.read_annotations("rec", "env0", fs=360).samples.tolist() \
            == t
        monkeypatch.setenv("WFDBANNSORT", "1")
        w.write_annotations("rec", "env1", t, symbols=s, legacy=legacy)
        assert w.read_annotations("rec", "env1", fs=360).samples.tolist() \
            == [100, 200, 300]
        # sort=False with WFDBANNSORT=1
        w.write_annotations("rec", "uns1", t, symbols=s, sort=False,
                            legacy=legacy)
        assert w.read_annotations("rec", "uns1", fs=360).samples.tolist() \
            == t
        # the option applies to that call only
        from wfdbx import _annot
        assert _annot._a.sort_override is None
    finally:
        w.wfdbverbose()


# ---------------------------------------------------------------------------
# The bulk MIT-format encoder of write_annotations (_putanns) writes the same
# bytes as putann for each annotation

def _random_annotations(rng, n):
    import numpy as np
    gaps = rng.integers(-50, 1500, n)
    big = rng.random(n) < 0.05      # large gaps (SKIP), forward and back
    gaps[big] = rng.integers(-(1 << 33), 1 << 33, int(big.sum()))
    times = np.cumsum(gaps)
    times[rng.random(n) < 0.02] = 0
    codes = rng.integers(0, 50, n)
    codes[rng.random(n) < 0.05] = 0
    subtypes = np.where(rng.random(n) < 0.2, rng.integers(-128, 128, n), 0)
    chans = np.where(rng.random(n) < 0.2, rng.integers(0, 256, n), 0)
    nums = np.where(rng.random(n) < 0.2, rng.integers(-128, 128, n), 0)
    aux = []
    for k in range(n):
        r = rng.random()
        if r < 0.6:
            aux.append(None)
        else:
            ln = int(rng.choice([0, 1, 2, 3, 254, 255,
                                 int(rng.integers(0, 256))]))
            aux.append("".join(chr(int(c)) for c in
                               rng.integers(32, 256, ln)))
    return times.tolist(), codes.tolist(), subtypes.tolist(), \
        chans.tolist(), nums.tolist(), aux


def _aux_bytes(x):
    if x is None:
        return None
    b = x.encode("latin-1")[:255]
    return bytes((len(b),)) + b


def _write_low_level(name, anns, bulk, freq=None):
    from wfdbx import _annot
    times, codes, subtypes, chans, nums, aux = anns
    if freq:
        w.setafreq(freq)
    assert w.annopen("rec", [w.Anninfo(name, w.WFDB_WRITE)]) == 0
    auxb = [_aux_bytes(x) for x in aux]
    if bulk:
        assert _annot._putanns(0, times, codes, subtypes, chans, nums,
                               auxb) == 0
    else:
        for k in range(len(times)):
            w.putann(0, w.Annotation(times[k], codes[k], subtypes[k],
                                     chans[k], nums[k], auxb[k]))
    w.wfdbquit()
    w.setafreq(0.0)
    return open("rec." + name, "rb").read()


def test_bulk_annotation_encoder(datadir, monkeypatch):
    import numpy as np
    from wfdbx._annot import WFDB_TIME_MAX
    monkeypatch.setenv("WFDBANNSORT", "0")      # (keep the order written)
    w.wfdbquiet()
    try:
        rng = np.random.default_rng(6)
        for trial in range(60):
            n = int(rng.choice([0, 1, 2, 5, 50, 500]))
            anns = _random_annotations(rng, n)
            freq = 1000.0 if trial % 3 == 0 else None
            ref = _write_low_level("ref", anns, False, freq)
            got = _write_low_level("blk", anns, True, freq)
            assert got == ref, trial
        # a time that putann rejects (overflow) is skipped in both
        anns = ([5, WFDB_TIME_MAX, 7, 3], [1, 1, 1, 1],
                [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0],
                [None, None, "a", None])
        assert _write_low_level("blk", anns, True) == \
            _write_low_level("ref", anns, False)
        # write_annotations (numpy arrays, lists, scalars) == putann
        anns = _random_annotations(rng, 2000)
        times, codes, subtypes, chans, nums, aux = anns
        w.write_annotations("rec", "hl", np.array(times), codes=codes,
                            subtypes=np.array(subtypes), chans=chans,
                            nums=nums, aux=aux, sort=False)
        assert open("rec.hl", "rb").read() == \
            _write_low_level("ref", anns, False)
        w.write_annotations("rec", "hl", times, codes=codes, subtypes=0,
                            chans=3, nums=-1, aux="x", sort=False)
        assert open("rec.hl", "rb").read() == _write_low_level(
            "ref", (times, codes, [0] * len(times), [3] * len(times),
                    [-1] * len(times), ["x"] * len(times)), False)
    finally:
        w.wfdbverbose()


def test_bulk_annotation_encoder_aha(datadir):
    # (an AHA-format output annotator: _putanns uses putann)
    from wfdbx import _annot
    anns = ([10, 20, 30], [1, 5, 1], [0, 0, 0], [0, 0, 0], [0, 0, 0],
            [None, "(VT", None])
    out = []
    for bulk in (False, True):
        assert w.annopen("rec", [w.Anninfo("aha", w.WFDB_AHA_WRITE)]) == 0
        if bulk:
            _annot._putanns(0, *anns[:5], [_aux_bytes(x) for x in anns[5]])
        else:
            for k in range(3):
                w.putann(0, w.Annotation(anns[0][k], anns[1][k], 0, 0, 0,
                                         _aux_bytes(anns[5][k])))
        w.wfdbquit()
        out.append(open("rec.aha", "rb").read())
    assert out[0] == out[1] and len(out[0]) > 0
