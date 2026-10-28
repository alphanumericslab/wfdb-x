//! Types, constants and structures of the WFDB library API (`<wfdb/wfdb.h>`).
//!
//! The structures have the C field names; `Default` gives C's zero values.
//! Strings are byte strings; a field that C may set to `NULL` is an
//! `Option<Vec<u8>>`.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a Rust translation of lib/wfdb.h from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: WFDB_DEFFREQ, WFDB_DEFGAIN and WFDB_DEFRES remain
// defined but are used only in legacy mode, and missing units are never taken
// to be millivolts. Each change is marked "WFDB-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C code: lib/wfdb.h, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2013 George B. Moody; revised 2010-2020 by
//   Benjamin Moody.
// Rust translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

/// Version of the WFDB Software Package implemented (major).
pub const WFDB_MAJOR: i32 = 10;
/// Version (minor).
pub const WFDB_MINOR: i32 = 7;
/// Version (release).
pub const WFDB_RELEASE: i32 = 0;

/// A sample value (units are adus).
pub type WfdbSample = i32;
/// A time (units are sample intervals; 64 bits, as `-DWFDB_LARGETIME`).
pub type WfdbTime = i64;
/// A date (units are days).
pub type WfdbDate = i64;
/// A frequency (Hz).
pub type WfdbFrequency = f64;
/// A gain (adus per physical unit).
pub type WfdbGain = f64;
/// A signal group number.
pub type WfdbGroup = u32;
/// A signal number.
pub type WfdbSignal = u32;
/// An annotator number.
pub type WfdbAnnotator = u32;

/// Smallest sample value.
pub const WFDB_SAMPLE_MIN: i32 = i32::MIN;
/// Largest sample value.
pub const WFDB_SAMPLE_MAX: i32 = i32::MAX;
/// Smallest time.
pub const WFDB_TIME_MIN: i64 = i64::MIN;
/// Largest time.
pub const WFDB_TIME_MAX: i64 = i64::MAX;

/// Value returned by `getvec` and `getframe` for invalid samples (unless
/// padding is enabled; see [`WFDB_GVPAD`]).
pub const WFDB_INVALID_SAMPLE: i32 = -32768;

/// Historical limit: annotators.
pub const WFDB_MAXANN: i32 = 2;
/// Historical limit: signals.
pub const WFDB_MAXSIG: i32 = 32;
/// Historical limit: samples per signal per frame.
pub const WFDB_MAXSPF: i32 = 4;
/// Maximum length of a record name.
pub const WFDB_MAXRNL: usize = 50;
/// Maximum length of a units string.
pub const WFDB_MAXUSL: usize = 50;
/// Maximum length of a signal description.
pub const WFDB_MAXDSL: usize = 100;

/// Standard input annotation file.
pub const WFDB_READ: i32 = 0;
/// Standard output annotation file.
pub const WFDB_WRITE: i32 = 1;
/// AHA-format input annotation file.
pub const WFDB_AHA_READ: i32 = 2;
/// AHA-format output annotation file.
pub const WFDB_AHA_WRITE: i32 = 3;
/// For output info files (open in append mode).
pub const WFDB_APPEND: i32 = 4;

/// Signal storage formats.
pub const WFDB_FMT_LIST: [i32; 14] = [0, 8, 16, 61, 80, 160, 212, 310, 311, 24, 32, 508, 516, 524];
/// Number of signal storage formats.
pub const WFDB_NFMTS: i32 = 14;

/// Default sampling frequency (Hz) of the C library.
///
/// WFDB-x: used only in legacy mode (see `Wfdb::wfdbx_set_legacy`): there
/// is no default sampling frequency (see `docs/DIVERGENCES.md`).
pub const WFDB_DEFFREQ: f64 = 250.0;
/// Default gain (adu/physical unit) of the C library.
///
/// WFDB-x: used only in legacy mode (see `Wfdb::wfdbx_set_legacy`): there
/// is no default gain (see `docs/DIVERGENCES.md`).
pub const WFDB_DEFGAIN: f64 = 200.0;
/// Default ADC resolution (bits) of the C library.
///
/// WFDB-x: used only in legacy mode (see `Wfdb::wfdbx_set_legacy`): there
/// is no default ADC resolution (see `docs/DIVERGENCES.md`).
pub const WFDB_DEFRES: i32 = 12;

/// getvec mode: one sample per signal per frame.
pub const WFDB_LOWRES: i32 = 0;
/// getvec mode: each sample of oversampled signals.
pub const WFDB_HIGHRES: i32 = 1;
/// getvec mode flag: replace invalid samples.
pub const WFDB_GVPAD: i32 = 2;

