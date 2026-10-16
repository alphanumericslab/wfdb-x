//! Port of `lib/wfdbinit.c`: `wfdbinit`, `wfdbquit`, `wfdbflush`.
//
// Copyright (C) 1983-2012 George B. Moody (original C implementation,
// lib/wfdbinit.c; revised 2012-2019 by Benjamin Moody).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

use crate::types::{Anninfo, Siginfo};
use crate::wfdb::{with_default, OptBytes, Wfdb};

impl Wfdb {
    /// C `wfdbinit(record, aiarray, nann, siarray, nsig)`: open the
    /// annotation files (`annopen`) and then the input signals
    /// (`isigopen`) of `record`. Returns the status of `annopen` if it
    /// failed, otherwise that of `isigopen`.
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
    /// restore the WFDB path, and release the library's buffers.
    pub fn wfdbquit(&mut self) {
        self.wfdb_anclose(); // close annotation files, reset variables
        self.wfdb_oinfoclose(); // close info file
        self.wfdb_sigclose(); // close signals, reset variables
        self.resetwfdb(); // restore the WFDB path
        self.wfdb_sampquit(); // release sample data buffer
        self.wfdb_freeinfo(); // release info strings
    }

    /// C `wfdbflush()`: write out buffered output annotations and samples.
    pub fn wfdbflush(&mut self) {
        self.wfdb_oaflush(); // flush buffered output annotations
        self.wfdb_osflush(); // flush buffered output samples
    }
}

/// C `wfdbinit` on the default instance (see [`Wfdb::wfdbinit`]).
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
pub fn wfdbquit() {
    with_default(super::wfdb::Wfdb::wfdbquit);
}

/// C `wfdbflush()` on the default instance (see [`Wfdb::wfdbflush`]).
pub fn wfdbflush() {
    with_default(super::wfdb::Wfdb::wfdbflush);
}
