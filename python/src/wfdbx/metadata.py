"""Header metadata: "Key: value" info strings in the header of a record.

The info strings of a header are its comment lines (lines that begin with
'#') after the record line, as the C function getinfo() reads them. Many
datasets store facts about the recording in them as "Key: value" pairs, for
example::

    # Age: 63
    # Sex: F
    # Dx: 164889003

The functions of this module read and change such entries:

* ``read_metadata(record)``: all the entries, in file order, as a list of
  (key, value) pairs.
* ``get_metadata(record, key)``: the value of one entry, or None.
* ``set_metadata(record, key, value)``: change the value of an entry, or
  add the entry.
* ``remove_metadata(record, key)``: remove an entry; returns the number of
  lines removed.
* ``update_metadata(record, changes)``: several changes in one write (a
  value of None removes the entry).

``read_header`` also returns the entries (``Header.metadata``), and
``write_record`` writes them (its ``metadata`` argument).

Rules:

* **Reading.** An info string is an entry if it contains a colon (':'). The
  key is the text between the '#' and the first colon, and the value is the
  rest of the line; spaces, tabs, VT, FF and CR at either end of each are
  removed. So
  "#Age:45", "# Age: 45" and "#  Age : 45" all give ("Age", "45"). An info
  string without a colon, or whose key is empty or contains '#', is a free
  comment: it is not returned, and it is never changed. Comment lines
  before the record line are not info strings, and are never read or
  changed. Only the header file (.hea) is read, not the .info file that
  getinfo() also reads.
* **Keys.** Keys are compared without regard to letter case (A-Z and a-z),
  so get_metadata(record, "age") finds "Age". A header should not hold two
  entries whose keys differ only in letter case. If one does (a file
  written by other software), reading returns the first of them, with a
  warning; set_metadata and update_metadata refuse to change that key
  (ValueError), and remove_metadata removes all of them. A key must not be
  empty, and must not contain ':', '#', a line break or a NUL character;
  it may contain spaces, as in "Date of birth".
* **Values** are text, which may be a whole sentence. Spaces at either end
  are removed; a value must not contain a line break or a NUL character.
  The empty string is allowed. Text is one byte per character (Latin-1),
  as in the rest of wfdbx; bytes objects are also accepted, as given.
* **Writing.** Entries are written as "# Key: value" (one space after '#'
  and one after the colon; "# Key:" if the value is empty), with the
  caller's spelling of the key. A changed entry replaces its line, at the
  same position; a new entry is added after the last info string (or, if
  the header has none, after its last line that is not blank). Every other
  byte of the header is kept: the record and signal lines, the free
  comments and the line endings (a new line ends as the record line does:
  "\\r\\n" in the headers written by WFDB). The new header is written to a
  temporary file, which then replaces the header, so that an error never
  leaves a partly written header. All the arguments are checked before
  anything is written.
* **Which file.** The header is found as the library finds a header
  (wfdb_open): under the input directory, or as given if the name is an
  absolute path, a ~ path or a URL. A header read from a URL can be read
  but not changed. A change is written to the header itself, or, with
  ``dir``, to a header of the same name in the directory ``dir``, leaving
  the original unchanged (the signal files are not copied). Only the named
  header is read or changed: for a multi-segment record, that is the
  master header, unless the name of a segment is given.

Metadata often holds information about patients. WFDB-x stores it as plain
text, exactly as given, and does not de-identify it.

This file is part of WFDB-x, an independent reimplementation of the WFDB
Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
has no counterpart in the original package.

Copyright (C) 2026 Reza Sameni.

This library is free software: you can redistribute it and/or modify it under
the terms of the GNU Lesser General Public License as published by the Free
Software Foundation, either version 2.1 of the License, or (at your option)
any later version. See LICENSE.
"""

import os
import sys
import tempfile
import warnings

from . import _wfdbio as wio
from ._wfdbio import WFDB_READ

__all__ = ["read_metadata", "get_metadata", "set_metadata",
           "remove_metadata", "update_metadata"]

_ENC = "latin-1"            # text encoding: one character per byte
_TRIM = b" \t\v\f\r"        # removed from both ends of keys and values
_FORBIDDEN_KEY = (b":", b"#", b"\r", b"\n", b"\0")
_FORBIDDEN_VALUE = (b"\r", b"\n", b"\0")
_DEFAULT_EOL = b"\r\n"      # line ending of the headers written by WFDB


# ---------------------------------------------------------------------------
# Parsing


