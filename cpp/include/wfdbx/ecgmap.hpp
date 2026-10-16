// wfdbx/ecgmap.hpp: annotation code mapping (C++ version of <wfdb/ecgmap.h>)
//
// The C header defines these as macros; here they are inline functions that
// call the corresponding library functions (wfdb_isqrs(), wfdb_map1(), ...
// of <wfdbx/wfdb.hpp>), so the tables they use are those of the library.
//
// Copyright (C) 1999 George B. Moody (original C header, lib/ecgmap.h).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
inline int isann(int a) { return wfdb_isann(a); }
/// 1 if `a` denotes a QRS complex (a beat), 0 otherwise.
inline int isqrs(int a) { return wfdb_isqrs(a); }
inline int setisqrs(int a, int x) { return wfdb_setisqrs(a, x); }
/// `a` mapped to one of NOTQRS, NORMAL, PVC, FUSION, LEARN.
inline int map1(int a) { return wfdb_map1(a); }
inline int setmap1(int a, int x) { return wfdb_setmap1(a, x); }
/// `a` mapped to one of NOTQRS, NORMAL, SVPB, PVC, FUSION, LEARN.
inline int map2(int a) { return wfdb_map2(a); }
inline int setmap2(int a, int x) { return wfdb_setmap2(a, x); }
/// The MIT code of AHA annotation code `a` (a character, e.g. 'V'), or
/// NOTQRS.
inline int ammap(int a) { return wfdb_ammap(a); }
/// The AHA code (a character) of MIT code `a` with subtype `s`.
inline int mamap(int a, int s) { return wfdb_mamap(a, s); }
/// The display position of annotations of type `a` (APSTD, ...).
inline int annpos(int a) { return wfdb_annpos(a); }
inline int setannpos(int a, int x) { return wfdb_setannpos(a, x); }
/// @}

} // namespace wfdbx

#endif // WFDBX_ECGMAP_HPP