/// Calibration pulse type: AC coupled.
pub const WFDB_AC_COUPLED: i32 = 0;
/// DC coupled.
pub const WFDB_DC_COUPLED: i32 = 1;
/// Square wave.
pub const WFDB_CAL_SQUARE: i32 = 2;
/// Sine wave.
pub const WFDB_CAL_SINE: i32 = 4;
/// Sawtooth wave.
pub const WFDB_CAL_SAWTOOTH: i32 = 6;
/// Undefined pulse shape.
pub const WFDB_CAL_UNDEF: i32 = 8;

/// Default WFDB path, used when the `WFDB` environment variable is not set
/// (the value of a release build of the C library 10.7.0 installed in
/// `/usr/local`; its URL component is ignored, since remote files are not
/// supported).
pub const DEFWFDB: &[u8] = b". /usr/local/database http://physionet.org/physiobank/database";
/// Default calibration file name.
pub const DEFWFDBCAL: &[u8] = b"wfdbcal";
/// Default value of `WFDBANNSORT` (sort out-of-order annotations).
pub const DEFWFDBANNSORT: i32 = 1;
/// Default getvec mode (`WFDBGVMODE`).
pub const DEFWFDBGVMODE: i32 = WFDB_LOWRES;

/// Path component type: a local directory.
pub const WFDB_LOCAL: i32 = 0;
/// Path component type: a URL (remote files are not supported; such
/// components of the WFDB path are skipped).
pub const WFDB_NET: i32 = 1;

/// Signal information (C `WFDB_Siginfo`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Siginfo {
    /// Name of the signal file.
    pub fname: Option<Vec<u8>>,
    /// Signal description.
    pub desc: Option<Vec<u8>>,
    /// Physical units (`None`: not specified; WFDB-x: never assumed to be
    /// mV).
    pub units: Option<Vec<u8>>,
    /// Gain (adu/physical unit; 0: uncalibrated).
    pub gain: f64,
    /// Initial value (that of sample number 0).
    pub initval: i32,
    /// Signal group number.
    pub group: u32,
    /// Storage format (8, 16, etc.).
    pub fmt: i32,
    /// Samples per frame (>1: oversampled).
    pub spf: i32,
    /// Block size (for character special files).
    pub bsize: i32,
    /// ADC resolution in bits (0: not specified).
    pub adcres: i32,
    /// ADC output given 0 VDC input.
    pub adczero: i32,
    /// ADC output given 0 physical units input.
    pub baseline: i32,
    /// Number of samples (0: unspecified).
    pub nsamp: i64,
    /// 16-bit checksum of all samples.
    pub cksum: i32,
}

/// Calibration information (C `WFDB_Calinfo`).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Calinfo {
    /// Low level of calibration pulse.
    pub low: f64,
    /// High level of calibration pulse.
    pub high: f64,
    /// Customary plotting scale (units per cm).
    pub scale: f64,
    /// Signal type.
    pub sigtype: Option<Vec<u8>>,
    /// Physical units.
    pub units: Option<Vec<u8>>,
    /// Calibration pulse type.
    pub caltype: i32,
}

/// Annotator information (C `WFDB_Anninfo`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Anninfo {
    /// Annotator name.
    pub name: Vec<u8>,
    /// [`WFDB_READ`], [`WFDB_WRITE`], ...
    pub stat: i32,
}

/// An annotation (C `WFDB_Annotation`).
///
/// As in C, `aux` is either absent (`NULL`) or holds the auxiliary
/// information *preceded by a byte that gives its length* (`aux[0]` is the
/// length, the data follow).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Annotation {
    /// Time, in sample intervals from the start of the record.
    pub time: i64,
    /// Annotation type (see [`crate::ecgcodes`]); C `char` (signed).
    pub anntyp: i8,
    /// Annotation subtype (C `signed char`).
    pub subtyp: i8,
    /// Channel number (C `unsigned char`).
    pub chan: u8,
    /// Annotator number (C `signed char`).
    pub num: i8,
    /// Auxiliary information (length byte first), or `None`.
    pub aux: Option<Vec<u8>>,
}

/// A segment of a multi-segment record (C `WFDB_Seginfo`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Seginfo {
    /// Segment (record) name (at most [`WFDB_MAXRNL`] bytes).
    pub recname: Vec<u8>,
    /// Number of samples in the segment.
    pub nsamp: i64,
    /// Sample number of the first sample of the segment.
    pub samp0: i64,
}
