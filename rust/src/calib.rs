//! Calibration list (port of `lib/calib.c`): `calopen` (reads a
//! calibration file into the calibration list), `getcal` (finds an entry of
//! the list), `putcal` (appends an entry), `newcal` (writes the list to a
//! calibration file) and `flushcal` (empties the list). Calibration files
//! are written with `\r\n` line separators.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of lib/calib.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language.
//
// Original C code: lib/calib.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1991-2013 George B. Moody; revised 2019-2022 by
//   Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use crate::cstd::{self, Strtok};
use crate::types::*;
use crate::wfdb::{with_default, OptBytes, Wfdb, NULL};
use crate::{cformat, cfprintf};

/// The state of `calib.c` (part of [`crate::Wfdb`]): the calibration list.
#[derive(Debug, Default)]
pub struct CalState {
    list: Vec<Calinfo>,
}

impl Wfdb {
    /// C `calopen(cfname)`: read a calibration file into the calibration
    /// list. With `NULL`, the file named by the environment variable
    /// `WFDBCAL` (default `wfdbcal`) is read. Unless the name begins with
    /// `+`, the list is emptied first. The file is looked for in the WFDB
    /// path. Returns 0, or -2 if the file cannot be read.
    ///
    /// Translation of the C function calopen() (lib/calib.c, WFDB 10.7.0):
    /// same arguments and results. Differences: the calibration file is found
    /// only where it is named, not by a search of the WFDB path; see
    /// docs/DIVERGENCES.md.
    pub fn calopen(&mut self, cfname: impl OptBytes) -> i32 {
        // If no calibration file is specified, use the default.
        let name: Vec<u8> = match cfname.opt_bytes() {
            Some(n) => cstd::cstr(n).to_vec(),
            None => cstd::getenv("WFDBCAL").unwrap_or_else(|| DEFWFDBCAL.to_vec()),
        };
        let mut cfname: &[u8] = &name;
        if cfname.first() == Some(&b'+') {
            // don't empty the calibration list
            cfname = &cfname[1..]; // discard the '+' prefix
        } else {
            self.flushcal(); // empty the calibration list
        }

        // Quit if file can't be found or opened.
        let Some(mut cfile) = self.wfdb_open(cfname, NULL, WFDB_READ) else {
            let msg = cformat!(b"calopen: can't read calibration file %s\n", cfname);
            self.wfdb_error(msg);
            return -2;
        };

        // Read a line of the calibration file on each iteration. See
        // wfdbcal(5) for a description of the format.
        let mut line = Vec::new();
        while cfile.getline(&mut line) > 0 {
            let buf = cstd::cstr(&line);
            // ignore leading whitespace
            let skip = buf
                .iter()
                .take_while(|&&c| c == b' ' || c == b'\t' || c == b'\r')
                .count();
            let buf = &buf[skip..];
            // skip comments, empty lines, and improperly formatted lines
            if buf.first() == Some(&b'#') {
                continue;
            }
            let mut tok = Strtok::new(buf);
            let (Some(p1), Some(p2), Some(p3), Some(p4), Some(p5), Some(p6)) = (
                tok.next(b"\t"),      // type
                tok.next(b" \t"),     // low
                tok.next(b" \t"),     // high
                tok.next(b" \t"),     // pulse
                tok.next(b" \t"),     // scale
                tok.next(b" \t\r\n"), // units
            ) else {
                continue;
            };

            let mut c = Calinfo::default();
            // "*" is a wildcard that matches any signal type.
            let p1: &[u8] = if p1 == b"*" { b"" } else { p1 };
            c.sigtype = Some(p1.to_vec());
            if p2 == b"-" {
                c.caltype = WFDB_AC_COUPLED;
                c.low = 0.0;
            } else {
                c.caltype = WFDB_DC_COUPLED;
                c.low = cstd::strtod(p2).0;
            }
            if p3 == b"-" {
                c.high = 0.0;
                c.low = 0.0;
            } else {
                c.high = cstd::strtod(p3).0;
            }
            match p4 {
                b"square" => c.caltype |= WFDB_CAL_SQUARE,
                b"sine" => c.caltype |= WFDB_CAL_SINE,
                b"sawtooth" => c.caltype |= WFDB_CAL_SAWTOOTH,
                _ => {} // otherwise pulse shape is undefined
            }
            c.scale = cstd::strtod(p5).0;
            c.units = Some(p6.to_vec());
            self.cal.list.push(c);
        }
        let _ = cfile.close();
        0
    }

    /// C `getcal(desc, units, &cal)`: find the first calibration list entry
    /// whose signal type is a prefix of `desc` and whose units are `units`
    /// (a `NULL` argument matches anything), and copy it into `cal`.
    /// Returns 0, or -1 if there is none.
    ///
    /// Translation of the C function getcal() (lib/calib.c, WFDB 10.7.0): same
    /// arguments and results.
    pub fn getcal(&mut self, desc: impl OptBytes, units: impl OptBytes, cal: &mut Calinfo) -> i32 {
        let desc = desc.opt_bytes().map(cstd::cstr);
        let units = units.opt_bytes().map(cstd::cstr);
        for c in &self.cal.list {
            let sigtype = c.sigtype.as_deref().unwrap_or(b"");
            let dmatch = match desc {
                None => true,
                Some(d) => d.starts_with(sigtype),
            };
            let umatch = match units {
                None => true,
                Some(u) => c.units.as_deref() == Some(u),
            };
            if dmatch && umatch {
                *cal = c.clone();
                return 0;
            }
        }
        -1
    }

