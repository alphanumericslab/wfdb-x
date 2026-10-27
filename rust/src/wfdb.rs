//! The library object [`Wfdb`], which holds all the state of the C library,
//! and the thread-local default instance used by the free functions.
//!
//! # Organization
//!
//! Each C library function is a method of [`Wfdb`] with the C name, defined
//! in the module that ports the corresponding C source file
//! (`impl Wfdb { ... }` blocks in `wfdbio.rs`, `signal.rs`, `annot.rs`,
//! `calib.rs`, `wfdbinit.rs`, `ecgcodes.rs`). The state of each C source
//! file is a sub-structure of `Wfdb` defined in that module:
//!
//! | field | type | module |
//! |---|---|---|
//! | `io` | `IoState` | `wfdbio.rs` (input/output directories, network access, WFDB path, errors, current record name) |
//! | `sig` | `SigState` | `signal.rs` (headers, signals, time base, info) |
//! | `ann` | `AnnState` | `annot.rs` (annotators, mnemonic tables) |
//! | `cal` | `CalState` | `calib.rs` (calibration list) |
//! | `maps` | `EcgMaps` | `ecgcodes.rs` (`<ecgmap.h>` tables) |
//!
//! Every C function is also a free function with the same name (in the
//! module that defines it, re-exported at the crate root) operating on the
//! default instance:
//!
//! ```
//! # use wfdbx::*;
//! setwfdb(".");                        // free function: default instance
//! let mut w = Wfdb::new();             // an independent instance
//! w.setwfdb(".");
//! assert_eq!(w.getwfdb(), b".");
//! ```
//!
//! Each free function borrows the default instance for the duration of
//! the call (`with_default(|w| w.f(...))`). Do not call a free function
//! from inside a closure passed to [`with_default`]: the default instance
//! would be borrowed twice, which panics.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

use std::cell::RefCell;

use crate::annot::AnnState;
use crate::calib::CalState;
use crate::ecgcodes::EcgMaps;
use crate::signal::SigState;
use crate::wfdbio::IoState;

/// The state of the WFDB library: what the C library keeps in global
/// variables (the WFDB path, open records, signals, annotators,
/// calibration list, ...).
///
/// Each C library function is a method of `Wfdb` with the C name and
/// arguments. Several independent instances may be used at once, each with
/// its own state (unlike the C library, where there is only one); `Wfdb`
/// is `Send`, so an instance can be moved to another thread.
///
/// The same functions are also available as free functions that use a
/// thread-local default instance (see [`with_default`]); use them for
/// line-by-line ports of C programs, and an explicit `Wfdb` otherwise.
///
/// # Examples
///
/// ```
/// use wfdbx::{Siginfo, Wfdb};
///
/// let mut w = Wfdb::new();
/// // The sample record 100s, the first minute of record 100 of the MIT-BIH
/// // Arrhythmia Database, included with wfdb-x in tests/data:
/// # w.wfdbx_set_input_dir("../tests/data");
/// # /*
/// w.wfdbx_set_input_dir("tests/data"); // from the repository root
/// # */
/// let mut si = vec![Siginfo::default(); 2];
/// if w.isigopen("100s", &mut si, 2) == 2 {
///     let mut v = [0i32; 2];
///     while w.getvec(&mut v) > 0 {
///         // v holds one sample (in ADC units) of each signal
///     }
/// }
/// w.wfdbquit(); // close the record
/// ```
///
/// Dropping a `Wfdb` drops its open files: their buffered output is
/// written out (as C's `exit` flushes every stream), but nothing else is
/// done (no annotation end markers, no header updates): call
/// [`Wfdb::wfdbquit`] first to close records properly.
#[derive(Default)]
pub struct Wfdb {
    /// I/O state (wfdbio.rs).
    pub(crate) io: IoState,
    /// Signal state (signal.rs).
    pub(crate) sig: SigState,
    /// Annotation state (annot.rs).
    pub(crate) ann: AnnState,
    /// Calibration state (calib.rs).
    pub(crate) cal: CalState,
    /// `<ecgmap.h>` tables (ecgcodes.rs).
    pub(crate) maps: EcgMaps,
}

