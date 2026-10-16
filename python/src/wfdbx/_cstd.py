"""C standard-library emulation helpers.

The WFDB library relies on the exact semantics of a handful of C library
functions (``strtol``, ``strtod``, ``strtok``, ``sscanf``, integer division,
fixed-width integer casts, ``printf``).  Reproducing them precisely is what
allows wfdb-x to read and write byte-identical files and text.

All text is handled as Python ``str`` decoded with ISO-8859-1 (latin-1), so
that every byte maps to exactly one character and round-trips unchanged.

Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
This library is free software; you can redistribute it and/or modify it under
the terms of the GNU Library General Public License as published by the Free
Software Foundation; either version 2 of the License, or (at your option) any
later version.
"""

import math
import re

__all__ = [
    "LONG_MAX", "LONG_MIN", "INT_MAX", "INT_MIN", "UINT_MAX",
    "strtol", "strtod", "atoi", "atof", "Strtok", "cdiv", "cmod",
    "int32", "uint32", "int16", "uint16", "int8", "uint8",
    "d2i", "d2l", "sprintf", "sscanf", "isspace", "fgets_lines",
    "GlibcRand", "cfmt_float",
]

# Limits of the C types on the reference platform (x86-64 Linux, LP64).
LONG_MAX = 0x7FFFFFFFFFFFFFFF
LONG_MIN = -0x8000000000000000
INT_MAX = 0x7FFFFFFF
INT_MIN = -0x80000000
UINT_MAX = 0xFFFFFFFF

_WS = " \t\n\v\f\r"     # the characters for which isspace() is true


def isspace(c):
    """C isspace() for a single character (C locale)."""
    return c != "" and c in _WS


def strtol(s, base=10, pos=0, lmin=LONG_MIN, lmax=LONG_MAX):
    """Emulate C strtol(s + pos, &end, base).

    Returns ``(value, end)`` where ``end`` is the index just past the parsed
    number, or ``pos`` if no conversion was performed.  Values are clamped to
    [lmin, lmax] as strtol does on overflow.
    """
    n = len(s)
    i = pos
    while i < n and s[i] in _WS:
        i += 1
    neg = False
    if i < n and s[i] in "+-":
        neg = s[i] == "-"
        i += 1
    if base == 0:
        if i + 1 < n and s[i] == "0" and s[i + 1] in "xX" and \
                i + 2 < n and s[i + 2] in "0123456789abcdefABCDEF":
            base = 16
            i += 2
        elif i < n and s[i] == "0":
            base = 8
        else:
            base = 10
    elif base == 16:
        if i + 1 < n and s[i] == "0" and s[i + 1] in "xX" and \
                i + 2 < n and s[i + 2] in "0123456789abcdefABCDEF":
            i += 2
    start = i
    v = 0
    while i < n:
        c = s[i]
        if "0" <= c <= "9":
            d = ord(c) - 48
        elif "a" <= c <= "z":
            d = ord(c) - 87
        elif "A" <= c <= "Z":
            d = ord(c) - 55
        else:
            break
        if d >= base:
            break
        v = v * base + d
        i += 1
    if i == start:
        return 0, pos
    if neg:
        v = -v
    if v > lmax:
        v = lmax
    elif v < lmin:
        v = lmin
    return v, i


def atoi(s):
    """C atoi(): strtol truncated to a 32-bit int."""
    return int32(strtol(s)[0])


_FLOAT_RE = re.compile(
    r"[+-]?(?:"
    r"0[xX](?:[0-9a-fA-F]+(?:\.[0-9a-fA-F]*)?|\.[0-9a-fA-F]+)(?:[pP][+-]?[0-9]+)?"
    r"|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?"
    r"|[iI][nN][fF](?:[iI][nN][iI][tT][yY])?"
    r"|[nN][aA][nN](?:\([0-9A-Za-z_]*\))?"
    r")")
_EXP_RE = re.compile(r"[eE][+-]?[0-9]+")


def strtod(s, pos=0):
    """Emulate C strtod(s + pos, &end).  Returns ``(value, end)``."""
    n = len(s)
    i = pos
    while i < n and s[i] in _WS:
        i += 1
    m = _FLOAT_RE.match(s, i)
    if not m:
        return 0.0, pos
    t = m.group(0)
    body = t.lstrip("+-")
    neg = t.startswith("-")
    if body[:2] in ("0x", "0X"):
        h = body[2:]
        if "p" in h or "P" in h:
            mant, exp = re.split("[pP]", h)
            exp = int(exp)
        else:
            mant, exp = h, 0
        if "." in mant:
            a, b = mant.split(".")
        else:
            a, b = mant, ""
        v = float(int(a or "0", 16)) if not b else \
            float(int((a or "0") + b, 16)) / (16.0 ** len(b))
        v = math.ldexp(v, exp)
    elif body[:1] in "iI":
        v = math.inf
    elif body[:1] in "nN":
        v = math.nan
    else:
        v = float(body)
    return (-v if neg else v), m.end()


