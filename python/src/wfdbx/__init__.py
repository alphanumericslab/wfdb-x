"""wfdb-x: a faithful Python implementation of the WFDB library.

wfdb-x reproduces the behavior of the WFDB Software Package (version 10.7.0)
by George B. Moody and contributors: it reads and writes the same files,
and its command-line tools produce the same output as the original C tools.

Two interfaces are provided:

* a high-level NumPy interface: ``read_record``, ``read_annotations``,
  ``read_header``, ``write_record`` and ``write_annotations`` (with the
  classes ``Record``, ``Header`` and ``Annotations``);
* the C library API, under the same names as in C (``isigopen``,
  ``getvec``, ``getann``, ``putann``, ``strtim``, ...).  Where a C function
  fills a caller-supplied array, the Python function fills a
  caller-supplied list (see the documentation of each function).

Example::

    import wfdbx
    rec = wfdbx.read_record("100s", sampto=1000, physical=True)
    ann = wfdbx.read_annotations("100s", "atr")

Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
This library is free software; you can redistribute it and/or modify it under
the terms of the GNU Library General Public License as published by the Free
Software Foundation; either version 2 of the License, or (at your option) any
later version.
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
from .resources import sample_data_dir, examples_dir, copy_examples
