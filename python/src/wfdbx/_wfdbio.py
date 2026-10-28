"""Low-level I/O for the WFDB library (port of lib/wfdbio.c).

This module implements file lookup (``wfdb_open``: the input and output
directories, and the WFDB path in legacy mode), access to remote files,
error reporting (``wfdb_error``/``wfdberror``), and the small binary helpers
used by the signal and annotation modules.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.

It is a Python translation of lib/wfdbio.c, lib/wfdb.h and lib/wfdblib.h from
the WFDB Software Package 10.7.0, by George B. Moody. The translation follows
the logic and behavior of the original code, but it is new code, not the
original C code.

Changes from the original: files are found only where they are named, not by a
search of the WFDB path: a relative name is read under the input directory and
written under the output directory (by default, the current directory), and an
absolute name, a ~ name or a URL is used as given; setwfdb, getwfdb and
resetwfdb set and return the input directory, and the WFDB environment variable
is ignored; a URL is opened only if network access is turned on
(wfdbx_set_network or WFDBX_NETWORK), and is then read in full by Python's
urllib; the original's HTTP and FTP code (NETFILES) is not translated; ".." is
accepted in names, and only the last component of a record name is checked;
write errors are counted (wfdbx_write_errors); additions:
wfdbx_set_input_dir, wfdbx_get_input_dir, wfdbx_set_output_dir,
wfdbx_get_output_dir, wfdbx_set_network, wfdbx_get_network,
wfdbx_write_errors and wfdbx_note_write_error; legacy mode
(wfdbx_set_legacy) restores the original behavior (the WFDB path, without
network access). Each change is marked "WFDB-x:" in the code;
docs/DIVERGENCES.md gives the reasons.

Original C code: lib/wfdbio.c, lib/wfdb.h and lib/wfdblib.h, WFDB Software
Package 10.7.0.
  lib/wfdbio.c: Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by
  Benjamin Moody.
  lib/wfdb.h: Copyright (C) 1983-2013 George B. Moody; revised 2010-2020 by
  Benjamin Moody.
  lib/wfdblib.h: Copyright (C) 1989-2012 George B. Moody; revised 2017-2022 by
  Benjamin Moody.
Python translation and changes: Copyright (C) 2026 Reza Sameni.

This library is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version. See LICENSE.
"""

import io
import os
import sys

from ._cstd import sprintf, strtol

__all__ = [
    "WFDB_MAJOR", "WFDB_MINOR", "WFDB_RELEASE", "WFDB_VERSION",
    "WFDB_LOCAL", "WFDB_NET", "WFDB_READ", "WFDB_WRITE", "WFDB_AHA_READ",
    "WFDB_AHA_WRITE", "WFDB_APPEND", "DEFWFDB", "DEFWFDBCAL",
    "WFDBFile", "getwfdb", "setwfdb", "resetwfdb", "wfdbquiet",
    "wfdbverbose", "wfdberror", "wfdb_error", "wfdbfile", "wfdbmemerr",
    "wfdb_me_fatal",
    "wfdbversion", "wfdbldflags", "wfdbcflags", "wfdbdefwfdb",
    "wfdbdefwfdbcal", "wfdb_open", "wfdb_fopen", "wfdb_checkname",
    "wfdb_striphea", "wfdb_setirec", "wfdb_getirec", "wfdb_addtopath",
    "wfdb_parse_path", "wfdbx_set_input_dir", "wfdbx_get_input_dir",
    "wfdbx_set_output_dir", "wfdbx_get_output_dir", "wfdbx_set_network",
    "wfdbx_get_network", "wfdbx_write_errors", "wfdbx_note_write_error",
]

WFDB_MAJOR = 10
WFDB_MINOR = 7
WFDB_RELEASE = 0
WFDB_VERSION = "10.7.0"
# The C library reports the date on which it was compiled; WFDB-x reports
# the date of the WFDB release it reproduces.
WFDB_BUILD_DATE = "Jun 10 2022"

WFDB_LOCAL = 0          # a local file
WFDB_NET = 1            # a remote file (http:// or https://)

# File modes (also the stat of an Anninfo).
WFDB_READ = 0           # standard input annotation file
WFDB_WRITE = 1          # standard output annotation file
WFDB_AHA_READ = 2       # AHA-format input annotation file
WFDB_AHA_WRITE = 3      # AHA-format output annotation file
WFDB_APPEND = 4         # for output info files

# The default WFDB path (wfdbdefwfdb; used in legacy mode only, which opens
# no URLs: there is no default URL anywhere in WFDB-x)
DEFWFDB = ". /usr/local/database http://physionet.org/physiobank/database"
DEFWFDBCAL = "wfdbcal"
WFDB_MAXRNL = 50        # maximum length of a record name
MAXNEST = 10            # maximum nesting of indirect (@FILE) WFDB paths
NET_TIMEOUT = 30        # timeout (seconds) for reading a remote file

DSEP = "/"              # directory separator
_ENC = "latin-1"        # text encoding: one character per byte


