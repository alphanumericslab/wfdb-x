"""Write the benchmark records (with the Python implementation of WFDB-x).

    python3 benchmarks/make_records.py DIR

DIR receives three records, the same on every run (fixed random seeds):

  long   2 signals, format 212, 360 Hz, 1 hour (1,296,000 frames), and its
         annotation file long.atr (4,500 beats, some with aux strings): a
         long single-segment record, like those of the MIT-BIH databases
  mimic  a multi-segment record of 12 segments of 75,000 frames, 125 Hz,
         4 signals in format 212, the first at 4 samples per frame (an ECG
         at 500 Hz): shaped like the records of the MIMIC Database
  wide   12 signals, format 16, 500 Hz, 10 minutes (300,000 frames): a
         12-lead ECG

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
It has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import os
import sys

import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "python", "src"))
import wfdbx  # noqa: E402


def walk(rng, n, cols, lo, hi):
    """A bounded random walk: n rows, cols columns, values in [lo, hi]."""
    x = np.cumsum(rng.integers(-8, 9, size=(n, cols)), axis=0)
    return np.clip(x, lo, hi)


def main(d):
    os.makedirs(d, exist_ok=True)
    rng = np.random.default_rng(2026)
    # long: 1 hour, 2 signals at 360 Hz, format 212, with annotations
    x = walk(rng, 1296000, 2, -2047, 2047)
    wfdbx.write_record("long", x, 360, fmt=212, gains=200, adcres=11,
                       units="mV", names=["MLII", "V5"], dir=d)
    t = np.cumsum(rng.integers(220, 360, size=4500))
    sym = rng.choice(["N", "N", "N", "N", "V", "A"], size=4500)
    aux = [("(AFIB" if k % 97 == 0 else None) for k in range(4500)]
    wfdbx.write_annotations("long", "atr", t, symbols=list(sym), aux=aux,
                            dir=d)
    # mimic: 12 segments of 75,000 frames, ECG at 4 samples per frame
    segs = []
    for k in range(12):
        name = "mimic_%02d" % (k + 1)
        y = walk(rng, 75000, 7, -2047, 2047)
        wfdbx.write_record(name, y, 125, fmt=212, samps_per_frame=[4, 1, 1, 1],
                           gains=[2000, 20, 2000, 2000], adcres=12,
                           units=["mV", "mmHg", "NU", "NU"],
                           names=["II", "ABP", "PLETH", "RESP"], dir=d)
        segs.append(name)
    with open(os.path.join(d, "mimic.hea"), "w") as f:
        f.write("mimic/12 4 125 %d\n" % (12 * 75000))
        for s in segs:
            f.write("%s 75000\n" % s)
    # wide: 12 leads, 500 Hz, 10 minutes, format 16
    z = walk(rng, 300000, 12, -32767, 32767)
    wfdbx.write_record("wide", z, 500, fmt=16, gains=1000, adcres=16,
                       units="mV", names=["I", "II", "III", "aVR", "aVL", "aVF",
                                          "V1", "V2", "V3", "V4", "V5", "V6"],
                       dir=d)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: make_records.py DIR")
    main(sys.argv[1])
