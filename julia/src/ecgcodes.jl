# ecgcodes.jl: annotation codes (<wfdb/ecgcodes.h>) and the annotation code
# mapping functions of <wfdb/ecgmap.h> (isann, isqrs, map1, map2, ammap,
# mamap, annpos and their setters).
#
# The mapping tables can be modified (setisqrs, setmap1, ...), so they are
# part of the library state (`w.maps`, an `EcgMaps`): the functions that use
# them take a `Wfdb` (or use the default instance). isann, ammap and mamap
# use constant tables.
#
# This file is part of WFDB-x, an independent reimplementation of the WFDB
# Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
#
# It is a Julia translation of lib/ecgcodes.h, lib/ecgmap.h and the annotation
# code mapping functions of lib/annot.c (wfdb_isann, wfdb_isqrs, wfdb_map1,
# wfdb_map2, wfdb_ammap, wfdb_mamap, wfdb_annpos and their setters) from the
# WFDB Software Package 10.7.0, by T. Baker and George B. Moody
# (lib/ecgcodes.h) and George B. Moody (lib/ecgmap.h, lib/annot.c). The
# translation follows the logic and behavior of the original code, but it is
# new code, not the original C code.
#
# Changes from the original: none, apart from the language.
#
# Original C code: lib/ecgcodes.h, lib/ecgmap.h and lib/annot.c, WFDB Software
# Package 10.7.0.
#   lib/ecgcodes.h: Copyright (C) 1999 George B. Moody.
#   lib/ecgmap.h: Copyright (C) 1999 George B. Moody.
#   lib/annot.c: Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by
#   Benjamin Moody.
# Julia translation and changes: Copyright (C) 2026 Reza Sameni.
#
# This library is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version. See LICENSE.

const NOTQRS = Int32(0)     # not-QRS (not a getann/putann code)
const NORMAL = Int32(1)     # normal beat
const LBBB = Int32(2)       # left bundle branch block beat
const RBBB = Int32(3)       # right bundle branch block beat
const ABERR = Int32(4)      # aberrated atrial premature beat
const PVC = Int32(5)        # premature ventricular contraction
const FUSION = Int32(6)     # fusion of ventricular and normal beat
const NPC = Int32(7)        # nodal (junctional) premature beat
const APC = Int32(8)        # atrial premature contraction
const SVPB = Int32(9)       # premature or ectopic supraventricular beat
const VESC = Int32(10)      # ventricular escape beat
const NESC = Int32(11)      # nodal (junctional) escape beat
const PACE = Int32(12)      # paced beat
const UNKNOWN = Int32(13)   # unclassifiable beat
const NOISE = Int32(14)     # signal quality change
const ARFCT = Int32(16)     # isolated QRS-like artifact
const STCH = Int32(18)      # ST change
const TCH = Int32(19)       # T-wave change
const SYSTOLE = Int32(20)   # systole
const DIASTOLE = Int32(21)  # diastole
const NOTE = Int32(22)      # comment annotation
const MEASURE = Int32(23)   # measurement annotation
const PWAVE = Int32(24)     # P-wave peak
const BBB = Int32(25)       # left or right bundle branch block
const PACESP = Int32(26)    # non-conducted pacer spike
const TWAVE = Int32(27)     # T-wave peak
const RHYTHM = Int32(28)    # rhythm change
const UWAVE = Int32(29)     # U-wave peak
const LEARN = Int32(30)     # learning
const FLWAV = Int32(31)     # ventricular flutter wave
const VFON = Int32(32)      # start of ventricular flutter/fibrillation
const VFOFF = Int32(33)     # end of ventricular flutter/fibrillation
const AESC = Int32(34)      # atrial escape beat
const SVESC = Int32(35)     # supraventricular escape beat
const LINK = Int32(36)      # link to external data (aux contains URL)
const NAPC = Int32(37)      # non-conducted P-wave (blocked APB)
const PFUS = Int32(38)      # fusion of paced and normal beat
const WFON = Int32(39)      # waveform onset
const PQ = WFON             # PQ junction (beginning of QRS)
const WFOFF = Int32(40)     # waveform end
const JPT = WFOFF           # J point (end of QRS)
const RONT = Int32(41)      # R-on-T premature ventricular contraction
"Value of the largest valid annotation code (must be < 50)."
const ACMAX = Int32(49)

