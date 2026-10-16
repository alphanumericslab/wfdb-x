"""Annotation codes and mapping tables (port of lib/ecgcodes.h, lib/ecgmap.h).

Copyright (C) 1999 George B. Moody (original C headers, lib/ecgcodes.h, by
T. Baker and G. Moody, and lib/ecgmap.h).
Python implementation part of wfdb-x, Reza Sameni, Oct 2026.
This library is free software; you can redistribute it and/or modify it under
the terms of the GNU Library General Public License as published by the Free
Software Foundation; either version 2 of the License, or (at your option) any
later version.
"""

NOTQRS = 0      # not-QRS (not a getann/putann code)
NORMAL = 1      # normal beat
LBBB = 2        # left bundle branch block beat
RBBB = 3        # right bundle branch block beat
ABERR = 4       # aberrated atrial premature beat
PVC = 5         # premature ventricular contraction
FUSION = 6      # fusion of ventricular and normal beat
NPC = 7         # nodal (junctional) premature beat
APC = 8         # atrial premature contraction
SVPB = 9        # premature or ectopic supraventricular beat
VESC = 10       # ventricular escape beat
NESC = 11       # nodal (junctional) escape beat
PACE = 12       # paced beat
UNKNOWN = 13    # unclassifiable beat
NOISE = 14      # signal quality change
ARFCT = 16      # isolated QRS-like artifact
STCH = 18       # ST change
TCH = 19        # T-wave change
SYSTOLE = 20    # systole
DIASTOLE = 21   # diastole
NOTE = 22       # comment annotation
MEASURE = 23    # measurement annotation
PWAVE = 24      # P-wave peak
BBB = 25        # left or right bundle branch block
PACESP = 26     # non-conducted pacer spike
TWAVE = 27      # T-wave peak
RHYTHM = 28     # rhythm change
UWAVE = 29      # U-wave peak
LEARN = 30      # learning
FLWAV = 31      # ventricular flutter wave
VFON = 32       # start of ventricular flutter/fibrillation
VFOFF = 33      # end of ventricular flutter/fibrillation
AESC = 34       # atrial escape beat
SVESC = 35      # supraventricular escape beat
LINK = 36       # link to external data (aux contains URL)
NAPC = 37       # non-conducted P-wave (blocked APB)
PFUS = 38       # fusion of paced and normal beat
WFON = 39       # waveform onset
PQ = WFON       # PQ junction (beginning of QRS)
WFOFF = 40      # waveform end
JPT = WFOFF     # J point (end of QRS)
RONT = 41       # R-on-T premature ventricular contraction
ACMAX = 49      # value of largest valid annot code (must be < 50)

# Annotation position codes
APUNDEF = 0
APSTD = 1
APHIGH = 2
APLOW = 3
APATT = 4
APAHIGH = 5
APALOW = 6

_qrs = [
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 1, 0, 0, 0, 0,
    1, 1, 0, 0, 1, 1, 0, 0, 1, 0,
    0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
]

_mp1 = [
    NOTQRS, NORMAL, NORMAL, NORMAL, NORMAL,
    PVC, FUSION, NORMAL, NORMAL, NORMAL,
    PVC, NORMAL, NORMAL, NORMAL, NOTQRS,
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NOTQRS,
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NOTQRS,
    NORMAL, NOTQRS, NOTQRS, NOTQRS, NOTQRS,
    LEARN, PVC, NOTQRS, NOTQRS, NORMAL,
    NORMAL, NOTQRS, NOTQRS, NORMAL, NOTQRS,
    NOTQRS, PVC, NOTQRS, NOTQRS, NOTQRS,
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NOTQRS,
]

_mp2 = [
    NOTQRS, NORMAL, NORMAL, NORMAL, SVPB,
    PVC, FUSION, SVPB, SVPB, SVPB,
    PVC, NORMAL, NORMAL, NORMAL, NOTQRS,
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NOTQRS,
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NOTQRS,
    NORMAL, NOTQRS, NOTQRS, NOTQRS, NOTQRS,
    LEARN, PVC, NOTQRS, NOTQRS, NORMAL,
    NORMAL, NOTQRS, NOTQRS, NORMAL, NOTQRS,
    NOTQRS, PVC, NOTQRS, NOTQRS, NOTQRS,
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NOTQRS,
]

