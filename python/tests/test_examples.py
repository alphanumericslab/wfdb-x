"""Tests of the sample data and the example notebooks shipped with wfdb-x.

The notebooks are executed only if nbformat, nbclient and ipykernel are
installed (pip install "wfdb-x[test,examples]").

Part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

import glob
import os

import pytest

import wfdbx

NOTEBOOKS = sorted(glob.glob(os.path.join(wfdbx.examples_dir(), "*.ipynb")))


@pytest.fixture
def sample_path():
    wfdbx.wfdbquit()
    old = wfdbx.getwfdb()
    wfdbx.setwfdb(wfdbx.sample_data_dir())
    yield
    wfdbx.wfdbquit()
    wfdbx.setwfdb(old)


def test_sample_record(sample_path):
    rec = wfdbx.read_record("100s")
    assert rec.fs == 360
    assert rec.signals.shape == (21600, 2)
    assert rec.names == ["MLII", "V5"]
    ann = wfdbx.read_annotations("100s", "atr")
    assert len(ann) == 75


def test_copy_examples(tmp_path):
    assert len(NOTEBOOKS) >= 7
    copied = wfdbx.copy_examples(str(tmp_path / "ex"))
    assert [os.path.basename(p) for p in copied] == \
        [os.path.basename(p) for p in NOTEBOOKS]


@pytest.mark.parametrize("path", NOTEBOOKS, ids=os.path.basename)
def test_notebook(path, tmp_path, monkeypatch):
    nbformat = pytest.importorskip("nbformat")
    nbclient = pytest.importorskip("nbclient")
    pytest.importorskip("ipykernel")
    # The kernel (and the tools the notebooks run) import the wfdbx under test
    pkg_root = os.path.dirname(os.path.dirname(os.path.abspath(wfdbx.__file__)))
    monkeypatch.setenv("PYTHONPATH", os.pathsep.join(
        filter(None, [pkg_root, os.environ.get("PYTHONPATH")])))
    nb = nbformat.read(path, as_version=4)
    client = nbclient.NotebookClient(
        nb, timeout=300, kernel_name="python3",
        resources={"metadata": {"path": str(tmp_path)}})
    client.execute()