# Annotation positions (annpos).
const APUNDEF = Int32(0)    # undefined annotation types
const APSTD = Int32(1)      # standard position
const APHIGH = Int32(2)     # a level above APSTD
const APLOW = Int32(3)      # a level below APSTD
const APATT = Int32(4)      # attached to the signal specified by chan
const APAHIGH = Int32(5)    # a level above APATT
const APALOW = Int32(6)     # a level below APATT

const _QRS_TABLE = Int8[
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0]

const _MP1_TABLE = Int8[
    0, 1, 1, 1, 1,      # NOTQRS, NORMAL, NORMAL, NORMAL, NORMAL: 0 - 4
    5, 6, 1, 1, 1,      # PVC, FUSION, NORMAL, NORMAL, NORMAL: 5 - 9
    5, 1, 1, 1, 0,      # PVC, NORMAL, NORMAL, NORMAL, NOTQRS: 10 - 14
    0, 0, 0, 0, 0,      # 15 - 19
    0, 0, 0, 0, 0,      # 20 - 24
    1, 0, 0, 0, 0,      # NORMAL: 25 - 29
    30, 5, 0, 0, 1,     # LEARN, PVC, NOTQRS, NOTQRS, NORMAL: 30 - 34
    1, 0, 0, 1, 0,      # NORMAL, NOTQRS, NOTQRS, NORMAL, NOTQRS: 35 - 39
    0, 5, 0, 0, 0,      # NOTQRS, PVC: 40 - 44
    0, 0, 0, 0, 0]      # 45 - 49

const _MP2_TABLE = Int8[
    0, 1, 1, 1, 9,      # NOTQRS, NORMAL, NORMAL, NORMAL, SVPB: 0 - 4
    5, 6, 9, 9, 9,      # PVC, FUSION, SVPB, SVPB, SVPB: 5 - 9
    5, 1, 1, 1, 0,      # PVC, NORMAL, NORMAL, NORMAL, NOTQRS: 10 - 14
    0, 0, 0, 0, 0,      # 15 - 19
    0, 0, 0, 0, 0,      # 20 - 24
    1, 0, 0, 0, 0,      # NORMAL: 25 - 29
    30, 5, 0, 0, 1,     # LEARN, PVC, NOTQRS, NOTQRS, NORMAL: 30 - 34
    1, 0, 0, 1, 0,      # 35 - 39
    0, 5, 0, 0, 0,      # 40 - 44
    0, 0, 0, 0, 0]      # 45 - 49

# AHA code ('E'..']') to MIT code.
const _AMMP_TABLE = Int8[
    VESC, FUSION, 0, 0, 0,          # 'E' - 'I'
    0, 0, 0, 0, NORMAL,             # 'J' - 'N'
    NOTE, PACE, UNKNOWN, RONT, 0,   # 'O' - 'S'
    0, NOISE, PVC, 0, 0,            # 'T' - 'X'
    0, 0, VFON, 0, VFOFF]           # 'Y' - ']'

# MIT code to AHA code.
const _MAMP_TABLE = b"ONNNNVFNNNENPQUOOOOOOOOOONOOOOQO[]NNOONOOROOOOOOOO"

const _ANNP_TABLE = Int8[
    0, 1, 1, 1, 1,
    1, 1, 1, 1, 1,
    1, 1, 1, 1, 2,
    0, 2, 0, 2, 2,
    2, 2, 2, 2, 2,
    1, 2, 2, 3, 2,
    1, 1, 1, 1, 1,
    1, 2, 2, 1, 2,
    2, 1, 0, 0, 0,
    0, 0, 0, 0, 0]

"""
The modifiable annotation code mapping tables of `<ecgmap.h>` (part of the
library state; not reset by `wfdbquit`). Indexed by `code + 1`.
"""
mutable struct EcgMaps
    qrs::Vector{Int8}
    mp1::Vector{Int8}
    mp2::Vector{Int8}
    annp::Vector{Int8}
end
EcgMaps() = EcgMaps(copy(_QRS_TABLE), copy(_MP1_TABLE), copy(_MP2_TABLE), copy(_ANNP_TABLE))

