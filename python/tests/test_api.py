"""Unit tests of the library functions that the command-line tools do not
exercise.

The expected values were produced by the original C library, using
tests/reference/api_expect.c (each test below corresponds to a function of
that program; run it to see the values).  The C++ and MATLAB/Octave
counterparts of these tests are cpp/tests/test_api_c.cpp and
matlab/tests/test_api_c.m.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
tests WFDB-x; it has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import math
import os
import subprocess
import sys

import wfdbx as w

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "src")


def isig(record):
    """Open all signals of a record (as isigopen(record, si, 8) in C)."""
    return w.isigopen(record, [], 8)


def vec(n, f=None):
    """Call f (getvec or getframe) with a vector of n samples; return the
    status followed by the samples."""
    v = [0] * n
    stat = (f or w.getvec)(v)
    return [stat] + v[:n]


def ann(n):
    """getann(n); return status, time, anntyp, subtyp, chan, num."""
    a = w.Annotation()
    stat = w.getann(n, a)
    return [stat, a.time, a.anntyp, a.subtyp, a.chan, a.num]


def cal(desc, units):
    c = w.Calinfo()
    stat = w.getcal(desc, units, c)
    if stat:
        return [stat]
    return [stat, c.low, c.high, c.scale, c.caltype, c.sigtype, c.units]


def readfile(name):
    with open(name, "rb") as f:
        return f.read()


# ---------------------------------------------------------------------------
# t_version

def test_version_and_errors(datadir):
    # wfdbversion, wfdbdefwfdb, wfdbldflags and wfdbcflags depend on how the
    # C library was built (with configure); WFDB-x gives the values of a
    # release build installed in /usr/local, and empty flags strings.
    assert w.wfdbversion() == "10.7.0"
    assert w.wfdbdefwfdb() == \
        ". /usr/local/database http://physionet.org/physiobank/database"
    assert w.wfdbdefwfdbcal() == "wfdbcal"
    assert w.wfdbldflags() == ""
    assert w.wfdbcflags() == ""
    assert w.wfdb_me_fatal() == 1
    w.wfdbmemerr(0)
    assert w.wfdb_me_fatal() == 0
    w.wfdbquiet()
    try:
        assert w.isigopen("nosuch", [], 8) == -1
        assert w.wfdberror() == "init: can't open header for record nosuch\n"
        assert w.annopen("nosuch", [w.Anninfo("atr", w.WFDB_READ)]) == -3
        assert w.wfdberror() == \
            "annopen: can't read annotator atr for record nosuch\n"
    finally:
        w.wfdbverbose()


def test_wfdberror_before_any_error():
    # (C prints its build date; WFDB-x gives the date of the 10.7.0 sources)
    code = ("import wfdbx; import sys; "
            "sys.stdout.write(wfdbx.wfdberror())")
    out = subprocess.run([sys.executable, "-c", code], capture_output=True,
                         text=True, env=dict(os.environ, PYTHONPATH=SRC))
    assert out.stdout.startswith("WFDB library version 10.7.0 (")
    assert out.stdout.endswith(").\n")


# ---------------------------------------------------------------------------
# t_path

def test_resetwfdb_fresh_process(datadir):
    # WFDB-x (normal mode): setwfdb sets the single input directory ("a b"
    # names two: an error, nothing changes); wfdbquit leaves it as it is.
    # In legacy mode, resetwfdb restores the path returned by the first
    # getwfdb (here, from the environment); wfdbquit calls resetwfdb.
    code = ("import wfdbx as w\n"
            "import sys; w.wfdbx_set_legacy(int(sys.argv[1]))\n"
            "print(w.getwfdb())\n"
            "w.setwfdb('a b'); print(w.getwfdb())\n"
            "w.resetwfdb(); print(w.getwfdb())\n"
            "w.setwfdb('c'); w.wfdbquit(); print(w.getwfdb())\n")
    for legacy, expected in [(0, ".\n.\n.\nc\n"), (1, ".\na b\n.\n.\n")]:
        out = subprocess.run([sys.executable, "-c", code, str(legacy)],
                             capture_output=True, text=True,
                             env=dict(os.environ, PYTHONPATH=SRC, WFDB="."))
        assert out.stdout == expected


def test_wfdbfile(datadir):
    w.wfdbquiet()
    w.setwfdb("a b")    # (wfdb-x: an error; nothing changes)
    w.wfdbverbose()
    assert w.getwfdb() == "."
    w.setwfdb(".")
    assert w.getwfdb() == "."
    assert w.wfdbfile("hea", "100s") == "./100s.hea"
    assert w.wfdbfile(None, None) == "./100s.hea"
    assert w.wfdbfile("hea", "100s.hea") == "./100s.hea"
    assert w.wfdbfile("atr", "100s") == "./100s.atr"
    assert w.wfdbfile("dat", "nosuch") is None
    assert w.wfdbfile("wfdbcal", None) == "./wfdbcal"


# ---------------------------------------------------------------------------
# t_bufsize

def test_buffer_sizes(datadir):
    try:
        assert w.setibsize(0) == 8192
        assert w.setibsize(1000) == 1000
        w.wfdbquiet()
        assert w.setibsize(-1) == -2
        assert w.setobsize(0) == 8192
        assert w.setobsize(2000) == 2000
        assert w.setobsize(-5) == -2
        isig("100s")
        assert w.setibsize(512) == -1
    finally:
        w.wfdbverbose()
        w.wfdbquit()
        w.setibsize(0)
        w.setobsize(0)


# ---------------------------------------------------------------------------
# t_signals

def test_getvec_modes_and_frequencies(datadir):
    assert w.getgvmode() == 0
    assert isig("100s") == 2
    assert w.getifreq() == 360
    assert w.getspf() == 1
    w.wfdbquit()
    isig("fmt16")
    assert vec(3) == [3, -7, 32, -33]
    assert vec(3) == [3, 4, 53, -47]
    assert vec(3) == [3, -20, 24, -27]
    assert w.setifreq(100.0) == 0
    assert w.getifreq() == 100
    assert w.isigsettime(0) == 0
    assert vec(3) == [3, -7, 32, -33]
    assert vec(3) == [3, -21, 23, -35]
    assert vec(3) == [3, 7, -14, -44]
    assert w.setifreq(1000.0) == 0
    assert w.getifreq() == 1000
    assert w.isigsettime(2) == 0
    assert vec(3) == [3, -7, 32, -33]
    for i in range(4):
        assert vec(3) == [3, 4, 53, -47]
    assert w.getafreq() == 1000      # (setifreq also calls setafreq)
    w.wfdbquiet()
    assert w.setifreq(-1.0) == -1
    w.wfdbverbose()
    assert w.getifreq() == 250
    w.setafreq(0.0)
    w.wfdbquit()
    isig("100s")
    w.setgvmode(w.WFDB_HIGHRES)
    assert w.getgvmode() == 1
    w.setgvmode(w.WFDB_GVPAD | w.WFDB_LOWRES)
    assert w.getgvmode() == 2
    w.setgvmode(w.WFDB_HIGHRES | w.WFDB_GVPAD | 4)
    assert w.getgvmode() == 3
    w.setgvmode(0)


def test_amplitude_conversion(datadir):
    isig("100s")    # gain 200, baseline 1024
    assert [w.adumuv(0, 200), w.adumuv(0, -37), w.adumuv(1, 1),
            w.adumuv(0, -1), w.adumuv(7, 100)] == [1000, -185, 5, -5, -32768]
    assert [w.muvadu(0, 1000), w.muvadu(0, -333), w.muvadu(1, 2),
            w.muvadu(9, 1000)] == [200, -67, 0, -32768]
    # wfdb-x: no default gain for invalid signal numbers (C: 200)
    assert [w.aduphys(0, 1224), w.aduphys(1, 900)] == [1.0, -0.62]
    assert math.isnan(w.aduphys(5, 300))
    assert [w.physadu(0, 1.0), w.physadu(1, -0.5023), w.physadu(5, 1.5)] == \
        [1224, 924, -32768]
    w.wfdbquit()
    isig("fmt16")   # 100(-5)/mV, 150(5)/uV, 200(15)/mmHg
    assert [w.adumuv(0, 100), w.adumuv(1, 150), w.adumuv(2, -7)] == \
        [1000, 1000, -35]
    assert [w.muvadu(0, 1000), w.muvadu(1, 1000), w.muvadu(2, -2500)] == \
        [100, 150, -500]
    assert [w.aduphys(0, 95), w.aduphys(1, 10), w.aduphys(2, -3)] == \
        [1.0, 0.033333333333333333, -0.089999999999999997]
    assert [w.physadu(0, 1.0), w.physadu(1, -2.25), w.physadu(2, 0.4)] == \
        [95, -333, 95]


def test_sample(datadir):
    isig("100s")
    assert w.sample_valid() == 0
    assert [w.sample(0, 0), w.sample_valid()] == [995, 1]
    assert [w.sample(1, 1000), w.sample_valid()] == [970, 1]
    assert [w.sample(0, 21599), w.sample_valid()] == [975, 1]
    assert [w.sample(0, 21600), w.sample_valid()] == [975, 0]
    assert [w.sample(0, 5), w.sample_valid()] == [995, 1]
    assert [w.sample(1, -3), w.sample_valid()] == [1011, 1]
    assert [w.sample(2, 0), w.sample_valid()] == [-32768, -1]


# ---------------------------------------------------------------------------
# t_frames

def test_getframe(datadir):
    isig("mfreq")    # 1, 2 and 4 samples per frame
    assert w.getspf() == 1
    assert w.getifreq() == 100
    assert vec(7, w.getframe) == [3, 138, 218, 2699, 219, -1316, 1120, 1973]
    assert vec(7, w.getframe) == [3, 2677, 1201, 275, -989, 1822, 2762,
                                  1927]
    assert vec(3) == [3, -597, -455, 181]
    w.isigsettime(599)
    assert vec(7, w.getframe) == [3, -1394, 715, 558, 2215, -1785, 860,
                                  -491]
    assert w.getframe([0] * 7) == -1
    w.wfdbquit()
    w.setgvmode(w.WFDB_HIGHRES)
    try:
        isig("mfreq")
        assert w.getspf() == 4
        assert w.getifreq() == 400
        assert vec(7, w.getframe) == [3, 138, 218, 2699, 219, -1316, 1120,
                                      1973]
        assert vec(3) == [3, 2677, 1201, -989]
        assert vec(3) == [3, 2677, 1201, 1822]
    finally:
        w.wfdbquit()
        w.setgvmode(0)


# ---------------------------------------------------------------------------
# t_groups

def test_isgsettime(datadir):
    isig("twog")     # group 0: signal 0; group 1: signals 1 and 2
    assert vec(3) == [3, 1020, 977, 316]
    assert w.isgsettime(1, 100) == 0
    assert vec(3) == [3, 1880, -630, 83]
    assert vec(3) == [3, 325, 245, 1597]
    assert w.isgsettime(0, 500) == 0
    assert vec(3) == [3, -1823, 338, -709]
    assert w.isgsettime(1, 1001) == 0
    assert w.getvec([0] * 3) == -1


# ---------------------------------------------------------------------------
# t_segments

def segs():
    return [(s.recname, s.nsamp, s.samp0) for s in w.getseginfo()]


def test_tnextvec_getseginfo(datadir):
    isig("100s")
    assert len(w.getseginfo()) == 0
    assert w.tnextvec(0, 5) == 5
    assert w.tnextvec(1, 0) == 0
    w.wfdbquit()
    isig("multi")
    assert segs() == [("100s", 21600, 0), ("null", 1800, 21600),
                      ("100s", 21600, 23400)]
    assert w.tnextvec(0, 0) == 0
    assert w.tnextvec(0, 21599) == 21599
    assert w.tnextvec(1, 21700) == 23500
    assert w.tnextvec(0, 44999) == 44999
    assert w.tnextvec(0, 45000) == -1
    w.wfdbquit()
    isig("vlay")
    assert segs() == [("vlay_0", 0, 0), ("fmt16", 1500, 0), ("~", 200, 1500),
                      ("fmt212", 1501, 1700)]
    w.wfdbquiet()
    try:
        assert w.tnextvec(0, 0) == 0
        assert w.tnextvec(1, 1499) == 1700
        assert w.tnextvec(2, 1500) == -1
        assert w.tnextvec(0, 1600) == -1
        assert w.tnextvec(5, 0) == -1
    finally:
        w.wfdbverbose()


# ---------------------------------------------------------------------------
# t_skew

def test_skew_and_start(datadir):
    isig("skew")
    assert [w.wfdbgetskew(s) for s in range(4)] == [0, 3, 7, 0]
    assert vec(3) == [3, -7, 21, -32768]
    w.wfdbsetiskew(1, 2)
    w.wfdbsetiskew(2, 100000)   # too large: ignored
    w.wfdbsetiskew(0, -1)       # negative: ignored
    assert [w.wfdbgetskew(s) for s in range(3)] == [0, 2, 7]
    w.wfdbquit()
    isig("prolog")
    assert [w.wfdbgetstart(0), w.wfdbgetstart(2), w.wfdbgetstart(3)] == \
        [100, 100, 0]
    w.wfdbquit()
    isig("100s")
    assert w.wfdbgetstart(0) == 0


# ---------------------------------------------------------------------------
# t_output

def test_output_prolog_skew_flush(datadir):
    w.setcfreq(0.0)     # (the counter frequency survives wfdbquit)
    si = [w.Siginfo(fname="out.dat", desc=d, units="mV", gain=100, group=0,
                    fmt=16, adcres=12) for d in ("first", "second")]
    w.setsampfreq(100.0)
    assert w.osigfopen(si, 2) == 2
    assert w.wfdbputprolog(b"PROLOG!", 7, 0) == 0
    w.wfdbsetskew(1, 4)
    for i in range(5):
        w.putvec([i, -i])
    assert w.annopen("out", [w.Anninfo("tst", w.WFDB_WRITE)]) == 0
    w.putann(0, w.Annotation(time=3, anntyp=w.NORMAL))
    w.putann(0, w.Annotation(time=4, anntyp=w.PVC))
    w.wfdbflush()
    assert os.path.getsize("out.dat") == 27
    assert os.path.getsize("out.tst") == 4
    assert w.newheader("out") == 0
    assert w.putinfo("info line") == 0
    w.wfdbquit()
    assert readfile("out.hea") == (
        b"out 2 100 5\r\n"
        b"out.dat 16+7 100/mV 12 0 0 10 0 first\r\n"
        b"out.dat 16:4+7 100/mV 12 0 0 -10 0 second\r\n"
        b"#info line\r\n")
    assert readfile("out.dat") == bytes.fromhex(
        "50524f4c4f4721 0000 0000 0100 ffff 0200 feff 0300 fdff 0400 fcff")
    assert readfile("out.tst") == bytes.fromhex("0304 0114 0000")

    w.setsampfreq(100.0)
    for s in si:
        s.fname = "out2.dat"
    w.osigfopen(si, 2)
    w.wfdbsetstart(0, 512)
    w.putvec([1, 2])
    w.newheader("out2")
    w.wfdbquit()
    assert readfile("out2.hea") == (
        b"out2 2 100 1\r\n"
        b"out2.dat 16+512 100/mV 12 0 1 1 0 first\r\n"
        b"out2.dat 16+512 100/mV 12 0 2 2 0 second\r\n")
    assert os.path.getsize("out2.dat") == 4


# ---------------------------------------------------------------------------
# t_info

def test_info(datadir):
    assert w.getinfo("100s") == " 69 M 1085 1629 x1"
    assert w.getinfo(None) == " Aldomet, Inderal"
    assert w.getinfo(None) == \
        "Produced by xform from record 100, beginning at 0:0"
    assert w.setinfo("newrec") == 0
    assert w.putinfo("first") == 0
    assert w.putinfo("second") == 0
    assert w.setinfo(None) == 0
    w.wfdbquiet()
    assert w.putinfo("third") == -1
    w.wfdbverbose()
    assert readfile("newrec.info") == b"#first\r\n#second\r\n"
    assert w.getinfo("newrec") == "first"
    assert w.getinfo(None) == "second"
    assert w.getinfo(None) is None
    assert w.setinfo("100s") == 0
    assert w.putinfo("extra") == 0
    w.wfdbquit()
    assert w.getinfo("100s") == " 69 M 1085 1629 x1"
    assert w.getinfo(None) == " Aldomet, Inderal"
    assert w.getinfo(None) == \
        "Produced by xform from record 100, beginning at 0:0"
    assert w.getinfo(None) == "extra"
    isig("fmt16")
    assert w.getinfo(None) is None
    w.wfdbquit()
    # wfdb_freeinfo: getinfo(None) restarts from the first info string of
    # the current input record (fmt16: its name survives wfdbquit)
    assert w.getinfo("100s") == " 69 M 1085 1629 x1"
    assert w.getinfo(None) == " Aldomet, Inderal"
    w.wfdb_freeinfo()
    assert w.getinfo(None) == \
        "generated by gen_records for wfdb-x conformance tests"
    isig("100s")
    assert w.getinfo(None) is None
    w.wfdb_freeinfo()
    assert w.getinfo(None) == " 69 M 1085 1629 x1"
    assert w.getinfo(None) == " Aldomet, Inderal"


# ---------------------------------------------------------------------------
# t_msheader

def test_setmsheader(datadir):
    assert w.setmsheader("msrec", ["100s", "null", "100s"], 3) == 0
    w.wfdbquiet()
    try:
        assert w.setmsheader("msbad", ["100s", "null", "100s"], 0) == -1
        assert w.setmsheader("msbad", ["100s", "fmt16"], 2) == -4
    finally:
        w.wfdbverbose()
    w.wfdbquit()
    assert readfile("msrec.hea") == \
        b"msrec/3 2 360 45000\r\n100s 21600\r\nnull 1800\r\n100s 21600\r\n"
    assert isig("msrec") == 2
    assert segs() == [("100s", 21600, 0), ("null", 1800, 21600),
                      ("100s", 21600, 23400)]
    w.isigsettime(21599)
    assert vec(2) == [2, 975, 989]
    assert vec(2) == [2, -32768, -32768]


# ---------------------------------------------------------------------------
# t_counter

def test_counter_and_base_time(datadir):
    isig("100s")
    assert w.getcfreq() == 360
    assert w.getbasecount() == 0
    w.setcfreq(1000.0)
    w.setbasecount(500.5)
    assert w.getcfreq() == 1000
    assert w.getbasecount() == 500.5
    assert w.strtim("c1500.5") == 360
    assert w.strtim("c500.5") == 0
    w.setcfreq(0.0)
    assert w.getcfreq() == 360
    assert w.setbasetime("10:20:30 15/6/2001") == 0
    assert w.timstr(0) == "[10:20:30 15/06/2001]"
    assert w.timstr(360) == "    0:01"
    assert w.timstr(-360) == "[10:20:31 15/06/2001]"
    assert w.mstimstr(-1000) == "[10:20:32.778 15/06/2001]"
    assert w.setbasetime("8:00") == 0
    assert w.timstr(0) == "[00:08:00]"
    assert w.timstr(-720) == "[00:08:02]"
    w.wfdbquiet()
    assert w.setbasetime("garbage") == -1
    w.wfdbverbose()
    w.setcfreq(500.0)
    w.wfdbquit()
    assert w.getcfreq() == 500
    w.setcfreq(0.0)


# ---------------------------------------------------------------------------
# t_calib

def test_calibration(datadir):
    try:
        assert w.calopen("wfdbcal") == 0
        assert cal("ECG lead II", "mV") == [0, 0, 1, 1, 4, "ECG", "mV"]
        assert cal("ECG", "uV") == [0, 0, 1, 1000, 4, "ECG", "uV"]
        assert cal("ABP", "mmHg") == [0, 0, 0, 100, 3, "ABP", "mmHg"]
        assert cal("BP", None) == [0, 0, 100, 100, 3, "BP", "mmHg"]
        assert cal(None, None) == [0, 0, 1, 1, 4, "ECG", "mV"]
        assert cal("nosuch", "x") == [-1]
        test = w.Calinfo(-1.5, 2.5, 3, "TEST", "xu",
                         w.WFDB_DC_COUPLED | w.WFDB_CAL_SINE)
        ac = w.Calinfo(0, 0, 7, "AC", "yu",
                       w.WFDB_AC_COUPLED | w.WFDB_CAL_UNDEF)
        assert w.putcal(test) == 0
        assert w.putcal(ac) == 0
        assert cal("TEST signal", "xu") == [0, -1.5, 2.5, 3, 5, "TEST", "xu"]
        w.flushcal()
        assert cal("ECG", "mV") == [-1]
        w.putcal(test)
        w.putcal(ac)
        w.putcal(w.Calinfo(1, 2, 0.25, "SQ", "zu",
                           w.WFDB_DC_COUPLED | w.WFDB_CAL_SQUARE))
        w.putcal(w.Calinfo(1, 2, 0.25, "SAW", "zu",
                           w.WFDB_AC_COUPLED | w.WFDB_CAL_SAWTOOTH))
        w.wfdbquiet()
        assert w.newcal("my.cal") == -1        # illegal name
        w.wfdbverbose()
        assert w.newcal("mycal") == 0
        assert readfile("mycal") == (
            b"TEST\t-1.5 2.5 sine 3 xu\r\n"
            b"AC\t- - undefined 7 yu\r\n"
            b"SQ\t1 2 square 0.25 zu\r\n"
            b"SAW\t- 2 sawtooth 0.25 zu\r\n")
        assert w.calopen("mycal") == 0
        assert cal("AC", "yu") == [0, 0, 0, 7, 0, "AC", "yu"]
        assert cal("ECG", "mV") == [-1]
        assert w.calopen("+wfdbcal") == 0
        assert cal("ECG", "mV") == [0, 0, 1, 1, 4, "ECG", "mV"]
        assert cal("SAW", None) == [0, 0, 2, 0.25, 6, "SAW", "zu"]
        w.wfdbquiet()
        assert w.calopen("nosuch.cal") == -2
    finally:
        w.wfdbverbose()
        w.flushcal()


# ---------------------------------------------------------------------------
# t_annot

def test_input_annotators(datadir):
    assert w.getafreq() == 0
    isig("100s")
    ai = [w.Anninfo("atr", w.WFDB_READ), w.Anninfo("ooo", w.WFDB_READ)]
    assert w.annopen("100s", ai, 2) == 0
    assert [w.getiafreq(0), w.getiafreq(1), w.getiafreq(2)] == [360, 360, -2]
    assert [w.getiaorigfreq(0), w.getiaorigfreq(1), w.getiaorigfreq(2)] == \
        [0, 360, -2]
    assert ann(0) == [0, 18, 28, 0, 0, 0]
    assert ann(0) == [0, 77, 1, 0, 0, 0]
    w.setiafreq(0, 1000.0)
    assert w.getiafreq(0) == 1000
    assert w.getiaorigfreq(0) == 0
    a = w.Annotation()
    assert w.getann(0, a) == 0
    assert [a.time, a.anntyp] == [1028, 1]
    w.wfdbquiet()
    try:
        assert w.ungetann(0, a) == 0
        assert w.ungetann(0, a) == -1        # the pushback buffer is full
        assert w.ungetann(5, a) == -2
    finally:
        w.wfdbverbose()
    assert ann(0) == [0, 1028, 1, 0, 0, 0]
    assert ann(0) == [0, 1839, 1, 0, 0, 0]
    assert w.ungetann(0, w.Annotation(time=5, anntyp=w.PVC, subtyp=0)) == 0
    assert ann(0) == [0, 5, 5, 0, 0, 0]
    w.setiafreq(0, 0.0)
    assert w.getiafreq(0) == 360
    assert ann(0) == [0, 946, 1, 0, 0, 0]
    w.iannclose(0)     # annotator 1 (ooo) becomes annotator 0
    assert [w.getiafreq(0), w.getiafreq(1)] == [360, -2]
    assert ann(0) == [0, 18, 1, 0, 0, 0]
    w.wfdbquiet()
    try:
        assert ann(1)[0] == -2
        w.iannclose(0)
        assert ann(0)[0] == -2
        w.iannclose(3)
    finally:
        w.wfdbverbose()
    w.wfdbquit()


def test_annotation_time_resolution(datadir):
    w.setafreq(1000.0)
    try:
        assert w.getafreq() == 1000
        w.annopen("100s", [w.Anninfo("hf", w.WFDB_WRITE)])
        w.putann(0, w.Annotation(time=1000, anntyp=w.NORMAL))
        w.putann(0, w.Annotation(time=2500, anntyp=w.NORMAL))
        w.wfdbquit()
        assert w.getafreq() == 1000
    finally:
        w.setafreq(0.0)
    w.annopen("100s", [w.Anninfo("hf", w.WFDB_READ)])
    assert w.getiafreq(0) == 1000
    assert w.getiaorigfreq(0) == 1000
    assert ann(0) == [0, 1000, 1, 0, 0, 0]
    w.setiafreq(0, 360.0)
    assert w.getiafreq(0) == 360
    assert ann(0) == [0, 900, 1, 0, 0, 0]


# ---------------------------------------------------------------------------
# t_strings

def test_ecgstr(datadir):
    assert [w.ecgstr(c) for c in (1, 0, 15, 22, 50, -1)] == \
        ["N", " ", "[15]", '"', "[50]", "[-1]"]
    assert [w.strecg("V"), w.strecg("xx"), w.strecg(""),
            w.strecg("[15]")] == [5, 0, 0, 15]
    try:
        assert w.setecgstr(5, "PVC") == 0
        assert w.ecgstr(5) == "PVC"
        assert w.annstr(5) == "V"
        assert [w.strecg("PVC"), w.strecg("V")] == [5, 0]
        w.wfdbquiet()
        assert w.setecgstr(50, "x") == -1
        assert w.setecgstr(-1, "x") == -1
        w.wfdbverbose()
        assert w.setecgstr(0, "Z") == 0
        assert w.ecgstr(0) == "Z"
    finally:
        w.wfdbverbose()
        w.setecgstr(5, "V")
        w.setecgstr(0, " ")


def test_annstr_anndesc(datadir):
    from wfdbx import _annot
    try:
        assert w.setannstr(5, "pvc") == 0
        assert w.annstr(5) == "pvc"
        assert w.ecgstr(5) == "V"
        assert [w.strann("pvc"), w.strann("V")] == [5, 0]
        assert w.setannstr(-6, "fus") == 0
        assert w.annstr(6) == "fus"
        w.wfdbquiet()
        assert w.setannstr(60, "x") == -1
        assert w.setannstr(-60, "x") == -1
        w.wfdbverbose()
        assert w.setannstr(0, "zero") == 0
        assert w.annstr(0) == "zero"
        assert w.annstr(60) == "[60]"
        assert w.setannstr(42, "new") == 0
        assert w.strann("new") == 42
        assert w.anndesc(1) == "Normal beat"
        assert w.anndesc(15) is None
        assert w.anndesc(60) == "illegal annotation code"
        assert w.anndesc(-1) == "illegal annotation code"
        assert w.setanndesc(15, "my description") == 0
        assert w.anndesc(15) == "my description"
        assert w.setanndesc(-43, "negative") == 0
        assert w.anndesc(43) == "negative"
        w.wfdbquiet()
        assert w.setanndesc(50, "x") == -1
        w.wfdbverbose()

        # Modified mnemonics (but not those set with a negative code) are
        # written into output annotation files ...
        w.annopen("100s", [w.Anninfo("mod", w.WFDB_WRITE)])
        w.putann(0, w.Annotation(time=10, anntyp=w.PVC))
        w.wfdbquit()
        assert readfile("100s.mod") == bytes.fromhex(
            "0058 1efc" + b"## annotation type definitions".hex() +
            "0058 27fc" + b"5 pvc Premature ventricular contraction".hex()
            + "00" +
            "0058 16fc" + b"15 [15] my description".hex() +
            "0058 07fc" + b"42 new ".hex() + "00" +
            "0058 15fc" + b"## end of definitions".hex() + "00" +
            "00ec ffff ffff 0100 0a14 0000")
        w.setannstr(5, "V")
        w.setannstr(-6, "F")
        w.setannstr(0, " ")
        w.setannstr(-42, "[42]")
        w.setanndesc(-15, "")
        w.setanndesc(-43, "")
        # ... and reading the file defines them again.
        w.annopen("100s", [w.Anninfo("mod", w.WFDB_READ)])
        assert ann(0) == [0, 10, 5, 0, 0, 0]
        assert w.annstr(5) == "pvc"
        assert w.anndesc(15) == "my description"
        assert w.anndesc(42) == ""
        w.wfdbquit()
    finally:
        w.wfdbverbose()
        # Restore the mnemonics, descriptions, and the (private) flags of
        # modified codes, which no library function resets.
        for c, s in ((5, "V"), (6, "F"), (0, " "), (42, "[42]")):
            w.setannstr(-c, s)
        w.setanndesc(-5, "Premature ventricular contraction")
        _annot._tstring[15] = None
        _annot._tstring[42] = None
        _annot._tstring[43] = None
        _annot._a.modified[:] = [0] * len(_annot._a.modified)


# ---------------------------------------------------------------------------
# t_maps

MAPS = """\
-1: 0 0 0 0 0 79 79
0: 0 0 0 0 0 79 79
1: 1 1 1 1 1 78 78
2: 1 1 1 1 1 78 78
3: 1 1 1 1 1 78 78
4: 1 1 1 9 1 78 78
5: 1 1 5 5 1 86 86
6: 1 1 6 6 1 70 70
7: 1 1 1 9 1 78 78
8: 1 1 1 9 1 78 78
9: 1 1 1 9 1 78 78
10: 1 1 5 5 1 69 69
11: 1 1 1 1 1 78 78
12: 1 1 1 1 1 80 80
13: 1 1 1 1 1 81 81
14: 1 0 0 0 2 79 85
15: 1 0 0 0 0 79 79
16: 1 0 0 0 2 79 79
17: 1 0 0 0 0 79 79
18: 1 0 0 0 2 79 79
19: 1 0 0 0 2 79 79
20: 1 0 0 0 2 79 79
21: 1 0 0 0 2 79 79
22: 1 0 0 0 2 79 79
23: 1 0 0 0 2 79 79
24: 1 0 0 0 2 79 79
25: 1 1 1 1 1 78 78
26: 1 0 0 0 2 79 79
27: 1 0 0 0 2 79 79
28: 1 0 0 0 3 79 79
29: 1 0 0 0 2 79 79
30: 1 1 30 30 1 81 81
31: 1 1 5 5 1 79 79
32: 1 0 0 0 1 91 91
33: 1 0 0 0 1 93 93
34: 1 1 1 1 1 78 78
35: 1 1 1 1 1 78 78
36: 1 0 0 0 2 79 79
37: 1 0 0 0 2 79 79
38: 1 1 1 1 1 78 78
39: 1 0 0 0 2 79 79
40: 1 0 0 0 2 79 79
41: 1 1 5 5 1 82 82
42: 1 0 0 0 0 79 79
43: 1 0 0 0 0 79 79
44: 1 0 0 0 0 79 79
45: 1 0 0 0 0 79 79
46: 1 0 0 0 0 79 79
47: 1 0 0 0 0 79 79
48: 1 0 0 0 0 79 79
49: 1 0 0 0 0 79 79
50: 0 0 0 0 0 79 79
"""

# ammap of the codes 'C' to '_'
AMMAP = [0, 0, 10, 6, 0, 0, 0, 0, 0, 0, 0, 1, 22, 12, 13, 41, 0, 0, 14, 5,
         0, 0, 0, 0, 32, 0, 33, 0, 0]


def test_code_maps():
    # (in Python, these are isann, isqrs, ... without the wfdb_ prefix)
    for line in MAPS.splitlines():
        code, values = line.split(":")
        c = int(code)
        assert [w.isann(c), w.isqrs(c), w.map1(c), w.map2(c), w.annpos(c),
                w.mamap(c, 0), w.mamap(c, -1)] == \
            [int(x) for x in values.split()], c
    assert [w.ammap(c) for c in range(ord("C"), ord("_") + 1)] == AMMAP
    try:
        assert w.setisqrs(1, 0) == 0
        assert w.isqrs(1) == 0
        assert w.setisqrs(60, 1) == 0
        assert w.setisqrs(2, 300) == 44     # (stored in a char)
        assert w.isqrs(2) == 44
        assert w.setmap1(14, w.PVC) == 5
        assert w.map1(14) == 5
        assert w.setmap1(0, w.PVC) == 0
        assert w.setmap2(14, w.SVPB) == 9
        assert w.map2(14) == 9
        assert w.setmap2(-3, w.PVC) == 0
        assert w.setannpos(14, 6) == 6
        assert w.annpos(14) == 6
        assert w.setannpos(50, 2) == 0
    finally:
        w.setisqrs(1, 1)
        w.setisqrs(2, 1)
        w.setmap1(14, w.NOTQRS)
        w.setmap2(14, w.NOTQRS)
        w.setannpos(14, 2)


# ---------------------------------------------------------------------------
# t_extra

def test_default_calibration_file(datadir):
    try:
        assert w.calopen(None) == 0     # $WFDBCAL (wfdbcal, set by setwfdb)
        assert cal("Resp", None) == [0, 0, 0, 1, 0, "Resp", "l"]
    finally:
        w.flushcal()


def test_uncalibrated_signals(datadir):
    isig("null")        # gain 0 (wfdb-x: no default gain; C assumed 200)
    w.wfdbquiet()
    try:
        assert [w.adumuv(0, 100), w.muvadu(1, 100)] == [-32768, -32768]
        assert math.isnan(w.aduphys(0, 100))
        assert w.physadu(1, 0.5) == -32768
    finally:
        w.wfdbverbose()
    assert vec(2) == [2, -32768, -32768]


def test_getframe_deskew(datadir):
    isig("skew")
    assert vec(3, w.getframe) == [3, -7, 21, -32768]
    assert vec(3, w.getframe) == [3, 4, -14, -85]
    w.isigsettime(1497)
    assert vec(3, w.getframe) == [-1, -32755, 16705, -32768]
    assert vec(3, w.getframe) == [-1, -32751, -14, 16705]


def test_multifrequency_resampling(datadir):
    isig("mfreq")
    assert w.setifreq(200.0) == 0
    assert vec(3) == [3, 138, 1459, 499]
    assert vec(3) == [3, 2677, 738, 1381]
    assert vec(3) == [3, 2677, 738, 1381]
    assert w.getafreq() == 200      # (setifreq also calls setafreq)
    w.setafreq(0.0)
    w.wfdbquit()
    isig("mfreq")
    assert [w.sample(2, 10), w.sample_valid()] == [869, 1]
    assert [w.sample(1, 599), w.sample_valid()] == [637, 1]
    w.wfdbquit()
    isig("multi")
    assert w.isigsettime(100) == 0
    assert w.tnextvec(0, 21650) == 23450
    assert vec(2) == [2, 969, 996]


def test_flac_failed_seek(datadir):
    # After a failed seek (past the end of a FLAC stream), libFLAC aborts
    # the decoding of the next block in the C library: getvec fails, and so
    # do later seeks; a seek to the current time is not performed.
    assert isig("flac16") == 3
    assert w.isigsettime(99999) == -1
    assert vec(3) == [-3, 0, 0, 0]
    assert w.isigsettime(0) == -1
    assert vec(3) == [-3, 0, 0, 0]
    w.wfdbquit()
    isig("flac16")
    assert w.isigsettime(99999) == -1
    assert w.isigsettime(5) == 0
    assert vec(3) == [3, -77, -57, -47]
    w.wfdbquit()
    isig("flac16")
    assert vec(3) == [3, -31, -38, -33]
    assert w.isigsettime(9001) == -1
    assert w.isigsettime(1) == 0
    assert vec(3) == [-3, 0, 0, 0]


def test_strtim_out_of_range():
    # Frame numbers without a record (frame frequency 0) and times out of
    # the range of WFDB_Time: the C conversion of the double gives LONG_MIN
    # on x86-64 (and "[...]" times wrap around as WFDB_Time differences).
    # (wfdb-x: without a sampling frequency, strtim fails for these strings
    # and returns 0; a frequency of 1 Hz is set for the out-of-range times.)
    w.wfdbquit()
    w.wfdbquiet()
    try:
        assert w.strtim("f5") == 0
        assert w.strtim("1e300") == 0
        w.setsampfreq(1.0)
        assert w.strtim("1e300") == -2 ** 63
        assert w.strtim("1:1e300") == -2 ** 63
    finally:
        w.setsampfreq(0.0)
        w.wfdbverbose()


# t_nodefaults (wfdb-x: no default sampling frequency, gain, ADC resolution
# or units; see docs/DIVERGENCES.md)

def test_time_needs_freq():
    w.setcfreq(10.0)    # (a counter frequency is defined in api_expect.c)
    try:
        ts = ["s10", "e", "i", "o", "c10", "f3", "10", "1:0", "[10:00:00]",
              " s5", ""]
        assert [w.wfdbx_time_needs_freq(t) for t in ts] == \
            [0, 0, 0, 0, 1, 1, 1, 1, 1, 0, 1]
        w.setcfreq(0.0)
        assert w.wfdbx_time_needs_freq("c10") == 0
    finally:
        w.setcfreq(0.0)


def test_no_default_frequency(datadir):
    w.wfdbquiet()
    try:
        # no input record: no sampling frequency
        assert w.strtim("1:0") == 0
        assert w.wfdberror() == "strtim: sampling frequency is not " \
            "specified\n"
        assert w.strtim("s10") == 10
        assert w.timstr(360) == "s360"
        assert w.wfdberror() == "timstr: sampling frequency is not " \
            "specified\n"
        assert w.mstimstr(-360) == "s360"
        assert w.wfdberror() == "mstimstr: sampling frequency is not " \
            "specified\n"
        # a header without a sampling frequency
        with open("nf.hea", "w") as f:
            f.write("nf 2\n100s.dat 212 200 11 1024 995 21537 0 MLII\n"
                    "100s.dat 212 200 11 1024 1011 -3962 0 V5\n")
        assert isig("nf") == 2
        assert w.sampfreq(None) == 0
        assert w.getifreq() == 0
        assert w.setifreq(100.0) == -1
        assert w.wfdberror() == "setifreq: sampling frequency is not " \
            "specified\n"
        assert w.strtim("2") == 0
        assert w.strtim("e") == 0
        assert w.mstimstr(100) == "s100"
        w.wfdbquit()
        # a frequency set by the caller applies
        assert w.setsampfreq(500.0) == 0
        assert isig("nf") == 2
        assert w.sampfreq(None) == 500
        assert w.strtim("2") == 1000
        assert w.mstimstr(100) == "    0:00.200"
        w.wfdbquit()
        assert w.sampfreq("nf") == 0
        w.wfdbquit()
    finally:
        w.wfdbverbose()


def test_no_default_gain(datadir):
    w.wfdbquiet()
    try:
        # uncalibrated signals (record null) and invalid signal numbers
        isig("null")
        assert math.isnan(w.aduphys(0, 100))
        assert w.wfdberror() == "aduphys: signal 0 is uncalibrated\n"
        assert w.physadu(0, 1.0) == -32768
        assert w.wfdberror() == "physadu: signal 0 is uncalibrated\n"
        assert w.adumuv(1, 100) == -32768
        assert w.muvadu(1, 100) == -32768
        assert w.wfdberror() == "muvadu: signal 1 is uncalibrated\n"
        w.wfdbquit()
        isig("100s")
        assert w.aduphys(0, 1124) == 0.5
        assert w.physadu(1, -0.5) == 924
        assert w.adumuv(0, 100) == 500
        assert w.muvadu(0, 1000) == 200
        assert math.isnan(w.aduphys(5, 100))
        assert w.wfdberror() == "aduphys: invalid signal number 5\n"
        assert w.physadu(5, 1.0) == -32768
        assert w.adumuv(2, 100) == -32768
        assert w.muvadu(2, 100) == -32768
        assert w.wfdberror() == "muvadu: invalid signal number 2\n"
        w.wfdbquit()
    finally:
        w.wfdbverbose()


def test_no_default_resolution_or_units(datadir):
    # no default ADC resolution: 0 if the header does not give it; no
    # default units (C: 12 bits for format 212, and millivolts)
    with open("nr.hea", "w") as f:
        f.write("nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n")
    si = []
    assert w.isigopen("nr", si, 8) == 2
    assert [s.adcres for s in si] == [0, 0]
    assert si[0].units is None
    w.wfdbquit()
    si = []
    w.isigopen("100s", si, 8)
    assert [s.adcres for s in si] == [11, 11]
    w.wfdbquit()


# t_legacy (wfdb-x: legacy mode, the original library's built-in defaults;
# see docs/DIVERGENCES.md)

def test_legacy(datadir):
    assert w.wfdbx_set_legacy(1) == 0
    try:
        assert w.wfdbx_get_legacy() == 1
        # amplitude conversion (gain 200, baseline 1024; invalid signal
        # numbers: gain 200, baseline 0)
        isig("100s")
        assert [w.adumuv(0, 200), w.adumuv(0, -37), w.adumuv(1, 1),
                w.adumuv(0, -1), w.adumuv(7, 100)] == [1000, -185, 5, -5, 500]
        assert [w.muvadu(0, 1000), w.muvadu(0, -333), w.muvadu(1, 2),
                w.muvadu(9, 1000)] == [200, -67, 0, 200]
        assert w.aduphys(0, 1224) == 1
        assert abs(w.aduphys(1, 900) - -0.62) < 1e-12
        assert w.aduphys(5, 300) == 1.5
        assert [w.physadu(0, 1.0), w.physadu(1, -0.5023),
                w.physadu(5, 1.5)] == [1224, 924, 300]
        assert w.aduphys(5, 100) == 0.5
        assert w.physadu(5, 1.0) == 200
        assert w.adumuv(2, 100) == 500
        assert w.muvadu(2, 100) == 20
        w.wfdbquit()
        # uncalibrated signals (record null): gain 200
        isig("null")
        assert (w.adumuv(0, 100), w.muvadu(1, 100)) == (500, 20)
        assert w.aduphys(0, 100) == 0.5
        assert w.physadu(1, 0.5) == 100
        assert w.physadu(0, 1.0) == 200
        w.wfdbquit()
        w.wfdbquiet()
        # no input record: 1 sample per second
        assert w.strtim("1:0") == 60
        assert w.strtim("s10") == 10
        assert w.timstr(360) == "    6:00"
        assert w.mstimstr(-360) == "    6:00.000"
        # a header without a sampling frequency: 250 Hz
        with open("nf.hea", "w") as f:
            f.write("nf 2\n100s.dat 212 200 11 1024 995 21537 0 MLII\n"
                    "100s.dat 212 200 11 1024 1011 -3962 0 V5\n")
        assert isig("nf") == 2
        assert w.sampfreq(None) == 250
        assert w.getifreq() == 250
        assert w.strtim("2") == 500
        assert w.strtim("e") == 0
        assert w.mstimstr(100) == "    0:00.400"
        assert w.setifreq(100.0) == 0
        assert w.getifreq() == 100
        w.wfdbquit()
        assert w.sampfreq("nf") == 250
        w.wfdbquit()
        # setifreq with an input record but no frequency
        isig("100s")
        w.setsampfreq(0.0)
        assert w.setifreq(100.0) == -1
        assert w.wfdberror() == "setifreq: no open input record\n"
        w.wfdbquit()
        # ADC resolution inferred from the format, or WFDB_DEFRES
        with open("nr.hea", "w") as f:
            f.write("nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n")
        si = []
        assert w.isigopen("nr", si, 8) == 2
        assert [s.adcres for s in si] == [12, 12]
        w.wfdbquit()
        with open("nr3.hea", "w") as f:
            f.write("nr3 5 360 10\nfmt16.dat 16\nfmt80.dat 80\n"
                    "fmt310.dat 310\nfmt160.dat 160\nfmt24.dat 24\n")
        si = []
        assert w.isigopen("nr3", si, 8) == 5
        assert [s.adcres for s in si] == [12, 8, 10, 16, 12]
        w.wfdbquit()
        w.wfdbverbose()
        assert w.wfdbx_set_legacy(0) == 1
        assert w.wfdbx_get_legacy() == 0
    finally:
        w.wfdbx_set_legacy(0)
        w.wfdbverbose()


def test_legacy_args():
    try:
        argv = ["rdsamp", "--legacy", "-r", "100s"]
        assert w.wfdbx_legacy_args(argv) == 1
        assert argv == ["rdsamp", "-r", "100s"] and w.wfdbx_get_legacy() == 1
        w.wfdbx_set_legacy(0)
        for argv in (["rdsamp"], ["rdsamp", "-r", "--legacy"],
                     ["rdsamp", "--legacy=1"]):
            before = list(argv)
            assert w.wfdbx_legacy_args(argv) == 0
            assert argv == before and w.wfdbx_get_legacy() == 0
    finally:
        w.wfdbx_set_legacy(0)


# ---------------------------------------------------------------------------
# t_outdir: the output directory (wfdbx_set_output_dir), the in-process
# sorting of an annotation file written there, and absolute paths (WFDB-x)

OREC_OAT = bytes.fromhex(
    "00581efc232320616e6e6f746174696f6e207479706520646566696e6974696f"
    "6e73005816fc3135205b31355d206d79206465736372697074696f6e005807fc"
    "3432206e65772000005815fc232320656e64206f6620646566696e6974696f6e"
    "730000ecffffffff0100050405140a040a040000")

OREC_SRT = OREC_OAT[:-10] + bytes.fromhex("0a040a040a040000")  # (t_sortfix)


def annopen_write(record, name):
    assert w.annopen(record, [w.Anninfo(name, w.WFDB_WRITE)], 1) == 0


def test_output_dir(datadir):
    from wfdbx import _annot
    try:
        w.setcfreq(0.0)     # (these survive wfdbquit)
        w.setafreq(0.0)
        # (the annotation type table, as left by t_strings in api_expect.c)
        w.setanndesc(15, "my description")
        w.setannstr(42, "new")
        w.setanndesc(42, "")
        assert w.wfdbx_get_output_dir() is None
        os.mkdir("odir")
        assert w.wfdbx_set_output_dir("odir") is None
        assert w.wfdbx_get_output_dir() == "odir"
        si = [w.Siginfo(fname="orec.dat", desc="sig", gain=200, fmt=16,
                        adcres=12)]
        w.setsampfreq(100.0)
        assert w.osigfopen(si, 1) == 1
        for i in range(3):
            w.putvec([10 * i - 7])
        assert w.newheader("orec") == 0
        assert w.annopen("orec", [w.Anninfo("oat", w.WFDB_WRITE)], 1) == 0
        a = w.Annotation()
        for i, t in enumerate([30, 10, 20, 10, 5]):  # out of order, duplicate
            a.time = t
            a.anntyp = w.PVC if i == 3 else w.NORMAL
            w.putann(0, a)
        w.wfdbquiet()
        w.wfdbquit()
        w.wfdbverbose()
        assert w.wfdbx_set_output_dir("") == "odir"
        assert w.wfdbx_get_output_dir() is None
        assert w.wfdbx_set_output_dir("odir2") is None
        assert w.wfdbx_set_output_dir(None) == "odir2"
        assert w.wfdbx_get_output_dir() is None
        assert readfile("odir/orec.hea") == \
            b"orec 1 100 3\r\norec.dat 16 200 12 0 -7 9 0 sig\r\n"
        assert readfile("odir/orec.dat") == bytes.fromhex("f9ff03000d00")
        assert readfile("odir/orec.oat") == OREC_OAT
        assert not os.path.exists("orec.hea")
        # a missing output directory is created (as are the missing
        # directories of any output file name)
        w.wfdbx_set_output_dir("newdir")
        assert w.osigfopen(si, 1) == 1
        assert w.annopen("orec", [w.Anninfo("oat", w.WFDB_WRITE)], 1) == 0
        w.wfdbquit()
        w.wfdbx_set_output_dir(None)
        assert (os.path.getsize("newdir/orec.dat"),
                os.path.getsize("newdir/orec.oat")) == (0, 2)
        # reading the record from the output directory
        w.setwfdb("odir")
        assert isig("orec") == 1
        assert [vec(1) for _ in range(3)] == [[1, -7], [1, 3], [1, 13]]
        assert w.annopen("orec", [w.Anninfo("oat", w.WFDB_READ)], 1) == 0
        assert [ann(0) for _ in range(5)] == [
            [0, 5, 1, 0, 0, 0], [0, 10, 5, 0, 0, 0], [0, 20, 1, 0, 0, 0],
            [0, 30, 1, 0, 0, 0], [-1, 0, 0, 0, 0, 0]]
        w.wfdbquit()
        w.setwfdb(".")      # (resetwfdb in api_expect.c, with WFDB=.)
        # t_sortfix: an out-of-order annotation at time 0 is not lost (it is
        # in legacy mode, as by sortann), and in legacy mode with an output
        # directory, sortann runs in that directory
        a = w.Annotation(0, w.NORMAL)
        w.wfdbquiet()
        for legacy in (0, 1):
            w.wfdbx_set_legacy(legacy)
            annopen_write("100s", "l0" if legacy else "m0")
            for t in (5, 0, 3):
                a.time = t
                w.putann(0, a)
            w.wfdbquit()
            w.wfdbx_set_output_dir("odir")
            annopen_write("orec", "lsrt" if legacy else "msrt")
            for t in (30, 10, 20):
                a.time = t
                w.putann(0, a)
            w.wfdbquit()
            w.wfdbx_set_output_dir(None)
        w.wfdbx_set_legacy(0)
        w.wfdbverbose()
        for name, times in (("m0", [0, 3, 5]), ("l0", [5])):
            assert w.annopen("100s", [w.Anninfo(name, w.WFDB_READ)], 1) == 0
            assert [ann(0) for _ in times] == [[0, t, 1, 0, 0, 0]
                                              for t in times]
            assert ann(0)[0] == -1
            w.wfdbquit()
        assert readfile("odir/orec.msrt") == readfile("odir/orec.lsrt") == \
            OREC_SRT
    finally:
        w.wfdbx_set_legacy(0)
        w.wfdbx_set_output_dir(None)
        w.wfdbverbose()
        w.setanndesc(-42, "")
        w.setannstr(-42, "[42]")
        _annot._tstring[15] = None
        _annot._tstring[42] = None
        _annot._a.modified[:] = [0] * len(_annot._a.modified)


def test_absolute_paths(datadir):
    rec = os.path.join(os.path.realpath(datadir), "100s")
    w.wfdbquiet()
    try:
        assert isig(rec) == 2
        assert vec(2) == [2, 995, 1011]
        assert w.wfdbfile("hea", rec) == rec + ".hea"
        assert w.annopen(rec, [w.Anninfo("atr", w.WFDB_READ)], 1) == 0
        assert ann(0) == [0, 18, 28, 0, 0, 0]
        w.wfdbquit()
        assert w.sampfreq(rec) == 360
        w.wfdbquit()
        assert isig(os.path.join(datadir, "nosuch")) == -1
        w.wfdbquit()
        # legacy mode: as in C, an absolute name is searched for in the WFDB
        # path (here "./" + the name) ...
        w.wfdbx_set_legacy(1)
        assert isig(rec) == -1
        assert w.annopen(rec, [w.Anninfo("atr", w.WFDB_READ)], 1) == -3
        w.wfdbquit()
        # ... unless the WFDB path has an empty component
        w.setwfdb(";")
        assert isig(rec) == 2
        assert vec(2) == [2, 995, 1011]
        w.wfdbquit()
        w.wfdbx_set_legacy(0)
        assert isig(rec) == 2
        w.wfdbquit()
    finally:
        w.wfdbx_set_legacy(0)
        w.resetwfdb()
        w.wfdbverbose()


# ---------------------------------------------------------------------------
# t_files (wfdb-x: finding files: the input directory, setwfdb and getwfdb,
# names, the output directory, files named in headers, "~" segments, network
# access).  The two curl lines of t_files (curl missing) do not apply to
# Python, which reads URLs with urllib.

def putfile(name, text):
    with open(name, "w") as f:
        f.write(text)


def test_files(datadir, monkeypatch):
    import shutil
    from wfdbx import _annot, _wfdbio
    cwd = os.path.realpath(datadir)
    monkeypatch.setattr(_wfdbio._io, "network_warned", False)
    w.wfdbquiet()
    try:
        # (the annotation type table, as left by the earlier functions of
        # api_expect.c: the annotation files written below begin with its
        # definitions)
        w.setanndesc(5, "x")    # (code 5 marked as modified)
        w.setanndesc(5, "Premature ventricular contraction")
        w.setanndesc(15, "my description")
        w.setannstr(42, "new")
        w.setanndesc(42, "")
        w.setwfdb(".")      # (as left by t_outdir)
        # the input directory
        assert w.wfdbx_set_input_dir(None) == "."
        assert w.wfdbx_get_input_dir() is None
        assert w.getwfdb() == "."
        assert w.wfdbx_set_input_dir("fsub") is None
        assert w.wfdbx_get_input_dir() == "fsub"
        assert w.getwfdb() == "fsub"
        assert w.wfdbx_set_input_dir("") == "fsub"
        assert w.wfdbx_get_input_dir() is None
        os.makedirs("fsub/data")
        shutil.copyfile("100s.dat", "fsub/sr.dat")
        shutil.copyfile("100s.atr", "fsub/sr.atr")
        putfile("fsub/sr.hea", "sr 2 360 21600\n"
                "sr.dat 212 200 11 1024 995 21537 0 MLII\n"
                "sr.dat 212 200 11 1024 1011 -3962 0 V5\n")
        shutil.copyfile("fmt16.dat", "fsub/data/a.dat")
        putfile("fsub/dd.hea", "dd 1 360 10\ndata/a.dat 16 200 12 0 0 0 0 s\n")
        w.wfdbx_set_input_dir("fsub")
        assert isig("sr") == 2
        assert vec(2) == [2, 995, 1011]
        assert w.annopen("sr", [w.Anninfo("atr", w.WFDB_READ)], 1) == 0
        assert ann(0) == [0, 18, 28, 0, 0, 0]
        assert w.wfdbfile("hea", "sr") == "fsub/sr.hea"
        assert w.wfdbfile("hea", "100s") is None        # (not searched)
        assert w.wfdbfile("sr.dat", None) == "fsub/sr.dat"
        w.wfdbquit()
        assert w.wfdbx_get_input_dir() == "fsub"
        w.wfdbx_set_input_dir("fsub/")
        assert w.wfdbfile("hea", "sr") == "fsub/sr.hea"
        w.wfdbx_set_input_dir(None)
        assert w.wfdbfile("hea", "fsub/sr") == "fsub/sr.hea"
        assert w.wfdbfile("hea", "fsub/../100s") == "fsub/../100s.hea"
        # setwfdb in normal mode
        w.setwfdb("fsub")
        assert w.wfdbx_get_input_dir() == "fsub"
        w.setwfdb(" ;fsub; ")
        assert w.wfdbx_get_input_dir() == "fsub"
        w.setwfdb("a b")
        assert w.wfdberror() == (
            "setwfdb: wfdb-x reads from a single input directory; use "
            "wfdbx_set_input_dir (or legacy mode for the WFDB search path)\n")
        assert w.wfdbx_get_input_dir() == "fsub"
        w.setwfdb("a:b")
        assert w.wfdbx_get_input_dir() == "fsub"
        w.setwfdb("http://127.0.0.1:1/db")
        assert w.getwfdb() == "http://127.0.0.1:1/db"
        w.setwfdb(";")
        assert w.wfdbx_get_input_dir() is None
        assert w.getwfdb() == "."
        w.setwfdb("fsub")
        w.wfdbx_set_input_dir("x")
        w.resetwfdb()
        assert w.wfdbx_get_input_dir() == "fsub"
        w.wfdbx_set_input_dir("x")
        w.wfdbquit()                # (leaves the input directory as it is)
        assert w.wfdbx_get_input_dir() == "x"
        w.setwfdb(None)
        assert w.wfdbx_get_input_dir() is None
        # legacy mode: the WFDB path; ".." is refused; the input directory
        # is not used
        w.wfdbx_set_legacy(1)
        w.setwfdb(".")
        w.wfdbx_set_input_dir("fsub")
        assert w.wfdbfile("hea", "fsub/../100s") is None
        assert w.wfdbfile("hea", "sr") is None
        assert w.getwfdb() == "."
        w.wfdbx_set_input_dir(None)
        w.wfdbx_set_legacy(0)
        # ~ names
        monkeypatch.setenv("HOME", cwd)
        assert w.wfdbfile("hea", "~/100s") == cwd + "/100s.hea"
        assert isig("~/fsub/sr") == 2
        w.wfdbquit()
        assert w.wfdbfile("hea", "~nosuchuser-wfdbx/100s") is None
        # the output directory
        assert w.wfdbx_set_output_dir("http://127.0.0.1:1/out") is None
        assert w.wfdberror() == ("wfdbx_set_output_dir: the output "
                                 "directory must be a local directory\n")
        assert w.wfdbx_set_output_dir("odir3") is None
        assert w.wfdbx_set_output_dir("https://127.0.0.1:1/out") == "odir3"
        assert w.wfdbx_get_output_dir() == "odir3"
        a = w.Annotation(0, w.NORMAL)
        fx = [w.Anninfo("fx", w.WFDB_WRITE)]
        assert w.annopen("fsub/sr", fx, 1) == 0
        w.putann(0, a)
        assert w.annopen(cwd + "/fsub/sr", fx, 1) == 0
        w.putann(0, a)
        w.wfdbquit()
        assert (os.path.getsize("odir3/fsub/sr.fx"),
                os.path.getsize("fsub/sr.fx")) == (152, 152)
        w.wfdbx_set_output_dir("~/odir4")
        assert w.annopen("sr", fx, 1) == 0
        w.putann(0, a)
        w.wfdbquit()
        assert os.path.getsize("odir4/sr.fx") == 152
        assert w.annopen("http://127.0.0.1:1/sr", fx, 1) == -4
        w.wfdbquit()
        w.wfdbx_set_output_dir(None)
        # files named in headers
        assert isig("fsub/dd") == 1
        assert [vec(1) for _ in range(3)] == [[1, -7], [1, 32], [1, -33]]
        w.wfdbquit()
        for bad in ("../100s.dat", "/100s.dat", "~/100s.dat",
                    "http://127.0.0.1:1/100s.dat", "data/../../100s.dat",
                    ".."):
            putfile("fsub/bad.hea",
                    "bad 2 360 10\n%s 16\ndata/a.dat 16\n" % bad)
            assert isig("fsub/bad") == 1
            assert w.wfdberror() == (
                "init: file %s named in the header of record fsub/bad is not "
                "in the header's directory\n" % bad)
            w.wfdbquit()
        putfile("fsub/ok.hea", "ok 1 360 10\nx..y.dat 16\n")
        shutil.copyfile("fmt16.dat", "fsub/x..y.dat")
        assert isig("fsub/ok") == 1
        w.wfdbquit()
        # segments: a null segment (~), and a segment outside the directory
        putfile("fsub/ms.hea", "ms/3 1 360 20\nms_0 0\n~ 10\ndd 10\n")
        putfile("fsub/ms_0.hea", "ms_0 1 360 0\n~ 0 200 12 0 0 0 0 s\n")
        assert isig("fsub/ms") == 1
        got = [vec(1) for _ in range(12)]
        assert [got[i] for i in (0, 9, 10, 11)] == \
            [[1, -32768], [1, -32768], [1, -7], [1, 32]]
        w.wfdbquit()
        putfile("fsub/ms2.hea", "ms2/2 1 360 20\ndd 10\n../fsub/dd 10\n")
        assert isig("fsub/ms2") == 1
        assert w.isigsettime(10) == -1
        w.wfdbquit()
        # network access (off by default)
        assert w.wfdbx_get_network() == 0
        msg = ("wfdb-x: network access is disabled; set WFDBX_NETWORK=1 or "
               "call wfdbx_set_network(1) to open http://127.0.0.1:1/x.hea\n")
        assert w.wfdbfile("hea", "http://127.0.0.1:1/x") is None
        assert w.wfdberror() == msg
        assert w.wfdbfile("hea", "http://127.0.0.1:1/y") is None
        assert w.wfdberror() == msg     # (printed once)
        assert w.wfdbx_set_network(1) == 0
        assert w.wfdbx_get_network() == 1
        assert w.wfdbfile("hea", "http://127.0.0.1:1/x") is None
        assert w.wfdberror() == msg     # (a failed fetch: no message)
        assert w.wfdbx_set_network(-1) == 1
        assert w.wfdbx_get_network() == 0
        assert w.wfdbx_set_network(0) == 0
    finally:
        w.wfdbquit()
        w.setanndesc(-42, "")
        w.setannstr(-42, "[42]")
        _annot._tstring[15] = None
        _annot._tstring[42] = None
        _annot._a.modified[:] = [0] * len(_annot._a.modified)
        w.wfdbx_set_legacy(0)
        w.wfdbx_set_network(None)
        w.wfdbx_set_output_dir(None)
        w.setwfdb(".")
        w.wfdbverbose()


# ---------------------------------------------------------------------------
# t_alias

def _fmt16_spec(fname):
    return [w.Siginfo(fname=fname, desc="s%d" % i, units="mV", gain=100,
                      group=0, fmt=16, adcres=12) for i in range(3)]


def test_output_file_is_input_file(datadir, capfd):
    """An output signal file is never a signal file of the open input record
    (the files are compared, not their names); legacy mode: no check."""
    with open("fmt16.dat", "rb") as f:
        fmt16 = f.read()
    with open("fmt212.dat", "rb") as f:
        fmt212 = f.read()
    os.link("fmt16.dat", "ahard16.dat")
    capfd.readouterr()
    # an open signal file; under another name; a hard link; a segment of a
    # multi-segment record that is not open yet (fmt212, vlay's last)
    for rec, fname in [("fmt16", "fmt16.dat"), ("fmt16", "./fmt16.dat"),
                       ("fmt16", "ahard16.dat"), ("skew", "fmt16.dat"),
                       ("vlay", "fmt16.dat"), ("vlay", "fmt212.dat")]:
        w.wfdbquit()
        assert w.isigopen(rec, [], 3) == 3
        w.setsampfreq(250.0)
        capfd.readouterr()     # (vlay: a sigmap_init message)
        assert w.osigfopen(_fmt16_spec(fname), 3) == -3
        assert capfd.readouterr().err == \
            "osigfopen: output file %s is also an input file\n" % fname
        v = [0] * 3
        assert w.getvec(v) == 3        # the input is still readable
    # osigopen names itself
    w.wfdbquit()
    assert w.isigopen("fmt16", [], 3) == 3
    capfd.readouterr()
    assert w.osigopen("fmt16", [], 3) == -3
    assert capfd.readouterr().err == \
        "osigopen: output file fmt16.dat is also an input file\n"
    w.wfdbquit()
    with open("fmt16.dat", "rb") as f:
        assert f.read() == fmt16
    with open("fmt212.dat", "rb") as f:
        assert f.read() == fmt212
    # not an input file: another file, a file that does not exist yet
    for fname in ("fmt8.dat", "new.dat"):
        assert w.isigopen("vlay", [], 3) == 3
        w.setsampfreq(250.0)
        assert w.osigfopen(_fmt16_spec(fname), 3) == 3
        w.wfdbquit()
    capfd.readouterr()
    # with no input record open, any file can be written
    w.setsampfreq(250.0)
    assert w.osigfopen(_fmt16_spec("fmt8.dat"), 3) == 3
    w.wfdbquit()
    assert capfd.readouterr().err == ""
    # legacy mode: the original behavior (the file is created, truncated)
    previous = w.wfdbx_set_legacy(1)
    try:
        assert w.isigopen("fmt16", [], 3) == 3
        w.setsampfreq(250.0)
        assert w.osigfopen(_fmt16_spec("fmt16.dat"), 3) == 3
        w.wfdbquit()
    finally:
        w.wfdbx_set_legacy(previous)
    assert os.path.getsize("fmt16.dat") == 0