class WFDBFile:
    """A WFDB_FILE: a local file or an in-memory copy of a remote file."""

    __slots__ = ("fp", "type", "name", "is_std", "out", "_err", "_eof")

    def __init__(self, fp, ftype=WFDB_LOCAL, name=None, is_std=False,
                 out=False):
        self.fp = fp
        self.type = ftype
        self.name = name
        self.is_std = is_std
        self.out = out          # WFDB-x: an output file (see close)
        self._err = False
        self._eof = False

    # The methods below emulate the C stdio functions used by the library.
    def read(self, n):
        try:
            b = self.fp.read(n)
        except (OSError, ValueError):
            self._err = True
            return b""
        if b is None:
            b = b""
        if len(b) < n:
            self._eof = True
        return b

    def readinto(self, buf):
        """Read up to len(buf) bytes into the writable buffer buf (as
        read(len(buf)), without an intermediate bytes object); returns the
        number of bytes read."""
        n = len(buf)
        got = 0
        try:
            readinto = getattr(self.fp, "readinto", None)
            if readinto is None:
                b = self.fp.read(n) or b""
                got = len(b)
                buf[:got] = b
            else:
                while got < n:
                    k = readinto(buf[got:])
                    if not k:
                        break
                    got += k
        except (OSError, ValueError):
            self._err = True
        if got < n:
            self._eof = True
        return got

    def readall(self):
        """Read everything up to the end of the file."""
        try:
            b = self.fp.read()
        except (OSError, ValueError):
            self._err = True
            return b""
        self._eof = True
        return b or b""

    def getc(self):
        b = self.read(1)
        return b[0] if b else -1

    def write(self, b):
        try:
            self.fp.write(b)
        except (OSError, ValueError):
            self._err = True
            if self.is_std:
                wfdbx_stdout_error()
            return 0
        return len(b)

    def putc(self, c):
        return self.write(bytes((c & 0xFF,)))

    def printf(self, fmt, *args):
        s = sprintf(fmt, *args)
        self.write(s.encode(_ENC))
        return len(s)

    def seek(self, offset, whence=0):
        try:
            self.fp.seek(offset, whence)
        except (OSError, ValueError):
            return -1
        self._eof = False
        return 0

    def tell(self):
        try:
            return self.fp.tell()
        except (OSError, ValueError):
            return -1

    def flush(self):
        try:
            self.fp.flush()
        except (OSError, ValueError):
            return -1
        return 0

    def feof(self):
        return self._eof

    def ferror(self):
        return self._err

    def clearerr(self):
        self._err = False
        self._eof = False

    def close(self):
        # WFDB-x: an output file that could not be written, flushed or
        # closed counts as a write error (see wfdbx_write_errors)
        if self.is_std:
            try:
                self.fp.flush()
            except (OSError, ValueError):
                self._err = True
            if self.out and self._err:
                _io.write_errors += 1
                wfdbx_stdout_error()
            return 0
        status = 0
        try:
            self.fp.close()
        except OSError:
            status = -1
        if self.out and (self._err or status):
            _io.write_errors += 1
        return status

    def getline(self):
        """wfdb_getline(): read one line including its newline (str)."""
        try:
            b = self.fp.readline()
        except (OSError, ValueError):
            self._err = True
            b = b""
        if not b or not b.endswith(b"\n"):
            self._eof = True
        return b.decode(_ENC)

    def g16(self):
        """Read a 16-bit integer in PDP-11 (little-endian) format."""
        b = self.read(2)
        lo = b[0] if len(b) > 0 else 0xFF
        hi = b[1] if len(b) > 1 else 0xFF
        x = (hi << 8) | lo
        return x - 0x10000 if x & 0x8000 else x

    def g32(self):
        """Read a 32-bit integer in PDP-11 format (high word first)."""
        x = self.g16()
        y = self.g16()
        v = ((x << 16) | (y & 0xFFFF))
        return v

    def p16(self, x):
        self.write(bytes((x & 0xFF, (x >> 8) & 0xFF)))

    def p32(self, x):
        self.p16((x >> 16) & 0xFFFF)
        self.p16(x & 0xFFFF)


class _IOState:
    def __init__(self):
        self.wfdbpath = None
        self.wfdbpath_init = None
        self.path_list = []          # list of [prefix, type]
        self.error_print = True
        self.error_flag = False
        self.error_message = None
        self.wfdb_filename = None
        self.irec = ""
        self.mem_behavior = 1
        # WFDB-x: the settings that locate files (see wfdbx_set_input_dir,
        # wfdbx_set_output_dir and wfdbx_set_network); each is read from its
        # environment variable when first needed (None: not yet)
        self.input_dir = None
        self.env_input_dir = None
        self.input_dir_init = False
        self.wfdb_warned = False
        self.setwfdb_called = False  # the input directory set by setwfdb:
        self.setwfdb_input_dir = None
        self.output_dir = None
        self.env_output_dir = None
        self.output_dir_init = False
        self.network = None
        self.env_network = False
        self.network_warned = False
        self.fetched = {}            # URL -> contents (bytes), or None
        self.write_errors = 0        # see wfdbx_write_errors
        self.stdout_failed = False   # see wfdbx_stdout_error


_io = _IOState()


def _stderr_write(s):
    try:
        sys.stderr.flush()
        buf = getattr(sys.stderr, "buffer", None)
        if buf is not None:
            buf.write(s.encode(_ENC, "replace"))
            buf.flush()
        else:
            sys.stderr.write(s)
            sys.stderr.flush()
    except (OSError, ValueError):
        pass


# ---------------------------------------------------------------------------
# WFDB path handling