class _Line:
    """One line of a header: its content (without the line ending) and its
    line ending (b"\\r\\n", b"\\n", or b"" for a last line without one)."""

    __slots__ = ("content", "eol")

    def __init__(self, content, eol):
        self.content = content
        self.eol = eol


def _split_lines(data):
    """The lines of data (bytes), split after each LF."""
    lines = []
    start = 0
    n = len(data)
    while start < n:
        i = data.find(b"\n", start)
        if i < 0:
            lines.append(_Line(data[start:], b""))
            break
        if i > start and data[i - 1:i] == b"\r":
            lines.append(_Line(data[start:i - 1], b"\r\n"))
        else:
            lines.append(_Line(data[start:i], b"\n"))
        start = i + 1
    return lines


def _fold(key):
    """key (bytes) with the letters A-Z changed to a-z."""
    return key.lower()      # (bytes.lower changes only A-Z)


def _record_line(lines):
    """The index of the record line: the first line that does not begin
    with '#' (as getinfo() reads a header), or None if there is none."""
    for i, ln in enumerate(lines):
        if not ln.content.startswith(b"#"):
            return i
    return None


def _entry(content):
    """(key, value) of an info string (bytes, beginning with '#'), or None
    if it is a free comment."""
    text = content[1:]
    i = text.find(b":")
    if i < 0:
        return None
    key = text[:i].strip(_TRIM)
    if not key or b"#" in key:
        return None
    return key, text[i + 1:].strip(_TRIM)


class _Header:
    """A parsed header: its lines, the index of the record line, the
    indices of the info strings, and the entries as (line index, key,
    value) in file order."""

    def __init__(self, data):
        self.lines = _split_lines(data)
        self.rec = _record_line(self.lines)
        self.info = []
        self.entries = []
        if self.rec is None:
            return
        for i in range(self.rec + 1, len(self.lines)):
            c = self.lines[i].content
            if c.startswith(b"#"):
                self.info.append(i)
                e = _entry(c)
                if e is not None:
                    self.entries.append((i, e[0], e[1]))

    def matches(self, key):
        """The line indices of the entries whose key is key, ignoring
        letter case."""
        f = _fold(key)
        return [i for i, k, _ in self.entries if _fold(k) == f]

    def eol(self):
        """The line ending of new lines: that of the record line, or of the
        first line that has one, or "\\r\\n"."""
        if self.rec is not None and self.lines[self.rec].eol:
            return self.lines[self.rec].eol
        for ln in self.lines:
            if ln.eol:
                return ln.eol
        return _DEFAULT_EOL

    def insertion_point(self):
        """The index at which new entries are inserted: after the last info
        string, or after the last line that is not blank."""
        if self.info:
            return self.info[-1] + 1
        for i in range(len(self.lines) - 1, -1, -1):
            if self.lines[i].content.strip(_TRIM):
                return i + 1
        return len(self.lines)

    def to_bytes(self):
        return b"".join(ln.content + ln.eol for ln in self.lines)


def _text(b):
    return b.decode(_ENC)


def _unique_entries(hdr, record):
    """The entries of hdr as (key, value) bytes pairs, with one entry per
    key (the first); a warning for each key that has more than one."""
    seen = {}
    out = []
    for i, k, v in hdr.entries:
        f = _fold(k)
        if f in seen:
            seen[f][1].append(i)
            continue
        seen[f] = (k, [i])
        out.append((k, v))
    for k, idx in seen.values():
        if len(idx) > 1:
            warnings.warn("header of record %s has more than one entry for "
                          "key %s (lines %s); the first is used" %
                          (record, _text(k),
                           ", ".join(str(i + 1) for i in idx)),
                          UserWarning, stacklevel=_warn_level())
    return out


def _warn_level():
    """The stacklevel for warnings.warn so that a warning points at the
    caller of wfdbx (past the functions of wfdbx)."""
    f = sys._getframe(1)
    level = 1
    while f is not None and \
            f.f_globals.get("__name__", "").startswith("wfdbx"):
        f = f.f_back
        level += 1
    return level


# ---------------------------------------------------------------------------
# Arguments


def _as_bytes(s, what):
    if isinstance(s, (bytes, bytearray)):
        return bytes(s)
    if not isinstance(s, str):
        raise TypeError("%s must be a string" % what)
    try:
        return s.encode(_ENC)
    except UnicodeEncodeError:
        raise ValueError("%s %r has a character that is not Latin-1 (one "
                         "byte per character); give it as bytes" % (what, s))


