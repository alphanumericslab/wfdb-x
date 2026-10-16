"""Low-level I/O for the WFDB library (port of lib/wfdbio.c).

This module implements the WFDB path, file lookup (``wfdb_open``), error
reporting (``wfdb_error``/``wfdberror``), and the small binary helpers used
by the signal and annotation modules.

Copyright (C) 1988-2013 George B. Moody (original C implementation,
lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
This library is free software; you can redistribute it and/or modify it under
the terms of the GNU Library General Public License as published by the Free
Software Foundation; either version 2 of the License, or (at your option) any
later version.
"""

import io
import os
import sys

from ._cstd import sprintf

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
    "wfdb_parse_path",
]

WFDB_MAJOR = 10
WFDB_MINOR = 7
WFDB_RELEASE = 0
WFDB_VERSION = "10.7.0"
# The C library reports the date on which it was compiled; wfdb-x reports
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

DEFWFDB = ". /usr/local/database http://physionet.org/physiobank/database"
DEFWFDBCAL = "wfdbcal"
WFDB_MAXRNL = 50        # maximum length of a record name
MAXNEST = 10            # maximum nesting of indirect (@FILE) WFDB paths
NET_TIMEOUT = 60        # timeout (seconds) for reading a remote file

DSEP = "/"              # directory separator
_ENC = "latin-1"        # text encoding: one character per byte


class WFDBFile:
    """A WFDB_FILE: a local file or an in-memory copy of a remote file."""

    __slots__ = ("fp", "type", "name", "is_std", "_err", "_eof")

    def __init__(self, fp, ftype=WFDB_LOCAL, name=None, is_std=False):
        self.fp = fp
        self.type = ftype
        self.name = name
        self.is_std = is_std
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
        if self.is_std:
            try:
                self.fp.flush()
            except (OSError, ValueError):
                pass
            return 0
        try:
            self.fp.close()
        except OSError:
            return -1
        return 0

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
    """Restore the WFDB path to the value first returned by getwfdb()."""
    if _io.wfdbpath_init is not None:
        _io.wfdbpath = _io.wfdbpath_init


def getwfdb():
    """Return the WFDB path: the list of places searched for WFDB files.

    The path is taken from the WFDB environment variable, or is DEFWFDB if
    WFDB is not set.  Its components (directories or URL prefixes) are
    separated by spaces or semicolons (or colons, other than in URLs).  A
    value "@file" means that the path is read from that file.
    """
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
    """Change the WFDB path (see getwfdb()).

    ``p`` replaces the current path; None restores the value of the WFDB
    environment variable (or DEFWFDB).  As in C, the WFDB environment
    variable is also set to ``p``, so that programs started afterwards
    inherit it.
    """
    if p is None:
        p = os.environ.get("WFDB")
        if p is None:
            p = DEFWFDB
    _export_config(p)
    p = _getiwfdb(p)
    _io.wfdbpath = p
    wfdb_parse_path(p)


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


def wfdb_parse_path(p):
    """Split a WFDB path string into the components searched by wfdb_open()."""
    _io.path_list = []
    if p is None:
        return 0
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
        _io.path_list.append([p[start:q], current_type])
        if q < n:
            q += 1
    return 0


def wfdb_addtopath(s):
    """Move the directory of file s to the front of the WFDB path.

    The directory is placed first (after '.', if '.' is first), so that the
    other files of the same record are found there.  Nothing is done if
    it is already in that position.
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
    """Suppress WFDB library error messages."""
    _io.error_print = False


def wfdbverbose():
    """Enable WFDB library error messages."""
    _io.error_print = True


def wfdberror():
    """Return the most recent WFDB library error message.

    If no error has occurred, a string giving the library version is
    returned instead.
    """
    if not _io.error_flag:
        _io.error_message = "WFDB library version %d.%d.%d (%s).\n" % (
            WFDB_MAJOR, WFDB_MINOR, WFDB_RELEASE, WFDB_BUILD_DATE)
    return _io.error_message


def wfdb_error(fmt, *args):
    """Record an error message (printf-style) and print it, unless wfdbquiet()
    is in effect."""
    _io.error_flag = True
    _io.error_message = sprintf(fmt, *args) if args else sprintf(fmt)
    if _io.error_print:
        _stderr_write(_io.error_message)


def wfdbmemerr(behavior):
    """Set the behavior on memory errors (accepted for compatibility only)."""
    _io.mem_behavior = behavior


def wfdb_me_fatal():
    """Return the value set by wfdbmemerr() (1 by default)."""
    return _io.mem_behavior


def wfdbversion():
    """Return the version of the WFDB library reproduced by wfdb-x."""
    return WFDB_VERSION


def wfdbldflags():
    """Return the linker flags of the C library (always empty in wfdb-x)."""
    return ""


def wfdbcflags():
    """Return the compiler flags of the C library (always empty in wfdb-x)."""
    return ""


def wfdbdefwfdb():
    """Return the default WFDB path (used when WFDB is not set)."""
    return DEFWFDB


def wfdbdefwfdbcal():
    """Return the default calibration file name (if WFDBCAL is not set)."""
    return DEFWFDBCAL


def wfdbfile(s, record):
    """Return the pathname (or URL) of a WFDB file, or None if it is not found.

    ``s`` is the file type (e.g. "hea", "dat", "atr") and ``record`` the
    record name; the file is searched for in the WFDB path.  If both are
    None, the name of the file most recently opened by the library is
    returned.
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
    """Return the name of the file most recently opened by wfdb_open."""
    return _io.wfdb_filename