def resetwfdb():
    """Restore the WFDB path to the value first returned by getwfdb().

    WFDB-x: in normal mode, restore the input directory set by the last
    setwfdb(), if any (wfdbquit() does not call resetwfdb in normal mode).

    Translation of the C function resetwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
    arguments and results. Differences: it restores the input directory set by
    the last setwfdb() (the WFDB path in legacy mode); see docs/DIVERGENCES.md.
    """
    if not _legacy():
        if _io.setwfdb_called:
            _put_input_dir(_io.setwfdb_input_dir)
        return
    if _io.wfdbpath_init is not None:
        _io.wfdbpath = _io.wfdbpath_init


def getwfdb():
    """Return the input directory, or "." if none is set.

    WFDB-x: files are not searched for (see wfdbx_set_input_dir).  In
    legacy mode, return the WFDB path, the list of places searched for WFDB
    files: it is taken from the WFDB environment variable, or is DEFWFDB if
    WFDB is not set; its components (directories or URL prefixes) are
    separated by spaces or semicolons (or colons, other than in URLs), and a
    value "@file" means that the path is read from that file.

    Translation of the C function getwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
    arguments and results. Differences: it returns the input directory (the
    WFDB path in legacy mode); see docs/DIVERGENCES.md.
    """
    if not _legacy():
        _init_input_dir()
        return _io.input_dir if _io.input_dir else "."
    if _io.wfdbpath is None:
        p = os.environ.get("WFDB")
        if p is None:
            p = DEFWFDB
        p = _getiwfdb(p)
        _io.wfdbpath = p
        _io.wfdbpath_init = p
        wfdb_parse_path(p)
    return _io.wfdbpath


def setwfdb(p):
    """Set the input directory (a C-compatible form of wfdbx_set_input_dir).

    WFDB-x: ``p`` is split into components as the WFDB path is (at spaces,
    semicolons, and colons other than in URLs); it must contain at most one
    non-empty component, which becomes the input directory (a directory, a
    ~ name or a URL; none, e.g. "" or ";", or None: the default).  With more
    than one, an error is reported and nothing changes: WFDB-x reads from a
    single input directory.  resetwfdb() restores the value set by the last
    setwfdb().

    In legacy mode, set the WFDB path (see getwfdb()) as the C library does:
    ``p`` replaces the current path; None restores the value of the WFDB
    environment variable (or DEFWFDB); the WFDB environment variable is also
    set to ``p``, so that programs started afterwards inherit it.

    Translation of the C function setwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
    arguments and results. Differences: it sets a single input directory (the
    WFDB path in legacy mode); see docs/DIVERGENCES.md.
    """
    if not _legacy():
        _setwfdb_normal(p)
        return
    if p is None:
        p = os.environ.get("WFDB")
        if p is None:
            p = DEFWFDB
    _export_config(p)
    p = _getiwfdb(p)
    _io.wfdbpath = p
    wfdb_parse_path(p)


def _setwfdb_normal(p):
    dirs = [c for c, _ in _path_components(p or "") if c]
    if len(dirs) > 1:
        wfdb_error("setwfdb: WFDB-x reads from a single input directory; use "
                   "wfdbx_set_input_dir (or legacy mode for the WFDB search "
                   "path)\n")
        return -1
    d = dirs[0] if dirs else None
    _put_input_dir(d)
    _io.setwfdb_input_dir = d
    _io.setwfdb_called = True
    return 0


def _export_config(p):
    os.environ["WFDB"] = p
    if os.environ.get("WFDBCAL") is None:
        os.environ["WFDBCAL"] = DEFWFDBCAL
    if os.environ.get("WFDBANNSORT") is None:
        os.environ["WFDBANNSORT"] = "1"
    if os.environ.get("WFDBGVMODE") is None:
        os.environ["WFDBGVMODE"] = "0"


def _getiwfdb(p):
    i = 0
    while i < MAXNEST and p is not None and p.startswith("@"):
        try:
            with open(p[1:], "rb") as f:
                data = f.read().decode(_ENC)
            while data and data[-1] in "\r\n":
                data = data[:-1]
            p = data
        except OSError:
            p = ""
        i += 1
    if p is not None and p.startswith("@"):
        wfdb_error("getwfdb: files nested too deeply\n")
        p = ""
    return p


def _path_components(p):
    """Split a WFDB path string into its components: a list of
    (prefix, type) pairs, type being WFDB_LOCAL or WFDB_NET."""
    out = []
    n = len(p)
    q = 0
    while q < n:
        while q < n and p[q] in " \t\n\r":
            q += 1
        start = q
        q -= 1
        current_type = WFDB_LOCAL
        slashes = 0
        while True:
            q += 1
            c = p[q] if q < n else "\0"
            if c == ":":
                if p[q + 1:q + 3] == "//":
                    current_type = WFDB_NET
                elif current_type != WFDB_NET or slashes > 2:
                    break
            elif c in "; \t\n\r\0":
                break
            elif c == "/":
                slashes += 1
        out.append((p[start:q], current_type))
        if q < n:
            q += 1
    return out


def wfdb_parse_path(p):
    """Split a WFDB path string into the components searched by wfdb_open()
    (legacy mode).

    Translation of the C function wfdb_parse_path() (lib/wfdbio.c, WFDB
    10.7.0): same arguments and results. Differences: it is used only in legacy
    mode; see docs/DIVERGENCES.md.
    """
    _io.path_list = [] if p is None else \
        [list(c) for c in _path_components(p)]
    return 0


