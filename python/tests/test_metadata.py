"""Tests of the metadata functions (read_metadata, get_metadata, set_metadata,
remove_metadata, update_metadata) and of the metadata of read_header and
write_record.

The shared cases (tests/metadata/cases.json, with the expected results in
tests/metadata/expected.json and expected/) are run by every implementation
of WFDB-x, which must give the same results and write byte-identical
headers. A URL is served by a local HTTP server (127.0.0.1).

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
tests WFDB-x; it has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import json
import os
import shutil
import stat
import warnings

import numpy as np
import pytest

import wfdbx
from wfdbx import _wfdbio
from test_files import Server

HERE = os.path.dirname(os.path.abspath(__file__))
META = os.path.join(os.path.dirname(os.path.dirname(HERE)), "tests",
                    "metadata")

pytestmark = pytest.mark.skipif(
    not os.path.isdir(META),
    reason="the metadata cases of the WFDB-x repository are not available")


def _cases():
    if not os.path.isdir(META):
        return []
    return json.load(open(os.path.join(META, "cases.json")))["cases"]


@pytest.fixture
def clean(tmp_path, monkeypatch):
    """A temporary current directory, with the default settings."""
    for k in ("WFDB", "WFDBX_INPUT_DIR", "WFDBX_OUTPUT_DIR", "WFDBX_NETWORK"):
        monkeypatch.delenv(k, raising=False)
    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(_wfdbio._io, "fetched", {})
    wfdbx.wfdbx_set_input_dir(None)
    wfdbx.wfdbx_set_output_dir(None)
    wfdbx.wfdbx_set_network(None)
    yield str(tmp_path)
    wfdbx.wfdbquit()
    wfdbx.wfdbx_set_input_dir(None)
    wfdbx.wfdbx_set_output_dir(None)
    wfdbx.wfdbx_set_network(None)


def _copy(name, d):
    shutil.copyfile(os.path.join(META, "headers", name + ".hea"),
                    os.path.join(d, name + ".hea"))
    return os.path.join(d, name)


@pytest.mark.parametrize("case", _cases(), ids=lambda c: c["name"])
def test_shared_case(case, clean):
    expected = json.load(open(os.path.join(META, "expected.json")))[
        case["name"]]
    rec = _copy(case["header"], clean)
    before = open(rec + ".hea", "rb").read()
    got = {}
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        try:
            op = case["op"]
            if op == "read":
                got["entries"] = [list(e) for e in wfdbx.read_metadata(rec)]
            elif op == "get":
                got["value"] = wfdbx.get_metadata(rec, case["key"])
            elif op == "set":
                wfdbx.set_metadata(rec, case["key"], case["value"])
            elif op == "remove":
                got["count"] = wfdbx.remove_metadata(rec, case["key"])
            elif op == "update":
                wfdbx.update_metadata(rec, [tuple(p) for p in
                                            case["changes"]])
        except (ValueError, TypeError):
            got = {"error": "argument"}
        except OSError:
            got = {"error": "file"}
    got["warnings"] = len(w)
    after = open(rec + ".hea", "rb").read()
    if "output" in expected:
        got["output"] = expected["output"]
        assert after == open(os.path.join(META, expected["output"]),
                             "rb").read()
    else:
        assert after == before
    assert got == expected
    # no temporary file is left behind
    assert os.listdir(clean) == [case["header"] + ".hea"]


def test_read_header_and_write_record(clean):
    x = np.zeros((10, 1), dtype=np.int32)
    wfdbx.write_record("w", x, fs=100, gains=200, adcres=12, units="mV",
                       comments=["a comment", "Site: B"],
                       metadata={"Age": " 63 ", "Notes": ""})
    data = open("w.hea", "rb").read()
    assert data.endswith(b"#a comment\r\n#Site: B\r\n# Age: 63\r\n"
                         b"# Notes:\r\n")
    h = wfdbx.read_header("w")
    assert h.metadata == [("Site", "B"), ("Age", "63"), ("Notes", "")]
    assert h.comments == ["a comment", "Site: B", " Age: 63", " Notes:"]
    wfdbx.write_record("v", x, fs=100, gains=200, adcres=12, units="mV",
                       metadata=[("Dx", "426783006")])
    assert wfdbx.read_metadata("v") == [("Dx", "426783006")]


def test_write_record_metadata_errors(clean):
    x = np.zeros((10, 1), dtype=np.int32)
    kw = dict(fs=100, gains=200, adcres=12, units="mV")
    for md in ({"a:b": "1"}, {"Age": "1\n2"}, [("Age", "1"), ("AGE", "2")],
               {"Age": None}, {"": "x"}):
        with pytest.raises(ValueError):
            wfdbx.write_record("e", x, metadata=md, **kw)
    with pytest.raises(ValueError):
        wfdbx.write_record("e", x, comments=["age: 1"], metadata={"Age": "2"},
                           **kw)
    assert os.listdir(clean) == []      # nothing was written


def test_info_file_ignored(clean):
    rec = _copy("lf", clean)
    open(rec + ".info", "wb").write(b"#Age: 1\n")
    assert wfdbx.read_metadata(rec) == []


def test_input_dir_and_dir(clean):
    os.mkdir("in")
    os.mkdir("out")
    _copy("basic", "in")
    original = open("in/basic.hea", "rb").read()
    assert wfdbx.get_metadata("basic", "Sex", input_dir="in") == "F"
    wfdbx.wfdbx_set_input_dir("in")
    assert wfdbx.get_metadata("basic.hea", "sex") == "F"
    wfdbx.set_metadata("basic", "Age", "64", dir="out")
    assert open("in/basic.hea", "rb").read() == original
    assert wfdbx.get_metadata("out/basic", "Age", input_dir="") == "64"
    # an unchanged header is still written to dir
    assert wfdbx.remove_metadata("basic", "Weight", dir="out") == 0
    assert open("out/basic.hea", "rb").read() == original
    with pytest.raises(FileNotFoundError):
        wfdbx.set_metadata("basic", "Age", "1", dir="none")
    wfdbx.wfdbx_set_input_dir(None)
    # the header is changed where it was read, not in the output directory
    wfdbx.wfdbx_set_output_dir("out")
    wfdbx.set_metadata("in/basic", "Age", "65")
    assert wfdbx.get_metadata("in/basic", "Age") == "65"


def test_missing_and_invalid(clean):
    with pytest.raises(OSError):
        wfdbx.read_metadata("none")
    with pytest.raises(OSError):
        wfdbx.set_metadata("none", "Age", "1")
    with pytest.raises(ValueError):
        wfdbx.read_metadata("")
    with pytest.raises(ValueError):
        wfdbx.read_metadata("-")
    _copy("basic", clean)
    with pytest.raises(TypeError):
        wfdbx.set_metadata("basic", "Age", 63)
    with pytest.raises(ValueError):
        wfdbx.set_metadata("basic", "Name", "Ā")
    wfdbx.set_metadata("basic", b"Name", b"Z\xc3\xbcrich")
    assert wfdbx.get_metadata("basic", "Name") == "ZÃ¼rich"
    open("norec.hea", "wb").write(b"# only a comment\n")
    assert wfdbx.read_metadata("norec") == []
    with pytest.raises(ValueError):
        wfdbx.set_metadata("norec", "Age", "1")


def test_permissions_kept(clean):
    rec = _copy("basic", clean)
    os.chmod(rec + ".hea", 0o640)
    wfdbx.set_metadata(rec, "Age", "64")
    assert stat.S_IMODE(os.stat(rec + ".hea").st_mode) == 0o640


def test_url(clean):
    _copy("basic", clean)
    srv = Server(clean)
    try:
        url = srv.url + "basic"
        with pytest.raises(OSError):
            wfdbx.read_metadata(url)            # network off
        assert wfdbx.get_metadata(url, "Age", network=True) == "63"
        with pytest.raises(ValueError):
            wfdbx.set_metadata(url, "Age", "1", network=True)
        os.mkdir("copy")
        wfdbx.set_metadata(url, "Age", "1", network=True, dir="copy")
        assert wfdbx.get_metadata("copy/basic", "Age") == "1"
        assert wfdbx.get_metadata("basic", "Age") == "63"
    finally:
        srv.close()


def test_read_header_edf(clean):
    shutil.copyfile(os.path.join(META, "..", "data", "fmt16.edf"),
                    "fmt16.edf")
    h = wfdbx.read_header("fmt16.edf")
    assert h.nsig > 0 and h.metadata == []