# Each macro also has the name of its function version in lib/annot.c
# (wfdb_isann, wfdb_isqrs, wfdb_setisqrs, ...).

"""
    isann(code) -> Int32

C `isann(code)` (`<wfdb/ecgmap.h>`): 1 if `code` is a legal annotation code
(1 to `ACMAX`), 0 otherwise.

Translation of the C macro isann() (lib/ecgmap.h, WFDB 10.7.0): same
arguments and results.
"""
@inline isann(code::Integer) = Int32(0 < code <= ACMAX)
const wfdb_isann = isann

"""
    ammap(code) -> Int32

C `ammap(code)`: the MIT annotation code of an AHA annotation code (a
character, `'E'` to `']'`); `NOTQRS` for other codes.

Translation of the C macro ammap() (lib/ecgmap.h, WFDB 10.7.0): same
arguments and results.
"""
@inline function ammap(code::Integer)
    (Int('D') < code <= Int(']')) ? Int32(_AMMP_TABLE[code-Int('E')+1]) : NOTQRS
end
const wfdb_ammap = ammap

"""
    mamap(code, subtype) -> Int32

C `mamap(code, subtype)`: the AHA annotation code (a character) of an MIT
annotation code and subtype; `'O'` for codes with no AHA equivalent.

Translation of the C macro mamap() (lib/ecgmap.h, WFDB 10.7.0): same
arguments and results.
"""
@inline function mamap(code::Integer, subtype::Integer)
    wfdb_isann(code) == 0 && return Int32('O')
    m = _MAMP_TABLE[code+1]
    (m == UInt8('U') && subtype != -1) ? Int32('O') : Int32(m)
end
const wfdb_mamap = mamap

# The table functions (C macros that index a table of <wfdb/ecgmap.h>), on a
# Wfdb or on the default instance: name, setter, table, and what it gives.
for (get, set, tab, what) in (
        (:isqrs, :setisqrs, :qrs, "1 if `code` denotes a QRS complex, 0 otherwise"),
        (:map1, :setmap1, :mp1, "`code` mapped into one of `NOTQRS`, `NORMAL`, `PVC`, `FUSION`, `LEARN`"),
        (:map2, :setmap2, :mp2,
         "`code` mapped into one of `NOTQRS`, `NORMAL`, `SVPB`, `PVC`, `FUSION`, `LEARN`"),
        (:annpos, :setannpos, :annp, "the position code (`APUNDEF`, `APSTD`, ...) for plotting `code`"))
    wget = Symbol(:wfdb_, get)
    wset = Symbol(:wfdb_, set)
    dflt = 0
    @eval begin
        @doc $("""
                   $(get)([w], code) -> Int32

               C `$(get)(code)`: $(what) (0 if `code` is not a legal annotation code).

               Translation of the C macro $(get)() (lib/ecgmap.h, WFDB 10.7.0): same
               arguments and results.
               """)
        function $get end
        @doc $("""
                   $(set)([w], code, value) -> Int32

               C `$(set)(code, value)`: change the result of `$(get)(code)` (stored as a C
               `char`); returns the new value, or 0 if `code` is not a legal annotation code.

               Translation of the C macro $(set)() (lib/ecgmap.h, WFDB 10.7.0): same
               arguments and results.
               """)
        function $set end
        function $wget(w::Wfdb, code::Integer)
            wfdb_isann(code) != 0 ? Int32(w.maps.$tab[code+1]) : Int32($dflt)
        end
        function $wset(w::Wfdb, code::Integer, newval::Integer)
            if wfdb_isann(code) != 0
                w.maps.$tab[code+1] = newval % Int8
                return Int32(newval % Int8)
            end
            Int32($dflt)
        end
        $wget(code::Integer) = $wget(lib(), code)
        $wset(code::Integer, newval::Integer) = $wset(lib(), code, newval)
        $get(w::Wfdb, code::Integer) = $wget(w, code)
        $get(code::Integer) = $wget(lib(), code)
        $set(w::Wfdb, code::Integer, newval::Integer) = $wset(w, code, newval)
        $set(code::Integer, newval::Integer) = $wset(lib(), code, newval)
    end
end
