"""The benchmark program of the Python implementation (its high-level API,
for context), with the operations of kotlin/benchmarks/src/Bench.kt (see
kotlin/benchmarks/run.sh):

    python3 bench.py gen    DIR                 (writes the input record big)
    python3 bench.py read   DIR REC REPS
    python3 bench.py write  DIR REC OUTDIR REPS
    python3 bench.py ann    OUTDIR REPS

Each prints the best time of REPS runs (after one untimed run) and, for
read, a digest of the samples (FNV-1a).

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
It has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it
under the terms of the GNU General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option)
any later version. See LICENSE.
"""

import sys
import time

import numpy as np
import wfdbx


def best_ms(reps, f):
    f()
    best = float("inf")
    for _ in range(reps):
        t = time.perf_counter()
        f()
        best = min(best, (time.perf_counter() - t) * 1000)
    return best


def fnv(samples):
    h = 14695981039346656037
    for v in samples.astype(np.uint32).ravel().tolist():
        h = ((h ^ v) * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return h


def main(a):
    if a[1] == "gen":
        # The input record: 4 signals of 2,000,000 frames in format 16
        # (random walks), at 500 Hz.
        rng = np.random.default_rng(1)
        x = np.cumsum(rng.integers(-20, 21, size=(2000000, 4)), axis=0)
        x = ((x + 16000) % 32000) - 16000
        wfdbx.write_record("big", x, 500, fmt=16, gains=[200, 200, 100, 1000],
                           adcres=16, units="mV", names=["I", "II", "V1", "ABP"],
                           base_time="08:00:00 01/01/2020", dir=a[2])
    elif a[1] == "read":
        out = []
        ms = best_ms(int(a[4]), lambda: out.append(
            wfdbx.read_record(a[3], input_dir=a[2])))
        r = out[-1]
        print("read_record %.1f ms frames=%d nsig=%d digest=%x" %
              (ms, r.signals.shape[0], r.signals.shape[1], fnv(r.signals)))
    elif a[1] == "write":
        r = wfdbx.read_record(a[3], input_dir=a[2])
        ms = best_ms(int(a[5]), lambda: wfdbx.write_record(
            a[3], r.signals, r.fs, fmt=16, gains=r.gains,
            baselines=r.baselines, adcres=16, units="mV", names=r.names,
            dir=a[4]))
        print("write_record %.1f ms" % ms)
    elif a[1] == "ann":
        n = 200000
        k = np.arange(n, dtype=np.int64)
        samples = 10 * k + (7 * k) % 9
        codes = np.array([1, 1, 1, 5, 8, 1, 12, 1])[k % 8]
        subtypes = (k % 50 == 0).astype(np.int64)
        aux = ["(N" if j % 1000 == 0 else None for j in range(n)]
        ms = best_ms(int(a[3]), lambda: wfdbx.write_annotations(
            "big", "bench", samples, codes=codes, subtypes=subtypes, aux=aux,
            dir=a[2]))
        print("write_annotations %.1f ms" % ms)


if __name__ == "__main__":
    main(sys.argv)
