// wfdbx/ecgmap.hpp: annotation code mapping (C++ version of <wfdb/ecgmap.h>).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of lib/ecgmap.h from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language.
//
// Original C code: lib/ecgmap.h, WFDB Software Package 10.7.0.
//   Copyright (C) 1999 George B. Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// The C header defines these as macros; here they are inline functions that
// call the corresponding library functions (wfdb_isqrs(), wfdb_map1(), ...
// of <wfdbx/wfdb.hpp>), so the tables they use are those of the library.

#ifndef WFDBX_ECGMAP_HPP
#define WFDBX_ECGMAP_HPP

#include "ecgcodes.hpp"
#include "wfdb.hpp"

namespace wfdbx {

/// @name Annotation position codes (returned by annpos())
/// @{
constexpr int APUNDEF = 0;  ///< for undefined annotation types
constexpr int APSTD = 1;    ///< standard position
constexpr int APHIGH = 2;   ///< a level above APSTD
constexpr int APLOW = 3;    ///< a level below APSTD
constexpr int APATT = 4;    ///< attached to the signal specified by `chan`
constexpr int APAHIGH = 5;  ///< a level above APATT
constexpr int APALOW = 6;   ///< a level below APATT
/// @}

/// @name The macros of <ecgmap.h>
/// `a` is an annotation code (see ecgcodes.hpp).  The tables used by isqrs,
/// map1, map2 and annpos can be changed with the corresponding set*
/// functions, which return the new value (0, or NOTQRS for setmap1 and
/// setmap2, if `a` is not a legal code, in which case nothing is changed).
/// @{

/// 1 if `a` is a legal annotation code (1 to ACMAX), 0 otherwise.
///
/// Translation of the C macro isann() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
inline int isann(int a) { return wfdb_isann(a); }
/// 1 if `a` denotes a QRS complex (a beat), 0 otherwise.
///
/// Translation of the C macro isqrs() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
inline int isqrs(int a) { return wfdb_isqrs(a); }
inline int setisqrs(int a, int x) { return wfdb_setisqrs(a, x); }
/// `a` mapped to one of NOTQRS, NORMAL, PVC, FUSION, LEARN.
///
/// Translation of the C macro map1() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
inline int map1(int a) { return wfdb_map1(a); }
inline int setmap1(int a, int x) { return wfdb_setmap1(a, x); }
/// `a` mapped to one of NOTQRS, NORMAL, SVPB, PVC, FUSION, LEARN.
///
/// Translation of the C macro map2() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
inline int map2(int a) { return wfdb_map2(a); }
inline int setmap2(int a, int x) { return wfdb_setmap2(a, x); }
/// The MIT code of AHA annotation code `a` (a character, e.g. 'V'), or
/// NOTQRS.
///
/// Translation of the C macro ammap() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
inline int ammap(int a) { return wfdb_ammap(a); }
/// The AHA code (a character) of MIT code `a` with subtype `s`.
///
/// Translation of the C macro mamap() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
inline int mamap(int a, int s) { return wfdb_mamap(a, s); }
/// The display position of annotations of type `a` (APSTD, ...).
///
/// Translation of the C macro annpos() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
inline int annpos(int a) { return wfdb_annpos(a); }
inline int setannpos(int a, int x) { return wfdb_setannpos(a, x); }
/// @}

} // namespace wfdbx

#endif // WFDBX_ECGMAP_HPP
