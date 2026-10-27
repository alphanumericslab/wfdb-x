//! Port of `lib/wfdbinit.c`: `wfdbinit`, `wfdbquit`, `wfdbflush`.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of lib/wfdbinit.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: wfdbquit leaves the input and output directories
// as they are (the original restored the WFDB path); legacy mode
// (wfdbx_set_legacy) restores the original behavior. Each change is marked
// "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C code: lib/wfdbinit.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2012 George B. Moody; revised 2012-2019 by
//   Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use crate::types::{Anninfo, Siginfo};
use crate::wfdb::{with_default, OptBytes, Wfdb};

impl Wfdb {
    /// C `wfdbinit(record, aiarray, nann, siarray, nsig)`: open the
    /// annotation files (`annopen`) and then the input signals
    /// (`isigopen`) of `record`. Returns the status of `annopen` if it
    /// failed, otherwise that of `isigopen`.
    ///
    /// Translation of the C function wfdbinit() (lib/wfdbinit.c, WFDB 10.7.0):
    /// same arguments and results. Differences: those of annopen() and
    /// isigopen(); see docs/DIVERGENCES.md.
    pub fn wfdbinit(
        &mut self,
        record: impl OptBytes,
        aiarray: &[Anninfo],
        nann: u32,
        siarray: &mut [Siginfo],
        nsig: u32,
    ) -> i32 {
        let record = record.opt_bytes();
        let mut stat = self.annopen(record, aiarray, nann);
        if stat == 0 {
            stat = self.isigopen(record, siarray, nsig as i32);
        }
        stat
    }

    /// C `wfdbquit()`: close all annotators, signals and the info file,
    /// restore the WFDB path (legacy mode only; wfdb-x: the input directory
    /// is kept), and release the library's buffers.
    ///
    /// Translation of the C function wfdbquit() (lib/wfdbinit.c, WFDB 10.7.0):
    /// same arguments and results. Differences: the input and output
    /// directories are kept (the WFDB path is restored only in legacy mode);
    /// see docs/DIVERGENCES.md.
    pub fn wfdbquit(&mut self) {
        self.wfdb_anclose(); // close annotation files, reset variables
        self.wfdb_oinfoclose(); // close info file
        self.wfdb_sigclose(); // close signals, reset variables
                              // wfdb-x: in normal mode, the input directory is left as it is (in
                              // the C library, resetwfdb restored the string returned by getwfdb,
                              // but not the list of directories searched)
        if self.wfdbx_get_legacy() != 0 {
            self.resetwfdb(); // restore the WFDB path
        }
        self.wfdb_sampquit(); // release sample data buffer
        self.wfdb_freeinfo(); // release info strings
    }

    /// C `wfdbflush()`: write out buffered output annotations and samples.
    ///
    /// Translation of the C function wfdbflush() (lib/wfdbinit.c, WFDB 10.7.0):
    /// same arguments and results.
    pub fn wfdbflush(&mut self) {
        self.wfdb_oaflush(); // flush buffered output annotations
        self.wfdb_osflush(); // flush buffered output samples
    }
}

/// C `wfdbinit` on the default instance (see [`Wfdb::wfdbinit`]).
///
/// Translation of the C function wfdbinit() (lib/wfdbinit.c, WFDB 10.7.0):
/// same arguments and results. Differences: those of annopen() and isigopen();
/// see docs/DIVERGENCES.md.
pub fn wfdbinit(
    record: impl OptBytes,
    aiarray: &[Anninfo],
    nann: u32,
    siarray: &mut [Siginfo],
    nsig: u32,
) -> i32 {
    with_default(|w| w.wfdbinit(record, aiarray, nann, siarray, nsig))
}

/// C `wfdbquit()` on the default instance (see [`Wfdb::wfdbquit`]).
///
/// Translation of the C function wfdbquit() (lib/wfdbinit.c, WFDB 10.7.0):
/// same arguments and results. Differences: the input and output directories
/// are kept (the WFDB path is restored only in legacy mode); see
/// docs/DIVERGENCES.md.
pub fn wfdbquit() {
    with_default(super::wfdb::Wfdb::wfdbquit);
}

/// C `wfdbflush()` on the default instance (see [`Wfdb::wfdbflush`]).
///
/// Translation of the C function wfdbflush() (lib/wfdbinit.c, WFDB 10.7.0):
/// same arguments and results.
pub fn wfdbflush() {
    with_default(super::wfdb::Wfdb::wfdbflush);
}
