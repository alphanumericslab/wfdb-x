//! Annotation codes (`<wfdb/ecgcodes.h>`) and the annotation code mapping
//! functions of `<wfdb/ecgmap.h>` (`isann`, `isqrs`, `map1`, `map2`,
//! `ammap`, `mamap`, `annpos` and their setters).
//!
//! The mapping tables can be modified (`setisqrs`, `setmap1`, ...), so they
//! are part of the library state: the functions that use them are methods
//! of [`Wfdb`] (`w.wfdb_isqrs(code)`), with free-function versions
//! (`isqrs(code)`) that use the default instance. `isann`, `ammap` and
//! `mamap` use constant tables and are plain functions.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of lib/ecgcodes.h, lib/ecgmap.h and the annotation
// code mapping functions of lib/annot.c (wfdb_isann, wfdb_isqrs, wfdb_map1,
// wfdb_map2, wfdb_ammap, wfdb_mamap, wfdb_annpos and their setters) from the
// WFDB Software Package 10.7.0, by T. Baker and George B. Moody
// (lib/ecgcodes.h) and George B. Moody (lib/ecgmap.h, lib/annot.c). The
// translation follows the logic and behavior of the original code, but it is
// new code, not the original C code.
//
// Changes from the original: none, apart from the language.
//
// Original C code: lib/ecgcodes.h, lib/ecgmap.h and lib/annot.c, WFDB Software
// Package 10.7.0.
//   lib/ecgcodes.h: Copyright (C) 1999 George B. Moody.
//   lib/ecgmap.h: Copyright (C) 1999 George B. Moody.
//   lib/annot.c: Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by
//   Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use crate::wfdb::{with_default, Wfdb};

/// Not-QRS (not a getann/putann code).
pub const NOTQRS: i32 = 0;
/// Normal beat.
pub const NORMAL: i32 = 1;
/// Left bundle branch block beat.
pub const LBBB: i32 = 2;
/// Right bundle branch block beat.
pub const RBBB: i32 = 3;
/// Aberrated atrial premature beat.
pub const ABERR: i32 = 4;
/// Premature ventricular contraction.
pub const PVC: i32 = 5;
/// Fusion of ventricular and normal beat.
pub const FUSION: i32 = 6;
/// Nodal (junctional) premature beat.
pub const NPC: i32 = 7;
/// Atrial premature contraction.
pub const APC: i32 = 8;
/// Premature or ectopic supraventricular beat.
pub const SVPB: i32 = 9;
/// Ventricular escape beat.
pub const VESC: i32 = 10;
/// Nodal (junctional) escape beat.
pub const NESC: i32 = 11;
/// Paced beat.
pub const PACE: i32 = 12;
/// Unclassifiable beat.
pub const UNKNOWN: i32 = 13;
/// Signal quality change.
pub const NOISE: i32 = 14;
/// Isolated QRS-like artifact.
pub const ARFCT: i32 = 16;
/// ST change.
pub const STCH: i32 = 18;
/// T-wave change.
pub const TCH: i32 = 19;
/// Systole.
pub const SYSTOLE: i32 = 20;
/// Diastole.
pub const DIASTOLE: i32 = 21;
/// Comment annotation.
pub const NOTE: i32 = 22;
/// Measurement annotation.
pub const MEASURE: i32 = 23;
/// P-wave peak.
pub const PWAVE: i32 = 24;
/// Left or right bundle branch block.
pub const BBB: i32 = 25;
/// Non-conducted pacer spike.
pub const PACESP: i32 = 26;
/// T-wave peak.
pub const TWAVE: i32 = 27;
/// Rhythm change.
pub const RHYTHM: i32 = 28;
/// U-wave peak.
pub const UWAVE: i32 = 29;
/// Learning.
pub const LEARN: i32 = 30;
/// Ventricular flutter wave.
pub const FLWAV: i32 = 31;
/// Start of ventricular flutter/fibrillation.
pub const VFON: i32 = 32;
/// End of ventricular flutter/fibrillation.
pub const VFOFF: i32 = 33;
/// Atrial escape beat.
pub const AESC: i32 = 34;
/// Supraventricular escape beat.
pub const SVESC: i32 = 35;
/// Link to external data (aux contains URL).
pub const LINK: i32 = 36;
/// Non-conducted P-wave (blocked APB).
pub const NAPC: i32 = 37;
/// Fusion of paced and normal beat.
pub const PFUS: i32 = 38;
/// Waveform onset.
pub const WFON: i32 = 39;
/// PQ junction (beginning of QRS).
pub const PQ: i32 = WFON;
/// Waveform end.
pub const WFOFF: i32 = 40;
/// J point (end of QRS).
pub const JPT: i32 = WFOFF;
/// R-on-T premature ventricular contraction.
pub const RONT: i32 = 41;
/// Value of the largest valid annotation code (must be < 50).
pub const ACMAX: i32 = 49;