# ---------------------------------------------------------------------------
# Opening files

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
        _stdout_file = WFDBFile(sys.stdout.buffer, WFDB_LOCAL, "-", True)
    return _stdout_file


def wfdb_open(s, record, mode):
    """Find and open a WFDB file of type s for a record.

    ``mode`` is WFDB_READ (search the WFDB path), WFDB_WRITE (create the
    file in the current directory, or under the directory part of
    ``record``) or WFDB_APPEND.  The record name "-" means the standard
    input or output.  Returns a WFDBFile, or None on failure.
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
    if mode == WFDB_WRITE:
        _io.wfdb_filename = _spr1(r, s)
        return wfdb_fopen(_io.wfdb_filename, "wb")
    elif mode == WFDB_APPEND:
        _io.wfdb_filename = _spr1(r, s)
        return wfdb_fopen(_io.wfdb_filename, "ab")
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


_net_cache = {}


def _net_open(url):
    """Read a remote file in its entirety (read-only access)."""
    if url in _net_cache:
        data = _net_cache[url]
    else:
        try:
            import urllib.request
            req = urllib.request.Request(
                url, headers={"User-Agent": "wfdb-x/" + WFDB_VERSION})
            with urllib.request.urlopen(req, timeout=NET_TIMEOUT) as resp:
                if getattr(resp, "status", 200) >= 400:
                    data = None
                else:
                    data = resp.read()
        except Exception:
            data = None
        _net_cache[url] = data
    if data is None:
        return None
    return io.BytesIO(data)


def wfdb_fopen(fname, mode):
    """Open a file by name (local path or URL); return a WFDBFile or None.

    ``mode`` is a binary mode ("rb", "wb" or "ab"); remote files can only
    be read.  Names containing ".." are refused.  When a file cannot be
    created, missing directories in its path are created and the attempt is
    repeated.
    """
    if fname is None or ".." in fname:
        return None
    if "://" in fname:
        if "r" not in mode:
            return None
        fp = _net_open(fname)
        if fp is None:
            return None
        return WFDBFile(fp, WFDB_NET, fname)
    try:
        if mode[0] == "r" and os.path.isdir(fname):
            return None
        fp = open(fname, mode)
        return WFDBFile(fp, WFDB_LOCAL, fname)
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
                return WFDBFile(fp, WFDB_LOCAL, fname)
            except OSError:
                pass
    return None


def wfdb_checkname(p, s):
    """Check that a record or annotator name contains only legal characters.

    Legal characters are letters, digits, '_', '~', '-' and '/'.  Returns
    0 if the name is legal, or -1 (after reporting an error naming the
    kind of name, ``s``) otherwise.
    """
    if p is None:
        p = ""
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
    """Save the current record name (substituted for '%r' in the WFDB path)."""
    i = p.rfind(DSEP)
    if i >= 0:
        p = p[i + 1:]
    if p != "-":
        _io.irec = p[:WFDB_MAXRNL]


def wfdb_getirec():
    """Return the current record name (None if not set)."""
    return _io.irec if _io.irec else None


def wfdb_striphea(p):
    """Return p without a trailing '.hea' (if present)."""
    if p is not None and len(p) > 4 and p.endswith(".hea"):
        return p[:-4]
    return p
