"""wfdb-x: read and write WFDB records in Python.

``wfdbx`` reads and writes physiological signal records in the WFDB format
used by PhysioNet. It is a complete Python implementation of the WFDB
Software Package 10.7.0: the library and all of its command-line tools. It
reads and writes the same files as the original C library, and its tools
print the same output.

You can use it in three ways:

* High-level functions that read and write whole records and annotation
  files as NumPy arrays: ``read_record``, ``read_header``,
  ``read_annotations``, ``write_record`` and ``write_annotations``. See
  ``help(wfdbx.highlevel)``. ``check_record`` checks a record and its
  annotation files, and reports each problem (``help(wfdbx.check)``).
* Command-line tools such as ``rdsamp``, ``rdann`` and ``wrsamp``, run
  through the ``wfdbx`` command, as in ``wfdbx rdsamp -r 100s -t 10``
  (which prints the first 10 seconds of the sample record 100s, included
  with wfdb-x, when the environment variable WFDBX_INPUT_DIR is set to its
  directory, ``wfdbx.sample_data_dir()``).
* The WFDB library functions under their C names (``isigopen``,
  ``getvec``, ``getann``, ...). Where a C function fills an array, the
  Python function fills a list that you pass.

Files are read from the input directory and written to the output
directory. Both are the current directory unless you set them with
``wfdbx_set_input_dir`` and ``wfdbx_set_output_dir``. Network access is
off unless you turn it on with ``wfdbx_set_network``.

Example, with the sample record 100s, included with wfdb-x (the first minute
of record 100 of the MIT-BIH Arrhythmia Database, in the directory
``wfdbx.sample_data_dir()``)::

    import wfdbx
    wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())
    rec = wfdbx.read_record("100s", sampto=1000, physical=True)
    ann = wfdbx.read_annotations("100s", "atr")

Documentation: https://github.com/alphanumericslab/wfdb-x/tree/main/python

This file is part of wfdb-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This library is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

__version__ = "1.0.0"

from ._wfdbio import (
    WFDB_READ, WFDB_WRITE, WFDB_AHA_READ, WFDB_AHA_WRITE, WFDB_APPEND,
    getwfdb, setwfdb, resetwfdb, wfdbquiet, wfdbverbose, wfdberror,
    wfdb_error, wfdbfile, wfdbmemerr, wfdb_me_fatal, wfdbversion,
    wfdbldflags, wfdbcflags,
    wfdbdefwfdb, wfdbdefwfdbcal, wfdbx_set_input_dir, wfdbx_get_input_dir,
    wfdbx_set_output_dir, wfdbx_get_output_dir, wfdbx_set_network,
    wfdbx_get_network,
)
from ._signal import (
    Siginfo, Seginfo, WFDB_INVALID_SAMPLE, WFDB_DEFFREQ, WFDB_DEFGAIN,
    WFDB_DEFRES, WFDB_LOWRES, WFDB_HIGHRES, WFDB_GVPAD, WFDB_MAXRNL,
    WFDB_MAXUSL, WFDB_MAXDSL, WFDB_FMT_LIST,
    isigopen, osigopen, osigfopen, findsig, getspf, setgvmode, getgvmode,
    setifreq, getifreq, getvec, getframe, putvec, isigsettime, isgsettime,
    tnextvec, setibsize, setobsize, newheader, setheader, setmsheader,
    getseginfo, wfdbgetskew, wfdbsetiskew, wfdbsetskew, wfdbgetstart,
    wfdbsetstart, wfdbputprolog, setinfo, putinfo, getinfo, sampfreq,
    setsampfreq, setbasetime, timstr, mstimstr, getcfreq, setcfreq,
    getbasecount, setbasecount, strtim, wfdbx_time_needs_freq, datstr,
    wfdbx_set_legacy, wfdbx_get_legacy, wfdbx_legacy_args,
    strdat, adumuv, muvadu,
    aduphys, physadu, sample, sample_valid, getframes, wfdb_freeinfo,
)
from ._annot import (
    Anninfo, Annotation, annopen, getann, ungetann, putann, iannsettime,
    ecgstr, strecg, setecgstr, annstr, strann, setannstr, anndesc,
    setanndesc, setafreq, getafreq, setiafreq, getiafreq, getiaorigfreq,
    iannclose, oannclose,
)
from ._ecgcodes import *  # noqa: F401,F403  (annotation codes and maps)
from ._calib import (
    Calinfo, calopen, getcal, putcal, newcal, flushcal, WFDB_AC_COUPLED,
    WFDB_DC_COUPLED, WFDB_CAL_SQUARE, WFDB_CAL_SINE, WFDB_CAL_SAWTOOTH,
    WFDB_CAL_UNDEF,
)
from ._wfdbinit import wfdbinit, wfdbquit, wfdbflush
from .highlevel import (Record, Header, Annotations, read_record,
                        read_annotations, write_record, write_annotations,
                        read_header)
from .check import CheckReport, Issue, check_record
from .resources import sample_data_dir, examples_dir, copy_examples
