"""Run the WFDB-x benchmarks: the same operations in the seven languages
(and wfdb-python and the original C tools, for comparison).

    python3 benchmarks/run.py [--langs L,L,...] [--reps N] [--data DIR]
                              [--no-build] [--json FILE] [--markdown FILE]

See benchmarks/README.md: what is measured, how, and what each language
needs. The results are printed as Markdown tables (and written to --json and
--markdown if given); docs/BENCHMARKS.md reports them.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
It has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import argparse
import json
import os
import platform
import resource
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BUILD = os.path.join(HERE, "build")
sys.path.insert(0, os.path.join(ROOT, "tests", "conformance"))
import harness  # noqa: E402  (impl_command: how each language runs a tool)

LANGS = ["cpp", "rust", "julia", "kotlin", "python", "r", "octave"]
NAMES = {"cpp": "C++", "rust": "Rust", "julia": "Julia", "kotlin": "Kotlin",
         "python": "Python", "r": "R", "octave": "MATLAB/Octave",
         "wfdb-python": "wfdb-python", "c": "C (original)"}
OPS = [("read_long", "read 1 h, 2 signals (fmt 212)"),
       ("read_long_phys", "the same, in physical units"),
       ("read_mimic", "read a 12-segment multi-frequency record"),
       ("read_wide", "read 10 min of 12 leads (fmt 16)"),
       ("write_long", "write 1 h, 2 signals (fmt 16)"),
       ("read_ann", "read 4,500 annotations"),
       ("write_ann", "write 4,500 annotations")]

# How to build (in BUILD) and run each benchmark driver:
#   DRIVER OP DATADIR REPS  ->  one JSON line (benchmarks/README.md)
OCTAVE = ["octave-cli", "--no-gui", "--norc", "-q"]
BUILDS = {
    "cpp": [["cmake", "-S", os.path.join(HERE, "cpp"), "-B",
             os.path.join(BUILD, "cpp"), "-DCMAKE_BUILD_TYPE=Release"],
            ["cmake", "--build", os.path.join(BUILD, "cpp"), "-j4"]],
    "rust": [["cargo", "build", "--release", "-q", "--manifest-path",
              os.path.join(HERE, "rust", "Cargo.toml"), "--target-dir",
              os.path.join(BUILD, "rust")]],
    # (no Gradle daemon: it would keep running, and loading the machine,
    # while the other languages are timed)
    "kotlin": [[os.path.join(ROOT, "kotlin", "gradlew"), "-q", "--no-daemon",
                "-p", os.path.join(ROOT, "kotlin"), "benchJar", "fatJar"]],
    "julia": [["julia", "--startup-file=no", "--project=" +
               os.path.join(ROOT, "julia"), "-e",
               "import Pkg; Pkg.instantiate(); import WFDBX"]],
}
DRIVERS = {
    "cpp": [os.path.join(BUILD, "cpp", "wfdbx_bench")],
    "rust": [os.path.join(BUILD, "rust", "release", "wfdbx_bench")],
    "julia": ["julia", "--startup-file=no", "--project=" +
              os.path.join(ROOT, "julia"), os.path.join(HERE, "julia",
                                                        "bench.jl")],
    "kotlin": ["java", "-jar", os.path.join(ROOT, "kotlin", "build", "libs",
                                            "wfdbx-bench.jar")],
    "python": [sys.executable, os.path.join(HERE, "python", "bench.py")],
    "r": ["Rscript", os.path.join(HERE, "r", "bench.R")],
    "octave": OCTAVE + [os.path.join(HERE, "matlab", "bench.m")],
    "wfdb-python": [os.environ.get("WFDB_PYTHON", sys.executable),
                    os.path.join(HERE, "wfdb_python", "bench.py")],
}
# The tools: the conformance harness's commands (compiled tools by name,
# with their directory first in PATH).
TOOL_BIN = {"cpp": os.path.join(ROOT, "cpp", "build", "bin"),
            "rust": os.path.join(ROOT, "rust", "target", "release")}
TOOL_BUILDS = {
    "cpp": [["cmake", "-S", os.path.join(ROOT, "cpp"), "-B",
             os.path.join(ROOT, "cpp", "build"), "-DCMAKE_BUILD_TYPE=Release"],
            ["cmake", "--build", os.path.join(ROOT, "cpp", "build"), "-j4"]],
    "rust": [["cargo", "build", "--release", "-q", "--manifest-path",
              os.path.join(ROOT, "rust", "Cargo.toml")]],
}
TOOLS = [("rdsamp", ["-r", "long"], "rdsamp -r long (1,296,000 lines)"),
         ("wfdbdesc", ["long"], "wfdbdesc long (start-up)")]


def timed(cmd, env=None, cwd=None, stdout=subprocess.PIPE):
    """Run cmd; return (seconds, peak RSS in MB, stdout)."""
    t = time.perf_counter()
    p = subprocess.Popen(cmd, stdout=stdout, stderr=subprocess.PIPE, env=env,
                         cwd=cwd)
    out, err = p.communicate()
    dt = time.perf_counter() - t
    # (the largest resident set of the children waited for so far)
    rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / 1024.0
    if p.returncode != 0:
        raise RuntimeError("%s: exit status %d\n%s" % (
            " ".join(cmd), p.returncode, (err or b"").decode(errors="replace")))
    return dt, rss, out


def peak_rss(cmd, env=None, cwd=None):
    """Run cmd in a fresh python process to read its own peak RSS (MB)."""
    code = ("import resource,subprocess,sys;"
            "r=subprocess.run(sys.argv[1:],stdout=subprocess.DEVNULL,"
            "stderr=subprocess.DEVNULL).returncode;"
            "print(resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss"
            "/1024.0 if r==0 else -1)")
    out = subprocess.run([sys.executable, "-c", code] + cmd, env=env, cwd=cwd,
                         stdout=subprocess.PIPE, check=True).stdout
    v = float(out)
    return None if v < 0 else v


def build(lang):
    steps = BUILDS.get(lang, []) + TOOL_BUILDS.get(lang, [])
    for cmd in steps:
        sys.stderr.write("  build: %s\n" % " ".join(cmd))
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL,
                       env=clean_env())


def clean_env():
    env = dict(os.environ)
    env.pop("JAVA_TOOL_OPTIONS", None)      # (it makes java print a line)
    return env


def run_driver(lang, op, data, reps):
    cmd = DRIVERS[lang] + [op, data, str(reps)]
    _, _, out = timed(cmd, env=clean_env())
    lines = [ln for ln in out.decode().splitlines() if ln.startswith("{")]
    if not lines:
        raise RuntimeError("%s %s: no result" % (lang, op))
    r = json.loads(lines[-1])
    r["rss_mb"] = peak_rss(cmd, env=clean_env())
    return r


def tool_env(lang, cbin):
    env = clean_env()
    bindir = cbin if lang == "c" else TOOL_BIN.get(lang)
    if bindir:
        env["PATH"] = bindir + os.pathsep + env.get("PATH", "")
    if lang == "python":
        env["PYTHONPATH"] = os.path.join(ROOT, "python", "src")
    return env


def run_tool(lang, tool, args, data, reps, cbin):
    cmd = harness.impl_command(lang, tool) + args
    env = tool_env(lang, cbin)
    best = None
    for _ in range(reps):
        with open(os.devnull, "wb") as null:
            dt, _, _ = timed(cmd, env=env, cwd=data, stdout=null)
        best = dt if best is None else min(best, dt)
    return {"best": best, "rss_mb": peak_rss(cmd, env=env, cwd=data)}


def same(a, b):
    if isinstance(a, float) or isinstance(b, float):
        return abs(a - b) <= 1e-6 * max(1.0, abs(a), abs(b))
    return a == b


def fmt_t(x):
    if x is None:
        return "–"
    if x < 1e-3:
        return "%.2f ms" % (x * 1e3)
    if x < 1:
        return "%.0f ms" % (x * 1e3) if x >= 0.1 else "%.1f ms" % (x * 1e3)
    return "%.2f s" % x


def tables(res, langs):
    out = []
    tl = [x for x in langs if x != "wfdb-python"]
    langs = [x for x in langs if x != "c"]
    head = "| | " + " | ".join(NAMES[x] for x in langs) + " |"
    rule = "|---|" + "---:|" * len(langs)
    out += ["**Library, best of the timed runs** (in a running program)", "",
            head, rule]
    for op, desc in OPS:
        row = [fmt_t(res.get(x, {}).get(op, {}).get("best")) for x in langs]
        out.append("| %s | %s |" % (desc, " | ".join(row)))
    out += ["", "**Library, first call** (includes compilation by a JIT)", "",
            head, rule]
    for op, desc in OPS:
        row = [fmt_t(res.get(x, {}).get(op, {}).get("first")) for x in langs]
        out.append("| %s | %s |" % (desc, " | ".join(row)))
    out += ["", "**Peak memory** (MB, the whole process)", "", head, rule]
    for op, desc in OPS[:1] + OPS[2:3]:
        row = [("%.0f" % v) if v else "–" for v in
               (res.get(x, {}).get(op, {}).get("rss_mb") for x in langs)]
        out.append("| %s | %s |" % (desc, " | ".join(row)))
    if any(x in res.get("_tools", {}) for x in tl):
        tl = [x for x in tl if x in res["_tools"]]
        out += ["", "**Command-line tools** (a whole process, best of the "
                "runs)", "", "| | " + " | ".join(NAMES[x] for x in tl) + " |",
                "|---|" + "---:|" * len(tl)]
        for tool, _, desc in TOOLS:
            row = [fmt_t(res["_tools"][x].get(tool, {}).get("best"))
                   for x in tl]
            out.append("| %s | %s |" % (desc, " | ".join(row)))
    return "\n".join(out) + "\n"


def versions():
    def v(cmd):
        try:
            return subprocess.run(cmd, stdout=subprocess.PIPE,
                                  stderr=subprocess.STDOUT, env=clean_env(),
                                  timeout=60).stdout.decode().splitlines()[0]
        except Exception:
            return None
    cpu = None
    try:
        for ln in open("/proc/cpuinfo"):
            if ln.startswith("model name"):
                cpu = ln.split(":", 1)[1].strip()
                break
    except OSError:
        pass
    return {"machine": platform.machine(), "system": platform.platform(),
            "cpu": cpu, "cores": os.cpu_count(),
            "python": platform.python_version(),
            "g++": v(["g++", "--version"]), "rustc": v(["rustc", "--version"]),
            "julia": v(["julia", "--version"]),
            "java": v(["java", "-version"]),
            "R": v(["Rscript", "--version"]),
            "octave": v(["octave-cli", "--version"])}


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--langs", default=",".join(LANGS + ["wfdb-python"]))
    ap.add_argument("--reps", type=int, default=5)
    ap.add_argument("--tool-reps", type=int, default=3)
    ap.add_argument("--data", default=os.path.join(BUILD, "data"))
    ap.add_argument("--cbin", help="the bin directory of the original WFDB "
                    "package, to time its tools too")
    ap.add_argument("--no-build", action="store_true")
    ap.add_argument("--no-tools", action="store_true")
    ap.add_argument("--ops", default=",".join(o for o, _ in OPS))
    ap.add_argument("--json")
    ap.add_argument("--markdown")
    a = ap.parse_args()
    langs = a.langs.split(",")
    ops = a.ops.split(",")
    data = os.path.abspath(a.data)
    if not os.path.exists(os.path.join(data, "long.hea")):
        sys.stderr.write("writing the records in %s\n" % data)
        subprocess.run([sys.executable, os.path.join(HERE, "make_records.py"),
                        data], check=True)
    res = {"_versions": versions(), "_tools": {}}
    for lang in langs:
        sys.stderr.write("== %s\n" % NAMES[lang])
        if not a.no_build:
            build(lang)
        res[lang] = {}
        for op in ops:
            r = run_driver(lang, op, data, a.reps)
            res[lang][op] = r
            sys.stderr.write("  %-15s best %-9s first %-9s check %s\n" % (
                op, fmt_t(r["best"]), fmt_t(r["first"]), r["check"]))
        if not a.no_tools and lang != "wfdb-python":
            res["_tools"][lang] = {
                t: run_tool(lang, t, args, data, a.tool_reps, None)
                for t, args, _ in TOOLS}
    if a.cbin and not a.no_tools:
        res["_tools"]["c"] = {t: run_tool("c", t, args, data, a.tool_reps,
                                          os.path.abspath(a.cbin))
                              for t, args, _ in TOOLS}
    # All the WFDB-x languages must have read and written the same data.
    bad = []
    for op in ops:
        checks = {x: res[x][op]["check"] for x in langs
                  if x != "wfdb-python" and op in res.get(x, {})}
        if checks and not all(same(v, list(checks.values())[0])
                              for v in checks.values()):
            bad.append("%s: %s" % (op, checks))
    order = [x for x in langs]
    if a.cbin:
        order.append("c")
    text = tables(res, order)
    sys.stdout.write("\n" + text)
    if a.json:
        with open(a.json, "w") as f:
            json.dump(res, f, indent=1)
    if a.markdown:
        with open(a.markdown, "w") as f:
            f.write(text)
    if bad:
        sys.stderr.write("DIFFERENT RESULTS:\n  " + "\n  ".join(bad) + "\n")
        sys.exit(1)


if __name__ == "__main__":
    main()
