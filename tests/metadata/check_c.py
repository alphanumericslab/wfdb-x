"""Check the metadata test headers with the original C programs.

For every header of the metadata tests (the inputs in headers/ and the
expected results in expected/), with the signal files of the test record
100s, this runs the C programs of the WFDB Software Package and checks:

* that wfdbdesc prints exactly the info strings of the header (as the C
  function getinfo() reads them): every comment line after the record
  line, in order, without its '#';
* that rdsamp reads the same samples as from the unchanged input header,
  and prints nothing on its standard error output (no checksum error or
  other message).

So a header changed by the metadata functions remains a valid WFDB header
for the C library. Run from the repository root, with the directory of the
C programs (for example, those built by benchmarks/c/build.sh or
tests/reference/build_reference.sh):

    python3 tests/metadata/check_c.py --c-bin benchmarks/build/c/wfdb/bin

This file is part of WFDB-x. Copyright (C) 2026 Reza Sameni. GNU General
Public License, version 3 or later; see LICENSE.
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


def info_strings(data):
    """The info strings of a header, as getinfo() reads them."""
    lines = lines_of(data)
    i = 0
    while i < len(lines) and lines[i].startswith(b"#"):
        i += 1
    return [ln[1:] for ln in lines[i + 1:] if ln.startswith(b"#")]


def record_name(data):
    for ln in lines_of(data):
        if not ln.startswith(b"#"):
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


def check(cbin, path, original):
    """Check one header; original is the input header it was made from."""
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
        if notes(out) != info_strings(data):
            problems.append("wfdbdesc info strings %r, expected %r" %
                            (notes(out), info_strings(data)))
        return problems
    finally:
        shutil.rmtree(d)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--c-bin", required=True,
                    help="directory of the C programs rdsamp and wfdbdesc")
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
        problems = check(a.c_bin, p, original)
        rel = os.path.relpath(p, HERE)
        if problems:
            failed += 1
            print("FAIL %s: %s" % (rel, "; ".join(problems)))
    print("%d headers checked with the C programs, %d failed" %
          (len(paths), failed))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
