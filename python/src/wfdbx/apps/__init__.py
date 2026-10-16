"""Command-line applications of wfdb-x (ports of the WFDB applications).

Each module in this package provides a ``main(argv=None)`` function that
behaves exactly like the corresponding C application, and can be run as
``python -m wfdbx.apps.NAME`` or through the ``wfdbx`` command.

Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
This program is free software; you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation; either version 2 of the License, or (at your option) any later
version.
"""

TOOLS = [
    # app/
    "ann2rr", "rdann", "rdsamp", "rr2ann", "sampfreq", "sigamp", "signame",
    "signum", "snip", "sortann", "time2sec", "wfdbcat", "wfdbdesc",
    "wfdbtime", "wfdbwhich", "wrann", "wrsamp", "xform",
    # convert/
    "a2m", "ad2m", "ahaecg2mit", "edf2mit", "m2a", "makeid", "md2a",
    "mit2edf", "mit2wav", "parsescp", "rdedfann", "readid", "revise",
    "wav2mit", "wfdb2mat",
]
