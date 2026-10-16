"""FLAC tests: decoding of libFLAC-written files and encoder round trip.

Part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import numpy as np

import wfdbx as w
from wfdbx._flac import decode_bytes


def test_decode_libflac_files(datadir):
    # flac16.dat was written by the C WFDB library with libFLAC 1.4.3;
    # fmt16 data were written in format 16 from the same generator.
    r = w.read_record("flac16")
    assert r.signals.shape == (9000, 3)
    chans, bps = decode_bytes(open("flac16.dat", "rb").read())
    assert bps == 16 and len(chans) == 3


def test_encoder_roundtrip(datadir):
    x = w.read_record("fmt16").signals
    w.write_record("fl", x, 250, fmt=516, gains=200, adcres=16, units="mV")
    y = w.read_record("fl").signals
    assert np.array_equal(x, y)
    chans, bps = decode_bytes(open("fl.dat", "rb").read())
    assert np.array_equal(np.array(chans).T, x)
