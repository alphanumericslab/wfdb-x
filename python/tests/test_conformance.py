"""Run the cross-language conformance suite against the Python tools.

The full suite takes a few minutes; set WFDBX_CONFORMANCE=0 to skip it, or
WFDBX_CONFORMANCE=rdsamp,rdann (for example) to run selected tools.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
tests WFDB-x; it has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import os
import subprocess
import sys

import pytest

from conftest import ROOT

SEL = os.environ.get("WFDBX_CONFORMANCE", "all")


@pytest.mark.skipif(SEL == "0", reason="disabled by WFDBX_CONFORMANCE=0")
@pytest.mark.skipif(not os.path.isdir(os.path.join(ROOT, "tests", "conformance")),
                    reason="the conformance suite of the WFDB-x repository "
                           "is not available")
def test_conformance():
    env = dict(os.environ)
    env["PYTHONPATH"] = os.path.join(ROOT, "python", "src") + os.pathsep + \
        env.get("PYTHONPATH", "")
    cmd = [sys.executable,
           os.path.join(ROOT, "tests", "conformance", "harness.py"),
           "check", "--impl", "python"]
    if SEL != "all":
        cmd += SEL.split(",")
    p = subprocess.run(cmd, env=env, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT)
    out = p.stdout.decode("latin-1", "replace")
    assert p.returncode == 0, out[-5000:]