/// Annotation position: undefined annotation types.
pub const APUNDEF: i32 = 0;
/// Standard position.
pub const APSTD: i32 = 1;
/// A level above APSTD.
pub const APHIGH: i32 = 2;
/// A level below APSTD.
pub const APLOW: i32 = 3;
/// Attached to the signal specified by `chan`.
pub const APATT: i32 = 4;
/// A level above APATT.
pub const APAHIGH: i32 = 5;
/// A level below APATT.
pub const APALOW: i32 = 6;

const N: usize = ACMAX as usize + 1;

const QRS_TABLE: [i8; N] = [
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 1,
    0, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0,
];

#[rustfmt::skip]
const MP1_TABLE: [i8; N] = [
    0, 1, 1, 1, 1,      // NOTQRS, NORMAL, NORMAL, NORMAL, NORMAL: 0 - 4
    5, 6, 1, 1, 1,      // PVC, FUSION, NORMAL, NORMAL, NORMAL: 5 - 9
    5, 1, 1, 1, 0,      // PVC, NORMAL, NORMAL, NORMAL, NOTQRS: 10 - 14
    0, 0, 0, 0, 0,      // 15 - 19
    0, 0, 0, 0, 0,      // 20 - 24
    1, 0, 0, 0, 0,      // NORMAL: 25 - 29
    30, 5, 0, 0, 1,     // LEARN, PVC, NOTQRS, NOTQRS, NORMAL: 30 - 34
    1, 0, 0, 1, 0,      // NORMAL, NOTQRS, NOTQRS, NORMAL, NOTQRS: 35 - 39
    0, 5, 0, 0, 0,      // NOTQRS, PVC: 40 - 44
    0, 0, 0, 0, 0,      // 45 - 49
];

#[rustfmt::skip]
const MP2_TABLE: [i8; N] = [
    0, 1, 1, 1, 9,      // NOTQRS, NORMAL, NORMAL, NORMAL, SVPB: 0 - 4
    5, 6, 9, 9, 9,      // PVC, FUSION, SVPB, SVPB, SVPB: 5 - 9
    5, 1, 1, 1, 0,      // PVC, NORMAL, NORMAL, NORMAL, NOTQRS: 10 - 14
    0, 0, 0, 0, 0,      // 15 - 19
    0, 0, 0, 0, 0,      // 20 - 24
    1, 0, 0, 0, 0,      // NORMAL: 25 - 29
    30, 5, 0, 0, 1,     // LEARN, PVC, NOTQRS, NOTQRS, NORMAL: 30 - 34
    1, 0, 0, 1, 0,      // 35 - 39
    0, 5, 0, 0, 0,      // 40 - 44
    0, 0, 0, 0, 0,      // 45 - 49
];

/// AHA code ('E'..=']') to MIT code.
#[rustfmt::skip]
const AMMP_TABLE: [i8; 25] = [
    VESC as i8, FUSION as i8, 0, 0, 0,              // 'E' - 'I'
    0, 0, 0, 0, NORMAL as i8,                       // 'J' - 'N'
    NOTE as i8, PACE as i8, UNKNOWN as i8, RONT as i8, 0, // 'O' - 'S'
    0, NOISE as i8, PVC as i8, 0, 0,                // 'T' - 'X'
    0, 0, VFON as i8, 0, VFOFF as i8,               // 'Y' - ']'
];

