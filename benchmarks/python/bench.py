"""Benchmark driver for the Python implementation of WFDB-x.

    python3 benchmarks/python/bench.py OP DATADIR REPS

See benchmarks/README.md for the operations and the output (one JSON line).

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
It has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import json
import os
import shutil
import sys
import tempfile
import time

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))), "python", "src"))
import wfdbx as w  # noqa: E402


def main(op, d, reps):
    w.wfdbx_set_input_dir(d)
    out = tempfile.mkdtemp(prefix="wfdbx-bench-")
    try:
        if op in ("write_long", "write_ann"):
            src = w.read_record("long")
            ann = w.read_annotations("long", "atr")
        if op == "read_long":
            def run():
                return int(w.read_record("long").signals.sum(dtype=np.int64))
        elif op == "read_long_phys":
            def run():
                return round(float(np.nansum(
                    w.read_record("long", physical=True).signals)), 3)
        elif op == "read_mimic":
            def run():
                return int(w.read_record("mimic").signals.sum(dtype=np.int64))
        elif op == "read_wide":
            def run():
                return int(w.read_record("wide").signals.sum(dtype=np.int64))
        elif op == "write_long":
            def run():
                w.write_record("out", src.signals, src.fs, fmt=16,
                               gains=src.gains, adcres=16, units=src.units,
                               dir=out)
                return os.path.getsize(os.path.join(out, "out.dat"))
        elif op == "read_ann":
            def run():
                return len(w.read_annotations("long", "atr").samples)
        elif op == "write_ann":
            def run():
                w.write_annotations("out", "atr", ann.samples, codes=ann.codes,
                                    aux=ann.aux, dir=out)
                return os.path.getsize(os.path.join(out, "out.atr"))
        else:
            sys.exit("unknown operation " + op)
        t = time.perf_counter()
        check = run()
        first = time.perf_counter() - t
        times = []
        for _ in range(reps):
            t = time.perf_counter()
            run()
            times.append(time.perf_counter() - t)
        print(json.dumps({"op": op, "first": first, "best": min(times),
                          "times": times, "check": check}))
    finally:
        shutil.rmtree(out, ignore_errors=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]))