def atof(s):
    """C atof()."""
    return strtod(s)[0]


class Strtok:
    """Emulate the stateful C strtok() over one string.

    ``Strtok(s).next(delims)`` corresponds to the first call
    ``strtok(s, delims)``; subsequent calls to ``next`` correspond to
    ``strtok(NULL, delims)``.
    """

    __slots__ = ("s", "pos")

    def __init__(self, s):
        self.s = s
        self.pos = 0

    def next(self, delims):
        """Return the next token (None when there are no more)."""
        s = self.s
        n = len(s)
        i = self.pos
        if i is None:
            return None
        while i < n and s[i] in delims:
            i += 1
        if i >= n:
            self.pos = None
            return None
        j = i
        while j < n and s[j] not in delims:
            j += 1
        if j < n:
            self.pos = j + 1
        else:
            self.pos = None
        return s[i:j]


def cdiv(a, b):
    """C integer division (truncation toward zero)."""
    q = abs(a) // abs(b)
    return q if (a >= 0) == (b >= 0) else -q


def cmod(a, b):
    """C integer remainder (sign follows the dividend)."""
    return a - b * cdiv(a, b)


# Conversions of an integer to a C integer type (two's complement wrap).

def int32(x):
    """(int) x."""
    x &= 0xFFFFFFFF
    return x - 0x100000000 if x & 0x80000000 else x


def uint32(x):
    """(unsigned) x."""
    return x & 0xFFFFFFFF


def int16(x):
    """(short) x."""
    x &= 0xFFFF
    return x - 0x10000 if x & 0x8000 else x


def uint16(x):
    """(unsigned short) x."""
    return x & 0xFFFF


def int8(x):
    """(signed char) x."""
    x &= 0xFF
    return x - 0x100 if x & 0x80 else x


def uint8(x):
    """(unsigned char) x."""
    return x & 0xFF


# Conversions of a double to an integer type, as compiled for x86-64
# (cvttsd2si): truncation toward zero, and the "integer indefinite" value
# (the most negative integer) for NaN and for values out of range.

def d2i(x):
    """(int) x for a double x."""
    if x != x or x >= 2147483648.0 or x <= -2147483649.0:
        return INT_MIN
    return int(x)


def fdiv(a, b):
    """a / b for doubles, as in C (IEEE 754): infinite or NaN if b is 0."""
    if b == 0.0:
        if a != a or a == 0.0:
            return float("nan")
        return math.copysign(float("inf"), a) * math.copysign(1.0, b)
    return a / b


def d2l(x):
    """(long) x for a double x."""
    if x != x or x >= 9223372036854775808.0 or x < -9223372036854775808.0:
        return LONG_MIN
    return int(x)


_LEN_MOD_RE = re.compile(r"%([-+ #0]*\d*(?:\.\d*)?)(?:hh|h|ll|l|L|q|j|z|t)([diouxXeEfFgGcs])")


def _strip_length_modifiers(fmt):
    return _LEN_MOD_RE.sub(r"%\1\2", fmt)


_fmt_cache = {}


def sprintf(fmt, *args):
    """C sprintf() for the subset of conversions used by WFDB.

    Length modifiers (``l``, ``ll``, ``h``) are accepted and ignored.  ``%u``
    is mapped to ``%d`` (callers must pass non-negative values).
    """
    f = _fmt_cache.get(fmt)
    if f is None:
        f = _strip_length_modifiers(fmt).replace("%u", "%d")
        f = re.sub(r"%([-+ #0]*\d*)c", r"%\1s", f)
        _fmt_cache[fmt] = f
    if not args:
        return f % ()
    return f % args


_SCANF_RE = re.compile(
    r"%(\*?)(\d*)(hh|h|ll|l|L|q|j|z|t)?([diouxXeEfFgGaAsc%\[])")
_SCANF_BASE = {"d": 10, "u": 10, "i": 0, "o": 8, "x": 16, "X": 16}