def wfdb_addtopath(s):
    """Move the directory of file s to the front of the WFDB path (used in
    legacy mode only).

    The directory is placed first (after '.', if '.' is first), so that the
    other files of the same record are found there.  Nothing is done if
    it is already in that position.

    Translation of the C function wfdb_addtopath() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results. Differences: it is used only in legacy mode;
    see docs/DIVERGENCES.md.
    """
    if not s:
        return
    p = len(s) - 1
    while p >= 0 and s[p] not in "/\\:":
        p -= 1
    if p == 0 and s[0] in "/\\:":
        p += 1
    if p < 0:
        return
    if _io.wfdbpath is None:
        getwfdb()
    plist = _io.path_list
    if not plist:
        return
    found = None
    for idx, c in enumerate(plist):
        if _strncmp_eq(c[0], s, p):
            if idx == 0 or (idx == 1 and plist[0][0] == "."):
                return      # no changes needed
            found = plist.pop(idx)
            break
    if found is None:
        prefix = s[:p]
        found = [prefix, WFDB_NET if "://" in prefix else WFDB_LOCAL]
    if plist[0][0] == ".":
        plist.insert(1, found)
    else:
        plist.insert(0, found)


def _strncmp_eq(a, b, n):
    """strncmp(a, b, n) == 0 for C strings a and b."""
    for i in range(n):
        ca = a[i] if i < len(a) else "\0"
        cb = b[i] if i < len(b) else "\0"
        if ca != cb:
            return False
        if ca == "\0":
            return True
    return True


# ---------------------------------------------------------------------------
# Error handling

def wfdbquiet():
    """Suppress WFDB library error messages.

    Translation of the C function wfdbquiet() (lib/wfdbio.c, WFDB 10.7.0): same
    arguments and results.
    """
    _io.error_print = False


def wfdbverbose():
    """Enable WFDB library error messages.

    Translation of the C function wfdbverbose() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results.
    """
    _io.error_print = True


def wfdberror():
    """Return the most recent WFDB library error message.

    If no error has occurred, a string giving the library version is
    returned instead.

    Translation of the C function wfdberror() (lib/wfdbio.c, WFDB 10.7.0): same
    arguments and results.
    """
    if not _io.error_flag:
        _io.error_message = "WFDB library version %d.%d.%d (%s).\n" % (
            WFDB_MAJOR, WFDB_MINOR, WFDB_RELEASE, WFDB_BUILD_DATE)
    return _io.error_message


def wfdb_error(fmt, *args):
    """Record an error message (printf-style) and print it, unless wfdbquiet()
    is in effect.

    Translation of the C function wfdb_error() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results.
    """
    _io.error_flag = True
    _io.error_message = sprintf(fmt, *args) if args else sprintf(fmt)
    if _io.error_print:
        _stderr_write(_io.error_message)


def wfdbmemerr(behavior):
    """Set the behavior on memory errors (accepted for compatibility only).

    Translation of the C function wfdbmemerr() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results.
    """
    _io.mem_behavior = behavior


def wfdb_me_fatal():
    """Return the value set by wfdbmemerr() (1 by default).

    Translation of the C function wfdb_me_fatal() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results.
    """
    return _io.mem_behavior


def wfdbversion():
    """Return the version of the WFDB library reproduced by WFDB-x.

    Translation of the C function wfdbversion() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results.
    """
    return WFDB_VERSION


def wfdbldflags():
    """Return the linker flags of the C library (always empty in WFDB-x).

    Translation of the C function wfdbldflags() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results. Differences: the result is always empty; see
    docs/KNOWN_C_BEHAVIORS.md.
    """
    return ""


def wfdbcflags():
    """Return the compiler flags of the C library (always empty in WFDB-x).

    Translation of the C function wfdbcflags() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results. Differences: the result is always empty; see
    docs/KNOWN_C_BEHAVIORS.md.
    """
    return ""


def wfdbdefwfdb():
    """Return the default WFDB path (used when WFDB is not set).

    Translation of the C function wfdbdefwfdb() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results.
    """
    return DEFWFDB


def wfdbdefwfdbcal():
    """Return the default calibration file name (if WFDBCAL is not set).

    Translation of the C function wfdbdefwfdbcal() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results.
    """
    return DEFWFDBCAL


def wfdbfile(s, record):
    """Return the pathname (or URL) of a WFDB file, or None if it is not found.

    ``s`` is the file type (e.g. "hea", "dat", "atr") and ``record`` the
    record name; the file is looked up as by wfdb_open (WFDB-x: under the
    input directory, for a relative name; in legacy mode, in the WFDB path).
    If both are None, the name of the file most recently opened by the
    library is returned.

    Translation of the C function wfdbfile() (lib/wfdbio.c, WFDB 10.7.0): same
    arguments and results. Differences: the file is found as wfdb_open() finds
    it, not by a search of the WFDB path; see docs/DIVERGENCES.md.
    """
    if s is None and record is None:
        return _io.wfdb_filename
    if record is not None:
        record = wfdb_striphea(record)
    f = wfdb_open(s, record, WFDB_READ)
    if f is not None:
        f.close()
        return _io.wfdb_filename
    return None


def _set_filename(name):
    _io.wfdb_filename = name


def get_filename():
    """Return the name of the file most recently opened by wfdb_open.

    Part of WFDB-x; not in the original WFDB package.
    """
    return _io.wfdb_filename


# ---------------------------------------------------------------------------
# Opening files

def _is_url(name):
    """True if name is an http:// or https:// URL."""
    return name.startswith("http://") or name.startswith("https://")