/// MIT code to AHA code.
const MAMP_TABLE: &[u8; N] = b"ONNNNVFNNNENPQUOOOOOOOOOONOOOOQO[]NNOONOOROOOOOOOO";

#[rustfmt::skip]
const ANNP_TABLE: [i8; N] = [
    0, 1, 1, 1, 1,
    1, 1, 1, 1, 1,
    1, 1, 1, 1, 2,
    0, 2, 0, 2, 2,
    2, 2, 2, 2, 2,
    1, 2, 2, 3, 2,
    1, 1, 1, 1, 1,
    1, 2, 2, 1, 2,
    2, 1, 0, 0, 0,
    0, 0, 0, 0, 0,
];

/// The modifiable annotation code mapping tables of `<ecgmap.h>` (part of
/// the [`Wfdb`] state; not reset by `wfdbquit`).
#[derive(Clone, Debug)]
pub struct EcgMaps {
    qrs: [i8; N],
    mp1: [i8; N],
    mp2: [i8; N],
    annp: [i8; N],
}

impl Default for EcgMaps {
    fn default() -> Self {
        EcgMaps {
            qrs: QRS_TABLE,
            mp1: MP1_TABLE,
            mp2: MP2_TABLE,
            annp: ANNP_TABLE,
        }
    }
}

/// C `isann(code)`: is `code` a legal annotation code?
///
/// Translation of the C function wfdb_isann() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
#[inline]
pub fn wfdb_isann(code: i32) -> i32 {
    (0 < code && code <= ACMAX) as i32
}

/// Alias of [`wfdb_isann`] (the `<ecgmap.h>` macro name).
///
/// Translation of the C macro isann() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
#[inline]
pub fn isann(code: i32) -> i32 {
    wfdb_isann(code)
}

/// C `ammap(code)`: map an AHA code (a character) to an MIT code.
///
/// Translation of the C function wfdb_ammap() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
#[inline]
pub fn wfdb_ammap(code: i32) -> i32 {
    if (b'D' as i32) < code && code <= b']' as i32 {
        AMMP_TABLE[(code - b'E' as i32) as usize] as i32
    } else {
        NOTQRS
    }
}

/// Alias of [`wfdb_ammap`].
///
/// Translation of the C macro ammap() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
#[inline]
pub fn ammap(code: i32) -> i32 {
    wfdb_ammap(code)
}

/// C `mamap(code, subtype)`: map an MIT code to an AHA code.
///
/// Translation of the C function wfdb_mamap() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
#[inline]
pub fn wfdb_mamap(code: i32, subtype: i32) -> i32 {
    if wfdb_isann(code) == 0 {
        return b'O' as i32;
    }
    let m = MAMP_TABLE[code as usize];
    if m == b'U' && subtype != -1 {
        b'O' as i32
    } else {
        m as i32
    }
}

/// Alias of [`wfdb_mamap`].
///
/// Translation of the C macro mamap() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
#[inline]
pub fn mamap(code: i32, subtype: i32) -> i32 {
    wfdb_mamap(code, subtype)
}

