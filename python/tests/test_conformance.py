"""Run the cross-language conformance suite against the Python tools.

The full suite takes a few minutes; set WFDBX_CONFORMANCE=0 to skip it, or
WFDBX_CONFORMANCE=rdsamp,rdann (for example) to run selected tools.

Part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import os
import subprocess
import sys

import pytest

from conftest import ROOT

SEL = os.environ.get("WFDBX_CONFORMANCE", "all")


@pytest.mark.skipif(SEL == "0", reason="disabled by WFDBX_CONFORMANCE=0")
@pytest.mark.skipif(not os.path.isdir(os.path.join(ROOT, "tests", "conformance")),
                    reason="the conformance suite of the wfdb-x repository "
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
