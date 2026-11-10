"""Check the metadata test headers with the original C programs.

For every header of the metadata tests (the inputs in headers/ and the
expected results in expected/), with the signal files of the test record
100s, this runs the C programs of the WFDB Software Package and checks:

* that wfdbdesc prints exactly the info strings of the header (as the
  function getinfo() reads them): every line that begins with '#' after
  the record line, in order, without its '#';
* that rdsamp reads the same samples as from the unchanged input header,
  and prints nothing on its standard error output (no checksum error or
  other message).

So a header changed by the metadata functions remains a valid WFDB header
for the C library.

The record line is found as the C header parser (readheader) finds it: the
first line that has a token (separated by spaces, tabs, CRs and LFs) that
does not begin with '#'. The C reference of WFDB-x (the C package with
tests/reference/divergences.patch, built by
tests/reference/build_reference.sh) has getinfo() find it so too, and the
metadata functions follow this rule. The original getinfo() takes the first
line that does not begin with '#', so for a header whose first line is
empty or blank (headers/leading.hea, headers/leadingblank.hea and the
headers made from them), it also prints the comments before the record
line. With --original, the expected info strings are those of the original
rule, for the programs of the unmodified package (WFDBX_ORIGINAL=1, as
benchmarks/c/build.sh builds them); the samples are checked in the same
way. Run from the repository root, with the directory of the C programs:

    python3 tests/metadata/check_c.py --c-bin build/wfdb-ref/bin
    python3 tests/metadata/check_c.py --original \
        --c-bin benchmarks/build/c/wfdb/bin

This file is part of WFDB-x. Copyright (C) 2026 Reza Sameni. GNU Lesser
General Public License, version 2.1 or later; see LICENSE.
"""

import argparse
import glob
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(HERE, "..", "data")
# the files that the test headers name (signal files and segments)
SUPPORT = ("100s.dat", "100s.hea", "null.hea")


def lines_of(data):
    out = data.split(b"\n")
    if out and out[-1] == b"":
        out.pop()
    return [ln[:-1] if ln.endswith(b"\r") else ln for ln in out]


def is_record_line(ln):
    """True if ln is the record line as readheader finds it: it has a
    token (separated by spaces, tabs, CRs and LFs, up to a NUL byte) that
    does not begin with '#'."""
    t = ln.split(b"\0", 1)[0].lstrip(b" \t\r\n")
    return t != b"" and not t.startswith(b"#")


def info_strings(data, original=False):
    """The info strings of a header, as getinfo() reads them: the lines
    that begin with '#' after the record line (original: after the first
    line that does not begin with '#', as the original getinfo() finds
    the record line)."""
    lines = lines_of(data)
    i = 0
    while i < len(lines) and (lines[i].startswith(b"#") if original
                              else not is_record_line(lines[i])):
        i += 1
    return [ln[1:] for ln in lines[i + 1:] if ln.startswith(b"#")]


def record_name(data):
    for ln in lines_of(data):
        if is_record_line(ln):
            return ln.split()[0].split(b"/")[0].decode("latin-1")
    raise ValueError("no record line")


def run(cbin, d, *args):
    p = subprocess.run([os.path.join(cbin, args[0])] + list(args[1:]),
                       cwd=d, capture_output=True)
    return p.returncode, p.stdout, p.stderr


def notes(out):
    """The info strings that wfdbdesc printed."""
    lines = out.split(b"\n")
    try:
        i = lines.index(b"Notes")
    except ValueError:
        return []
    j = lines.index(b"=====", i + 2)
    return lines[i + 2:j]


def check(cbin, path, original, original_rule=False):
    """Check one header; original is the input header it was made from;
    original_rule: the C programs are those of the unmodified package."""
    data = open(path, "rb").read()
    name = record_name(data)
    d = tempfile.mkdtemp()
    try:
        for f in SUPPORT:
            shutil.copyfile(os.path.join(DATA, f), os.path.join(d, f))
        problems = []
        samples = {}
        for label, hdr in (("original", original), ("changed", data)):
            open(os.path.join(d, name + ".hea"), "wb").write(hdr)
            rc, out, err = run(cbin, d, "rdsamp", "-r", name)
            if rc != 0 or err:
                problems.append("rdsamp (%s header): status %d, %r" %
                                (label, rc, err[:200]))
            samples[label] = out
        if samples["original"] != samples["changed"]:
            problems.append("rdsamp reads different samples")
        rc, out, err = run(cbin, d, "wfdbdesc", name)
        if rc != 0:
            problems.append("wfdbdesc: status %d" % rc)
        expected = info_strings(data, original_rule)
        if notes(out) != expected:
            problems.append("wfdbdesc info strings %r, expected %r" %
                            (notes(out), expected))
        return problems
    finally:
        shutil.rmtree(d)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--c-bin", required=True,
                    help="directory of the C programs rdsamp and wfdbdesc")
    ap.add_argument("--original", action="store_true",
                    help="the C programs are those of the unmodified "
                    "package, whose getinfo() takes the first line that "
                    "does not begin with '#' for the record line")
    a = ap.parse_args()
    a.c_bin = os.path.abspath(a.c_bin)
    cases = {c["name"]: c for c in
             json.load(open(os.path.join(HERE, "cases.json")))["cases"]}
    paths = sorted(glob.glob(os.path.join(HERE, "headers", "*.hea")))
    paths += sorted(glob.glob(os.path.join(HERE, "expected", "*.hea")))
    failed = 0
    for p in paths:
        base = os.path.basename(p)[:-4]
        src = cases[base]["header"] if base in cases else base
        original = open(os.path.join(HERE, "headers", src + ".hea"),
                        "rb").read()
        problems = check(a.c_bin, p, original, a.original)
        rel = os.path.relpath(p, HERE)
        if problems:
            failed += 1
            print("FAIL %s: %s" % (rel, "; ".join(problems)))
    print("%d headers checked with the C programs, %d failed" %
          (len(paths), failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