def _check_key(key):
    """key as bytes, without spaces at either end, checked."""
    k = _as_bytes(key, "metadata key").strip(_TRIM)
    if not k:
        raise ValueError("metadata key must not be empty")
    for c in _FORBIDDEN_KEY:
        if c in k:
            raise ValueError("metadata key %r must not contain %s" %
                             (key, _NAMES[c]))
    return k


def _check_value(key, value):
    """value as bytes, without spaces at either end, checked."""
    v = _as_bytes(value, "metadata value").strip(_TRIM)
    for c in _FORBIDDEN_VALUE:
        if c in v:
            raise ValueError("value of metadata key %r must not contain %s" %
                             (key, _NAMES[c]))
    return v


_NAMES = {b":": "':'", b"#": "'#'", b"\r": "a line break",
          b"\n": "a line break", b"\0": "a NUL character"}


def _line(key, value):
    """The info string of an entry, as written: "# Key: value"."""
    return b"# " + key + b":" + (b" " + value if value else b"")


def _check_changes(changes):
    """changes (a mapping, or a sequence of (key, value) pairs) as a list
    of (key bytes, value bytes or None), checked: valid keys and values,
    and no two keys that differ only in letter case."""
    items = changes.items() if hasattr(changes, "items") else changes
    out = []
    seen = set()
    for item in items:
        try:
            key, value = item
        except (TypeError, ValueError):
            raise TypeError("metadata must be a mapping, or a sequence of "
                            "(key, value) pairs")
        k = _check_key(key)
        f = _fold(k)
        if f in seen:
            raise ValueError("metadata key %r is given more than once "
                             "(keys are compared without regard to letter "
                             "case)" % (key,))
        seen.add(f)
        out.append((k, None if value is None else _check_value(key, value)))
    return out


def info_lines(metadata, comments=()):
    """The info strings (as putinfo() takes them: without the '#') of the
    entries of metadata, for write_record: " Key: value". Raises
    ValueError if an entry is invalid, if two keys differ only in letter
    case, or if one of comments (the other info strings) is already an
    entry for one of these keys. A value of None is not allowed."""
    entries = _check_changes(metadata)
    folded = {_fold(k) for k, _ in entries}
    for k, v in entries:
        if v is None:
            raise ValueError("value of metadata key %r must not be None" %
                             _text(k))
    for c in comments:
        e = _entry(b"#" + _as_bytes(c, "comment"))
        if e is not None and _fold(e[0]) in folded:
            raise ValueError("metadata key %r is also given in comments" %
                             _text(e[0]))
    return [_text(_line(k, v)[1:]) for k, v in entries]


# ---------------------------------------------------------------------------
# Files


def _record_name(record):
    if not isinstance(record, str) or not record:
        raise ValueError("record name must not be empty")
    if record == "-":
        raise ValueError("the metadata of a header read from the standard "
                         "input cannot be read or changed")
    return wio.wfdb_striphea(record)


def _read(record):
    """(bytes of the header, name of the file it was read from, True if
    that is a URL). Raises IOError if the header cannot be read."""
    name = _record_name(record)
    f = wio.wfdb_open("hea", name, WFDB_READ)
    if f is None:
        raise IOError("can't read header for record %s" % record)
    try:
        data = f.fp.read()
        path = f.name
    except (OSError, ValueError):
        raise IOError("can't read header for record %s" % record)
    finally:
        f.close()
    return data, path, wio._is_url(path)


def _destination(record, path, is_url, dir):
    """The file to which a changed header is written."""
    if dir is None:
        if is_url:
            raise ValueError("header of record %s was read from a URL, "
                             "and cannot be changed (give dir to write the "
                             "changed header to a local directory)" % record)
        return path
    d = wio._expand_home(os.fspath(dir))
    if not os.path.isdir(d):
        raise FileNotFoundError("directory %s does not exist" % dir)
    base = path.replace("\\", "/").rsplit("/", 1)[-1]
    return os.path.join(d, base)


def _write(dest, data, record):
    """Write data to dest through a temporary file in the same directory,
    which then replaces dest (keeping its permissions)."""
    d = os.path.dirname(dest) or "."
    try:
        fd, tmp = tempfile.mkstemp(prefix="." + os.path.basename(dest) + ".",
                                   suffix=".tmp", dir=d)
    except OSError:
        raise IOError("can't write header for record %s" % record)
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        try:
            os.chmod(tmp, os.stat(dest).st_mode & 0o7777)
        except OSError:
            os.chmod(tmp, 0o666 & ~_umask())
        os.replace(tmp, dest)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise IOError("can't write header for record %s" % record)


