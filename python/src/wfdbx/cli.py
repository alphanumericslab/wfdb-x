"""The ``wfdbx`` command: run any WFDB-x command-line tool.

Usage: wfdbx TOOL [ARGUMENTS ...]     (for example: wfdbx rdsamp -r 100s)
       wfdbx --list                   (list the available tools)
       wfdbx --examples [DIR]         (copy the example notebooks to DIR,
                                      by default ./wfdbx-examples)

In the example, 100s is the sample record included with WFDB-x (the first
minute of record 100 of the MIT-BIH Arrhythmia Database); it is read when the
environment variable WFDBX_INPUT_DIR is set to its directory,
``wfdbx.sample_data_dir()``.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import importlib
import sys

from .apps import TOOLS


def main(argv=None):
    """Run the tool named by argv[0] with the remaining arguments."""
    if argv is None:
        argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        sys.stderr.write(__doc__.split("\n\n")[1] + "\n")
        return 1 if not argv else 0
    if argv[0] == "--list":
        sys.stdout.write("\n".join(TOOLS) + "\n")
        return 0
    if argv[0] == "--examples":
        from .resources import copy_examples
        dest = argv[1] if len(argv) > 1 else "wfdbx-examples"
        for path in copy_examples(dest):
            sys.stdout.write(path + "\n")
        return 0
    if argv[0] == "--version":
        from . import __version__
        sys.stdout.write("WFDB-x %s\n" % __version__)
        return 0
    tool = argv[0]
    if tool not in TOOLS:
        sys.stderr.write("wfdbx: unknown tool '%s' (try 'wfdbx --list')\n"
                         % tool)
        return 1
    mod = importlib.import_module("wfdbx.apps." + tool)
    return mod.main([tool] + argv[1:])


if __name__ == "__main__":
    sys.exit(main())