def _is_dsep(c):
    """True if c is a directory separator ('/', and on MS-Windows '\\')."""
    return c == "/" or (os.name == "nt" and c == "\\")


def _init_input_dir():
    if not _io.input_dir_init:
        _io.input_dir_init = True
        v = os.environ.get("WFDBX_INPUT_DIR")
        if v:
            _io.env_input_dir = _io.input_dir = v
    if not _io.wfdb_warned and not _legacy():
        _io.wfdb_warned = True
        if os.environ.get("WFDB"):
            wfdb_error("WFDB-x: the WFDB environment variable is ignored; "
                       "set WFDBX_INPUT_DIR instead (or use legacy mode)\n")


def _put_input_dir(d):
    _init_input_dir()
    _io.input_dir = d if d else _io.env_input_dir


# WFDB-x: the input directory is not used in legacy mode, which searches the
# WFDB path.
def wfdbx_set_input_dir(d):
    """Set the input directory, and return the previous one.

    A file named by a plain or relative name, such as "100" or "mitdb/100",
    is read from the input directory. A full path, a ~ path or a URL is used
    as given. The setting applies to the high-level functions, the WFDB
    library functions and the tools.

    Arguments:
      d   a local directory, a ~ path, or the URL of a directory, such as
          "https://physionet.org/files/mitdb/1.0.0/". Reading from a URL also
          needs network access (see wfdbx_set_network). None or "" restores
          the default: the WFDBX_INPUT_DIR environment variable if it is set,
          otherwise the current directory.

    Returns:
      the previous input directory, or None if none was set

    Example (100s is the sample record included with WFDB-x: the first
    minute of record 100 of the MIT-BIH Arrhythmia Database, in the
    directory wfdbx.sample_data_dir())::

        wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())
        rec = wfdbx.read_record("100s")
        wfdbx.wfdbx_set_input_dir(None)      # back to the default

    Part of WFDB-x; not in the original WFDB package.
    """
    _init_input_dir()
    previous = _io.input_dir
    _put_input_dir(d)
    return previous


def wfdbx_get_input_dir():
    """Return the input directory, or None if none is set.

    See wfdbx_set_input_dir.

    Part of WFDB-x; not in the original WFDB package.
    """
    _init_input_dir()
    return _io.input_dir


_OUTPUT_URL_ERROR = ("wfdbx_set_output_dir: the output directory must be a "
                     "local directory\n")


def _init_output_dir():
    if not _io.output_dir_init:
        _io.output_dir_init = True
        v = os.environ.get("WFDBX_OUTPUT_DIR")
        if v:
            if _is_url(v):
                wfdb_error(_OUTPUT_URL_ERROR)
            else:
                _io.env_output_dir = _io.output_dir = v


def wfdbx_set_output_dir(d):
    """Set the output directory, and return the previous one.

    A file you write under a plain or relative name, such as "rec" or
    "out/rec", is created in the output directory. A full path or a ~ path is
    used as given. The setting applies to the high-level functions, the WFDB
    library functions and the tools.

    Arguments:
      d   a local directory or a ~ path. None or "" restores the default: the
          WFDBX_OUTPUT_DIR environment variable if it is set, otherwise the
          current directory. A URL is refused: an error is reported and the
          setting does not change.

    Returns:
      the previous output directory, or None if none was set. If d is a URL,
      the current output directory.

    Example (the example writes an annotation file, out/100s.qrs, for the
    sample record 100s included with WFDB-x: the first minute of record 100
    of the MIT-BIH Arrhythmia Database)::

        wfdbx.wfdbx_set_output_dir("out")
        wfdbx.write_annotations("100s", "qrs", [100, 460], symbols=["N", "N"])
        # writes out/100s.qrs

    Part of WFDB-x; not in the original WFDB package.
    """
    _init_output_dir()
    if d and _is_url(d):
        wfdb_error(_OUTPUT_URL_ERROR)
        return _io.output_dir
    previous = _io.output_dir
    _io.output_dir = d if d else _io.env_output_dir
    return previous


def wfdbx_get_output_dir():
    """Return the output directory, or None if none is set.

    See wfdbx_set_output_dir.

    Part of WFDB-x; not in the original WFDB package.
    """
    _init_output_dir()
    return _io.output_dir


# WFDB-x: remote files are read in full with urllib; redirects are followed,
# an HTTP status of 400 or more is a failure, and reading gives up if
# connecting takes 30 s or no data arrives for 30 s, with no limit on the
# total time. Each URL is requested at most once per process. Legacy mode
# reads no remote files.
def wfdbx_set_network(on):
    """Turn network access on or off, and return the previous setting.

    With network access on, files can be read from URLs, such as a PhysioNet
    database. It is off by default. Remote files are read once and kept for
    the rest of the session. A download gives up when it cannot connect, or
    receives nothing, for 30 seconds.

    Arguments:
      on  True (or 1) to turn network access on, False (or 0) to turn it off.
          None or a negative number restores the default: on if the
          WFDBX_NETWORK environment variable is a non-zero number, otherwise
          off.

    Returns:
      the previous setting: 1 (on) or 0 (off)

    Example (reads record 100 of the MIT-BIH Arrhythmia Database from
    PhysioNet)::

        wfdbx.wfdbx_set_network(1)
        wfdbx.wfdbx_set_input_dir("https://physionet.org/files/mitdb/1.0.0/")
        rec = wfdbx.read_record("100", sampto="0:10")

    Part of WFDB-x; not in the original WFDB package.
    """
    previous = wfdbx_get_network()
    if on is None or (not isinstance(on, bool) and on < 0):
        _io.network = _io.env_network
    else:
        _io.network = bool(on)
    return previous


