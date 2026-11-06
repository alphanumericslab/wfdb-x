"""Write the expected results of the metadata cases (cases.json).

The metadata functions are additions of WFDB-x: the C package has no
counterpart, so their expected results are produced by the Python
implementation (the reference of WFDB-x), and were checked by hand when
they were made. Every implementation must give the same results, and write
byte-identical headers. Run from the repository root:

    PYTHONPATH=python/src python3 tests/metadata/make_expected.py

It writes expected.json (the result of each case), expected/NAME.hea
(the header after each change that succeeds), and cases.tsv (the cases and
their results in a plain-text form, for the languages that have no JSON
parser in their standard library).

This file is part of WFDB-x. Copyright (C) 2026 Reza Sameni. GNU General
Public License, version 3 or later; see LICENSE.
"""

import json
import os
import shutil
import sys
import tempfile
import warnings

import wfdbx

HERE = os.path.dirname(os.path.abspath(__file__))


def text(s):
    # JSON strings stand for bytes: each character U+0000..U+00FF is a byte
    return s


def run(case, d):
    """Run one case in directory d (holding a copy of its header)."""
    rec = os.path.join(d, case["header"])
    op = case["op"]
    out = {}
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        try:
            if op == "read":
                out["entries"] = [list(e) for e in wfdbx.read_metadata(rec)]
            elif op == "get":
                out["value"] = wfdbx.get_metadata(rec, case["key"])
            elif op == "set":
                wfdbx.set_metadata(rec, case["key"], case["value"])
            elif op == "remove":
                out["count"] = wfdbx.remove_metadata(rec, case["key"])
            elif op == "update":
                wfdbx.update_metadata(rec, [tuple(p) for p in
                                            case["changes"]])
            else:
                raise SystemExit("unknown op %s" % op)
        except (ValueError, TypeError) as e:
            out = {"error": "argument", "message": str(e)}
        except OSError as e:
            out = {"error": "file", "message": str(e)}
    out["warnings"] = len(w)
    return out


def hx(s):
    """A string (one character per byte) as "x" followed by its bytes in
    hexadecimal, or "-" for None."""
    return "-" if s is None else "x" + s.encode("latin-1").hex()


def write_tsv(cases, results):
    """The cases and their results in cases.tsv, for the languages without
    a JSON parser in their standard library: one line per case, ten
    tab-separated columns (see README.md)."""
    rows = ["# name\theader\top\tkey\tvalue\tchanges\terror\twarnings"
            "\tresult\toutput"]
    for c in cases:
        r = results[c["name"]]
        changes = ",".join(hx(k) + ":" + hx(v)
                           for k, v in c.get("changes", []))
        if "entries" in r:
            result = ",".join(hx(k) + ":" + hx(v) for k, v in r["entries"])
        elif "value" in r:
            result = hx(r["value"])
        elif "count" in r:
            result = str(r["count"])
        else:
            result = "-"
        rows.append("\t".join([
            c["name"], c["header"], c["op"], hx(c.get("key")),
            hx(c.get("value")), changes, r.get("error", "-"),
            str(r["warnings"]), result, r.get("output", "-")]))
    with open(os.path.join(HERE, "cases.tsv"), "w", newline="\n") as f:
        f.write("\n".join(rows) + "\n")


def main():
    cases = json.load(open(os.path.join(HERE, "cases.json")))["cases"]
    exp_dir = os.path.join(HERE, "expected")
    shutil.rmtree(exp_dir, ignore_errors=True)
    os.makedirs(exp_dir)
    results = {}
    for case in cases:
        d = tempfile.mkdtemp()
        try:
            src = os.path.join(HERE, "headers", case["header"] + ".hea")
            dst = os.path.join(d, case["header"] + ".hea")
            shutil.copyfile(src, dst)
            r = run(case, d)
            after = open(dst, "rb").read()
            if case["op"] in ("set", "remove", "update"):
                if "error" in r:
                    assert after == open(src, "rb").read(), case["name"]
                else:
                    open(os.path.join(exp_dir, case["name"] + ".hea"),
                         "wb").write(after)
                    r["output"] = "expected/%s.hea" % case["name"]
            r.pop("message", None)
            results[case["name"]] = r
        finally:
            shutil.rmtree(d)
    with open(os.path.join(HERE, "expected.json"), "w") as f:
        json.dump(results, f, indent=1, ensure_ascii=True)
        f.write("\n")
    write_tsv(cases, results)
    print("%d cases" % len(results))


if __name__ == "__main__":
    sys.exit(main())
