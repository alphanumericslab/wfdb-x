"""Shared fixtures for the wfdb-x Python tests.

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
tests wfdb-x; it has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import os
import shutil
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DATA = os.path.join(ROOT, "tests", "data")
# The tests run against python/src when run from the repository, else against
# the installed package.
sys.path.insert(0, os.path.join(os.path.dirname(HERE), "src"))

import wfdbx  # noqa: E402


@pytest.fixture
def datadir(tmp_path, monkeypatch):
    """A temporary copy of tests/data as the current directory and WFDB.

    The test records are those of the wfdb-x repository: tests that need them
    are skipped where they are not available (e.g., in a source distribution).
    """
    if not os.path.isdir(DATA):
        pytest.skip("the test records of the wfdb-x repository are not available")
    d = tmp_path / "data"
    shutil.copytree(DATA, d)
    monkeypatch.chdir(d)
    wfdbx.wfdbquit()
    wfdbx.setwfdb(".")
    yield str(d)
    wfdbx.wfdbquit()