def sscanf(s, fmt):
    """Emulate C sscanf() for %d %i %u %x %o %f %e %g %s %c (and %*...).

    Returns ``(n, values)``: n is the C return value (number of assigned
    conversions, or -1 if the input ended before the first conversion);
    values is the list of the values assigned, in order.
    """
    values = []
    nconv = 0
    i = 0
    n = len(s)
    pos = 0
    eof_before_first = False
    while pos < len(fmt):
        c = fmt[pos]
        if c == "%":
            m = _SCANF_RE.match(fmt, pos)
            if not m:
                break
            pos = m.end()
            suppress, width, _, conv = m.groups()
            width = int(width) if width else 0
            if conv == "%":
                while i < n and s[i] in _WS:
                    i += 1
                if i < n and s[i] == "%":
                    i += 1
                    continue
                break
            if conv not in "c[":
                while i < n and s[i] in _WS:
                    i += 1
            if i >= n:
                if nconv == 0 and not values:
                    eof_before_first = True
                break
            sub = s[i:i + width] if width else s[i:]
            if conv in "diouxX":
                v, end = strtol(sub, _SCANF_BASE[conv])
                if end == 0:
                    break
                i += end
            elif conv in "eEfFgGaA":
                v, end = strtod(sub)
                if end == 0:
                    break
                i += end
            elif conv == "s":
                j = 0
                while j < len(sub) and sub[j] not in _WS:
                    j += 1
                v = sub[:j]
                i += j
            elif conv == "c":
                w = width or 1
                if len(sub) < w:
                    break
                v = sub[:w]
                i += w
            else:
                break
            if not suppress:
                values.append(v)
                nconv += 1
        elif c in _WS:
            while i < n and s[i] in _WS:
                i += 1
            pos += 1
        else:
            if i < n and s[i] == c:
                i += 1
                pos += 1
            else:
                if i >= n and nconv == 0:
                    eof_before_first = True
                break
    if eof_before_first and nconv == 0:
        return -1, values
    return nconv, values


def fgets_lines(data, size):
    """Split bytes into the successive results of fgets(buf, size, fp).

    Yields str (latin-1) pieces of at most size-1 characters, each ending
    with a newline unless the line was longer or the input ended.
    """
    i = 0
    n = len(data)
    lim = size - 1
    while i < n:
        j = data.find(b"\n", i, i + lim)
        if j < 0:
            j = min(i + lim, n)
        else:
            j += 1
        yield data[i:j].decode("latin-1")
        i = j


class GlibcRand:
    """Exact emulation of glibc's srand()/rand() (TYPE_3 additive generator).

    The state has 31 words; rand() returns (r[i-31] + r[i-3]) >> 1.  srand()
    seeds it with the Park-Miller "minimal standard" generator (16807 * x
    mod 2^31 - 1, computed with Schrage's method: 127773 = m // a, 2836 =
    m % a) and discards the first 310 outputs, as glibc does.
    """

    RAND_MAX = 2147483647

    _DEG, _SEP = 31, 3      # degree and separation of the trinomial
    _DISCARD = 10 * _DEG    # outputs discarded after seeding

    def __init__(self, seed=1):
        self.srand(seed)

    def srand(self, seed):
        """Seed the generator (srand)."""
        deg = self._DEG
        seed &= 0xFFFFFFFF
        if seed == 0:
            seed = 1
        r = [0] * (deg + self._SEP)
        r[0] = seed - 0x100000000 if seed & 0x80000000 else seed
        for i in range(1, deg):
            hi, lo = divmod(r[i - 1], 127773) if r[i - 1] >= 0 else \
                (-((-r[i - 1]) // 127773), -((-r[i - 1]) % 127773))
            word = 16807 * lo - 2836 * hi
            if word < 0:
                word += 2147483647
            r[i] = word
        for i in range(deg, deg + self._SEP):
            r[i] = r[i - deg]
        self.r = [x & 0xFFFFFFFF for x in r]
        for _ in range(self._DISCARD):
            self._next()

    def _next(self):
        r = self.r
        v = (r[-self._DEG] + r[-self._SEP]) & 0xFFFFFFFF
        r.append(v)
        if len(r) > 2 * (self._DEG + self._SEP):    # trim the history
            del r[:-(self._DEG + self._SEP)]
        return v >> 1

    def rand(self):
        """Return the next pseudo-random number (rand)."""
        return self._next()


def cfmt_float(spec, x):
    """Format a double with a printf conversion (e.g. "%g"), as glibc does.

    Unlike Python, glibc prints the sign of a NaN ("-nan").
    """
    if x != x:
        neg = math.copysign(1.0, x) < 0
        m = re.match(r"%([-+ #0]*)(\d*)(?:\.\d*)?[a-zA-Z]", spec)
        flags, width = (m.group(1), m.group(2)) if m else ("", "")
        s = ("-" if neg else ("+" if "+" in flags else
                              (" " if " " in flags else ""))) + \
            ("NAN" if spec[-1].isupper() else "nan")
        if width:
            s = s.ljust(int(width)) if "-" in flags else s.rjust(int(width))
        return s
    return spec % x
