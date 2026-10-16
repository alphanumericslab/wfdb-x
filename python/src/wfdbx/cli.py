"""The ``wfdbx`` command: run any wfdb-x command-line tool.

Usage: wfdbx TOOL [ARGUMENTS ...]     (for example: wfdbx rdsamp -r 100s)
       wfdbx --list                   (list the available tools)
       wfdbx --examples [DIR]         (copy the example notebooks to DIR,
                                      by default ./wfdbx-examples)

Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
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
        from . import __version__, wfdbversion
        sys.stdout.write("wfdb-x %s (WFDB %s)\n" % (__version__,
                                                    wfdbversion()))
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
