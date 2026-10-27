//! # wfdb-x for Rust
//!
//! The `wfdbx` crate reads and writes physiological signal records in the
//! WFDB format used by [PhysioNet](https://physionet.org). It is a complete
//! Rust implementation of the WFDB Software Package 10.7.0: the library and
//! all of its command-line tools. It reads and writes the same files as the
//! original C library, and its tools print the same output.
//!
//! You can use it in three ways:
//!
//! * **High-level functions** that read and write whole records and
//!   annotation files in one call: [`read_record`], [`read_header`],
//!   [`read_annotations`], [`write_record`], [`write_record_physical`],
//!   [`write_annotations`]. They return a [`Result`] whose error type is
//!   [`record::Error`]. [`check_record`] checks a record and reports every
//!   problem it finds.
//! * **Command-line tools** such as `rdsamp`, `rdann` and `wrsamp`, each a
//!   separate program of this crate.
//! * **The WFDB library functions** under their C names ([`isigopen`],
//!   [`getvec`], [`getann`], ...), for programs written against the C
//!   library.
//!
//! ## Quick start
//!
//! This program reads the sample record `100s`, the first minute of record
//! 100 of the MIT-BIH Arrhythmia Database, which is included with wfdb-x in
//! the `tests/data` directory of a copy of the repository. Run it from the
//! root of the repository, or change the input directory in its first line.
//!
//! ```
//! use wfdbx::{read_annotations, read_header, read_record, ReadOptions};
//!
//! # wfdbx::wfdbx_set_input_dir("../tests/data");
//! # /*
//! wfdbx::wfdbx_set_input_dir("tests/data");
//! # */
//! let rec = read_record("100s", &ReadOptions::default())?; // signals in ADC units
//! assert_eq!((rec.fs, rec.nsig, rec.nsamples()), (360.0, 2, 21600));
//! let mlii = rec.physical_signal(0)?; // signal 0 in physical units
//!
//! let hdr = read_header("100s", false)?; // the header only, no samples
//! assert_eq!(hdr.nsamples, 21600);
//!
//! let ann = read_annotations("100s", "atr", None, None, None, false)?;
//! assert_eq!(ann.len(), 75);
//! # let _ = mlii;
//! # Ok::<(), wfdbx::record::Error>(())
//! ```
//!
//! ## Where files are read and written
//!
//! A full path, a `~` path or a URL is used as given. Any other name is read
//! from the input directory ([`wfdbx_set_input_dir`], `WFDBX_INPUT_DIR`) and
//! written to the output directory ([`wfdbx_set_output_dir`],
//! `WFDBX_OUTPUT_DIR`). Both are the current directory unless you set them.
//! A URL is opened only when network access is on ([`wfdbx_set_network`],
//! `WFDBX_NETWORK=1`).
//!
//! ## The WFDB library functions
//!
//! The library's state, such as the open record and annotators, is held by
//! a [`Wfdb`] value. Each C library function is a method of it, with the C
//! name. This example reads the sample record `100s` (see the quick start)
//! from the `tests/data` directory of a copy of the repository:
//!
//! ```
//! use wfdbx::{Siginfo, Wfdb};
//!
//! let mut w = Wfdb::new();
//! # w.wfdbx_set_input_dir("../tests/data");
//! # /*
//! w.wfdbx_set_input_dir("tests/data"); // from the repository root
//! # */
//! let mut si = vec![Siginfo::default(); 2];
//! let nsig = w.isigopen("100s", &mut si, 2); // open 2 signals
//! let mut v = vec![0; nsig.max(0) as usize];
//! while w.getvec(&mut v) > 0 {
//!     // v holds one sample per signal, in ADC units
//! }
//! w.wfdbquit();
//! ```
//!
//! Every method is also a free function with the same name and arguments,
//! such as `wfdbx::isigopen(...)`. The free functions use a default [`Wfdb`]
//! value, one per thread. Separate [`Wfdb`] values do not share any state.
//!
//! Differences from C that come from the language:
//!
//! * Strings are bytes. Arguments accept `&str`, `&[u8]` or `b"..."`, and
//!   results are `Vec<u8>`. C's `NULL` is `None`; pass [`NULL`] for a `NULL`
//!   argument.
//! * C's `int` is `i32`, `long` and `WFDB_Time` are `i64`, `WFDB_Sample` is
//!   `i32`, and `char` is `i8`.
//! * The structures ([`Siginfo`], [`Calinfo`], [`Anninfo`], [`Annotation`],
//!   [`Seginfo`]) have the C field names. `Default::default()` gives C's
//!   zero values.
//! * Where a C function fills an array, the Rust function fills a slice that
//!   you pass. An empty slice stands for C's `NULL`.
//! * Errors are reported by return values, as in C. [`wfdberror`] returns
//!   the last message, and [`wfdbquiet`] stops the messages from being
//!   printed.
//!
//! ## Modules
//!
//! | module | contents |
//! |---|---|
//! | [`record`] | the high-level functions and their types |
//! | [`signal`] | signals and headers |
//! | [`annot`] | annotations |
//! | [`calib`] | the calibration list |
//! | [`check`] | [`check_record`]: checking a record |
//! | [`wfdbio`] | file names, the input and output directories, network access, error messages, [`WfdbFile`] |
//! | [`wfdbinit`](mod@wfdbinit) | `wfdbinit`, `wfdbquit`, `wfdbflush` |
//! | [`ecgcodes`] | annotation codes and the `<ecgmap.h>` functions |
//! | [`types`] | the types, constants and structures of `<wfdb/wfdb.h>` |
//! | [`wfdb`] | the [`Wfdb`] type |
//! | [`cstd`] | the C standard functions that the tools use, such as a `printf` that formats numbers exactly as the GNU C library does |
//!
//! The public items of these modules are also available at the crate root,
//! except [`record::Error`].
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

#![warn(missing_docs)]

pub mod cstd;

pub mod annot;
pub mod calib;
pub mod check;
pub mod ecgcodes;
pub(crate) mod flac;
pub mod record;
pub mod signal;
pub mod types;
pub mod wfdb;
pub mod wfdbinit;
pub mod wfdbio;

pub use annot::*;
pub use calib::*;
pub use check::{check_record, check_record_with, CheckReport, Issue, Severity};
pub use ecgcodes::*;
pub use record::{
    read_annotations, read_annotations_with, read_header, read_header_with, read_record,
    write_annotations, write_annotations_with, write_record, write_record_physical,
    AnnWriteOptions, Annotations, Header, ReadOptions, Record, TimeSpec, WriteOptions,
};
pub use signal::*;
pub use types::*;
pub use wfdb::*;
pub use wfdbinit::*;
pub use wfdbio::*;