def _umask():
    m = os.umask(0)
    os.umask(m)
    return m


def _with_input(func, input_dir, network):
    """Call func() with the input directory and network permission set for
    the call only (if not None)."""
    previous_dir = wio.wfdbx_set_input_dir(input_dir) \
        if input_dir is not None else None
    previous_net = wio.wfdbx_set_network(network) \
        if network is not None else None
    try:
        return func()
    finally:
        if network is not None:
            wio.wfdbx_set_network(previous_net)
        if input_dir is not None:
            wio.wfdbx_set_input_dir(previous_dir)


def _change(record, changes, input_dir, network, dir):
    """Apply changes (a checked list of (key, value or None)) to the header
    of record; returns the number of lines removed."""
    data, path, is_url = _with_input(lambda: _read(record), input_dir,
                                     network)
    dest = _destination(record, path, is_url, dir)
    hdr = _Header(data)
    if hdr.rec is None:
        raise ValueError("header of record %s has no record line" % record)
    # (every change is checked before the header is changed)
    for k, v in changes:
        idx = hdr.matches(k)
        if v is not None and len(idx) > 1:
            raise ValueError("header of record %s has more than one entry "
                             "for key %s (lines %s); remove them first" %
                             (record, _text(k),
                              ", ".join(str(i + 1) for i in idx)))
    removed = 0
    for k, v in changes:
        idx = hdr.matches(k)
        if v is None:
            for i in sorted(idx, reverse=True):
                _delete(hdr, i)
            removed += len(idx)
        elif idx:
            ln = hdr.lines[idx[0]]
            hdr.lines[idx[0]] = _Line(_line(k, v), ln.eol)
            hdr = _Header(hdr.to_bytes())
        else:
            _insert(hdr, _line(k, v))
            hdr = _Header(hdr.to_bytes())
    out = hdr.to_bytes()
    if out != data or dir is not None:
        _write(dest, out, record)
    return removed


def _delete(hdr, i):
    """Remove line i of hdr (and parse the header again)."""
    del hdr.lines[i]
    new = _Header(hdr.to_bytes())
    hdr.lines, hdr.rec, hdr.info, hdr.entries = (new.lines, new.rec,
                                                 new.info, new.entries)


def _insert(hdr, content):
    """Insert a line of the given content at the insertion point of hdr."""
    eol = hdr.eol()
    at = hdr.insertion_point()
    if at > 0 and not hdr.lines[at - 1].eol:
        hdr.lines[at - 1].eol = eol
    hdr.lines.insert(at, _Line(content, eol))


def header_metadata(record):
    """The entries of the header of record, as read_metadata() returns
    them, with the library's current input settings (for read_header)."""
    data, _, _ = _read(record)
    return [(_text(k), _text(v))
            for k, v in _unique_entries(_Header(data), record)]


# ---------------------------------------------------------------------------
# The public functions


def read_metadata(record, *, input_dir=None, network=None):
    """Read the metadata of a record: the "Key: value" entries of its header.

    Arguments:
      record     record name, without the .hea extension (a trailing ".hea" is
                 also accepted): a full path, absolute ("/data/mitdb/100") or
                 in the home directory ("~/Documents/100s"), used as given; a
                 relative path ("100s", "data/100s"), read from the input
                 directory if one is set, otherwise from the current directory;
                 or a URL ("https://physionet.org/files/mitdb/1.0.0/100"), read
                 only if network access is on
      input_dir  input directory for this call only (optional): a local
                 directory, a ~ path or a URL, under which relative record
                 names are read. It does not apply to full paths or URLs.
                 Default: the current setting (see wfdbx_set_input_dir).
      network    True to allow reading URLs for this call only, False to
                 forbid it. Default: the current setting.

    Returns:
      a list of (key, value) pairs of strings, in file order. A key that
      appears more than once (ignoring letter case) is returned once, with
      its first value, and a UserWarning is issued.

    Raises:
      IOError    if the header cannot be found or read
      ValueError if record is empty or "-"

    Example::

        wfdbx.read_metadata("rec")     # [("Age", "63"), ("Sex", "F")]

    Part of WFDB-x; not in the original WFDB package. See the module help
    (help(wfdbx.metadata)) for the rules.
    """
    return _with_input(lambda: header_metadata(record), input_dir, network)