    /// C `putcal(&cal)`: append an entry to the calibration list.
    ///
    /// Translation of the C function putcal() (lib/calib.c, WFDB 10.7.0): same
    /// arguments and results.
    pub fn putcal(&mut self, cal: &Calinfo) -> i32 {
        self.cal.list.push(cal.clone());
        0
    }

    /// C `newcal(cfname)`: write the calibration list to a calibration
    /// file. Returns 0, or -1 on errors.
    ///
    /// Translation of the C function newcal() (lib/calib.c, WFDB 10.7.0): same
    /// arguments and results.
    pub fn newcal(&mut self, cfname: impl AsRef<[u8]>) -> i32 {
        let cfname = cstd::cstr(cfname.as_ref());
        if self.wfdb_checkname(cfname, b"calibration file") < 0 {
            return -1;
        }
        let Some(mut cfile) = self.wfdb_open(cfname, NULL, WFDB_WRITE) else {
            let msg = cformat!(b"newcal: can't create calibration file %s\n", cfname);
            self.wfdb_error(msg);
            return -1;
        };

        for c in &self.cal.list {
            // If sigtype is an empty string (matches anything), write it as
            // "*".
            let sigtype = c.sigtype.as_deref().unwrap_or(b"");
            cfprintf!(
                cfile,
                b"%s\t",
                if sigtype.is_empty() { b"*" } else { sigtype }
            );
            if c.caltype & WFDB_DC_COUPLED != 0 {
                cfprintf!(cfile, b"%g ", c.low);
            } else {
                cfprintf!(cfile, b"- ");
            }
            if c.high != c.low {
                cfprintf!(cfile, b"%g ", c.high);
            } else {
                cfprintf!(cfile, b"- ");
            }
            let pulsetype: &[u8] = match c.caltype & !WFDB_DC_COUPLED {
                WFDB_CAL_SQUARE => b"square",
                WFDB_CAL_SINE => b"sine",
                WFDB_CAL_SAWTOOTH => b"sawtooth",
                _ => b"undefined",
            };
            let units: &[u8] = c.units.as_deref().unwrap_or(b"(null)");
            cfprintf!(cfile, b"%s %g %s\r\n", pulsetype, c.scale, units);
        }

        let mut errflag = cfile.error();
        if cfile.close() != 0 {
            errflag = true;
        }
        if errflag {
            self.wfdb_error("newcal: write error in calibration file\n");
            return -1;
        }
        0
    }

    /// C `flushcal()`: empty the calibration list.
    ///
    /// Translation of the C function flushcal() (lib/calib.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn flushcal(&mut self) {
        self.cal.list.clear();
    }
}

/// C `calopen` on the default instance (see [`Wfdb::calopen`]).
///
/// Translation of the C function calopen() (lib/calib.c, WFDB 10.7.0): same
/// arguments and results. Differences: the calibration file is found only
/// where it is named, not by a search of the WFDB path; see
/// docs/DIVERGENCES.md.
pub fn calopen(cfname: impl OptBytes) -> i32 {
    with_default(|w| w.calopen(cfname))
}

/// C `getcal` on the default instance (see [`Wfdb::getcal`]).
///
/// Translation of the C function getcal() (lib/calib.c, WFDB 10.7.0): same
/// arguments and results.
pub fn getcal(desc: impl OptBytes, units: impl OptBytes, cal: &mut Calinfo) -> i32 {
    with_default(|w| w.getcal(desc, units, cal))
}

/// C `putcal` on the default instance (see [`Wfdb::putcal`]).
///
/// Translation of the C function putcal() (lib/calib.c, WFDB 10.7.0): same
/// arguments and results.
pub fn putcal(cal: &Calinfo) -> i32 {
    with_default(|w| w.putcal(cal))
}

/// C `newcal` on the default instance (see [`Wfdb::newcal`]).
///
/// Translation of the C function newcal() (lib/calib.c, WFDB 10.7.0): same
/// arguments and results.
pub fn newcal(cfname: impl AsRef<[u8]>) -> i32 {
    with_default(|w| w.newcal(cfname))
}

/// C `flushcal` on the default instance (see [`Wfdb::flushcal`]).
///
/// Translation of the C function flushcal() (lib/calib.c, WFDB 10.7.0): same
/// arguments and results.
pub fn flushcal() {
    with_default(super::wfdb::Wfdb::flushcal);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn put_and_get() {
        let mut w = Wfdb::new();
        let c = Calinfo {
            low: 0.0,
            high: 1.0,
            scale: 1.0,
            sigtype: Some(b"ECG".to_vec()),
            units: Some(b"mV".to_vec()),
            caltype: WFDB_DC_COUPLED | WFDB_CAL_SQUARE,
        };
        w.putcal(&c);
        let mut out = Calinfo::default();
        assert_eq!(w.getcal("ECG lead II", "mV", &mut out), 0);
        assert_eq!(out, c);
        assert_eq!(w.getcal("ECG", "uV", &mut out), -1);
        assert_eq!(w.getcal(NULL, NULL, &mut out), 0);
        assert_eq!(w.getcal("BP", NULL, &mut out), -1);
        w.flushcal();
        assert_eq!(w.getcal(NULL, NULL, &mut out), -1);
    }
}
