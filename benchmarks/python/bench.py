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
import struct
import sys
import tempfile
import time

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))), "python", "src"))
import wfdbx as w  # noqa: E402


def dump_samples(path, x, dtype):
    """Samples, frame by frame (row-major), little-endian."""
    np.ascontiguousarray(x, dtype=dtype).tofile(path)


def dump_annotations(path, a):
    """Each annotation: time (int64), code, subtype, chan, num, the length
    of the aux text (int32; -1 if none) and the aux text, little-endian."""
    with open(path, "wb") as f:
        for k in range(len(a.samples)):
            x = a.aux[k] if a.aux is not None else None
            b = x.encode("latin-1") if x is not None else b""
            f.write(struct.pack("<qiiiii", int(a.samples[k]), int(a.codes[k]),
                                int(a.subtypes[k]), int(a.chans[k]),
                                int(a.nums[k]), len(b) if x is not None
                                else -1) + b)


def main(op, d, reps):
    w.wfdbx_set_input_dir(d)
    out = tempfile.mkdtemp(prefix="wfdbx-bench-")
    dump = os.environ.get("WFDBX_BENCH_DUMP")
    try:
        if op in ("write_long", "write_ann"):
            src = w.read_record("long")
            ann = w.read_annotations("long", "atr")
        # run() is the timed call; check() and save() see its result.
        if op in ("read_long", "read_mimic", "read_wide"):
            rec = op[5:]

            def run():
                return w.read_record(rec).signals

            def check(x):
                return int(x.sum(dtype=np.int64))

            def save(x, p):
                dump_samples(p + ".bin", x, "<i4")
        elif op == "read_long_phys":
            def run():
                return w.read_record("long", physical=True).signals

            def check(x):
                return round(float(np.nansum(x)), 3)

            def save(x, p):
                dump_samples(p + ".bin", x, "<f8")
        elif op == "write_long":
            def run():
                w.write_record("out", src.signals, src.fs, fmt=16,
                               gains=src.gains, adcres=16, units=src.units,
                               dir=out)

            def check(x):
                return os.path.getsize(os.path.join(out, "out.dat"))

            def save(x, p):
                shutil.copyfile(os.path.join(out, "out.hea"), p + ".hea")
                shutil.copyfile(os.path.join(out, "out.dat"), p + ".dat")
        elif op == "read_ann":
            def run():
                return w.read_annotations("long", "atr")

            def check(x):
                return len(x.samples)

            def save(x, p):
                dump_annotations(p + ".ann", x)
        elif op == "write_ann":
            def run():
                w.write_annotations("out", "atr", ann.samples, codes=ann.codes,
                                    aux=ann.aux, dir=out)

            def check(x):
                return os.path.getsize(os.path.join(out, "out.atr"))

            def save(x, p):
                shutil.copyfile(os.path.join(out, "out.atr"), p + ".atr")
        else:
            sys.stderr.write("unknown operation %s\n" % op)
            sys.exit(2)
        t = time.perf_counter()
        result = run()
        first = time.perf_counter() - t
        value = check(result)
        if dump:
            save(result, os.path.join(dump, op))
        times = []
        for _ in range(reps):
            t = time.perf_counter()
            run()
            times.append(time.perf_counter() - t)
        print(json.dumps({"op": op, "first": first, "best": min(times),
                          "times": times, "check": value}))
    finally:
        shutil.rmtree(out, ignore_errors=True)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]))