def get_metadata(record, key, *, input_dir=None, network=None):
    """Return the value of one metadata entry of a record, or None.

    Arguments:
      record     record name (see read_metadata)
      key        the key, such as "Age". Letter case is ignored, and spaces
                 at either end are removed.
      input_dir, network
                 as for read_metadata

    Returns:
      the value (a string; "" for an entry with an empty value), or None if
      the header has no entry for key. If it has more than one, the first is
      returned, and a UserWarning is issued.

    Raises:
      IOError    if the header cannot be found or read
      TypeError  if key is not a string (str or bytes)
      ValueError if record is empty or "-", or if key is not a valid key
                 (see set_metadata)

    Example::

        age = wfdbx.get_metadata("rec", "age")     # "63"

    Part of WFDB-x; not in the original WFDB package.
    """
    f = _fold(_check_key(key))
    for k, v in read_metadata(record, input_dir=input_dir, network=network):
        if _fold(_as_bytes(k, "key")) == f:
            return v
    return None


def set_metadata(record, key, value, *, input_dir=None, network=None,
                 dir=None):
    """Set the value of a metadata entry in the header of a record.

    If the header has an entry for key (ignoring letter case), its line is
    replaced by "# Key: value", at the same position, with the spelling of
    key given here. Otherwise the entry is added after the last info string
    of the header. Every other line is kept, byte for byte.

    Arguments:
      record     record name (see read_metadata). The header is changed where
                 it was read, unless dir is given; a header read from a URL can
                 only be written elsewhere, with dir.
      key        the key, such as "Age" or "Date of birth". Spaces at either
                 end are removed. It must not be empty, and must not contain
                 ':', '#', a line break or a NUL character.
      value      the value: a string, which may be a sentence. Spaces at
                 either end are removed. It must not contain a line break or
                 a NUL character; it may be empty.
      input_dir, network
                 input directory and network permission for reading the
                 header, for this call only (see read_metadata)
      dir        directory (which must exist) in which to write the changed
                 header, under the same file name, instead of changing the
                 header itself. The signal files are not copied.

    Returns:
      None

    Raises:
      IOError            if the header cannot be read, or the changed header
                         cannot be written
      TypeError          if key or value is not a string (str or bytes)
      ValueError         if key or value is not valid, if the header has more
                         than one entry for key, if it has no record line, if
                         it was read from a URL and dir is not given, or if
                         record is empty or "-"
      FileNotFoundError  if dir does not exist

    The arguments are checked before anything is written, and the header is
    replaced in one step (through a temporary file), so that an error leaves
    it unchanged.

    Example::

        wfdbx.set_metadata("rec", "Age", "63")     # writes "# Age: 63"

    Part of WFDB-x; not in the original WFDB package.
    """
    k = _check_key(key)
    _change(record, [(k, _check_value(key, value))], input_dir, network, dir)


def remove_metadata(record, key, *, input_dir=None, network=None, dir=None):
    """Remove a metadata entry from the header of a record.

    Every entry for key (ignoring letter case) is removed, so this also
    repairs a header that has more than one. Other lines are kept, byte for
    byte. Nothing is written if the header has no entry for key (unless dir
    is given).

    Arguments:
      record, input_dir, network, dir
                 as for set_metadata
      key        the key (see set_metadata)

    Returns:
      the number of lines removed (0 if the header has no entry for key)

    Raises:
      as set_metadata

    Example::

        wfdbx.remove_metadata("rec", "Age")     # 1

    Part of WFDB-x; not in the original WFDB package.
    """
    return _change(record, [(_check_key(key), None)], input_dir, network,
                   dir)


def update_metadata(record, changes, *, input_dir=None, network=None,
                    dir=None):
    """Make several changes to the metadata of a record in one write.

    Arguments:
      record, input_dir, network, dir
                 as for set_metadata
      changes    a mapping from key to value, or a sequence of (key, value)
                 pairs. Each is applied in order, as set_metadata(key,
                 value) does, or, if value is None, as remove_metadata(key)
                 does. No two keys may differ only in letter case.

    Returns:
      None

    Raises:
      as set_metadata; TypeError also if changes is neither a mapping nor
      a sequence of (key, value) pairs. All the changes are checked first:
      if one is not valid, none is made.

    Example::

        wfdbx.update_metadata("rec", {"Age": "64", "Dx": None})

    Part of WFDB-x; not in the original WFDB package.
    """
    _change(record, _check_changes(changes), input_dir, network, dir)
