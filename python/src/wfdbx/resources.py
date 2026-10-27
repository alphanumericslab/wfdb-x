"""Files shipped with the WFDB-x package: a sample record and the example
notebooks.

``sample_data_dir()`` is the directory of the sample record ``100s`` (the
first minute of MIT-BIH Arrhythmia Database record 100, with its beat
annotations), so that examples run without a network connection::

    import wfdbx
    rec = wfdbx.read_record("100s", physical=True,
                            input_dir=wfdbx.sample_data_dir())

``copy_examples(dest)`` copies the example notebooks to a directory where
they can be opened and run (``wfdbx --examples DIR`` does the same from the
command line).

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This library is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import os
import shutil

__all__ = ["sample_data_dir", "examples_dir", "copy_examples"]

_HERE = os.path.dirname(os.path.abspath(__file__))


def sample_data_dir():
    """Return the directory that holds the sample record ``100s``.

    Part of WFDB-x; not in the original WFDB package.
    """
    return os.path.join(_HERE, "sample_data")


def examples_dir():
    """Return the directory that holds the example notebooks (``*.ipynb``).

    Part of WFDB-x; not in the original WFDB package.
    """
    return os.path.join(_HERE, "examples")


def copy_examples(dest):
    """Copy the example notebooks to directory ``dest`` (created if needed).

    Existing files of the same names are replaced.  Returns the list of the
    paths of the copied notebooks, in order.

    Part of WFDB-x; not in the original WFDB package.
    """
    os.makedirs(dest, exist_ok=True)
    copied = []
    for name in sorted(os.listdir(examples_dir())):
        if name.endswith(".ipynb"):
            target = os.path.join(dest, name)
            shutil.copyfile(os.path.join(examples_dir(), name), target)
            copied.append(target)
    return copied
