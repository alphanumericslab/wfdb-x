"""Benchmark driver for wfdb-python (the wfdb package on PyPI), for
comparison with WFDB-x.

    python3 benchmarks/wfdb_python/bench.py OP DATADIR REPS

The same operations and output as the WFDB-x drivers (benchmarks/README.md).
wfdb-python must be installed (pip install wfdb).

This file is part of WFDB-x. Copyright (C) 2026 Reza Sameni. GPL-3.0-or-later;
see LICENSE.
"""

import json
import os
import shutil
import sys
import tempfile
import time

import numpy as np
import wfdb


def main(op, d, reps):
    out = tempfile.mkdtemp(prefix="wfdbpy-bench-")
    rec = lambda name, **kw: wfdb.rdrecord(os.path.join(d, name), **kw)
    try:
        if op in ("write_long", "write_ann"):
            src = rec("long", physical=False)
            ann = wfdb.rdann(os.path.join(d, "long"), "atr")
        if op == "read_long":
            def run():
                return int(rec("long", physical=False).d_signal.sum(
                    dtype=np.int64))
        elif op == "read_long_phys":
            def run():
                return round(float(np.nansum(rec("long").p_signal)), 3)
        elif op == "read_mimic":
            def run():
                r = rec("mimic", physical=False, m2s=True)
                return int(r.d_signal.sum(dtype=np.int64))
        elif op == "read_wide":
            def run():
                return int(rec("wide", physical=False).d_signal.sum(
                    dtype=np.int64))
        elif op == "write_long":
            def run():
                wfdb.wrsamp("out", fs=src.fs, units=src.units,
                            sig_name=src.sig_name, d_signal=src.d_signal,
                            fmt=["16"] * src.n_sig, adc_gain=src.adc_gain,
                            baseline=src.baseline, write_dir=out)
                return os.path.getsize(os.path.join(out, "out.dat"))
        elif op == "read_ann":
            def run():
                return len(wfdb.rdann(os.path.join(d, "long"), "atr").sample)
        elif op == "write_ann":
            def run():
                wfdb.wrann("out", "atr", ann.sample, symbol=ann.symbol,
                           aux_note=ann.aux_note, write_dir=out)
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
