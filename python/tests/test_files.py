"""Tests of finding files (wfdb-x): the input directory, the output
directory, network access, files named in headers, and legacy mode.

Remote files are served by a local HTTP server (127.0.0.1): no test contacts
another host.  (See also test_api.py::test_files, the counterpart of t_files
in tests/reference/api_expect.c.)

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
tests wfdb-x; it has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import functools
import http.server
import os
import shutil
import subprocess
import sys
import threading

import pytest

import wfdbx as w
from wfdbx import _wfdbio

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(os.path.dirname(HERE), "src")

SR_HEA = ("sr 2 360 21600\n"
          "sr.dat 212 200 11 1024 995 21537 0 MLII\n"
          "sr.dat 212 200 11 1024 1011 -3962 0 V5\n")
NET_OFF = ("wfdb-x: network access is disabled; set WFDBX_NETWORK=1 or call "
           "wfdbx_set_network(1) to open %s\n")
WFDB_IGNORED = ("wfdb-x: the WFDB environment variable is ignored; set "
                "WFDBX_INPUT_DIR instead (or use legacy mode)\n")


def putfile(name, data):
    os.makedirs(os.path.dirname(name) or ".", exist_ok=True)
    with open(name, "wb" if isinstance(data, bytes) else "w") as f:
        f.write(data)


def make_sr(d):
    """Record sr (a copy of 100s) in directory d."""
    putfile(os.path.join(d, "sr.hea"), SR_HEA)
    shutil.copyfile("100s.dat", os.path.join(d, "sr.dat"))
    shutil.copyfile("100s.atr", os.path.join(d, "sr.atr"))


@pytest.fixture
def settings(datadir, monkeypatch):
    """datadir, with the settings at their defaults (no input or output
    directory, network off, messages not yet printed) and restored
    afterwards; HOME is the subdirectory home of datadir."""
    for k in ("WFDB", "WFDBX_INPUT_DIR", "WFDBX_OUTPUT_DIR", "WFDBX_NETWORK"):
        monkeypatch.delenv(k, raising=False)
    home = os.path.join(os.path.realpath(datadir), "home")
    os.mkdir(home)
    monkeypatch.setenv("HOME", home)
    for k, v in (("network_warned", False), ("fetched", {}),
                 ("setwfdb_called", False), ("setwfdb_input_dir", None)):
        monkeypatch.setattr(_wfdbio._io, k, v)
    w.wfdbx_set_input_dir(None)
    w.wfdbx_set_output_dir(None)
    w.wfdbx_set_network(None)
    yield datadir
    w.wfdbquit()
    w.wfdbx_set_legacy(0)
    w.wfdbx_set_input_dir(None)
    w.wfdbx_set_output_dir(None)
    w.wfdbx_set_network(None)
    w.wfdbverbose()


class Server:
    """A local HTTP server serving directory d, logging the requested
    paths."""

    def __init__(self, d):
        log = self.log = []

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                log.append(self.path)
                if self.path.startswith("/redirect/"):
                    self.send_response(302)
                    self.send_header("Location", "/www/" + self.path[10:])
                    self.end_headers()
                    return
                super().do_GET()

        self.httpd = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0), functools.partial(Handler, directory=d))
        self.url = "http://127.0.0.1:%d/" % self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()


@pytest.fixture
def server(settings):
    """A local HTTP server serving the work directory."""
    srv = Server(settings)
    yield srv
    srv.close()


def run(code, **env):
    """Run Python code in a fresh process (with the given environment
    variables, in the current directory); return (stdout, stderr)."""
    e = dict(os.environ, PYTHONPATH=SRC)
    for k in ("WFDB", "WFDBX_INPUT_DIR", "WFDBX_OUTPUT_DIR", "WFDBX_NETWORK"):
        e.pop(k, None)
    e.update(env)
    p = subprocess.run([sys.executable, "-c", "import wfdbx as w\n" + code],
                       capture_output=True, text=True, env=e)
    assert p.returncode == 0, p.stderr
    return p.stdout, p.stderr


# ---------------------------------------------------------------------------
# Settings

def test_settings_defaults_and_previous(settings):
    assert w.wfdbx_get_input_dir() is None
    assert w.wfdbx_get_output_dir() is None
    assert w.wfdbx_get_network() == 0
    assert w.wfdbx_set_input_dir("a") is None
    assert w.wfdbx_set_input_dir("b") == "a"
    assert w.wfdbx_set_input_dir("") == "b"
    assert w.wfdbx_get_input_dir() is None
    assert w.wfdbx_set_output_dir("o") is None
    assert w.wfdbx_set_output_dir(None) == "o"
    assert w.wfdbx_set_network(1) == 0
    assert w.wfdbx_set_network(True) == 1
    assert w.wfdbx_set_network(0) == 1
    assert w.wfdbx_set_network(None) == 0
    assert w.wfdbx_set_network(-1) == 0
    assert w.wfdbx_get_network() == 0


def test_settings_environment(settings):
    code = ("print(w.wfdbx_get_input_dir(), w.wfdbx_get_output_dir(), "
            "w.wfdbx_get_network())\n"
            "print(w.wfdbx_set_input_dir('x'), w.wfdbx_set_input_dir(None))\n"
            "print(w.wfdbx_set_output_dir('y'), w.wfdbx_set_output_dir(''))\n"
            "print(w.wfdbx_set_network(0), w.wfdbx_set_network(-1))\n"
            "print(w.wfdbx_get_input_dir(), w.wfdbx_get_output_dir(), "
            "w.wfdbx_get_network())\n")
    out, err = run(code, WFDBX_INPUT_DIR="in", WFDBX_OUTPUT_DIR="out",
                   WFDBX_NETWORK="1")
    assert out == "in out 1\nin x\nout y\n1 0\nin out 1\n"
    assert err == ""
    # (strtol(value) != 0)
    for value, on in (("0", 0), ("", 0), ("x", 0), (" 2", 1), ("-1", 1),
                      ("0x1", 0), ("1abc", 1)):
        out, _ = run("print(w.wfdbx_get_network())", WFDBX_NETWORK=value)
        assert out == "%d\n" % on
    out, _ = run("print(w.wfdbx_get_input_dir())", WFDBX_INPUT_DIR="")
    assert out == "None\n"
    # an output directory URL is refused
    out, err = run("print(w.wfdbx_get_output_dir())",
                   WFDBX_OUTPUT_DIR="http://127.0.0.1:1/")
    assert out == "None\n"
    assert err == ("wfdbx_set_output_dir: the output directory must be a "
                   "local directory\n")


def test_settings_survive_wfdbquit(settings):
    w.wfdbx_set_input_dir("a")
    w.wfdbx_set_output_dir("b")
    w.wfdbx_set_network(1)
    w.wfdbquit()
    assert (w.wfdbx_get_input_dir(), w.wfdbx_get_output_dir(),
            w.wfdbx_get_network()) == ("a", "b", 1)


def test_setwfdb_getwfdb(settings):
    w.wfdbquiet()
    assert w.getwfdb() == "."
    for p, d in (("sub", "sub"), ("  sub  ", "sub"), (";sub;", "sub"),
                 ("http://h:80/a", "http://h:80/a"), ("~/x", "~/x"),
                 ("@file", "@file"), ("%r", "%r"), ("", None), (";", None),
                 (None, None)):
        w.setwfdb("old")
        w.setwfdb(p)
        assert w.wfdbx_get_input_dir() == d
        assert w.getwfdb() == (d or ".")
    w.setwfdb("keep")
    for p in ("a b", "a;b", "a:b", ". http://h/x", "http://h/x:/y"):
        w.setwfdb(p)
        assert w.wfdbx_get_input_dir() == "keep"
        assert w.wfdberror().startswith("setwfdb: wfdb-x reads from a single")
    # resetwfdb restores the setting of the last setwfdb
    w.wfdbx_set_input_dir("other")
    w.resetwfdb()
    assert w.wfdbx_get_input_dir() == "keep"


def test_wfdb_variable_ignored(settings):
    make_sr("sub")
    code = ("print(w.isigopen('100s', [], 2))\nw.wfdbquit()\n"
            "print(w.isigopen('100s', [], 2))\n")
    out, err = run(code, WFDB="sub")
    assert out == "2\n2\n"
    assert err == WFDB_IGNORED          # (once)
    out, err = run("print(w.isigopen('sr', [], 2))", WFDB="sub")
    assert out == "-1\n"
    assert err == WFDB_IGNORED + "init: can't open header for record sr\n"
    # not needed for an absolute name; not printed in legacy mode, where
    # WFDB is the path
    out, err = run("print(w.isigopen(%r, [], 2))" %
                   os.path.realpath("100s"), WFDB="sub")
    assert (out, err) == ("2\n", "")
    out, err = run("w.wfdbx_set_legacy(1)\nprint(w.isigopen('sr', [], 2))",
                   WFDB="sub")
    assert (out, err) == ("2\n", "")
    out, err = run("print(w.getwfdb())", WFDB="")
    assert (out, err) == (".\n", "")


# ---------------------------------------------------------------------------
# Names

def test_names(settings):
    cwd = os.path.realpath(settings)
    make_sr("sub")
    make_sr("home/hr")
    os.makedirs("sub/deeper")
    f = w.wfdbfile
    assert f("hea", "100s") == "100s.hea"
    assert f("hea", "sub/sr") == "sub/sr.hea"
    assert f("hea", "sub/deeper/../sr") == "sub/deeper/../sr.hea"
    assert f("hea", "sub/../100s") == "sub/../100s.hea"
    assert f("hea", cwd + "/sub/sr") == cwd + "/sub/sr.hea"
    assert f("hea", "~/hr/sr") == cwd + "/home/hr/sr.hea"
    assert f("hea", "~nosuchuser-wfdbx/hr/sr") is None
    assert f("hea", "sr") is None                 # nothing is searched
    w.wfdbx_set_input_dir("sub")
    assert f("hea", "sr") == "sub/sr.hea"
    assert f("hea", "100s") is None               # nothing is searched
    assert f("hea", "../100s") == "sub/../100s.hea"
    assert f("hea", cwd + "/100s") == cwd + "/100s.hea"
    w.wfdbx_set_input_dir("sub/")
    assert f("hea", "sr") == "sub/sr.hea"         # (one separator)
    w.wfdbx_set_input_dir(cwd + "/sub")
    assert f("hea", "sr") == cwd + "/sub/sr.hea"
    w.wfdbx_set_input_dir("~/hr")
    assert f("hea", "sr") == cwd + "/home/hr/sr.hea"
    w.wfdbx_set_input_dir("~")
    assert f("hea", "hr/sr") == cwd + "/home/hr/sr.hea"
    # (the trailing '/' expansion and the 8.3 form are kept)
    w.wfdbx_set_input_dir(None)
    os.makedirs("sr")
    shutil.copyfile("sub/sr.hea", "sr/sr.hea")
    assert f("hea", "sr/") == "sr/sr.hea"
    putfile("sub/x.abc", "")
    assert f("abcdef", "sub/x") == "sub/x.abc"


def test_expand_home(settings, monkeypatch):
    e = _wfdbio._expand_home
    monkeypatch.setenv("HOME", "/h/")
    assert (e("~"), e("~/a"), e("a~"), e("x")) == ("/h", "/h/a", "a~", "x")
    monkeypatch.setenv("HOME", "")
    assert e("~/a") == "/a"
    assert e("~") == "/"
    if os.name != "nt":
        import pwd
        user = pwd.getpwuid(os.getuid())
        assert e("~" + user.pw_name + "/a") == \
            user.pw_dir.rstrip("/") + "/a"
        assert e("~nosuchuser-wfdbx/a") == "~nosuchuser-wfdbx/a"
        monkeypatch.delenv("HOME")
        assert e("~/a") == user.pw_dir.rstrip("/") + "/a"


def test_output_names(settings):
    cwd = os.path.realpath(settings)
    a = w.Annotation(0, w.NORMAL)

    def write(record, name="x"):
        st = w.annopen(record, [w.Anninfo(name, w.WFDB_WRITE)], 1)
        if st == 0:
            w.putann(0, a)
        w.wfdbquit()
        return st

    w.wfdbx_set_output_dir("out")
    assert write("r") == 0 and os.path.exists("out/r.x")
    assert write("sub/r") == 0 and os.path.exists("out/sub/r.x")
    assert write("../up") == 0 and os.path.exists("up.x")
    assert write(cwd + "/abs") == 0 and os.path.exists("abs.x")
    assert write("~/hm") == 0 and os.path.exists("home/hm.x")
    w.wfdbx_set_output_dir("~/o2")
    assert write("r") == 0 and os.path.exists("home/o2/r.x")
    w.wfdbx_set_output_dir("out/")
    assert write("r", "y") == 0 and os.path.exists("out/r.y")
    w.wfdbx_set_output_dir(None)
    w.wfdbquiet()
    assert write("http://127.0.0.1:1/r") == -4
    # legacy mode: any name in the output directory (as in round 1)
    w.wfdbx_set_legacy(1)
    w.wfdbx_set_output_dir("lout")
    assert write(cwd + "/labs") == 0
    assert os.path.exists("lout" + cwd + "/labs.x")


# ---------------------------------------------------------------------------
# Files named in headers

def test_header_relative_files(settings):
    make_sr("sub")
    putfile("sub/dd.hea", "dd 1 360 10\ndata/a.dat 16\n")
    shutil.copyfile("fmt16.dat", "sub/a.dat")
    os.makedirs("sub/data")
    shutil.copyfile("fmt16.dat", "sub/data/a.dat")
    # sr.dat is next to sub/sr.hea (not in the current directory)
    rec = w.read_record("sub/sr", sampto=2)
    assert rec.signals.tolist() == [[995, 1011], [995, 1011]]
    assert rec.siginfo[0].fname == "sr.dat"     # (as written in the header)
    assert w.read_record("sub/dd", sampto=2).signals.tolist() == [[-7], [32]]
    # a header naming a file that is not next to it: nothing is searched
    putfile("sub/sib.hea", "sib 1 360 10\n100s.dat 212\n")
    w.wfdbquiet()
    with pytest.raises(IOError):
        w.read_record("sub/sib")
    # legacy mode: the WFDB path is searched (here, ".")
    assert len(w.read_record("sub/sib", legacy=True).signals) > 0


@pytest.mark.parametrize("name", [
    "../100s.dat", "/100s.dat", "~/100s.dat", "~", "http://127.0.0.1:1/a.dat",
    "https://127.0.0.1:1/a.dat", "data/../../100s.dat", "..", "a/../b.dat"])
def test_header_containment(settings, name):
    putfile("sub/bad.hea", "bad 2 360 10\n%s 16\nok.dat 16\n" % name)
    shutil.copyfile("fmt16.dat", "sub/ok.dat")
    w.wfdbquiet()
    assert w.isigopen("sub/bad", [], 2) == 1    # (the second file opens)
    assert w.wfdberror() == ("init: file %s named in the header of record "
                             "sub/bad is not in the header's directory\n"
                             % name)


def test_header_containment_ok_names(settings):
    # ".." within a name, "-" (standard input), "./x"
    os.makedirs("sub/a..b")
    putfile("sub/ok.hea", "ok 3 360 10\nx..y.dat 16\na..b/c.dat 16\n"
            "./d.dat 16\n")
    for n in ("x..y.dat", "a..b/c.dat", "d.dat"):
        shutil.copyfile("fmt16.dat", "sub/" + n)
    assert w.isigopen("sub/ok", [], 3) == 3


def test_segments(settings):
    make_sr("sub")
    putfile("sub/dd.hea", "dd 1 360 10\ndata/a.dat 16 200 12 0 0 0 0 s\n")
    os.makedirs("sub/data")
    shutil.copyfile("fmt16.dat", "sub/data/a.dat")
    os.makedirs("sub/seg")
    putfile("sub/seg/dd.hea", "dd 1 360 10\nx.dat 16 200 12 0 0 0 0 s\n")
    shutil.copyfile("fmt16.dat", "sub/seg/x.dat")
    # a null segment (~), a layout header, and a segment in a subdirectory
    putfile("sub/ms.hea", "ms/4 1 360 30\nms_0 0\n~ 10\ndd 10\nseg/dd 10\n")
    putfile("sub/ms_0.hea", "ms_0 1 360 0\n~ 0 200 12 0 0 0 0 s\n")
    dd = w.read_record("sub/dd", sampto=9).signals[:, 0].tolist()
    rec = w.read_record("sub/ms", sampto=19)
    assert rec.signals[:, 0].tolist() == [-32768] * 10 + dd
    rec = w.read_record("sub/ms", sampfrom=20, sampto=29)     # (seg/dd)
    assert rec.signals[:, 0].tolist() == dd
    # segments outside the directory are refused
    w.wfdbquiet()
    for seg in ("../sub/dd", "/x", "~/dd", "http://127.0.0.1:1/dd"):
        putfile("sub/ms2.hea", "ms2/2 1 360 20\ndd 10\n%s 10\n" % seg)
        assert w.isigopen("sub/ms2", [], 1) == 1
        assert w.isigsettime(10) == -1
        w.wfdbquit()
    # setmsheader: the segment names are given by the caller (resolved as
    # any name)
    w.wfdbverbose()
    assert w.setmsheader("msw", ["sub/dd", "sub/seg/dd"]) == 0
    w.wfdbquit()
    with open("msw.hea") as f:
        assert f.read().splitlines()[1:3] == ["sub/dd 10", "sub/seg/dd 10"]


# ---------------------------------------------------------------------------
# Network access

def test_network_off(server):
    w.wfdbquiet()
    assert w.isigopen(server.url + "100s", [], 2) == -1
    assert w.wfdberror() == "init: can't open header for record %s100s\n" % \
        server.url
    assert server.log == []
    out, err = run("w.wfdbfile('hea', %r)\nw.wfdbfile('atr', %r)\n" %
                   (server.url + "100s", server.url + "100s"))
    assert err == NET_OFF % (server.url + "100s.hea")       # (once)
    assert server.log == []


def test_network_on(server):
    w.wfdbx_set_network(1)
    rec = w.read_record(server.url + "100s", sampto=3)
    assert rec.signals.tolist() == [[995, 1011]] * 3
    assert len(w.read_annotations(server.url + "100s", "atr")) == 75
    # each URL is requested once (the header, the signal file, the .info
    # file and its 8.3 form, which do not exist, and the annotation file)
    assert server.log == ["/100s.hea", "/100s.dat", "/100s.info",
                          "/100s.inf", "/100s.atr"]
    w.wfdbx_set_input_dir(server.url)
    assert w.read_record("100s", sampto=1).signals.tolist() == [[995, 1011]]
    assert len(server.log) == 5                   # (cached)
    assert w.wfdbfile("hea", "100s") == server.url + "100s.hea"
    w.wfdbx_set_input_dir(server.url[:-1])    # (without the final '/')
    assert w.wfdbfile("hea", "100s") == server.url + "100s.hea"


def test_network_subdirectories_and_errors(server):
    os.makedirs("www/data")
    putfile("www/rec.hea", "rec 1 360 10\ndata/a.dat 16\n")
    shutil.copyfile("fmt16.dat", "www/data/a.dat")
    putfile("www/nodat.hea", "nodat 1 360 10\nnodat.dat 16\n")
    putfile("www/bad.hea", "bad 1 360 10\n../100s.dat 16\n")
    make_sr("www")
    w.wfdbx_set_network(1)
    w.wfdbx_set_input_dir(server.url + "www")
    assert w.read_record("rec", sampto=2).signals.tolist() == [[-7], [32]]
    assert "/www/data/a.dat" in server.log
    w.wfdbquiet()
    with pytest.raises(IOError):
        w.read_record("nodat")
    with pytest.raises(IOError):
        w.read_record("nosuch")                 # 404
    with pytest.raises(IOError):
        w.read_record("bad")
    assert w.wfdberror().startswith("isigopen: none of the signals")
    n = len(server.log)
    with pytest.raises(IOError):
        w.read_record("nosuch")                 # (the failure is cached)
    assert len(server.log) == n
    assert "/100s.dat" not in server.log and "/www/../100s.dat" not in \
        server.log
    # redirects are followed (the header's directory is that of its URL)
    w.wfdbx_set_input_dir(None)
    assert w.read_record(server.url + "redirect/sr", sampto=1).signals \
        .tolist() == [[995, 1011]]
    # a URL cannot be written; an output directory URL is refused
    assert w.annopen(server.url + "x", [w.Anninfo("a", w.WFDB_WRITE)], 1) \
        == -4
    assert w.wfdbx_set_output_dir(server.url) is None


def test_network_legacy(server):
    # legacy mode reads no remote files (as the reference C build), even
    # with network access on; URL path entries are not opened either
    w.wfdbx_set_network(1)
    w.wfdbx_set_legacy(1)
    w.wfdbquiet()
    assert w.isigopen(server.url + "100s", [], 2) == -1
    w.setwfdb(server.url)
    assert w.isigopen("100s", [], 2) == -1
    w.setwfdb(".")
    assert server.log == []


# ---------------------------------------------------------------------------
# The high-level options

def test_highlevel_options(server):
    make_sr("sub")
    w.wfdbx_set_input_dir("elsewhere")
    assert w.read_header("sr", input_dir="sub").nsig == 2
    rec = w.read_record("100s", input_dir=server.url, network=True,
                        sampto=1)
    assert rec.signals.tolist() == [[995, 1011]]
    ann = w.read_annotations("sr", "atr", input_dir="sub")
    assert len(ann) == 75
    assert w.wfdbx_get_input_dir() == "elsewhere"   # restored
    assert w.wfdbx_get_network() == 0
    # also on errors
    w.wfdbquiet()
    with pytest.raises(IOError):
        w.read_record("nosuch", input_dir="sub", network=True)
    assert (w.wfdbx_get_input_dir(), w.wfdbx_get_network()) == \
        ("elsewhere", 0)
    # network=False forbids it for the call; None keeps the setting
    w.wfdbx_set_network(1)
    with pytest.raises(IOError):
        w.read_header(server.url + "100s", network=False)
    assert w.wfdbx_get_network() == 1
    assert w.read_header(server.url + "100s").nsig == 2
    # the output directory (dir=) and the input directory are independent
    w.write_annotations("w1", "q", [1, 2], symbols=["N", "N"], dir="sub")
    assert os.path.exists("sub/w1.q")
    assert len(w.read_annotations("w1", "q", input_dir="sub", fs=100)) == 2


def test_legacy_unchanged(settings):
    make_sr("sub")
    w.wfdbquiet()
    w.wfdbx_set_legacy(1)
    w.wfdbx_set_input_dir("sub")         # (not used in legacy mode)
    assert w.isigopen("sr", [], 2) == -1
    w.setwfdb("sub .")                   # the WFDB path
    assert w.isigopen("sr", [], 2) == 2
    assert w.wfdbfile("atr", "sr") == "sub/sr.atr"
    assert w.getwfdb() == "sub ."
    assert w.isigopen("sub/../100s", [], 2) == -1      # ".." refused
    assert w.wfdbfile("hea", "~/x") is None
    w.setwfdb(".")
