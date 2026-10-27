"""Tests of check_record (wfdbx.check).

The corpus of check_corpus.py (one broken record for each issue code, a
clean record, records of tests/data, annotation files) is generated in a
temporary directory, and the report of each case is compared with the
expected lines (EXPECTED below, which is also what the other languages must
print).

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
tests wfdb-x; it has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import os
import sys

import pytest

import wfdbx as w
from wfdbx import check as chk

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import check_corpus  # noqa: E402

from conftest import DATA  # noqa: E402

# The report of each case of the corpus: "== RECORD ANN..." then its lines.
EXPECTED = """\
== clean
no problems found
== clean atr
no problems found
== clean atr 123 nofile trunc ooo badc nulc undef late
warning: annotator 123: the annotator name consists only of digits
error: annotator nofile: the annotation file cannot be read
error: annotator trunc: the annotation file ends unexpectedly after 3 annotations
error: annotator ooo: 3 annotations are out of order; the first is at sample 50, after sample 100
error: annotator badc: 2 annotations have an invalid code; the first is at sample 20 (code 55)
warning: annotator nulc: 1 annotation has code 0 (NOTQRS): at sample 20
warning: annotator undef: 2 annotations use codes without a mnemonic; the first is at sample 10 (code 42)
warning: annotator late: 2 annotations are after the end of the record (1000 samples); the first is at sample 1000
== h_unread atr
error: the header cannot be read
== missing
error: the header cannot be read
== nosig
info: the record has no signals
== nofs
warning: the sampling frequency is not specified
warning: the record length is not specified
info: the signal files hold 1000 frames
== nolen
warning: the record length is not specified
info: the signal files hold 1000 frames
== h_long
error: line 4 of the header is longer than 255 characters
error: line 6 of the header is longer than 255 characters
== h_ascii
warning: line 5 of the header contains non-ASCII characters
== hname
warning: the header names the record "hnam", but its file name is "hname"
== h_wrong
error: the header cannot be read
error: line 4 of the header is longer than 255 characters
warning: the header names the record "other", but its file name is "h_wrong"
== h_large
info: the record has more than 2147483647 samples, which 32-bit applications cannot handle
error: the signal files end after 1000 frames, before the 3000000000 given in the header
== s_desc
warning: signal 0: the signal has no description
warning: signal 1: the signal has no description
== s_descnum
warning: signal 0: the description "2" is only a number
warning: signal 1: the description "-1.5" is only a number
== s_descctl
error: signal 0: the description "ECG\\x09I" contains control characters
== s_fmt8
warning: signal 0: format 8 stores first differences, which cannot follow steep slopes
warning: signal 1: format 8 stores first differences, which cannot follow steep slopes
== s_gain0
warning: signal 0: the signal is uncalibrated (no gain is given)
warning: signal 1: the signal is uncalibrated (no gain is given)
== s_gainneg
info: signal 0: the gain is negative (-200.5)
== s_units
warning: signal 0: the units are not specified
warning: signal 1: the units are not specified
== s_unitsctl
error: signal 0: the units "m\\x01V" contain control characters
== s_nores
warning: signal 0: the signal has no description
warning: signal 0: the ADC resolution is not specified
warning: signal 1: the signal has no description
warning: signal 1: the ADC resolution is not specified
== s_bigres
error: signal 0: the ADC resolution (16 bits) exceeds what format 212 can store (12 bits)
error: signal 1: the ADC resolution (16 bits) exceeds what format 212 can store (12 bits)
== s_range
error: signal 0: the ADC range (-32668 to 32867) does not fit in format 16 (-32768 to 32767)
error: signal 1: the ADC range (-32668 to 32867) does not fit in format 16 (-32768 to 32767)
== s_fname
warning: signal 0: the signal file name "s_f@name.dat" contains characters other than letters, digits, '_', '-' and '.'
warning: signal 1: the signal file name "s_f@name.dat" contains characters other than letters, digits, '_', '-' and '.'
== s_dup
warning: 3 signals have the description "ECG"
== d_nofile
error: the signal file "d_nofile_missing.dat" cannot be read
== d_range
error: signal 0: 2 samples are outside the ADC range (-2048 to 2047); the first is sample 10 (value 3000)
error: signal 1: 1 sample is outside the ADC range (-2048 to 2047): sample 30 (value 2048)
== d_invalid
info: signal 1: 4 samples are invalid (missing data); the first is sample 5
== d_cksum
error: signal 1: the checksum does not match: the header gives 1, the samples sum to 0
== d_short
error: the signal files end after 900 frames, before the 1000 given in the header
== d_long
warning: the signal files hold 1000 frames, more than the 900 given in the header
== d_skew
no problems found
== d_skewlong
warning: the signal files hold 1000 frames, more than the 900 given in the header
== d_flac
warning: the record length is not specified
error: the signal data cannot be read after 0 frames (getvec status -3)
== m_ok
no problems found
== m_nest
error: segment m_inner: the segment is itself a multi-segment record
== m_unread
error: segment seg_missing: the segment cannot be read
== m_fs
error: segment seg_fs: the segment's sampling frequency (500) differs from the record's (250)
== m_layout
error: segment seg_gain, signal 1: the signal differs from the record's signal 1 in its description ("ECG 2", expected "ECG II")
error: segment seg_gain, signal 1: the signal differs from the record's signal 1 in its gain (100, expected 200)
error: segment seg_one: the segment has 1 signal, but the record has 2
== m_var
error: segment seg_gain, signal 1: the signal "ECG 2" is not in the layout
== m_len atr
warning: the segment lengths add up to 1000 samples, but the master header gives 1500
warning: annotator atr: 1 annotation is after the end of the record (1000 samples): at sample 1200
== 100s atr
warning: signal 0: the units are not specified
warning: signal 1: the units are not specified
== fms
error: segment fmt16, signal 0: 1487 samples are outside the ADC range (-2048 to 2047); the first is sample 13 (value 32767)
info: segment fmt16, signal 2: 30 samples are invalid (missing data); the first is sample 7
error: segment fmt212, signal 1: the ADC range (-2047 to 2048) does not fit in format 212 (-2048 to 2047)
error: segment fmt212, signal 2: the ADC range (-2046 to 2049) does not fit in format 212 (-2048 to 2047)
error: segment fmt212, signal 0: the signal differs from the record's signal 0 in its description ("sig0 fmt212", expected "sig0 fmt16")
error: segment fmt212, signal 1: the signal differs from the record's signal 1 in its description ("sig1 fmt212", expected "sig1 fmt16")
error: segment fmt212, signal 2: the signal differs from the record's signal 2 in its description ("sig2 fmt212", expected "sig2 fmt16")
info: segment fmt212, signal 2: 30 samples are invalid (missing data); the first is sample 7
== multi
warning: segment 100s, signal 0: the units are not specified
warning: segment 100s, signal 1: the units are not specified
== vlay
error: segment fmt16, signal 1: the signal "sig1 fmt16" is not in the layout
error: segment fmt16, signal 0: 1487 samples are outside the ADC range (-2048 to 2047); the first is sample 13 (value 32767)
info: segment fmt16, signal 2: 30 samples are invalid (missing data); the first is sample 7
error: segment fmt212, signal 1: the ADC range (-2047 to 2048) does not fit in format 212 (-2048 to 2047)
error: segment fmt212, signal 2: the ADC range (-2046 to 2049) does not fit in format 212 (-2048 to 2047)
error: segment fmt212, signal 0: the signal "sig0 fmt212" is not in the layout
error: segment fmt212, signal 2: the signal "sig2 fmt212" is not in the layout
info: segment fmt212, signal 2: 30 samples are invalid (missing data); the first is sample 7
"""

ALL_CODES = {
    "header_unreadable", "no_signals", "fs_missing", "length_missing",
    "header_line_long", "header_not_ascii", "header_name", "length_large",
    "desc_missing", "desc_number", "desc_control", "format_difference",
    "gain_missing", "gain_negative", "units_missing", "units_control",
    "adcres_missing", "adcres_too_large", "adc_range", "filename",
    "desc_duplicate", "file_unreadable", "file_large", "sample_range",
    "invalid_samples", "checksum", "length_short", "length_long",
    "length_unspecified_frames", "read_error", "nested",
    "segment_unreadable", "segment_fs", "layout_signals", "layout_mismatch",
    "layout_missing_signal", "segment_lengths", "annotator_name",
    "annotations_unreadable", "annotations_truncated", "annotations_order",
    "annotation_code", "annotation_null", "annotation_undefined",
    "annotations_after_end"}


def _expected():
    cases, cur = {}, None
    for line in EXPECTED.splitlines():
        if line.startswith("== "):
            cur = line[3:]
            cases[cur] = []
        else:
            cases[cur].append(line)
    return cases


@pytest.fixture
def corpus(tmp_path):
    d = str(tmp_path / "corpus")
    data = DATA if os.path.isdir(DATA) else None
    cases = check_corpus.make_corpus(d, data)
    w.wfdbquit()
    yield d, cases
    w.wfdbquit()


def test_corpus(corpus):
    d, cases = corpus
    expected = _expected()
    seen = set()
    for rec, anns in cases:
        key = " ".join([rec] + anns)
        report = w.check_record(rec, anns, input_dir=d)
        assert report.lines() == expected[key], key
        assert str(report) == "\n".join(expected[key])
        assert report.record == rec
        assert report.ok == (not any(i.severity == "error"
                                     for i in report.issues))
        seen.update(i.code for i in report.issues)
    if os.path.isdir(DATA):
        assert len(cases) == len(expected)
    # every issue code is produced by the corpus (file_large: see below)
    assert ALL_CODES - seen == {"file_large"}


def test_corpus_script(tmp_path):
    # the script writes the corpus, cases.txt and expected.txt (= EXPECTED)
    d = str(tmp_path / "c")
    argv = ["check_corpus.py", d] + ([DATA] if os.path.isdir(DATA) else [])
    assert check_corpus.main(argv) == 0
    with open(os.path.join(d, "expected.txt")) as f:
        text = f.read()
    with open(os.path.join(d, "cases.txt")) as f:
        cases = f.read().splitlines()
    assert [x[3:] for x in text.splitlines() if x.startswith("== ")] == cases
    if os.path.isdir(DATA):
        assert text == EXPECTED


def test_issue_fields(corpus):
    d, _ = corpus
    r = w.check_record("d_cksum", input_dir=d)
    assert not r.ok and len(r.issues) == 1
    i = r.issues[0]
    assert (i.severity, i.code, i.where) == ("error", "checksum", "signal 1")
    assert i.message == ("the checksum does not match: the header gives 1, "
                         "the samples sum to 0")
    assert str(i) == "error: signal 1: " + i.message
    assert i == w.Issue("error", "checksum", "signal 1", i.message)
    assert repr(r).startswith("CheckReport(record='d_cksum', ok=False")
    r = w.check_record("clean", "atr", input_dir=d)     # (one annotator)
    assert r.ok and r.issues == [] and str(r) == "no problems found"
    # warnings and infos only: ok
    r = w.check_record("nolen", input_dir=d)
    assert r.ok and [i.severity for i in r.issues] == ["warning", "info"]
    assert str(r.issues[0]) == "warning: the record length is not specified"


def test_arguments():
    with pytest.raises(TypeError):
        w.check_record(None)
    with pytest.raises(ValueError):
        w.check_record("")
    with pytest.raises(TypeError):
        w.check_record("100s", [1])


def test_sample_record():
    # the bundled sample record: its header gives no units (as in the
    # MIT-BIH Arrhythmia Database), which is all that is reported
    r = w.check_record("100s", ["atr"], input_dir=w.sample_data_dir())
    assert r.ok
    assert r.lines() == [
        "warning: signal 0: the units are not specified",
        "warning: signal 1: the units are not specified"]


def test_settings_restored(corpus, capfd):
    # legacy mode off during the call and restored; the library prints
    # nothing; the input directory is restored
    d, _ = corpus
    prev_dir = w.wfdbx_get_input_dir()
    w.wfdbx_set_legacy(1)
    try:
        r = w.check_record("nofs", ["nofile"], input_dir=d)
        assert w.wfdbx_get_legacy() == 1
    finally:
        w.wfdbx_set_legacy(0)
    # (legacy mode would assume 250 Hz: the frequency is reported missing)
    assert r.issues[0].code == "fs_missing"
    assert capfd.readouterr().err == ""
    assert w.wfdbx_get_input_dir() == prev_dir
    # the library's messages are printed again after the call
    w.isigopen("no_such_record", None, 0)
    assert "no_such_record" in capfd.readouterr().err
    w.wfdbquit()


def test_modification_labels(tmp_path):
    # codes 42 and 43 defined by the file's modification labels have a
    # mnemonic (no warning); the definitions do not outlive the check
    d = str(tmp_path)
    check_corpus._record(d, "rec", check_corpus._samples())
    w.setannstr(42, "QQ")
    w.setanndesc(42, "my beat")
    try:
        w.write_annotations("rec", "lab", [10, 20, 30], codes=[42, 1, 43],
                            dir=d)
    finally:
        w.setannstr(-42, "[42]")
        w.setanndesc(-42, None)
    from wfdbx import _annot
    _annot._a.modified[42] = 0
    r = w.check_record("rec", ["lab"], input_dir=d)
    assert r.lines() == ["warning: annotator lab: 1 annotation uses a code "
                         "without a mnemonic: at sample 30 (code 43)"]
    assert w.annstr(42) == "[42]"


def test_file_large(corpus, monkeypatch):
    # (a signal file of more than 2^31 - 1 bytes: its size is simulated)
    d, _ = corpus
    monkeypatch.setattr(chk, "_file_size", lambda ig: (1 << 31))
    r = w.check_record("clean", input_dir=d)
    assert r.lines() == [
        'warning: the signal file "clean.dat" has more than 2147483647 '
        'bytes, which 32-bit applications cannot handle']


def test_quoting():
    assert chk._q("a\tb\x7f\xe9\"c") == '"a\\x09b\\x7f\\xe9\"c"'
    assert chk._is_number("12") and chk._is_number("-1.5")
    assert chk._is_number("+.5") and not chk._is_number("1.2.3")
    assert not chk._is_number("V5") and not chk._is_number("-")