def wfdbx_get_network():
    """Return 1 if network access is on, 0 otherwise.

    See wfdbx_set_network.

    Part of WFDB-x; not in the original WFDB package.
    """
    if _io.network is None:
        v = os.environ.get("WFDBX_NETWORK")
        _io.env_network = v is not None and strtol(v, 10)[0] != 0
        _io.network = _io.env_network
    return 1 if _io.network else 0


def _legacy():
    from ._signal import wfdbx_get_legacy   # (imported here: an import cycle)
    return wfdbx_get_legacy()


def _is_absolute_path(name):
    """True if name is an absolute local path: on POSIX systems, one that
    begins with '/'; on MS-Windows, one that begins with 'X:\\', 'X:/',
    '\\\\' or '/'."""
    if os.name == "nt":
        if len(name) > 2 and name[0].isascii() and name[0].isalpha() and \
                name[1] == ":" and name[2] in "\\/":
            return True
        if name.startswith("\\\\"):
            return True
    return name.startswith("/")


def _spr1(record, ftype):
    return record if ftype == "" else record + "." + ftype


def _spr2(record, ftype):
    # Alternate (8.3-style) name: the file type truncated to 3 characters.
    return record + "." if ftype == "" else record + "." + ftype[:3]


_stdin_file = None
_stdout_file = None


def _std_stream(read):
    global _stdin_file, _stdout_file
    if read:
        if _stdin_file is None:
            _stdin_file = WFDBFile(sys.stdin.buffer, WFDB_LOCAL, "-", True)
        return _stdin_file
    if _stdout_file is None:
        _stdout_file = WFDBFile(sys.stdout.buffer, WFDB_LOCAL, "-", True,
                                out=True)
    return _stdout_file


def _expand_home(name):
    """Return name with a leading "~" or "~/" replaced by the home directory
    ($HOME, or that of the current user if HOME is not set; on MS-Windows,
    %USERPROFILE%), and, on POSIX systems, "~user" by the home directory of
    that user (unchanged if there is no such user), as os.path.expanduser
    does on POSIX systems."""
    if not name.startswith("~"):
        return name
    i = 1
    while i < len(name) and not _is_dsep(name[i]):
        i += 1
    home = None
    if i == 1:
        if os.name == "nt":
            home = os.environ.get("USERPROFILE")
        else:
            home = os.environ.get("HOME")
            if home is None:
                try:
                    import pwd
                    home = pwd.getpwuid(os.getuid()).pw_dir
                except (ImportError, KeyError):
                    home = None
    elif os.name != "nt":
        try:
            import pwd
            home = pwd.getpwnam(name[1:i]).pw_dir
        except (ImportError, KeyError):
            home = None
    if home is None:
        return name
    while home and _is_dsep(home[-1]):
        home = home[:-1]
    return (home + name[i:]) or "/"


def _join(d, name, sep):
    """d + sep + name, with exactly one separator ('/' in a URL)."""
    if _is_url(d):
        sep = "/"
    if not d or d[-1] == sep or _is_dsep(d[-1]):
        return d + name
    return d + sep + name


def _resolve(name, output):
    """The location of the file named name (normal mode): an absolute name
    or a URL as given, a ~ name expanded, and a relative name under the
    input directory (for reading) or the output directory (for writing), if
    one is set."""
    if name.startswith("~"):
        return _expand_home(name)
    if _is_absolute_path(name) or _is_url(name):
        return name
    if output:
        _init_output_dir()
        d = _io.output_dir
    else:
        _init_input_dir()
        d = _io.input_dir
    if not d:
        return name
    return _join(_expand_home(d), name, DSEP if output else "/")


def _in_header_dir(name):
    """True if a file name found in a header names a file in the header's
    directory or below it: a relative name that does not begin with '~'
    and has no ".." component (on MS-Windows, no drive letter either)."""
    if _is_absolute_path(name) or _is_url(name) or name.startswith("~"):
        return False
    if os.name == "nt":
        if name[1:2] == ":":
            return False
        name = name.replace("\\", "/")
    return ".." not in name.split("/")


def _dirname(name):
    """The directory part of a file name or URL, including its final
    separator ("" if it has none)."""
    i = len(name)
    while i > 0 and not _is_dsep(name[i - 1]):
        i -= 1
    return name[:i]


def _open_at(p, s):
    """Open the file at location p for reading, trying both forms of its
    name (see _spr1 and _spr2) there."""
    s = s or ""
    _io.wfdb_filename = _spr1(p, s)
    f = wfdb_fopen(_io.wfdb_filename, "rb")
    if f is not None:
        return f
    long_filename = _io.wfdb_filename
    _io.wfdb_filename = _spr2(p, s)
    if _io.wfdb_filename != long_filename:
        return wfdb_fopen(_io.wfdb_filename, "rb")
    return None


def _open_in(d, s, name, record):
    """Open, for reading, a file named in the header of a record (a signal
    file, or a segment of type s): name, in the directory d of that header
    (as given by _dirname; None if unknown, for a header read from the
    standard input: then name is resolved as any relative name).  The name
    must be in that directory or below it; the signal file name "-" (the
    standard input) is also accepted."""
    if name == "-":
        return wfdb_open(s, name, WFDB_READ)
    if not _in_header_dir(name):
        wfdb_error("init: file %s named in the header of record %s is not "
                   "in the header's directory\n", name, record)
        return None
    if d is None:
        return wfdb_open(s, name, WFDB_READ)
    return _open_at(d + name, s)