_ammp = [
    VESC, FUSION, NOTQRS, NOTQRS, NOTQRS,       # 'E' - 'I'
    NOTQRS, NOTQRS, NOTQRS, NOTQRS, NORMAL,     # 'J' - 'N'
    NOTE, PACE, UNKNOWN, RONT, NOTQRS,          # 'O' - 'S'
    NOTQRS, NOISE, PVC, NOTQRS, NOTQRS,         # 'T' - 'X'
    NOTQRS, NOTQRS, VFON, NOTQRS, VFOFF,        # 'Y' - ']'
]

_mamp = [ord(c) for c in (
    "ONNNN" "VFNNN" "ENPQU" "OOOOO" "OOOOO"
    "NOOOO" "QO[]N" "NOONO" "OROOO" "OOOOO")]

_annp = [
    APUNDEF, APSTD, APSTD, APSTD, APSTD,
    APSTD, APSTD, APSTD, APSTD, APSTD,
    APSTD, APSTD, APSTD, APSTD, APHIGH,
    APUNDEF, APHIGH, APUNDEF, APHIGH, APHIGH,
    APHIGH, APHIGH, APHIGH, APHIGH, APHIGH,
    APSTD, APHIGH, APHIGH, APLOW, APHIGH,
    APSTD, APSTD, APSTD, APSTD, APSTD,
    APSTD, APHIGH, APHIGH, APSTD, APHIGH,
    APHIGH, APSTD, APUNDEF, APUNDEF, APUNDEF,
    APUNDEF, APUNDEF, APUNDEF, APUNDEF, APUNDEF,
]


def _c8(x):
    """Store x in a C 'char' (signed on the reference platform)."""
    x &= 0xFF
    return x - 256 if x > 127 else x


def isann(a):
    """Return True if a is a legal annotation code (1 to ACMAX)."""
    return 0 < a <= ACMAX


def isqrs(a):
    """Return 1 if annotation code a denotes a QRS complex, 0 otherwise."""
    return _qrs[a] if isann(a) else 0


def setisqrs(a, x):
    """Set the value returned by isqrs(a) to x; return the new value."""
    if isann(a):
        _qrs[a] = _c8(x)
        return _qrs[a]
    return 0


def map1(a):
    """Map annotation code a to one of NOTQRS, NORMAL, PVC, FUSION, LEARN."""
    return _mp1[a] if isann(a) else NOTQRS


def setmap1(a, x):
    """Set the value returned by map1(a) to x; return the new value."""
    if isann(a):
        _mp1[a] = _c8(x)
        return _mp1[a]
    return NOTQRS


def map2(a):
    """Map annotation code a to NOTQRS, NORMAL, SVPB, PVC, FUSION or LEARN."""
    return _mp2[a] if isann(a) else NOTQRS


def setmap2(a, x):
    """Set the value returned by map2(a) to x; return the new value."""
    if isann(a):
        _mp2[a] = _c8(x)
        return _mp2[a]
    return NOTQRS


def ammap(a):
    """Map an AHA annotation code (a character code, e.g. ord('N')) to MIT."""
    return _ammp[a - ord("E")] if ord("D") < a <= ord("]") else NOTQRS


def mamap(a, s):
    """Map MIT code a, with subtype s, to an AHA code (a character code)."""
    if isann(a):
        m = _mamp[a]
        return ord("O") if (m == ord("U") and s != -1) else m
    return ord("O")


def annpos(a):
    """Return the position code of annotation code a (APSTD, APHIGH, ...)."""
    return _annp[a] if isann(a) else APUNDEF


def setannpos(a, x):
    """Set the value returned by annpos(a) to x; return the new value."""
    if isann(a):
        _annp[a] = _c8(x)
        return _annp[a]
    return APUNDEF


# Function versions exported with the wfdb_ prefix, as in the C library.
wfdb_isann = isann
wfdb_isqrs = isqrs
wfdb_setisqrs = setisqrs
wfdb_map1 = map1
wfdb_setmap1 = setmap1
wfdb_map2 = map2
wfdb_setmap2 = setmap2
wfdb_ammap = ammap
wfdb_mamap = mamap
wfdb_annpos = annpos
wfdb_setannpos = setannpos
