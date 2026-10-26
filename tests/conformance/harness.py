#!/usr/bin/env python3
"""Cross-language conformance harness for wfdb-x.

Every test case runs one WFDB command-line tool in a fresh copy of
tests/data, and records its standard output, standard error, exit status,
and any files it creates or modifies.  HOME is the subdirectory home of that
work directory; a case that uses {url} also gets a local HTTP server
(127.0.0.1) serving a copy of it.  The work directory, HOME and the URL of
the server are written as {cwd}, {home} and {url} in the recorded outputs.
Golden results are produced by the original C implementation (WFDB 10.7.0,
built from third_party/) and stored in tests/conformance/golden/.  Each
wfdb-x implementation must reproduce them byte for byte.

Usage:
  harness.py golden --cbin DIR [CASE ...]     regenerate golden results
  harness.py check --impl IMPL [CASE ...]     compare an implementation
  (with --legacy: the legacy suite, run with --legacy, against the results
  of the unmodified C package)
  harness.py list                             list the test cases

IMPL is one of: python, cpp, rust, julia, r, octave, matlab, c, or a
command template containing {tool} (e.g. "/path/to/bin/{tool}").
Set WFDBX_<IMPL>_CMD to override the command template of an implementation,
or (for cpp and rust) WFDBX_<IMPL>_BIN to use another directory of tools.

Part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import argparse
import difflib
import hashlib
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DATA = os.path.join(ROOT, "tests", "data")
GOLDEN = os.path.join(HERE, "golden")

sys.path.insert(0, HERE)
from cases import CASES  # noqa: E402

# The legacy suite (--legacy): the cases of the original package, run with
# --legacy as the first argument of each tool, against the results of the
# unmodified C package.
LEGACY = os.path.join(HERE, "legacy")


# The default value of the WFDB environment variable in a case: none in the
# modern suite (wfdb-x reads relative names from the current directory, the
# work directory), "." in the legacy suite (the WFDB path).
DEFAULT_WFDB = None


def use_legacy_suite(prefix=True):
    """Select the legacy suite; with prefix, --legacy is passed to the tools
    (not to the unmodified C package, which produces its results)."""
    global CASES, GOLDEN, DEFAULT_WFDB
    DEFAULT_WFDB = "."
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "legacy_cases", os.path.join(LEGACY, "cases.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    CASES = [dict(c, args=(["--legacy"] if prefix else []) + c["args"])
             for c in mod.CASES]
    GOLDEN = os.path.join(LEGACY, "golden")

# Compiled implementations: the tools are run by name, with their directory
# first in PATH (as for the C reference), so that argv[0] is the tool name.
BIN_DIRS = {
    "c": None,          # given by --cbin
    "cpp": os.path.join(ROOT, "cpp", "build", "bin"),
    "rust": os.path.join(ROOT, "rust", "target", "release"),
}

IMPL_TEMPLATES = {
    "python": [sys.executable, "-m", "wfdbx.apps.{tool}"],
    "julia": ["julia", "--startup-file=no", "--project=" +
              os.path.join(ROOT, "julia"),
              os.path.join(ROOT, "julia", "bin", "wfdbx.jl"), "{tool}"],
    "r": ["Rscript", os.path.join(ROOT, "r", "inst", "bin", "wfdbx.R"),
          "{tool}"],
    "octave": ["octave-cli", "--no-gui", "--norc", "-q",
               os.path.join(ROOT, "matlab", "bin", "wfdbx_cli.m"), "{tool}"],
    "matlab": [os.path.join(ROOT, "matlab", "bin", "wfdbx_matlab.sh"),
               "{tool}"],
}


def impl_command(impl, tool, cbin=None):
    env_t = os.environ.get("WFDBX_%s_CMD" % impl.upper())
    if impl in BIN_DIRS and not env_t:
        return [tool]       # found via PATH, so that argv[0] == tool
    if env_t:
        tmpl = shlex.split(env_t)
    elif impl in IMPL_TEMPLATES:
        tmpl = IMPL_TEMPLATES[impl]
    else:
        tmpl = shlex.split(impl)
    return [t.replace("{tool}", tool) for t in tmpl]


def snapshot(d):
    """Map relative path -> (size, mtime_ns, content hash) for files in d."""
    out = {}
    for base, _, files in os.walk(d):
        for f in files:
            p = os.path.join(base, f)
            rel = os.path.relpath(p, d)
            with open(p, "rb") as fp:
                out[rel] = fp.read()
    return out


class _Server:
    """A local HTTP server (127.0.0.1, a free port) serving directory d, in a
    thread; base is its URL, ending in "/"."""

    def __init__(self, d):
        import functools
        import http.server
        import threading

        class Handler(http.server.SimpleHTTPRequestHandler):
            def log_message(self, *args):
                pass

        self.httpd = http.server.ThreadingHTTPServer(
            ("127.0.0.1", 0),
            functools.partial(Handler, directory=d))
        self.base = "http://127.0.0.1:%d/" % self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever,
                                       daemon=True)
        self.thread.start()

    def close(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join()


def _uses_url(case):
    """True if the case refers to the local HTTP server ({url})."""
    def has(x):
        if isinstance(x, bytes):
            return b"{url}" in x
        return isinstance(x, str) and "{url}" in x
    return any(has(x) for x in
               list(case["args"]) + list(case.get("env", {}).values()) +
               list(case.get("files", {}).values()) +
               list(case.get("www_files", {}).values()) +
               [case.get("stdin")])


def run_case(case, cmd_prefix, extra_env=None):
    """Run a case; return dict with stdout, stderr, status, files."""
    work = tempfile.mkdtemp(prefix="wfdbx-")
    server = None
    try:
        wd = os.path.join(work, "data")
        shutil.copytree(DATA, wd)
        cwd = os.path.realpath(wd)
        # HOME is the (empty) subdirectory home of the work directory, so
        # that ~ names are reproducible ({home})
        home = os.path.join(cwd, "home")
        os.makedirs(home, exist_ok=True)
        # {url}: the base URL of a local HTTP server, serving a copy of the
        # work directory (with the case's files and www_files), started for
        # the cases that use it
        www = os.path.join(work, "www")
        url = None
        if _uses_url(case):
            os.makedirs(www)
            server = _Server(www)
            url = server.base

        def subst(x):
            if isinstance(x, bytes):
                for k, v in (("{url}", url), ("{home}", home),
                             ("{cwd}", cwd)):
                    if v is not None:
                        x = x.replace(k.encode(), os.fsencode(v))
                return x
            for k, v in (("{url}", url), ("{home}", home), ("{cwd}", cwd)):
                if v is not None:
                    x = x.replace(k, v)
            return x

        def put(d, files):
            for name, content in files.items():
                p = os.path.join(d, name)
                os.makedirs(os.path.dirname(p), exist_ok=True)
                with open(p, "wb") as f:
                    f.write(subst(content if isinstance(content, bytes)
                                  else content.encode("latin-1")))

        put(wd, case.get("files", {}))
        if url:
            shutil.copytree(wd, www, dirs_exist_ok=True)
            put(www, case.get("www_files", {}))
        before = snapshot(wd)
        env = dict(os.environ)
        for k in ("WFDB", "WFDBCAL", "WFDBANNSORT", "WFDBGVMODE",
                  "WFDBX_INPUT_DIR", "WFDBX_OUTPUT_DIR", "WFDBX_NETWORK"):
            env.pop(k, None)
        wfdb = case.get("wfdb", DEFAULT_WFDB)
        if wfdb is not None:
            env["WFDB"] = wfdb
        env["LC_ALL"] = "C"
        env["TZ"] = "UTC"
        env["HOME"] = home
        # the local server is reached directly, never through a proxy
        env["NO_PROXY"] = env["no_proxy"] = "127.0.0.1,localhost"
        env.update({k: subst(v) for k, v in case.get("env", {}).items()})
        if extra_env:
            env.update(extra_env)
        stdin = case.get("stdin")
        if isinstance(stdin, str):
            stdin = stdin.encode("latin-1")
        if stdin is not None:
            stdin = subst(stdin)
        # {cwd} in an argument stands for the (absolute) work directory, and
        # the work directory in the outputs is written as {cwd} (likewise
        # {home} and {url})
        args = [subst(a) for a in case["args"]]
        p = subprocess.run(cmd_prefix + args, cwd=wd, env=env,
                           input=stdin if stdin is not None else b"",
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           timeout=case.get("timeout", 600))
        after = snapshot(wd)
        files = {k: v for k, v in after.items()
                 if k not in before or before[k] != v}
        for k in case.get("ignore_files", []):
            files.pop(k, None)
        places = [(url, "{url}"), (home, "{home}"),
                  (os.path.join(wd, "home"), "{home}"),
                  (cwd, "{cwd}"), (wd, "{cwd}")]
        return {"stdout": _normalize(p.stdout, places),
                "stderr": _normalize(p.stderr, places),
                "status": p.returncode, "files": files}
    finally:
        if server:
            server.close()
        shutil.rmtree(work, ignore_errors=True)


def _normalize(out, places):
    """Write each of the given places (path or URL, placeholder) in out as
    its placeholder, the longest first."""
    for d, ph in sorted(set(p for p in places if p[0]),
                        key=lambda p: len(p[0]), reverse=True):
        out = out.replace(os.fsencode(d), ph.encode())
    return out


BIG = 65536     # larger golden blobs are stored as SHA-256 digests


class Digest(bytes):
    """Stands in for a large golden blob; compares equal by SHA-256."""

    def __new__(cls, hexdigest, size):
        o = bytes.__new__(cls, b"")
        o.hexdigest = hexdigest
        o.size = size
        return o

    def __eq__(self, other):
        if isinstance(other, Digest):
            return self.hexdigest == other.hexdigest
        return len(other) == self.size and \
            hashlib.sha256(other).hexdigest() == self.hexdigest

    def __ne__(self, other):
        return not self.__eq__(other)

    __hash__ = bytes.__hash__


def _write_blob(path, data):
    if len(data) > BIG:
        with open(path + ".sha256", "w") as f:
            f.write("%s %d\n" % (hashlib.sha256(data).hexdigest(), len(data)))
    else:
        with open(path, "wb") as f:
            f.write(data)


def _read_blob(path):
    if os.path.exists(path + ".sha256"):
        with open(path + ".sha256") as f:
            h, n = f.read().split()
        return Digest(h, int(n))
    with open(path, "rb") as f:
        return f.read()


def golden_name(cid):
    """The directory name of a case: its id, with each capital letter written
    as '^' and the letter in lower case (e.g. rdsamp-r_100s_S is stored as
    rdsamp-r_100s_^s), so that ids differing only in case (-s and -S) get
    distinct directories on case-insensitive file systems (macOS, Windows)."""
    return re.sub(r"[A-Z]", lambda m: "^" + m.group(0).lower(), cid)


def golden_dir(cid):
    return os.path.join(GOLDEN, golden_name(cid))


def save_golden(cid, res):
    d = golden_dir(cid)
    if os.path.isdir(d):
        shutil.rmtree(d)
    os.makedirs(os.path.join(d, "files"))
    _write_blob(os.path.join(d, "stdout"), res["stdout"])
    _write_blob(os.path.join(d, "stderr"), res["stderr"])
    with open(os.path.join(d, "status"), "w") as f:
        f.write("%d\n" % res["status"])
    for name, data in res["files"].items():
        p = os.path.join(d, "files", name)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        _write_blob(p, data)


def load_golden(cid):
    d = golden_dir(cid)
    stdout = _read_blob(os.path.join(d, "stdout"))
    stderr = _read_blob(os.path.join(d, "stderr"))
    with open(os.path.join(d, "status")) as f:
        status = int(f.read().strip())
    files = {}
    fd = os.path.join(d, "files")
    for base, _, names in os.walk(fd):
        for n in names:
            rel = os.path.relpath(os.path.join(base, n), fd)
            if rel.endswith(".sha256"):
                rel = rel[:-7]
            files[rel] = _read_blob(os.path.join(fd, rel))
    return {"stdout": stdout, "stderr": stderr, "status": status,
            "files": files}


def _diff(a, b, label, limit=20):
    if isinstance(a, Digest):
        return "   (large output: SHA-256 mismatch; expected %d bytes, got %d)\n" \
            % (a.size, len(b))
    al = a.decode("latin-1").splitlines(True)
    bl = b.decode("latin-1").splitlines(True)
    d = list(difflib.unified_diff(al, bl, "expected " + label,
                                  "actual " + label, n=1))
    if len(d) > limit:
        d = d[:limit] + ["... (%d more diff lines)\n" % (len(d) - limit)]
    return "".join(d)


def _same_flac(a, b):
    """True if two FLAC streams decode to the same samples."""
    sys.path.insert(0, os.path.join(ROOT, "python", "src"))
    try:
        from wfdbx._flac import decode_bytes
        return decode_bytes(bytes(a)) == decode_bytes(bytes(b))
    except Exception:
        return False


def compare(exp, act, case):
    problems = []
    if exp["status"] != act["status"]:
        problems.append("exit status: expected %d, got %d" %
                        (exp["status"], act["status"]))
    if exp["stdout"] != act["stdout"]:
        problems.append("stdout differs:\n" +
                        _diff(exp["stdout"], act["stdout"], "stdout"))
    if not case.get("ignore_stderr") and exp["stderr"] != act["stderr"]:
        problems.append("stderr differs:\n" +
                        _diff(exp["stderr"], act["stderr"], "stderr"))
    ef, af = exp["files"], act["files"]
    for k in sorted(set(ef) | set(af)):
        if k not in af:
            problems.append("file %s not written" % k)
        elif k not in ef:
            problems.append("unexpected file %s written" % k)
        elif k in case.get("flac_files", ()) and \
                not isinstance(ef[k], Digest) and _same_flac(ef[k], af[k]):
            continue    # FLAC: compare decoded samples, not bytes
        elif ef[k] != af[k]:
            if not isinstance(ef[k], Digest) and \
                    all(c < 128 for c in ef[k][:2000]):
                problems.append("file %s differs:\n" % k +
                                _diff(ef[k], af[k], k))
            else:
                el = ef[k].size if isinstance(ef[k], Digest) else len(ef[k])
                n = next((i for i in range(min(len(ef[k]), len(af[k])))
                          if ef[k][i] != af[k][i]),
                         min(len(ef[k]), len(af[k])))
                problems.append("file %s differs (sizes %d/%d, first "
                                "difference at byte %d)" %
                                (k, el, len(af[k]), n))
    return problems


def select(names):
    if not names:
        return CASES
    out = []
    for c in CASES:
        if any(c["id"] == n or c["id"].startswith(n + "-") or
               c["args"] and c.get("tool") == n for n in names):
            out.append(c)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawTextHelpFormatter)
    sub = ap.add_subparsers(dest="cmd")
    g = sub.add_parser("golden")
    g.add_argument("--cbin", required=True)
    g.add_argument("--legacy", action="store_true",
                   help="the legacy suite (unmodified C package)")
    g.add_argument("cases", nargs="*")
    c = sub.add_parser("check")
    c.add_argument("--impl", required=True)
    c.add_argument("--cbin")
    c.add_argument("--legacy", action="store_true",
                   help="the legacy suite: tools run with --legacy")
    c.add_argument("-v", "--verbose", action="store_true")
    c.add_argument("-x", "--exitfirst", action="store_true")
    c.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 1,
                   help="number of cases to run in parallel")
    c.add_argument("cases", nargs="*")
    sub.add_parser("list")
    a = ap.parse_args()
    if getattr(a, "legacy", False):
        # the legacy results are produced by the unmodified C package
        # (tests/reference/build_reference.sh with WFDBX_ORIGINAL=1)
        use_legacy_suite(prefix=(a.cmd == "check"))
    if a.cmd == "list":
        for case in CASES:
            print("%-40s %s %s" % (case["id"], case["tool"],
                                   " ".join(case["args"])))
        return 0
    if a.cmd == "golden":
        for case in select(a.cases):
            path = os.path.abspath(a.cbin) + os.pathsep + \
                os.environ.get("PATH", "")
            res = run_case(case, impl_command("c", case["tool"]),
                           {"PATH": path})
            save_golden(case["id"], res)
            print("%-40s status %d, %d bytes out, %d files" % (
                case["id"], res["status"], len(res["stdout"]),
                len(res["files"])))
        return 0
    if a.cmd == "check":
        cases = select(a.cases)

        def one(case):
            if not os.path.isdir(golden_dir(case["id"])):
                return case, ["missing golden results"]
            exp = load_golden(case["id"])
            extra = None
            bindir = a.cbin if a.impl == "c" else (
                os.environ.get("WFDBX_%s_BIN" % a.impl.upper()) or
                BIN_DIRS.get(a.impl))
            if bindir and not os.environ.get("WFDBX_%s_CMD" % a.impl.upper()):
                extra = {"PATH": os.path.abspath(bindir) + os.pathsep +
                         os.environ.get("PATH", "")}
            act = run_case(case, impl_command(a.impl, case["tool"], a.cbin),
                           extra)
            return case, compare(exp, act, case)

        nfail = 0
        if a.jobs > 1 and not a.exitfirst:
            from concurrent.futures import ThreadPoolExecutor
            with ThreadPoolExecutor(a.jobs) as ex:
                results = list(ex.map(one, cases))
        else:
            results = (one(c) for c in cases)
        for case, problems in results:
            if problems:
                nfail += 1
                print("FAIL %s  (%s %s)" % (case["id"], case["tool"],
                                           " ".join(case["args"])))
                for p in problems:
                    print("   " + p.replace("\n", "\n   "))
                if a.exitfirst:
                    break
            elif a.verbose:
                print("ok   %s" % case["id"])
        print("%d of %d cases passed" % (len(cases) - nfail, len(cases)))
        return 1 if nfail else 0
    ap.print_help()
    return 2


if __name__ == "__main__":
    sys.exit(main())