def _expand_record(record):
    """The record name as wfdb_open uses it: a name ending with '/' gets
    another copy of its final element ('abc/123/' -> 'abc/123/123')."""
    rlen = len(record)
    r = record
    if rlen > 1 and record[-1] == "/":
        p = rlen - 1
        q = p - 1
        while q > 0:
            if record[q] == "/":
                q += 1
                break
            q -= 1
        if q < p:
            r = record + record[q:p]
    return r


def _output_file(name):
    """WFDB-x: the name of the local file that wfdb_open(name, None,
    WFDB_WRITE) creates in normal mode, or None if it creates none (the
    standard output, or a URL)."""
    if not name or name == "-":
        return None
    r = _expand_record(name)
    if _is_url(r):
        return None
    return _resolve(r, True)


def wfdb_open(s, record, mode):
    """Open a WFDB file of type s for a record.

    ``mode`` is WFDB_READ, WFDB_WRITE (create the file) or WFDB_APPEND.  The
    file name is the record name and the type, joined by a '.' (or either of
    them alone if the other is empty).  The record name "-" means the
    standard input or output.  WFDB-x: a relative name is read under the
    input directory (wfdbx_set_input_dir) and written under the output
    directory (wfdbx_set_output_dir); an absolute name, a ~ name or a URL is
    used as given (a URL can only be read, and only if network access is
    allowed: wfdbx_set_network).  Nothing is searched.  In legacy mode,
    an input file is searched for in the WFDB path (see getwfdb), and an
    output file is created as named (in the output directory, if one is
    set).  Returns a WFDBFile, or None on failure.

    Translation of the C function wfdb_open() (lib/wfdbio.c, WFDB 10.7.0): same
    arguments and results. Differences: a file is opened only where its name
    says (under the input or output directory, or as given), never searched
    for, and a URL is read only if network access is on; see
    docs/DIVERGENCES.md.
    """
    if s is None:
        s = ""
    if record is None or record == "":
        if s:
            record, s = s, ""
        else:
            return None
    if record == "-":
        return _std_stream(mode == WFDB_READ)
    r = _expand_record(record)
    if mode in (WFDB_WRITE, WFDB_APPEND):
        _io.wfdb_filename = _spr1(r, s)
        _init_output_dir()
        if not _legacy():
            # WFDB-x: a relative name in the output directory, if one is
            # set; a URL cannot be written
            if _is_url(_io.wfdb_filename):
                return None
            _io.wfdb_filename = _resolve(_io.wfdb_filename, True)
        elif _io.output_dir:    # WFDB-x: legacy mode: any name
            _io.wfdb_filename = _io.output_dir + DSEP + _io.wfdb_filename
        return wfdb_fopen(_io.wfdb_filename,
                          "wb" if mode == WFDB_WRITE else "ab")
    if not _legacy():
        # WFDB-x: the one location that the name designates
        return _open_at(_resolve(r, False), s)
    if not _io.path_list:
        getwfdb()
    if r.startswith("http://") or r.startswith("https://"):
        _io.wfdb_filename = _spr1(r, s)
        f = wfdb_fopen(_io.wfdb_filename, "rb")
        if f is not None:
            wfdb_addtopath(_io.wfdb_filename)
            return f
    irec = _io.irec
    for comp in list(_io.path_list):
        prefix, ctype = comp
        buf = []
        i = 0
        n = len(prefix)
        while i < n:
            c = prefix[i]
            if c == "%":
                i += 1
                c = prefix[i] if i < n else "\0"
                if c == "r":
                    buf.append(irec)
                    i += 1
                elif "1" <= c <= "9" and i + 1 < n and prefix[i + 1] == "r":
                    buf.append(irec[:ord(c) - 48])
                    i += 2
                else:
                    if c != "\0":
                        buf.append(c)
                    i += 1
            else:
                buf.append(c)
                i += 1
        b = "".join(buf)
        if b:
            if ctype == WFDB_NET:
                if b[-1] != "/":
                    b += "/"
            elif b[-1] != DSEP:
                b += DSEP
        b = b + r
        _io.wfdb_filename = _spr1(b, s)
        f = wfdb_fopen(_io.wfdb_filename, "rb")
        if f is not None:
            wfdb_addtopath(_io.wfdb_filename)
            return f
        long_filename = _io.wfdb_filename
        _io.wfdb_filename = _spr2(b, s)
        if _io.wfdb_filename != long_filename:
            f = wfdb_fopen(_io.wfdb_filename, "rb")
            if f is not None:
                wfdb_addtopath(_io.wfdb_filename)
                return f
    return None


def _fetch(url):
    """Read a remote file in full (WFDB-x: once per process; failures are
    remembered too).  Returns its contents (bytes), or None."""
    if url in _io.fetched:
        return _io.fetched[url]
    data = None
    try:
        import urllib.request
        req = urllib.request.Request(
            url, headers={"User-Agent": "wfdb-x/" + WFDB_VERSION})
        with urllib.request.urlopen(req, timeout=NET_TIMEOUT) as resp:
            if getattr(resp, "status", 200) < 400:
                data = resp.read()
    except Exception:
        data = None
    _io.fetched[url] = data
    return data