impl Wfdb {
    /// Creates a new library state, as at the start of a C program (no open
    /// records; the settings that locate files, wfdb-x: `WFDBX_INPUT_DIR`,
    /// `WFDBX_OUTPUT_DIR`, `WFDBX_NETWORK`, or in legacy mode the WFDB path,
    /// are read from the environment on first use).
    ///
    /// Part of wfdb-x; not in the original WFDB package.
    pub fn new() -> Wfdb {
        Wfdb::default()
    }
}

thread_local! {
    static DEFAULT: RefCell<Wfdb> = RefCell::new(Wfdb::new());
}

/// Runs `f` with the default instance, the thread-local [`Wfdb`] used by
/// the free functions, and returns its result.
///
/// This gives access to the default instance as a `&mut Wfdb`, for
/// example to call several methods without borrowing it each time.
///
/// # Panics
///
/// If called while the default instance is already borrowed: from inside
/// `f` itself, either by a nested `with_default` call or by calling one of
/// the free functions.
///
/// # Examples
///
/// ```
/// wfdbx::setwfdb(".");
/// let path = wfdbx::with_default(|w| w.getwfdb());
/// assert_eq!(path, b".");
/// ```
///
/// Part of wfdb-x; not in the original WFDB package.
pub fn with_default<R>(f: impl FnOnce(&mut Wfdb) -> R) -> R {
    DEFAULT.with(|d| f(&mut d.borrow_mut()))
}

/// Is legacy mode on in the default instance (false if it is in use)?
/// Used by [`crate::cstd::exit`].
pub(crate) fn default_legacy() -> bool {
    DEFAULT
        .try_with(|d| d.try_borrow().is_ok_and(|w| w.wfdbx_get_legacy() != 0))
        .unwrap_or(false)
}

/// Drop the default instance (flushing its open output files), if it is
/// not in use. Called by [`crate::cstd::exit`].
pub(crate) fn release_default_at_exit() {
    let _ = DEFAULT.try_with(|d| {
        if let Ok(mut w) = d.try_borrow_mut() {
            let old = std::mem::take(&mut *w);
            drop(old);
        }
    });
}

/// A string argument that may be C's `NULL`.
///
/// Implemented for `&str`, `&[u8]`, `&[u8; N]`, `&Vec<u8>`, `&String`
/// (never `NULL`) and for `Option`s of these (`None` is `NULL`); [`NULL`]
/// is a typed `None`.
pub trait OptBytes {
    /// The bytes, or `None` for `NULL`.
    fn opt_bytes(&self) -> Option<&[u8]>;
}

/// C's `NULL` string, for arguments of type `impl OptBytes`.
pub const NULL: Option<&'static [u8]> = None;

impl OptBytes for &str {
    fn opt_bytes(&self) -> Option<&[u8]> {
        Some(self.as_bytes())
    }
}
impl OptBytes for &String {
    fn opt_bytes(&self) -> Option<&[u8]> {
        Some(self.as_bytes())
    }
}
impl OptBytes for &[u8] {
    fn opt_bytes(&self) -> Option<&[u8]> {
        Some(self)
    }
}
impl<const N: usize> OptBytes for &[u8; N] {
    fn opt_bytes(&self) -> Option<&[u8]> {
        Some(&self[..])
    }
}
impl OptBytes for &Vec<u8> {
    fn opt_bytes(&self) -> Option<&[u8]> {
        Some(self.as_slice())
    }
}
impl OptBytes for Option<&[u8]> {
    fn opt_bytes(&self) -> Option<&[u8]> {
        *self
    }
}
impl OptBytes for Option<&str> {
    fn opt_bytes(&self) -> Option<&[u8]> {
        self.map(str::as_bytes)
    }
}
impl OptBytes for Option<&Vec<u8>> {
    fn opt_bytes(&self) -> Option<&[u8]> {
        self.map(std::vec::Vec::as_slice)
    }
}
impl OptBytes for &Option<Vec<u8>> {
    fn opt_bytes(&self) -> Option<&[u8]> {
        self.as_deref()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wfdb_is_send() {
        fn assert_send<T: Send>() {}
        assert_send::<Wfdb>();
    }

    #[test]
    fn independent_instances() {
        let mut a = Wfdb::new();
        let mut b = Wfdb::new();
        a.wfdb_setirec(b"rec_a");
        assert_eq!(b.wfdb_getirec(), None);
        b.wfdbquiet();
        b.wfdb_error("x\n");
        assert_eq!(b.wfdberror(), b"x\n");
        assert_ne!(a.wfdberror(), b"x\n");
    }
}
