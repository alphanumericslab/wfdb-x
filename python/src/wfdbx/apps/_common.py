"""Helpers shared by the WFDB-x command-line applications.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import sys

from .._cstd import sprintf, sscanf
from .._wfdbio import (wfdbx_write_errors, wfdbx_note_write_error,
                       wfdbx_stdout_error, wfdbx_stdout_failed)
from .._signal import (wfdbx_get_legacy, wfdbx_set_legacy, wfdbx_legacy_args,
                       sampfreq, setsampfreq, WFDB_DEFFREQ,
                       WFDB_DEFGAIN)

_MAXPARTS = 4096        # strings buffered by Output before writing them


class Output:
    """Buffered byte-exact standard output (latin-1 text)."""

    def __init__(self, stream=None):
        if stream is None:
            stream = sys.stdout
        self.raw = getattr(stream, "buffer", stream)
        self.parts = []
        self.size = 0

    def write(self, s):
        self.parts.append(s)
        self.size += 1
        if self.size >= _MAXPARTS:
            self.flush()

    def printf(self, fmt, *args):
        """Write printf-style formatted text."""
        self.write(sprintf(fmt, *args))

    def flush(self):
        if self.parts:
            data = "".join(self.parts).encode("latin-1", "replace")
            self.parts = []
            self.size = 0
            try:
                self.raw.write(data)
            except BrokenPipeError:
                raise SystemExit(1)
            except OSError:
                wfdbx_stdout_error()
        try:
            self.raw.flush()
        except BrokenPipeError:
            pass
        except OSError:
            wfdbx_stdout_error()
        except ValueError:
            pass


def eprint(s):
    """Write a string to the standard error output (unbuffered)."""
    flush_stdout()
    raw = getattr(sys.stderr, "buffer", None)
    if raw is not None:
        raw.write(s.encode("latin-1", "replace"))
        raw.flush()
    else:
        sys.stderr.write(s)
        sys.stderr.flush()


def flush_stdout():
    """Flush the standard output (a failure is noted: see run)."""
    try:
        sys.stdout.flush()
    except BrokenPipeError:
        pass
    except OSError:
        wfdbx_stdout_error()
    except ValueError:
        pass


def write_stdout(out, data):
    """Write bytes to out, the binary standard output (a failure is noted:
    see run)."""
    try:
        out.write(data)
    except BrokenPipeError:
        raise SystemExit(1)
    except OSError:
        wfdbx_stdout_error()


class RawOutput:
    """The binary standard output, written directly (a failure is noted:
    see run)."""

    def __init__(self):
        self.raw = sys.stdout.buffer

    def write(self, data):
        write_stdout(self.raw, data)

    def flush(self):
        flush_stdout()


class OutputFile:
    """A file that an application writes itself (opened as by open(name,
    "wb"), which raises OSError if it cannot be created).  A failed write
    is remembered; wfdb-x: in normal mode, close() then prints "PNAME: write
    error on NAME" and counts a write error (see wfdbx_write_errors)."""

    def __init__(self, name, pname):
        self.fp = open(name, "wb")
        self.name = name
        self.pname = pname
        self.err = False

    def write(self, data):
        if not self.err:
            try:
                self.fp.write(data)
            except OSError:
                self.err = True

    def close(self):
        try:
            self.fp.close()
        except OSError:
            self.err = True
        if self.err and not legacy():
            eprintf("%s: write error on %s\n", self.pname, self.name)
            wfdbx_note_write_error()


def eprintf(fmt, *args):
    """Write printf-style formatted text to the standard error output."""
    eprint(sprintf(fmt, *args))


class Exit(Exception):
    """Raised to terminate an application with a status code."""

    def __init__(self, code):
        Exception.__init__(self, code)
        self.code = code


def run(main_func, argv, out=None):
    """Run an application's main function, handling Exit and flushing.

    wfdb-x: --legacy as the first argument (argv[1]) is removed and turns
    legacy mode on for the run (see wfdbx_legacy_args), before anything
    else; the previous setting is restored afterwards.

    wfdb-x: at the end, in normal mode, a standard output that could not be
    written is reported ("PROGRAM: write error on standard output"), and the
    exit status 0 becomes 1 if the standard output or another output file
    could not be written (see wfdbx_write_errors), as for the standard tools.
    Legacy mode keeps the original exit status.
    """
    argv = list(argv)
    previous = wfdbx_get_legacy()
    wfdbx_legacy_args(argv)
    errors = wfdbx_write_errors()
    try:
        code = main_func(argv)
    except Exit as e:
        code = e.code
    finally:
        if out is not None:
            out.flush()
        flush_stdout()
        mode = legacy()
        wfdbx_set_legacy(previous)
    code = 0 if code is None else code
    if not mode:
        failed = wfdbx_stdout_failed()
        if failed:
            eprintf("%s: write error on standard output\n", prog_name(argv[0]))
        if code == 0 and (failed or wfdbx_write_errors() > errors):
            code = 1
    return code


def legacy():
    """True in legacy mode (wfdb-x: the original behavior, --legacy)."""
    return wfdbx_get_legacy() != 0


def prog_name(s):
    """Return the program name (everything after the last '/')."""
    i = s.rfind("/")
    return s[i + 1:]


def freq_option(argv, i, pname):
    """Parse the argument of a -F option (WFDB-x) at argv[i].

    Returns the sampling frequency, or raises Exit(1) after the C error
    message if the argument is missing, not a number, or not positive.
    """
    if i < len(argv):
        n, v = sscanf(argv[i], "%lf")
        if n == 1 and v[0] > 0.0:
            return v[0]
    eprintf("%s: sampling frequency (> 0) must follow -F\n", pname)
    raise Exit(1)


def legacy_help(help_lines, changes):
    """wfdb-x: the help text of the original program (printed in legacy
    mode): help_lines, with each line that is a key of changes replaced by
    its value (removed if the value is None)."""
    return [changes.get(s, s) for s in help_lines
            if changes.get(s, s) is not None]


def legacy_sampfreq(record):
    """wfdb-x: legacy mode (original behavior): the sampling frequency of
    record, or WFDB_DEFFREQ (also set with setsampfreq) if its header
    cannot be read."""
    sps = sampfreq(record)
    if sps < 0.0:
        sps = WFDB_DEFFREQ
        setsampfreq(sps)
    return sps


def legacy_gains(si):
    """wfdb-x: legacy mode (original behavior): give uncalibrated signals
    (gain 0) the C programs' default gain, WFDB_DEFGAIN."""
    for s in si:
        if s.gain == 0.0:
            s.gain = WFDB_DEFGAIN


def freq_not_specified(pname, record, use_f=False):
    """Report that the sampling frequency of a record is not specified
    (wfdb-x: there is no default sampling frequency)."""
    eprintf("%s: sampling frequency of record %s is not specified%s\n",
            pname, record, " (use -F)" if use_f else "")