def _fetch_open(url):
    """Open a remote file for reading (normal mode), if network access is
    allowed; the first time it is not, print a message."""
    if not wfdbx_get_network():
        if not _io.network_warned:
            _io.network_warned = True
            wfdb_error("WFDB-x: network access is disabled; set "
                       "WFDBX_NETWORK=1 or call wfdbx_set_network(1) to "
                       "open %s\n", url)
        return None
    data = _fetch(url)
    if data is None:
        return None
    return WFDBFile(io.BytesIO(data), WFDB_NET, url)


def wfdb_fopen(fname, mode):
    """Open a file by name (local path or URL); return a WFDBFile or None.

    ``mode`` is a binary mode ("rb", "wb" or "ab").  An http:// or https://
    URL can only be read, if network access is allowed (see
    wfdbx_set_network).  When a file cannot be created, missing directories
    in its path are created and the attempt is repeated.  In legacy mode,
    names containing ".." or "://" are refused (as by the reference C
    library, built without network support).

    Translation of the C function wfdb_fopen() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results. Differences: a URL is read only if network
    access is on, and names containing ".." are accepted; see
    docs/DIVERGENCES.md.
    """
    if fname is None:
        return None
    if _legacy():
        if ".." in fname or "://" in fname:
            return None
    elif _is_url(fname):
        return _fetch_open(fname) if mode[0] == "r" else None
    try:
        if mode[0] == "r" and os.path.isdir(fname):
            return None
        fp = open(fname, mode)
        return WFDBFile(fp, WFDB_LOCAL, fname, out=mode[0] != "r")
    except OSError:
        pass
    if mode in ("wb", "ab"):
        stat = 1
        for i, c in enumerate(fname):
            if c == "/":
                try:
                    os.mkdir(fname[:i], 0o755)
                    stat = 0
                except OSError:
                    stat = 1
        if stat == 0:
            try:
                fp = open(fname, mode)
                return WFDBFile(fp, WFDB_LOCAL, fname, out=True)
            except OSError:
                pass
    return None


# WFDB-x: write errors.  Decided by Reza Sameni, Oct 2026: a program must not
# report success when its output was not written.
def wfdbx_write_errors():
    """Return the number of write errors since the program started.

    These are the output files that the library could not write, flush or
    close (found when they are closed, as by wfdbquit()), and the errors
    reported with wfdbx_note_write_error().  The high-level writers raise
    an error when they meet one, and the command-line tools then exit with
    status 1.

    Part of WFDB-x; not in the original WFDB package.
    """
    return _io.write_errors


def wfdbx_note_write_error():
    """Count a write error (see wfdbx_write_errors()): for an application
    that writes a file itself.

    Part of WFDB-x; not in the original WFDB package.
    """
    _io.write_errors += 1


def wfdbx_stdout_error():
    """Note that the standard output could not be written.  What is left of
    the output is lost; from now on it goes to the null device, so that the
    writes that follow, and the final flush, succeed (as they do, without
    effect, in C)."""
    if _io.stdout_failed:
        return
    _io.stdout_failed = True
    try:
        fd = os.open(os.devnull, os.O_WRONLY)
        try:
            os.dup2(fd, sys.stdout.fileno())
        finally:
            os.close(fd)
    except (OSError, ValueError, AttributeError):
        pass


def wfdbx_stdout_failed():
    """True if the standard output could not be written (see
    wfdbx_stdout_error)."""
    return _io.stdout_failed


def wfdb_checkname(p, s):
    """Check that a record or annotator name contains only legal characters.

    Legal characters are letters, digits, '_', '~', '-' and '/'.  Returns
    0 if the name is legal, or -1 (after reporting an error naming the
    kind of name, ``s``) otherwise.

    Translation of the C function wfdb_checkname() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results. Differences: only the last component of a
    record name is checked; see docs/DIVERGENCES.md.
    """
    if p is None:
        p = ""
    # WFDB-x: a record name may be a path; outside legacy mode only its last
    # component (the record's own name) is checked, so that directories with
    # other characters (such as "my.data/rec") can be written.
    if s == "record" and not _legacy():
        p = p[p.rfind(DSEP) + 1:]
    if p == "":
        wfdb_error("init: illegal character %d in %s name\n", 0, s)
        return -1
    for c in p:
        if ("0" <= c <= "9") or c in "_~-" or c == DSEP or \
                ("a" <= c <= "z") or ("A" <= c <= "Z"):
            continue
        o = ord(c)
        if o > 127:         # C reports the character as a (signed) char
            o -= 256
        wfdb_error("init: illegal character %d in %s name\n", o, s)
        return -1
    return 0


def wfdb_setirec(p):
    """Save the current record name (substituted for '%r' in the WFDB path).

    Translation of the C function wfdb_setirec() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results.
    """
    i = p.rfind(DSEP)
    if i >= 0:
        p = p[i + 1:]
    if p != "-":
        _io.irec = p[:WFDB_MAXRNL]


def wfdb_getirec():
    """Return the current record name (None if not set).

    Translation of the C function wfdb_getirec() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results.
    """
    return _io.irec if _io.irec else None


def wfdb_striphea(p):
    """Return p without a trailing '.hea' (if present).

    Translation of the C function wfdb_striphea() (lib/wfdbio.c, WFDB 10.7.0):
    same arguments and results.
    """
    if p is not None and len(p) > 4 and p.endswith(".hea"):
        return p[:-4]
    return p
