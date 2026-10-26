//! # wfdb-x for Rust
//!
//! A reimplementation of the [WFDB Software Package](https://physionet.org/content/wfdb/)
//! (version 10.7.0, by George B. Moody and contributors) in Rust, with no
//! dependencies beyond the standard library. It reads and writes exactly
//! the same files as the original C library (headers, signal files in all
//! storage formats including FLAC, annotation files, calibration files),
//! and the command-line tools built with it produce byte-identical output
//! to the C tools.
//!
//! The crate offers two APIs:
//!
//! * a **high-level API** ([`read_record`], [`read_header`],
//!   [`read_annotations`], [`write_record`], [`write_record_physical`],
//!   [`write_annotations`]) that reads or writes a whole record or
//!   annotation file in one call and returns a [`Result`];
//! * the **C-style API**: every function of the C library, with its C name,
//!   arguments and status codes, for code that needs fine control (sample by
//!   sample reading, random access, multi-segment records, ...) or that is
//!   ported from C.
//!
//! ## Quick start
//!
//! ```no_run
//! use wfdbx::{read_record, ReadOptions, Siginfo, Wfdb};
//!
//! // High-level API: the first 10 seconds of record 100s, in one call.
//! let opt = ReadOptions { to: Some("0:10".into()), ..Default::default() };
//! let rec = read_record("100s", &opt)?;
//! println!("{} samples, first in physical units: {}", rec.nsamples(), rec.physical(0, 0)?);
//!
//! // C-style API: as in a C program (isigopen, getvec).
//! let mut w = Wfdb::new();
//! let mut si = vec![Siginfo::default(); 2];
//! let nsig = w.isigopen("100s", &mut si, 2);
//! let mut v = vec![0; nsig.max(0) as usize];
//! for _ in 0..10 {
//!     if w.getvec(&mut v) < 0 {
//!         break;
//!     }
//!     println!("{v:?}"); // one sample per signal, in ADC units
//! }
//! # Ok::<(), wfdbx::record::Error>(())
//! ```
//!
//! ## The C-style API: `Wfdb` or free functions
//!
//! All the state that the C library keeps in global variables (the input
//! directory or WFDB path, open signals and annotators, time base, ...) is
//! held by a [`Wfdb`] value; each C library function is a method with the C
//! name:
//!
//! ```
//! use wfdbx::Wfdb;
//! let mut w = Wfdb::new();
//! w.wfdbx_set_input_dir("/usr/local/database");
//! assert_eq!(w.getwfdb(), b"/usr/local/database");
//! ```
//!
//! Every method is also available as a free function with the same name
//! and arguments (`wfdbx::getwfdb()`, `wfdbx::isigopen(...)`), operating on
//! a thread-local default instance. The free functions are convenient for
//! line-by-line ports of C programs; prefer an explicit [`Wfdb`] in library
//! code, or when several records must be open at the same time
//! independently (instances do not share state, and a `Wfdb` can be moved
//! to another thread). See [`wfdb`] for details.
//!
//! As in C, functions report errors by their return value (a negative
//! status code, or `None` where C returns a `NULL` pointer; each function
//! documents its codes) and print an error message on the standard error
//! unless [`wfdbquiet`] has been called; [`wfdberror`] returns the last
//! message.
//!
//! ## Conventions
//!
//! * Strings are byte strings: arguments are `&[u8]`-like (`"100s"` and
//!   `b"100s"` both work where an [`OptBytes`] or `AsRef<[u8]>` is taken),
//!   results are `Vec<u8>`. C's `NULL` is `None` ([`NULL`] for arguments).
//! * Integer types follow the C reference platform (x86-64 Linux):
//!   `int` is `i32`, `long` and `WFDB_Time` are `i64`, `char` is `i8`.
//! * Structures ([`Siginfo`], [`Calinfo`], [`Anninfo`], [`Annotation`],
//!   [`Seginfo`]) have the C field names; `Default` gives C's zero values.
//! * Functions that fill an array supplied by the caller take a mutable
//!   slice (`isigopen(record, &mut si, nsig)`, `getvec(&mut v)`); an empty
//!   slice stands for C's `NULL`.
//! * Files are found where they are named (wfdb-x): a relative name is read
//!   under the input directory ([`wfdbx_set_input_dir`], `WFDBX_INPUT_DIR`)
//!   and written under the output directory ([`wfdbx_set_output_dir`],
//!   `WFDBX_OUTPUT_DIR`), by default the current directory; an absolute
//!   name, a `~` name or a URL is used as given (a URL only with network
//!   access, [`wfdbx_set_network`]); nothing is searched. Legacy mode
//!   searches the WFDB path (the `WFDB` environment variable, or
//!   [`setwfdb`]), without network access.
//! * Formatted output uses [`cstd`]'s glibc-exact `printf`
//!   ([`cformat!`], [`cprintf!`]).
//!
//! ## Modules
//!
//! | module | contents |
//! |---|---|
//! | [`cstd`] | C standard library emulation (printf, strtol, strtod, sscanf, rand, stdio) |
//! | [`wfdbio`] | finding files (input/output directories, network, WFDB path), `wfdb_open`, errors, [`WfdbFile`] (port of `lib/wfdbio.c`) |
//! | [`signal`] | signals and headers (port of `lib/signal.c`) |
//! | [`annot`] | annotations (port of `lib/annot.c`) |
//! | [`calib`] | calibration list (port of `lib/calib.c`) |
//! | [`wfdbinit`](mod@wfdbinit) | `wfdbinit`, `wfdbquit`, `wfdbflush` |
//! | [`ecgcodes`] | annotation codes and `<ecgmap.h>` functions |
//! | [`types`] | types, constants and structures of `<wfdb/wfdb.h>` |
//! | [`record`] | high-level API ([`read_record`], [`read_header`], [`read_annotations`], [`write_record`], [`write_record_physical`], [`write_annotations`]) |
//!
//! The public items of the library modules are re-exported at the crate
//! root (those of [`record`], except its `Error` type, too).
//
// See docs/AUTHORS.md for the authors of the original C code (WFDB Software
// Package 10.7.0).
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

#![warn(missing_docs)]

pub mod cstd;

pub mod annot;
pub mod calib;
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
pub use ecgcodes::*;
pub use record::{
    read_annotations, read_annotations_with, read_header, read_header_with, read_record,
    write_annotations, write_record, write_record_physical, Annotations, ReadOptions, Record,
    TimeSpec, WriteOptions,
};
pub use signal::*;
pub use types::*;
pub use wfdb::*;
pub use wfdbinit::*;
pub use wfdbio::*;