impl Wfdb {
    /// C `isqrs(code)`: 1 if `code` denotes a QRS complex.
    ///
    /// Translation of the C function wfdb_isqrs() (lib/annot.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdb_isqrs(&self, code: i32) -> i32 {
        if wfdb_isann(code) != 0 {
            self.maps.qrs[code as usize] as i32
        } else {
            0
        }
    }

    /// C `setisqrs(code, newval)` (the value is stored as a `char`, so
    /// `setisqrs(2, 300)` returns 44).
    ///
    /// Translation of the C function wfdb_setisqrs() (lib/annot.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn wfdb_setisqrs(&mut self, code: i32, newval: i32) -> i32 {
        if wfdb_isann(code) != 0 {
            self.maps.qrs[code as usize] = newval as i8;
            newval as i8 as i32
        } else {
            0
        }
    }

    /// C `map1(code)`: map to one of NORMAL, PVC, FUSION, LEARN, NOTQRS.
    ///
    /// Translation of the C function wfdb_map1() (lib/annot.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdb_map1(&self, code: i32) -> i32 {
        if wfdb_isann(code) != 0 {
            self.maps.mp1[code as usize] as i32
        } else {
            NOTQRS
        }
    }

    /// C `setmap1(code, newval)`: set the `map1` value of an annotation
    /// type. Returns `newval` (as a C `char`), or `NOTQRS` if `code` is not
    /// an annotation type.
    ///
    /// Translation of the C function wfdb_setmap1() (lib/annot.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdb_setmap1(&mut self, code: i32, newval: i32) -> i32 {
        if wfdb_isann(code) != 0 {
            self.maps.mp1[code as usize] = newval as i8;
            newval as i8 as i32
        } else {
            NOTQRS
        }
    }

    /// C `map2(code)`: map to one of NORMAL, SVPB, PVC, FUSION, LEARN,
    /// NOTQRS.
    ///
    /// Translation of the C function wfdb_map2() (lib/annot.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdb_map2(&self, code: i32) -> i32 {
        if wfdb_isann(code) != 0 {
            self.maps.mp2[code as usize] as i32
        } else {
            NOTQRS
        }
    }

    /// C `setmap2(code, newval)`: set the `map2` value of an annotation
    /// type. Returns `newval` (as a C `char`), or `NOTQRS` if `code` is not
    /// an annotation type.
    ///
    /// Translation of the C function wfdb_setmap2() (lib/annot.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdb_setmap2(&mut self, code: i32, newval: i32) -> i32 {
        if wfdb_isann(code) != 0 {
            self.maps.mp2[code as usize] = newval as i8;
            newval as i8 as i32
        } else {
            NOTQRS
        }
    }

    /// C `annpos(code)`: the display position of an annotation type.
    ///
    /// Translation of the C function wfdb_annpos() (lib/annot.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdb_annpos(&self, code: i32) -> i32 {
        if wfdb_isann(code) != 0 {
            self.maps.annp[code as usize] as i32
        } else {
            0
        }
    }

    /// C `setannpos(code, newval)`: set the display position of an
    /// annotation type. Returns `newval` (as a C `char`), or 0 if `code` is
    /// not an annotation type.
    ///
    /// Translation of the C function wfdb_setannpos() (lib/annot.c, WFDB
    /// 10.7.0): same arguments and results.
    pub fn wfdb_setannpos(&mut self, code: i32, newval: i32) -> i32 {
        if wfdb_isann(code) != 0 {
            self.maps.annp[code as usize] = newval as i8;
            newval as i8 as i32
        } else {
            0
        }
    }
}

/// C `isqrs(code)` on the default instance.
///
/// Translation of the C macro isqrs() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
pub fn isqrs(code: i32) -> i32 {
    with_default(|w| w.wfdb_isqrs(code))
}
/// C `wfdb_isqrs(code)` on the default instance (see [`Wfdb::wfdb_isqrs`]).
///
/// Translation of the C function wfdb_isqrs() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
pub fn wfdb_isqrs(code: i32) -> i32 {
    isqrs(code)
}
/// C `setisqrs(code, newval)` on the default instance.
///
/// Translation of the C macro setisqrs() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
pub fn setisqrs(code: i32, newval: i32) -> i32 {
    with_default(|w| w.wfdb_setisqrs(code, newval))
}
/// C `wfdb_setisqrs` on the default instance (see [`Wfdb::wfdb_setisqrs`]).
///
/// Translation of the C function wfdb_setisqrs() (lib/annot.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdb_setisqrs(code: i32, newval: i32) -> i32 {
    setisqrs(code, newval)
}
/// C `map1(code)` on the default instance.
///
/// Translation of the C macro map1() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
pub fn map1(code: i32) -> i32 {
    with_default(|w| w.wfdb_map1(code))
}
/// C `wfdb_map1` on the default instance (see [`Wfdb::wfdb_map1`]).
///
/// Translation of the C function wfdb_map1() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
pub fn wfdb_map1(code: i32) -> i32 {
    map1(code)
}
/// C `setmap1(code, newval)` on the default instance.
///
/// Translation of the C macro setmap1() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
pub fn setmap1(code: i32, newval: i32) -> i32 {
    with_default(|w| w.wfdb_setmap1(code, newval))
}
/// C `wfdb_setmap1` on the default instance (see [`Wfdb::wfdb_setmap1`]).
///
/// Translation of the C function wfdb_setmap1() (lib/annot.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdb_setmap1(code: i32, newval: i32) -> i32 {
    setmap1(code, newval)
}
/// C `map2(code)` on the default instance.
///
/// Translation of the C macro map2() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
pub fn map2(code: i32) -> i32 {
    with_default(|w| w.wfdb_map2(code))
}
/// C `wfdb_map2` on the default instance (see [`Wfdb::wfdb_map2`]).
///
/// Translation of the C function wfdb_map2() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
pub fn wfdb_map2(code: i32) -> i32 {
    map2(code)
}
/// C `setmap2(code, newval)` on the default instance.
///
/// Translation of the C macro setmap2() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
pub fn setmap2(code: i32, newval: i32) -> i32 {
    with_default(|w| w.wfdb_setmap2(code, newval))
}
/// C `wfdb_setmap2` on the default instance (see [`Wfdb::wfdb_setmap2`]).
///
/// Translation of the C function wfdb_setmap2() (lib/annot.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdb_setmap2(code: i32, newval: i32) -> i32 {
    setmap2(code, newval)
}
/// C `annpos(code)` on the default instance.
///
/// Translation of the C macro annpos() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
pub fn annpos(code: i32) -> i32 {
    with_default(|w| w.wfdb_annpos(code))
}
/// C `wfdb_annpos` on the default instance (see [`Wfdb::wfdb_annpos`]).
///
/// Translation of the C function wfdb_annpos() (lib/annot.c, WFDB 10.7.0): same
/// arguments and results.
pub fn wfdb_annpos(code: i32) -> i32 {
    annpos(code)
}
/// C `setannpos(code, newval)` on the default instance.
///
/// Translation of the C macro setannpos() (lib/ecgmap.h, WFDB 10.7.0): same
/// arguments and results.
pub fn setannpos(code: i32, newval: i32) -> i32 {
    with_default(|w| w.wfdb_setannpos(code, newval))
}
/// C `wfdb_setannpos` on the default instance (see [`Wfdb::wfdb_setannpos`]).
///
/// Translation of the C function wfdb_setannpos() (lib/annot.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdb_setannpos(code: i32, newval: i32) -> i32 {
    setannpos(code, newval)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tables() {
        let mut w = Wfdb::new();
        assert_eq!(w.wfdb_isqrs(NORMAL), 1);
        assert_eq!(w.wfdb_isqrs(NOISE), 0);
        assert_eq!(w.wfdb_map1(APC), NORMAL);
        assert_eq!(w.wfdb_map2(APC), SVPB);
        assert_eq!(w.wfdb_map1(RONT), PVC);
        assert_eq!(w.wfdb_setisqrs(2, 300), 44);
        assert_eq!(w.wfdb_isqrs(2), 44);
        assert_eq!(w.wfdb_annpos(RHYTHM), APLOW);
        assert_eq!(wfdb_ammap(b'N' as i32), NORMAL);
        assert_eq!(wfdb_ammap(b']' as i32), VFOFF);
        assert_eq!(wfdb_ammap(b'D' as i32), NOTQRS);
        assert_eq!(wfdb_mamap(PVC, 0), b'V' as i32);
        assert_eq!(wfdb_mamap(NOISE, 0), b'O' as i32);
        assert_eq!(wfdb_mamap(NOISE, -1), b'U' as i32);
        assert_eq!(wfdb_mamap(VFON, 0), b'[' as i32);
        assert_eq!(wfdb_isann(0), 0);
        assert_eq!(wfdb_isann(ACMAX), 1);
    }
}
