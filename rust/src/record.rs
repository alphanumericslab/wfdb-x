//! The high-level functions: read and write whole records and annotation
//! files in one call.
//!
//! | Function | What it does |
//! |---|---|
//! | [`read_record`] | reads the signals of a record into a [`Record`] |
//! | [`read_header`], [`read_header_with`] | reads the header of a record into a [`Header`] |
//! | [`read_annotations`], [`read_annotations_with`] | reads an annotation file into an [`Annotations`] value |
//! | [`write_record`], [`write_record_physical`] | writes a record from samples in ADC units or in physical units |
//! | [`write_annotations`], [`write_annotations_with`] | writes an annotation file |
//!
//! Each function returns a [`Result`] whose error type is [`Error`]. Each is
//! a free function, which uses the default [`Wfdb`] value of the thread,
//! and a method of [`Wfdb`]. A call closes the records and annotators open
//! in the [`Wfdb`] value it uses.
//!
//! Text read from files, such as signal descriptions, units and annotation
//! mnemonics, is given as bytes (`Vec<u8>`). You can set a `Vec<u8>` field
//! from a `&str` with `.into()`.
//!
//! ```
//! use wfdbx::record::{read_annotations, read_record, ReadOptions};
//!
//! // The sample record 100s, the first minute of record 100 of the MIT-BIH
//! // Arrhythmia Database, included with wfdb-x in tests/data:
//! # wfdbx::wfdbx_set_input_dir("../tests/data");
//! # /*
//! wfdbx::wfdbx_set_input_dir("tests/data"); // from the repository root
//! # */
//! let opt = ReadOptions { to: Some("0:10".into()), ..Default::default() };
//! let rec = read_record("100s", &opt)?;          // the first 10 seconds
//! let v = rec.physical(0, 1)?;                  // sample 0 of signal 1, in physical units
//! let ann = read_annotations("100s", "atr", None, None, None, false)?;
//! for i in 0..ann.len() {
//!     println!("{} {}", ann.samples[i], String::from_utf8_lossy(&ann.symbols[i]));
//! }
//! # let _ = v;
//! # Ok::<(), wfdbx::record::Error>(())
//! ```
//!
//! # Signal parameters
//!
//! These functions never assume a sampling frequency, gain, ADC resolution
//! or units that a record does not give. [`write_record`] needs the gains,
//! the ADC resolutions and the units of the calibrated signals. A record
//! whose header gives no frequency is read with `fs` 0, a signal without an
//! ADC resolution has `adcres` 0, and a signal without units has `units`
//! `None`. An operation that needs a missing value returns an [`Error`].
//! See `docs/DIVERGENCES.md` in the repository.
//!
//! # Input and output directories
//!
//! [`ReadOptions::input_dir`] and [`ReadOptions::network`] set the input
//! directory and network access for one call. [`WriteOptions::dir`] and
//! [`AnnWriteOptions::dir`] set the output directory for one call. See
//! [`Wfdb::wfdbx_set_input_dir`], [`Wfdb::wfdbx_set_network`] and
//! [`Wfdb::wfdbx_set_output_dir`].
//!
//! # Legacy mode
//!
//! [`ReadOptions::legacy`], [`WriteOptions::legacy`] and the `legacy`
//! argument of [`read_header`] and [`read_annotations`] make a call behave
//! as the original WFDB package, including its assumed signal parameters.
//! Use legacy mode only to reproduce old results. See
//! [`Wfdb::wfdbx_set_legacy`].
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

use std::path::{Path, PathBuf};

use crate::cstd::{self, d2i};
use crate::types::*;
use crate::wfdb::{with_default, Wfdb, NULL};
use crate::wfdbio::wfdbx_write_errors;

/// The error type of the high-level functions.
///
/// It carries a message saying what failed (for example
/// `can't read record 100s`), available through [`Error::message`] or
/// `Display`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Error {
    message: String,
}

impl Error {
    pub(crate) fn new(message: impl Into<String>) -> Error {
        Error {
            message: message.into(),
        }
    }

    /// Returns the error message.
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Error {}

fn lossy(b: &[u8]) -> String {
    String::from_utf8_lossy(cstd::cstr(b)).into_owned()
}

/// A time in a record: a sample number, or a WFDB time string.
///
/// Time strings are those accepted by `strtim`: an elapsed time
/// (`"0:10"`, `"1:02:03.5"`), a sample number (`"s1000"`), a time of day
/// (`"[12:00:00]"`), or `"e"` for the end of the record. `TimeSpec`
/// converts from integers and strings, so `Some(1000.into())` and
/// `Some("0:10".into())` both work where an `Option<TimeSpec>` is taken.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TimeSpec {
    /// A sample number.
    Sample(i64),
    /// A time string (converted with `strtim` for the open record).
    Str(Vec<u8>),
}

impl TimeSpec {
    /// Returns the sample number this time denotes.
    ///
    /// Time strings are converted with `strtim` for the record open in `w`
    /// (a time of day gives the elapsed time from the start of the record,
    /// i.e. the absolute value of what `strtim` returns).
    pub fn resolve(&self, w: &mut Wfdb) -> i64 {
        match self {
            TimeSpec::Sample(t) => *t,
            TimeSpec::Str(s) => {
                let t = w.strtim(s);
                if t < 0 {
                    t.wrapping_neg()
                } else {
                    t
                }
            }
        }
    }

    /// Returns `true` if this time is a string that needs a sampling
    /// frequency to be converted (see [`Wfdb::wfdbx_time_needs_freq`]).
    pub fn needs_freq(&self, w: &mut Wfdb) -> bool {
        match self {
            TimeSpec::Sample(_) => false,
            TimeSpec::Str(s) => w.wfdbx_time_needs_freq(s) != 0,
        }
    }
}

impl From<i64> for TimeSpec {
    fn from(t: i64) -> TimeSpec {
        TimeSpec::Sample(t)
    }
}
impl From<i32> for TimeSpec {
    fn from(t: i32) -> TimeSpec {
        TimeSpec::Sample(t as i64)
    }
}
impl From<u32> for TimeSpec {
    fn from(t: u32) -> TimeSpec {
        TimeSpec::Sample(t as i64)
    }
}
impl From<usize> for TimeSpec {
    fn from(t: usize) -> TimeSpec {
        TimeSpec::Sample(t as i64)
    }
}
impl From<&str> for TimeSpec {
    fn from(s: &str) -> TimeSpec {
        TimeSpec::Str(s.as_bytes().to_vec())
    }
}
impl From<String> for TimeSpec {
    fn from(s: String) -> TimeSpec {
        TimeSpec::Str(s.into_bytes())
    }
}
impl From<&[u8]> for TimeSpec {
    fn from(s: &[u8]) -> TimeSpec {
        TimeSpec::Str(s.to_vec())
    }
}

/// The signals of a record (or of a part of one), as read by
/// [`read_record`].
///
/// Samples are stored frame by frame in one vector of ADC units; use
/// [`at`](Record::at), [`physical`](Record::physical) or
/// [`physical_signal`](Record::physical_signal) to access them.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Record {
    /// Record name.
    pub name: Vec<u8>,
    /// Sampling frequency in Hz of the returned samples. With
    /// [`ReadOptions::highres`], it is that of the fastest signal. It is 0
    /// if the header does not give it.
    pub fs: f64,
    /// Number of (returned) signals.
    pub nsig: usize,
    /// Signal number, in the record, of each returned signal.
    pub signals: Vec<usize>,
    /// Samples in ADC units, frame by frame: `samples[i * nsig + s]` is
    /// sample `i` of signal `s`. Invalid samples are
    /// [`WFDB_INVALID_SAMPLE`].
    pub samples: Vec<i32>,
    /// Signal information, one per returned signal.
    pub siginfo: Vec<Siginfo>,
    /// Start time and date as text, to the second, such as
    /// `"[14:00:03 21/06/2024]"`. `None` if the header gives no start time.
    pub base_time: Option<String>,
    /// Start time in milliseconds after midnight, such as `50403500` for
    /// 14:00:03.500. `Some` exactly when `base_time` is.
    pub base_time_ms: Option<i64>,
    /// Start date as `[year, month, day]`. `None` if the header gives no
    /// date.
    pub base_date: Option<[i32; 3]>,
    /// Sample number of the first returned sample.
    pub sampfrom: i64,
    /// The info strings of the header (its comment lines), and those of the
    /// record's `.info` file if it has one.
    pub comments: Vec<Vec<u8>>,
    /// `false` if the signal data do not match the checksums in the header.
    /// Checksums are only checked when a read reaches the end of the
    /// record, so a read that stops earlier gives `true`. See
    /// [`ReadOptions::checksum_warning`].
    pub checksum_ok: bool,
    /// `true` if the record was read in legacy mode. [`Record::physical`]
    /// then uses a gain of 200 for uncalibrated signals.
    pub legacy: bool,
}

impl Record {
    /// Returns the number of samples per signal (the number of frames).
    pub fn nsamples(&self) -> usize {
        self.samples.len().checked_div(self.nsig).unwrap_or(0)
    }

    /// Returns sample `i` of signal `s`, in ADC units.
    ///
    /// # Panics
    ///
    /// If `i` or `s` is out of range.
    pub fn at(&self, i: usize, s: usize) -> i32 {
        self.samples[i * self.nsig + s]
    }

    /// Returns sample `i` of signal `s` in physical units, computed as
    /// `(value - baseline) / gain`. An invalid sample gives NaN.
    ///
    /// # Errors
    ///
    /// If the signal is uncalibrated (gain 0): "signal N of record REC is
    /// uncalibrated".
    ///
    /// # Panics
    ///
    /// If `i` or `s` is out of range.
    pub fn physical(&self, i: usize, s: usize) -> Result<f64, Error> {
        let g = self.calibrated_gain(s)?;
        let v = self.at(i, s);
        if v == WFDB_INVALID_SAMPLE {
            return Ok(f64::NAN);
        }
        Ok((v as f64 - self.siginfo[s].baseline as f64) / g)
    }

    /// Returns all samples of signal `s` in physical units, as
    /// [`physical`](Record::physical) computes them.
    ///
    /// # Errors
    ///
    /// If the signal is uncalibrated (gain 0).
    pub fn physical_signal(&self, s: usize) -> Result<Vec<f64>, Error> {
        self.calibrated_gain(s)?;
        (0..self.nsamples()).map(|i| self.physical(i, s)).collect()
    }

    /// The gain of returned signal `s`, or an error if it is uncalibrated
    /// (in legacy mode, `WFDB_DEFGAIN`).
    fn calibrated_gain(&self, s: usize) -> Result<f64, Error> {
        let g = self.siginfo[s].gain;
        if g == 0.0 && self.legacy {
            return Ok(WFDB_DEFGAIN); // wfdb-x: legacy mode (original behavior)
        }
        if g == 0.0 {
            let n = self.signals.get(s).copied().unwrap_or(s);
            return Err(Error::new(format!(
                "signal {n} of record {} is uncalibrated",
                lossy(&self.name)
            )));
        }
        Ok(g)
    }

    /// Returns the signal descriptions (`desc`), one per returned signal
    /// (empty for a signal without a description).
    pub fn names(&self) -> Vec<Vec<u8>> {
        self.siginfo
            .iter()
            .map(|si| cstd::cstr(si.desc.as_deref().unwrap_or(b"")).to_vec())
            .collect()
    }
}

/// The header of a record, as read by [`read_header`]: the data of its
/// record line, its signal specifications and its info strings.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Header {
    /// Record name, as given.
    pub name: Vec<u8>,
    /// Sampling frequency in Hz. It is 0 if the header does not give it.
    pub fs: f64,
    /// Counter frequency in Hz, as `getcfreq` gives it.
    pub counter_freq: f64,
    /// Base counter value, as `getbasecount` gives it.
    pub base_counter: f64,
    /// Number of samples per signal given by the record line (0 if it does
    /// not give it).
    pub nsamples: i64,
    /// Number of signals.
    pub nsig: usize,
    /// Signal specifications, one per signal (file name, format, gain,
    /// units, description, ...).
    pub siginfo: Vec<Siginfo>,
    /// Start time and date as text, as in [`Record::base_time`].
    pub base_time: Option<String>,
    /// Start time in milliseconds after midnight, as in
    /// [`Record::base_time_ms`].
    pub base_time_ms: Option<i64>,
    /// Start date as `[year, month, day]`, as in [`Record::base_date`].
    pub base_date: Option<[i32; 3]>,
    /// Info strings, as in [`Record::comments`].
    pub comments: Vec<Vec<u8>>,
}

/// Options of [`write_annotations_with`]. The default writes to the output
/// directory and sorts an out-of-order file as `WFDBANNSORT` says.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AnnWriteOptions {
    /// An existing directory in which to create the file, for this call
    /// only. The record name must then be a plain name, without a
    /// directory. `None`: the output directory.
    pub dir: Option<PathBuf>,
    /// Whether annotations that are not in time order are sorted when the
    /// file is written. `Some(true)` always sorts, and `Some(false)` keeps
    /// the order you gave (without the library's advice to run `sortann`),
    /// for this call only. `None`: the environment
    /// variable `WFDBANNSORT` decides (sorting is on unless it is 0).
    pub sort: Option<bool>,
}

/// Options of [`read_record`], [`read_header_with`] and
/// [`read_annotations_with`]. The default reads all signals of the whole
/// record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadOptions {
    /// Signals to read, by number (`"0"`, `"1"`, ...) or name (`"MLII"`).
    /// Empty: all signals.
    pub channels: Vec<String>,
    /// First sample: a sample number or a time string (see [`TimeSpec`]).
    /// Default: the start of the record.
    pub from: Option<TimeSpec>,
    /// The sample after the last one: a sample number or a time string.
    /// Default: the end of the record.
    pub to: Option<TimeSpec>,
    /// Read a multi-frequency record at its highest sampling frequency:
    /// every sample of the faster signals, with the samples of the slower
    /// ones repeated. Default (`false`): one sample per signal and frame,
    /// with the samples of the faster signals averaged over each frame.
    pub highres: bool,
    /// Replace invalid samples by the previous valid sample, instead of
    /// returning [`WFDB_INVALID_SAMPLE`]. Default: `false`.
    pub pad: bool,
    /// Behave as the original WFDB package, including its assumed signal
    /// parameters (see [`Wfdb::wfdbx_set_legacy`]). Use it only to
    /// reproduce old results. Default: `false`.
    pub legacy: bool,
    /// The input directory for this call only: a local directory, a `~`
    /// path or a URL (see [`Wfdb::wfdbx_set_input_dir`]). An empty string
    /// means the default. `None`: the current setting.
    pub input_dir: Option<String>,
    /// Turn network access on (`Some(true)`) or off (`Some(false)`) for
    /// this call only (see [`Wfdb::wfdbx_set_network`]). `None`: the current
    /// setting.
    pub network: Option<bool>,
    /// Print a warning on the standard error when the signal data do not
    /// match the checksums in the header. The data are returned either way,
    /// and [`Record::checksum_ok`] is `false`. [`Wfdb::wfdbquiet`] also
    /// turns the warning off. Default: `true`.
    pub checksum_warning: bool,
}

impl Default for ReadOptions {
    fn default() -> Self {
        ReadOptions {
            channels: Vec::new(),
            from: None,
            to: None,
            highres: false,
            pad: false,
            legacy: false,
            input_dir: None,
            network: None,
            checksum_warning: true,
        }
    }
}

/// The annotations of an annotation file, as read by [`read_annotations`]
/// and written by [`write_annotations`]. Each field is a vector with one
/// entry per annotation, in file order.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Annotations {
    /// Record name.
    pub record: Vec<u8>,
    /// Annotator name.
    pub annotator: Vec<u8>,
    /// The frequency in which `samples` are counted, in Hz (0 if unknown).
    /// [`write_annotations`] does not use it: it takes its own `fs`
    /// argument.
    pub fs: f64,
    /// Annotation times, in samples.
    pub samples: Vec<i64>,
    /// Annotation codes ([`NORMAL`](crate::NORMAL), [`PVC`](crate::PVC), ...).
    pub codes: Vec<i32>,
    /// Mnemonics of the annotation codes (`b"N"`, `b"V"`, ...). When
    /// writing, an empty or missing entry means: use `codes`.
    pub symbols: Vec<Vec<u8>>,
    /// Subtypes.
    pub subtypes: Vec<i32>,
    /// Channel numbers.
    pub chans: Vec<i32>,
    /// Annotator numbers (the `num` fields).
    pub nums: Vec<i32>,
    /// Auxiliary text of each annotation, or `None`.
    pub aux: Vec<Option<Vec<u8>>>,
}

impl Annotations {
    /// Returns the number of annotations.
    pub fn len(&self) -> usize {
        self.samples.len()
    }

    /// Returns `true` if there are no annotations.
    pub fn is_empty(&self) -> bool {
        self.samples.is_empty()
    }
}

/// Options of [`write_record`] and [`write_record_physical`].
///
/// A per-signal vector holds one value for all signals, or one value per
/// signal. An optional one may also be empty, for its default value.
///
/// `gains`, `adcres` and `units` have no default: you must give the gain
/// and the ADC resolution of every signal, and the units of every signal
/// whose gain is not 0.
#[derive(Clone, Debug, PartialEq)]
pub struct WriteOptions {
    /// Storage format (the same for all signals; default 16).
    pub fmt: i32,
    /// Gains, in ADC units per physical unit (required). A gain of 0 marks
    /// a signal as uncalibrated, which is only allowed for samples given in
    /// ADC units ([`write_record`]).
    pub gains: Vec<f64>,
    /// Baselines (default: the ADC zeros).
    pub baselines: Vec<i32>,
    /// ADC zeros (default: 0).
    pub adczeros: Vec<i32>,
    /// ADC resolutions in bits, at least 1 (required).
    pub adcres: Vec<i32>,
    /// Physical units, such as `Some("mV".into())`. Required for each
    /// signal whose gain is not 0; `None` for an uncalibrated signal.
    pub units: Vec<Option<Vec<u8>>>,
    /// Signal descriptions.
    pub names: Vec<Vec<u8>>,
    /// Samples per frame, at least 1 (default 1; more for the oversampled
    /// signals of a multi-frequency record).
    pub samps_per_frame: Vec<i32>,
    /// Start time and date, such as `"12:00:00 01/01/2020"`. Default: none.
    pub base_time: Option<Vec<u8>>,
    /// Info strings (comment lines), written at the end of the header.
    pub comments: Vec<Vec<u8>>,
    /// Behave as the original WFDB package, including its assumed signal
    /// parameters (see [`Wfdb::wfdbx_set_legacy`]). Use it only to
    /// reproduce old results. Default: `false`.
    pub legacy: bool,
    /// An existing directory in which to create the files, for this call
    /// only. The record name must then be a plain name, without a
    /// directory. The record can then be read from that directory under its
    /// plain name. Default: `None`, the output directory.
    pub dir: Option<PathBuf>,
}

impl Default for WriteOptions {
    fn default() -> Self {
        WriteOptions {
            fmt: 16,
            gains: Vec::new(), // required: no default gain (wfdb-x)
            baselines: Vec::new(),
            adczeros: vec![0],
            adcres: Vec::new(),
            units: Vec::new(),
            names: Vec::new(),
            samps_per_frame: Vec::new(),
            base_time: None,
            comments: Vec::new(),
            legacy: false,
            dir: None,
        }
    }
}

fn per_signal<T: Clone>(v: &[T], k: usize, dflt: T) -> T {
    if v.is_empty() {
        return dflt;
    }
    if v.len() == 1 {
        v[0].clone()
    } else if k < v.len() {
        v[k].clone()
    } else {
        dflt
    }
}

/// The ADC resolution (bits) of the samples of a storage format, as the
/// original package inferred it (legacy mode).
fn legacy_adcres(fmt: i32) -> i32 {
    match fmt {
        80 | 508 => 8,
        212 => 12,
        310 | 311 => 10,
        24 | 524 => 24,
        32 => 32,
        _ => 16,
    }
}

/// The gain of signal `k`: the single value of `gains`, or its `k`-th one.
///
/// wfdb-x: there is no default gain (C assumed `WFDB_DEFGAIN`, as legacy
/// mode does).
fn gain_of(gains: &[f64], k: usize, legacy: bool) -> Result<f64, Error> {
    if legacy {
        return Ok(per_signal(gains, k, WFDB_DEFGAIN));
    }
    match gains.len() {
        1 => Ok(gains[0]),
        n if k < n => Ok(gains[k]),
        _ => Err(Error::new("write_record: gains must be specified")),
    }
}

/// Checks the samples per frame given to `write_record` (in both modes,
/// before anything else): each signal has at least one sample per frame.
fn check_write_spf(opt: &WriteOptions) -> Result<(), Error> {
    if opt.samps_per_frame.iter().any(|&n| n < 1) {
        Err(Error::new(
            "write_record: samps_per_frame must hold integers >= 1",
        ))
    } else {
        Ok(())
    }
}

/// Checks the sampling frequency given to `write_record` (not checked in
/// legacy mode, as in the original package).
fn check_write_freq(fs: f64, legacy: bool) -> Result<(), Error> {
    // wfdb-x: no default sampling frequency (C assumed 250 Hz).
    if fs > 0.0 || legacy {
        Ok(())
    } else {
        Err(Error::new(
            "write_record: the sampling frequency must be > 0",
        ))
    }
}

/// The ADC resolution (bits) of signal `k`: the single value of `adcres`,
/// or its `k`-th one.
///
/// wfdb-x: there is no default ADC resolution (C inferred it from the
/// format, or assumed `WFDB_DEFRES`, 12 bits; legacy mode infers it from
/// the format).
fn adcres_of(adcres: &[i32], k: usize, fmt: i32, legacy: bool) -> Result<i32, Error> {
    if legacy {
        return Ok(per_signal(adcres, k, legacy_adcres(fmt)));
    }
    let r = match adcres.len() {
        1 => adcres[0],
        n if k < n => adcres[k],
        _ => 0,
    };
    if r < 1 {
        Err(Error::new(
            "write_record: ADC resolution(s) must be specified",
        ))
    } else {
        Ok(r)
    }
}

/// The units of signal `k`: the single value of `units`, or its `k`-th one;
/// required if the signal is calibrated (`gain` is not 0).
///
/// wfdb-x: there are no default units (C left them out: millivolts; legacy
/// mode does not require them).
fn units_of(
    units: &[Option<Vec<u8>>],
    k: usize,
    gain: f64,
    legacy: bool,
) -> Result<Option<Vec<u8>>, Error> {
    if legacy {
        return Ok(per_signal(units, k, None));
    }
    let u = per_signal(units, k, None).filter(|u| !u.is_empty());
    if u.is_none() && gain != 0.0 {
        Err(Error::new("write_record: units must be specified"))
    } else {
        Ok(u)
    }
}

/// A string result that may or may not be optional (so that this module
/// works with either form of `annstr`).
trait IntoOptBytes {
    fn into_opt_bytes(self) -> Option<Vec<u8>>;
}
impl IntoOptBytes for Vec<u8> {
    fn into_opt_bytes(self) -> Option<Vec<u8>> {
        Some(self)
    }
}
impl IntoOptBytes for Option<Vec<u8>> {
    fn into_opt_bytes(self) -> Option<Vec<u8>> {
        self
    }
}

impl Wfdb {
    /// Runs `f` with library legacy mode on if `legacy` is true, restoring
    /// the previous setting afterwards (also when `f` fails).
    fn with_legacy<T>(&mut self, legacy: bool, f: impl FnOnce(&mut Wfdb) -> T) -> T {
        if !legacy {
            return f(self);
        }
        let previous = self.wfdbx_set_legacy(1);
        let r = f(self);
        self.wfdbx_set_legacy(previous);
        r
    }

    /// Runs `f` with the library's output directory
    /// ([`Wfdb::wfdbx_set_output_dir`]) set to `dir`, if given, restoring
    /// the previous one afterwards (also when `f` fails). With `dir`,
    /// `record` must not contain a directory, and `dir` must exist.
    fn with_output_dir<T>(
        &mut self,
        dir: Option<&Path>,
        record: &[u8],
        f: impl FnOnce(&mut Wfdb) -> Result<T, Error>,
    ) -> Result<T, Error> {
        let Some(dir) = dir.filter(|d| !d.as_os_str().is_empty()) else {
            return f(self);
        };
        if record.contains(&b'/') || (cfg!(windows) && record.contains(&b'\\')) {
            return Err(Error::new(
                "record name must not contain a directory when dir is given",
            ));
        }
        if !dir.is_dir() {
            return Err(Error::new(format!(
                "directory {} does not exist",
                dir.display()
            )));
        }
        let previous =
            self.wfdbx_set_output_dir(&cstd::os_to_bytes(dir.as_os_str().to_os_string()));
        let r = f(self);
        self.wfdbx_set_output_dir(&previous);
        r
    }

    /// Runs `f` with the input directory and network access of `opt`, if
    /// given, restoring the previous settings afterwards (also when `f`
    /// fails).
    pub(crate) fn with_input<T>(&mut self, opt: &ReadOptions, f: impl FnOnce(&mut Wfdb) -> T) -> T {
        let prev_dir = opt
            .input_dir
            .as_ref()
            .map(|d| self.wfdbx_set_input_dir(d.as_bytes()));
        let prev_net = opt.network.map(|n| self.wfdbx_set_network(i32::from(n)));
        let r = f(self);
        if let Some(n) = prev_net {
            self.wfdbx_set_network(n);
        }
        if let Some(d) = prev_dir {
            self.wfdbx_set_input_dir(&d);
        }
        r
    }

    fn hl_fail<T>(&mut self, msg: String) -> Result<T, Error> {
        self.wfdbquit();
        Err(Error::new(msg))
    }

    /// Whether `from` or `to` is a time string that needs a sampling
    /// frequency.
    fn times_need_freq(&mut self, from: &Option<TimeSpec>, to: &Option<TimeSpec>) -> bool {
        from.as_ref().is_some_and(|t| t.needs_freq(self))
            || to.as_ref().is_some_and(|t| t.needs_freq(self))
    }

    /// The base time text, base time in milliseconds and base date of the
    /// open record, for a record whose sampling frequency is `fs`.
    fn base_time_fields(&mut self, fs: f64) -> (Option<String>, Option<i64>, Option<[i32; 3]>) {
        let (ms, date) = self.wfdbx_base_time_date();
        // (A header without a sampling frequency cannot give a base time.)
        if fs > 0.0 {
            let bt = self.timstr(0);
            if bt.first() == Some(&b'[') {
                return (Some(lossy(&bt)), Some(ms), date);
            }
        }
        (None, None, date)
    }

    /// The info strings of `record` (open).
    fn info_strings(&mut self, record: &[u8]) -> Vec<Vec<u8>> {
        let mut v = Vec::new();
        let mut c = self.getinfo(record);
        while let Some(s) = c {
            v.push(s);
            c = self.getinfo(NULL);
        }
        v
    }

    /// Reads the header of a record, using this `Wfdb` value (see
    /// [`read_header`]).
    ///
    /// # Errors
    ///
    /// If the header cannot be read.
    ///
    /// Part of wfdb-x; not in the original WFDB package.
    pub fn read_header(&mut self, record: impl AsRef<[u8]>, legacy: bool) -> Result<Header, Error> {
        let opt = ReadOptions {
            legacy,
            ..Default::default()
        };
        self.read_header_with(record, &opt)
    }

    /// Reads the header of a record with the `input_dir`, `network` and
    /// `legacy` options of `opt`, using this `Wfdb` value (see
    /// [`read_header_with`]).
    ///
    /// # Errors
    ///
    /// If the header cannot be read.
    ///
    /// Part of wfdb-x; not in the original WFDB package.
    pub fn read_header_with(
        &mut self,
        record: impl AsRef<[u8]>,
        opt: &ReadOptions,
    ) -> Result<Header, Error> {
        let record = record.as_ref();
        self.with_legacy(opt.legacy, |w| {
            w.with_input(opt, |w| w.read_header_impl(record))
        })
    }

    fn read_header_impl(&mut self, record: &[u8]) -> Result<Header, Error> {
        self.wfdbquit();
        let n = self.isigopen(record, &mut [], 0);
        if n < 0 {
            return self.hl_fail(format!("can't read header for record {}", lossy(record)));
        }
        let mut si = vec![Siginfo::default(); n as usize];
        if n > 0 {
            self.isigopen(record, &mut si, -n);
        }
        let fs = self.sampfreq(NULL);
        let (base_time, base_time_ms, base_date) = self.base_time_fields(fs);
        let h = Header {
            name: record.to_vec(),
            fs,
            counter_freq: self.getcfreq(),
            base_counter: self.getbasecount(),
            nsamples: self.wfdbx_header_nsamples(),
            nsig: si.len(),
            siginfo: si,
            base_time,
            base_time_ms,
            base_date,
            comments: self.info_strings(record),
        };
        self.wfdbquit();
        Ok(h)
    }

    /// Reads the signals of a record, using this `Wfdb` value (see
    /// [`read_record`]).
    ///
    /// # Errors
    ///
    /// As [`read_record`].
    ///
    /// Part of wfdb-x; not in the original WFDB package.
    pub fn read_record(
        &mut self,
        record: impl AsRef<[u8]>,
        opt: &ReadOptions,
    ) -> Result<Record, Error> {
        let record = record.as_ref();
        self.with_legacy(opt.legacy, |w| {
            w.with_input(opt, |w| w.read_record_impl(record, opt))
        })
    }

    fn read_record_impl(&mut self, record: &[u8], opt: &ReadOptions) -> Result<Record, Error> {
        let rname = lossy(record);
        self.wfdbquit();
        let nsig = self.isigopen(record, &mut [], 0);
        if nsig <= 0 {
            return self.hl_fail(format!("can't read record {rname}"));
        }
        let mut si = vec![Siginfo::default(); nsig as usize];
        let nsig = self.isigopen(record, &mut si, nsig);
        if nsig <= 0 {
            return self.hl_fail(format!("can't open signals of record {rname}"));
        }
        let nsig = nsig as usize;
        self.setgvmode(
            (if opt.highres {
                WFDB_HIGHRES
            } else {
                WFDB_LOWRES
            }) | (if opt.pad { WFDB_GVPAD } else { 0 }),
        );

        let mut rec = Record {
            name: record.to_vec(),
            fs: self.sampfreq(NULL),
            legacy: self.wfdbx_get_legacy() != 0,
            ..Default::default()
        };
        // wfdb-x: no default sampling frequency (C assumed 250 Hz).
        if rec.fs <= 0.0 && !rec.legacy && self.times_need_freq(&opt.from, &opt.to) {
            return self.hl_fail(format!(
                "sampling frequency of record {rname} is not specified"
            ));
        }
        let from = match &opt.from {
            Some(t) => t.resolve(self),
            None => 0,
        };
        let to = opt.to.as_ref().map(|t| t.resolve(self));

        let mut cols: Vec<usize> = Vec::new();
        if opt.channels.is_empty() {
            cols.extend(0..nsig);
        } else {
            for c in &opt.channels {
                let k = self.findsig(c);
                if k < 0 || k as usize >= nsig {
                    return self.hl_fail(format!("record {rname} has no signal {c}"));
                }
                cols.push(k as usize);
            }
        }
        (rec.base_time, rec.base_time_ms, rec.base_date) = self.base_time_fields(rec.fs);
        if self.isigsettime(from) < 0 {
            return self.hl_fail(format!("can't seek to sample {from} of record {rname}"));
        }

        // getvec returns one value per signal in either mode. The frames are
        // read straight into one vector, allocated for the expected number
        // of frames (from `to`, or from the length of the record if the
        // header gives it; at most 2^26 values at first, in case the header
        // or `to` promises more than the files hold).
        let expected = match to {
            Some(t) => (t - from).max(0),
            None => (self.wfdbx_header_nsamples() - from).max(0),
        };
        let mut all: Vec<i32> = Vec::new();
        all.reserve_exact((expected as usize).saturating_mul(nsig).min(1 << 26));
        const BLOCK: i64 = 1 << 20; // frames read per getvecs call at most
        let mut remaining = to.map(|t| if t > from { t - from } else { 0 });
        let mut checksum_error = false;
        // (getvec's own checksum message is replaced by the warning below)
        self.sig.cksum_quiet = true;
        while remaining.map_or(true, |r| r > 0) {
            let n = match remaining {
                Some(r) => r.min(BLOCK),
                None if expected > all.len() as i64 / nsig as i64 => {
                    (expected - all.len() as i64 / nsig as i64).min(BLOCK)
                }
                None => 65536,
            };
            let len = all.len();
            all.resize(len + n as usize * nsig, 0);
            let (got, stat) = self.getvecs_status(&mut all[len..], n);
            let got = got.max(0);
            if let Some(r) = remaining.as_mut() {
                *r -= got;
            }
            let mut keep = got as usize;
            if stat == -4 {
                // wfdb-x: a checksum error: the vector read last holds valid
                // data and is returned; reading continues (in high-resolution
                // mode, each vector of the last frame returns -4), and a
                // warning follows.
                keep += 1;
                checksum_error = true;
                if let Some(r) = remaining.as_mut() {
                    *r -= 1;
                }
            }
            all.truncate(len + keep * nsig);
            if stat == -4 {
                continue;
            }
            if got < n {
                // wfdb-x: a status below -1 (e.g. -3, unexpected EOF: a
                // signal file shorter than its header says, or a decoder or
                // I/O error) is an error, not the end of the data (-1).
                if stat < -1 {
                    self.sig.cksum_quiet = false;
                    return self.hl_fail(format!(
                        "can't read signal data of record {rname} (getvec status {stat})"
                    ));
                }
                break;
            }
        }
        self.sig.cksum_quiet = false;
        if checksum_error && opt.checksum_warning {
            self.wfdb_error(format!(
                "wfdb-x: checksum error in record {rname}: the signal data do not match the checksums in its header\n"
            ));
        }
        rec.checksum_ok = !checksum_error;

        rec.nsig = cols.len();
        if cols.iter().copied().eq(0..nsig) {
            all.shrink_to_fit();
            rec.samples = all;
        } else {
            let nframes = all.len() / nsig;
            rec.samples = Vec::with_capacity(nframes * cols.len());
            for frame in all.chunks_exact(nsig) {
                rec.samples.extend(cols.iter().map(|&c| frame[c]));
            }
        }
        for &k in &cols {
            rec.siginfo.push(si[k].clone());
        }
        rec.signals = cols;
        rec.sampfrom = from;
        rec.comments = self.info_strings(record);
        self.wfdbquit();
        Ok(rec)
    }

    /// Reads an annotation file, using this `Wfdb` value (see
    /// [`read_annotations`]).
    ///
    /// # Errors
    ///
    /// As [`read_annotations`].
    ///
    /// Part of wfdb-x; not in the original WFDB package.
    pub fn read_annotations(
        &mut self,
        record: impl AsRef<[u8]>,
        annotator: impl AsRef<[u8]>,
        from: Option<TimeSpec>,
        to: Option<TimeSpec>,
        fs: Option<f64>,
        legacy: bool,
    ) -> Result<Annotations, Error> {
        let opt = ReadOptions {
            from,
            to,
            legacy,
            ..Default::default()
        };
        self.read_annotations_with(record, annotator, fs, &opt)
    }

    /// Reads an annotation file with the options of `opt`, using this `Wfdb`
    /// value (see [`read_annotations_with`]).
    ///
    /// # Errors
    ///
    /// As [`read_annotations`].
    ///
    /// Part of wfdb-x; not in the original WFDB package.
    pub fn read_annotations_with(
        &mut self,
        record: impl AsRef<[u8]>,
        annotator: impl AsRef<[u8]>,
        fs: Option<f64>,
        opt: &ReadOptions,
    ) -> Result<Annotations, Error> {
        let (record, annotator) = (record.as_ref(), annotator.as_ref());
        let (from, to) = (opt.from.clone(), opt.to.clone());
        self.with_legacy(opt.legacy, |w| {
            w.with_input(opt, |w| {
                w.read_annotations_impl(record, annotator, from, to, fs)
            })
        })
    }

    fn read_annotations_impl(
        &mut self,
        record: &[u8],
        annotator: &[u8],
        from: Option<TimeSpec>,
        to: Option<TimeSpec>,
        fs: Option<f64>,
    ) -> Result<Annotations, Error> {
        let legacy = self.wfdbx_get_legacy() != 0;
        // (`!(f > 0.0)` also rejects NaN, as the tools' -F does)
        if fs.is_some_and(|f| f.is_nan() || f <= 0.0) {
            return Err(Error::new("fs must be > 0"));
        }
        self.wfdbquit();
        // wfdb-x: no default sampling frequency (C assumed 250 Hz if the
        // record had no header, as legacy mode does); `fs` gives one, as
        // rdann -F does.
        let f = self.sampfreq(record);
        if f <= 0.0 {
            if let Some(f) = fs {
                self.setsampfreq(f);
            } else if legacy {
                self.setsampfreq(WFDB_DEFFREQ); // wfdb-x: legacy mode
            }
        }
        let ai = Anninfo {
            name: annotator.to_vec(),
            stat: WFDB_READ,
        };
        if self.annopen(record, &[ai], 1) < 0 {
            return self.hl_fail(format!(
                "can't read annotator {} for record {}",
                lossy(annotator),
                lossy(record)
            ));
        }
        if self.sampfreq(NULL) <= 0.0 && !legacy && self.times_need_freq(&from, &to) {
            return self.hl_fail(format!(
                "sampling frequency of record {} is not specified",
                lossy(record)
            ));
        }
        let t0 = match &from {
            Some(t) => t.resolve(self),
            None => 0,
        };
        let t1 = to.as_ref().map(|t| t.resolve(self));
        if t0 != 0 && self.iannsettime(t0) < 0 {
            return self.hl_fail(format!("can't seek in annotator {}", lossy(annotator)));
        }
        let mut res = Annotations {
            record: record.to_vec(),
            annotator: annotator.to_vec(),
            ..Default::default()
        };
        let mut a = Annotation::default();
        loop {
            let stat = self.getann(0, &mut a);
            if stat != 0 {
                // wfdb-x: -1 is the end of the file; any other status (e.g.
                // -3, unexpected EOF, or an I/O error) is an error.
                if stat != -1 {
                    return self.hl_fail(format!(
                        "can't read annotation file {} of record {} (getann status {stat})",
                        lossy(annotator),
                        lossy(record)
                    ));
                }
                break;
            }
            if let Some(t1) = t1 {
                if a.time >= t1 {
                    break;
                }
            }
            res.samples.push(a.time);
            res.codes.push(a.anntyp as i32);
            res.symbols.push(
                self.annstr(a.anntyp as i32)
                    .into_opt_bytes()
                    .unwrap_or_default(),
            );
            res.subtypes.push(a.subtyp as i32);
            res.chans.push(a.chan as i32);
            res.nums.push(a.num as i32);
            match &a.aux {
                Some(x) if !x.is_empty() => {
                    let len = x[0] as usize;
                    let text = &x[1..(1 + len).min(x.len())];
                    res.aux.push(Some(cstd::cstr(text).to_vec()));
                }
                _ => res.aux.push(None),
            }
        }
        res.fs = self.getiafreq(0);
        self.wfdbquit();
        Ok(res)
    }

    fn write_adc(
        &mut self,
        record: &[u8],
        samples: &[i32],
        nsig: usize,
        fs: f64,
        opt: &WriteOptions,
    ) -> Result<(), Error> {
        if nsig == 0 {
            return Err(Error::new("write_record: no signals"));
        }
        let legacy = self.wfdbx_get_legacy() != 0;
        check_write_freq(fs, legacy)?;
        let mut si = vec![Siginfo::default(); nsig];
        let mut frame = 0usize;
        let mut fname = record.to_vec();
        fname.extend_from_slice(b".dat");
        for (k, s) in si.iter_mut().enumerate() {
            s.fname = Some(fname.clone());
            s.desc = Some(per_signal(&opt.names, k, Vec::new()));
            s.gain = gain_of(&opt.gains, k, legacy)?;
            s.units = units_of(&opt.units, k, s.gain, legacy)?;
            s.fmt = opt.fmt;
            s.spf = per_signal(&opt.samps_per_frame, k, 1);
            s.adczero = per_signal(&opt.adczeros, k, 0);
            s.baseline = per_signal(&opt.baselines, k, s.adczero);
            s.adcres = adcres_of(&opt.adcres, k, opt.fmt, legacy)?;
            frame += s.spf as usize;
        }
        if samples.len() % frame != 0 {
            return Err(Error::new(
                "write_record: the number of samples is not a multiple of the frame size",
            ));
        }
        self.wfdbquit();
        let errors = wfdbx_write_errors();
        if self.osigfopen(&si, nsig as u32) != nsig as i32 {
            return self.hl_fail(format!(
                "can't create signal file for record {}",
                lossy(record)
            ));
        }
        self.setsampfreq(fs);
        // The counter frequency and base count survive wfdbquit() (as in
        // the C library); a new record written here has neither.
        self.setcfreq(0.0);
        self.setbasecount(0.0);
        if let Some(bt) = &opt.base_time {
            self.setbasetime(bt);
        }
        for f in samples.chunks(frame) {
            self.putvec(f);
        }
        if self.newheader(record) < 0 {
            return self.hl_fail(format!("can't create header for record {}", lossy(record)));
        }
        for c in &opt.comments {
            self.putinfo(c);
        }
        self.wfdbquit();
        if wfdbx_write_errors() > errors {
            return Err(Error::new(format!(
                "write error on record {}",
                lossy(record)
            )));
        }
        Ok(())
    }

    /// Writes a record from samples in ADC units, using this `Wfdb` value
    /// (see [`write_record`]).
    ///
    /// # Errors
    ///
    /// As [`write_record`].
    ///
    /// Part of wfdb-x; not in the original WFDB package.
    pub fn write_record(
        &mut self,
        record: impl AsRef<[u8]>,
        samples: &[i32],
        nsig: usize,
        fs: f64,
        opt: &WriteOptions,
    ) -> Result<(), Error> {
        let record = record.as_ref();
        check_write_spf(opt)?;
        self.with_output_dir(opt.dir.as_deref(), record, |w| {
            w.with_legacy(opt.legacy, |w| w.write_adc(record, samples, nsig, fs, opt))
        })
    }

    /// Writes a record from samples in physical units, using this `Wfdb`
    /// value (see [`write_record_physical`]).
    ///
    /// # Errors
    ///
    /// As [`write_record_physical`].
    ///
    /// Part of wfdb-x; not in the original WFDB package.
    pub fn write_record_physical(
        &mut self,
        record: impl AsRef<[u8]>,
        samples: &[f64],
        nsig: usize,
        fs: f64,
        opt: &WriteOptions,
    ) -> Result<(), Error> {
        let record = record.as_ref();
        check_write_spf(opt)?;
        self.with_output_dir(opt.dir.as_deref(), record, |w| {
            w.with_legacy(opt.legacy, |w| {
                w.write_physical(record, samples, nsig, fs, opt)
            })
        })
    }

    fn write_physical(
        &mut self,
        record: &[u8],
        samples: &[f64],
        nsig: usize,
        fs: f64,
        opt: &WriteOptions,
    ) -> Result<(), Error> {
        let legacy = self.wfdbx_get_legacy() != 0;
        // Gain and baseline of each column of a frame
        let mut g: Vec<f64> = Vec::new();
        let mut b: Vec<i32> = Vec::new();
        if nsig == 0 {
            return Err(Error::new("write_record: no signals"));
        }
        check_write_freq(fs, legacy)?;
        for k in 0..nsig {
            let mut gain = gain_of(&opt.gains, k, legacy)?;
            if gain == 0.0 && legacy {
                gain = WFDB_DEFGAIN; // wfdb-x: legacy mode (original behavior)
            } else if gain == 0.0 {
                // wfdb-x: no default gain (C assumed WFDB_DEFGAIN)
                return Err(Error::new(format!(
                    "write_record: signal {k} is uncalibrated"
                )));
            }
            let zero = per_signal(&opt.adczeros, k, 0);
            let base = per_signal(&opt.baselines, k, zero);
            let spf = per_signal(&opt.samps_per_frame, k, 1);
            for _ in 0..spf {
                g.push(gain);
                b.push(base);
            }
        }
        if g.is_empty() {
            return Err(Error::new("write_record: no signals"));
        }
        let adc: Vec<i32> = samples
            .iter()
            .enumerate()
            .map(|(i, &x)| {
                let c = i % g.len();
                let v = x * g[c];
                if v.is_nan() {
                    WFDB_INVALID_SAMPLE
                } else {
                    let r = if v >= 0.0 {
                        (v + 0.5).trunc()
                    } else {
                        (v - 0.5).trunc()
                    };
                    d2i(r + b[c] as f64)
                }
            })
            .collect();
        self.write_adc(record, &adc, nsig, fs, opt)
    }

    /// Writes an annotation file, using this `Wfdb` value (see
    /// [`write_annotations`]).
    ///
    /// # Errors
    ///
    /// As [`write_annotations`].
    ///
    /// Part of wfdb-x; not in the original WFDB package.
    pub fn write_annotations(
        &mut self,
        record: impl AsRef<[u8]>,
        annotator: impl AsRef<[u8]>,
        ann: &Annotations,
        fs: f64,
        dir: Option<&Path>,
    ) -> Result<(), Error> {
        let opt = AnnWriteOptions {
            dir: dir.map(Path::to_path_buf),
            sort: None,
        };
        self.write_annotations_with(record, annotator, ann, fs, &opt)
    }

    /// Writes an annotation file with the options `opt`, using this `Wfdb`
    /// value (see [`write_annotations_with`]).
    ///
    /// # Errors
    ///
    /// As [`write_annotations`].
    ///
    /// Part of wfdb-x; not in the original WFDB package.
    pub fn write_annotations_with(
        &mut self,
        record: impl AsRef<[u8]>,
        annotator: impl AsRef<[u8]>,
        ann: &Annotations,
        fs: f64,
        opt: &AnnWriteOptions,
    ) -> Result<(), Error> {
        let record = record.as_ref();
        let annotator = annotator.as_ref();
        self.with_output_dir(opt.dir.as_deref(), record, |w| {
            let previous = std::mem::replace(&mut w.ann.sort_override, opt.sort);
            let r = w.write_ann(record, annotator, ann, fs);
            w.ann.sort_override = previous;
            r
        })
    }

    fn write_ann(
        &mut self,
        record: &[u8],
        annotator: &[u8],
        ann: &Annotations,
        fs: f64,
    ) -> Result<(), Error> {
        let n = ann.samples.len();
        self.wfdbquit();
        let errors = wfdbx_write_errors();
        if fs > 0.0 {
            self.setafreq(fs);
        }
        let ai = Anninfo {
            name: annotator.to_vec(),
            stat: WFDB_WRITE,
        };
        if self.annopen(record, &[ai], 1) < 0 {
            if fs > 0.0 {
                self.setafreq(0.0);
            }
            return self.hl_fail(format!(
                "can't create annotator {} for record {}",
                lossy(annotator),
                lossy(record)
            ));
        }
        for k in 0..n {
            let mut a = Annotation {
                time: ann.samples[k],
                ..Default::default()
            };
            match ann.symbols.get(k) {
                Some(sym) if !sym.is_empty() => a.anntyp = self.strann(&sym[..]) as i8,
                _ => {
                    if let Some(&c) = ann.codes.get(k) {
                        a.anntyp = c as i8;
                    }
                }
            }
            if let Some(&x) = ann.subtypes.get(k) {
                a.subtyp = x as i8;
            }
            if let Some(&x) = ann.chans.get(k) {
                a.chan = x as u8;
            }
            if let Some(&x) = ann.nums.get(k) {
                a.num = x as i8;
            }
            if let Some(Some(x)) = ann.aux.get(k) {
                let data = &x[..x.len().min(usize::from(u8::MAX))]; // length byte limit
                let mut v = vec![data.len() as u8];
                v.extend_from_slice(data);
                a.aux = Some(v);
            }
            self.putann(0, &a);
        }
        self.wfdbquit();
        if fs > 0.0 {
            self.setafreq(0.0);
        }
        if wfdbx_write_errors() > errors {
            return Err(Error::new(format!(
                "write error on annotator {} for record {}",
                lossy(annotator),
                lossy(record)
            )));
        }
        Ok(())
    }
}

/// Reads the signals of a record.
///
/// Reads the whole record, or the part and the signals that `opt` selects.
/// The samples are returned in ADC units, frame by frame. Use
/// [`Record::physical_signal`] for physical units.
///
/// # Arguments
///
/// * `record`: the record name or path. A relative name is read from the
///   input directory (see [`Wfdb::wfdbx_set_input_dir`]).
/// * `opt`: the signals, the part of the record and other options (see
///   [`ReadOptions`]).
///
/// Uses the default [`Wfdb`] value of the thread; [`Wfdb::read_record`]
/// uses a given one.
///
/// # Examples
///
/// ```
/// use wfdbx::{read_record, ReadOptions};
///
/// // The sample record 100s, the first minute of record 100 of the MIT-BIH
/// // Arrhythmia Database, included with wfdb-x in tests/data:
/// # wfdbx::wfdbx_set_input_dir("../tests/data");
/// # /*
/// wfdbx::wfdbx_set_input_dir("tests/data"); // from the repository root
/// # */
/// // Signals "MLII" and "V5" from 10 to 20 seconds.
/// let opt = ReadOptions {
///     channels: vec!["MLII".into(), "V5".into()],
///     from: Some("0:10".into()),
///     to: Some("0:20".into()),
///     ..Default::default()
/// };
/// let rec = read_record("100s", &opt)?;
/// let mlii: Vec<f64> = rec.physical_signal(0)?; // in physical units
/// assert_eq!((mlii.len(), rec.fs), (3600, 360.0));
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// * The record cannot be read, or a signal of `opt.channels` does not
///   exist.
/// * A time string of `opt` needs the sampling frequency, and the header does
///   not give it: "sampling frequency of record REC is not specified".
/// * A signal file is shorter than its header says, or cannot be read:
///   "can't read signal data of record REC (getvec status S)".
///
/// When the data do not match the checksums in the header, every sample is
/// returned, [`Record::checksum_ok`] is `false`, and a warning is printed
/// unless [`ReadOptions::checksum_warning`] is `false`.
///
/// Part of wfdb-x; not in the original WFDB package.
pub fn read_record(record: impl AsRef<[u8]>, opt: &ReadOptions) -> Result<Record, Error> {
    with_default(|w| w.read_record(record, opt))
}

/// Reads the header of a record, without opening its signal files.
///
/// # Arguments
///
/// * `record`: the record name or path. A relative name is read from the
///   input directory (see [`Wfdb::wfdbx_set_input_dir`]).
/// * `legacy`: behave as the original WFDB package (see
///   [`ReadOptions::legacy`]). Normally `false`.
///
/// Returns a [`Header`]: the sampling frequency, counter frequency, base
/// counter value, number of samples, start time and date, the
/// specifications of each signal and the info strings. Uses the default
/// [`Wfdb`] value of the thread; [`Wfdb::read_header`] uses a given one.
///
/// # Examples
///
/// ```
/// // The sample record 100s, the first minute of record 100 of the MIT-BIH
/// // Arrhythmia Database, included with wfdb-x in tests/data:
/// # wfdbx::wfdbx_set_input_dir("../tests/data");
/// # /*
/// wfdbx::wfdbx_set_input_dir("tests/data"); // from the repository root
/// # */
/// let h = wfdbx::read_header("100s", false)?;
/// println!("{} signals at {} Hz, {} samples", h.nsig, h.fs, h.nsamples);
/// for s in &h.siginfo {
///     let desc = s.desc.as_deref().unwrap_or(b"");
///     println!("{} (format {})", String::from_utf8_lossy(desc), s.fmt);
/// }
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// If the header cannot be read: "can't read header for record REC".
///
/// Part of wfdb-x; not in the original WFDB package.
pub fn read_header(record: impl AsRef<[u8]>, legacy: bool) -> Result<Header, Error> {
    with_default(|w| w.read_header(record, legacy))
}

/// Reads the header of a record, as [`read_header`] does, with the
/// `input_dir`, `network` and `legacy` options of `opt`. The other options
/// are not used. Uses the default [`Wfdb`] value of the thread.
///
/// # Errors
///
/// If the header cannot be read: "can't read header for record REC".
///
/// Part of wfdb-x; not in the original WFDB package.
pub fn read_header_with(record: impl AsRef<[u8]>, opt: &ReadOptions) -> Result<Header, Error> {
    with_default(|w| w.read_header_with(record, opt))
}

/// Reads an annotation file.
///
/// # Arguments
///
/// * `record`: the record name or path. A relative name is read from the
///   input directory (see [`Wfdb::wfdbx_set_input_dir`]).
/// * `annotator`: the file suffix: `"atr"` reads `100s.atr` for record
///   `100s`.
/// * `from`, `to`: read only the annotations from time `from` up to, but not
///   including, time `to`: sample numbers or time strings (see
///   [`TimeSpec`]). `None`: from the start, or to the end.
/// * `fs`: the sampling frequency to use when the record has no header, or
///   its header gives none. `None`: no frequency is set.
/// * `legacy`: behave as the original WFDB package (see
///   [`ReadOptions::legacy`]). Normally `false`.
///
/// Returns an [`Annotations`] value with the annotations in file order.
/// Without a sampling frequency, its `fs` is the frequency stored in the
/// annotation file, or 0. Uses the default [`Wfdb`] value of the thread;
/// [`Wfdb::read_annotations`] uses a given one.
///
/// # Examples
///
/// ```
/// use wfdbx::{read_annotations, PVC};
///
/// // The sample record 100s, the first minute of record 100 of the MIT-BIH
/// // Arrhythmia Database, included with wfdb-x in tests/data:
/// # wfdbx::wfdbx_set_input_dir("../tests/data");
/// # /*
/// wfdbx::wfdbx_set_input_dir("tests/data"); // from the repository root
/// # */
/// let ann = read_annotations("100s", "atr", None, Some("0:30".into()), None, false)?;
/// let npvc = ann.codes.iter().filter(|&&c| c == PVC).count();
/// for i in 0..ann.len() {
///     println!("{} {}", ann.samples[i], String::from_utf8_lossy(&ann.symbols[i]));
/// }
/// println!("{npvc} PVCs in the first 30 seconds");
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// * `fs` is not positive: "fs must be > 0".
/// * The annotation file cannot be read, or `from` cannot be reached.
/// * The annotation file ends early (it is truncated), or a read error
///   occurs, before `to`: "can't read annotation file ANN of record REC
///   (getann status S)".
/// * A time string needs the sampling frequency, and none is known:
///   "sampling frequency of record REC is not specified".
///
/// Part of wfdb-x; not in the original WFDB package.
pub fn read_annotations(
    record: impl AsRef<[u8]>,
    annotator: impl AsRef<[u8]>,
    from: Option<TimeSpec>,
    to: Option<TimeSpec>,
    fs: Option<f64>,
    legacy: bool,
) -> Result<Annotations, Error> {
    with_default(|w| w.read_annotations(record, annotator, from, to, fs, legacy))
}

/// Reads an annotation file, as [`read_annotations`] does, with the `from`,
/// `to`, `input_dir`, `network` and `legacy` options of `opt`. The other
/// options are not used. Uses the default [`Wfdb`] value of the thread.
///
/// # Examples
///
/// This reads the annotations of record 100 of the MIT-BIH Arrhythmia
/// Database from PhysioNet.
///
/// ```no_run
/// use wfdbx::{read_annotations_with, ReadOptions};
///
/// let opt = ReadOptions {
///     input_dir: Some("https://physionet.org/files/mitdb/1.0.0/".into()),
///     network: Some(true),
///     ..Default::default()
/// };
/// let ann = read_annotations_with("100", "atr", None, &opt)?;
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// As [`read_annotations`].
///
/// Part of wfdb-x; not in the original WFDB package.
pub fn read_annotations_with(
    record: impl AsRef<[u8]>,
    annotator: impl AsRef<[u8]>,
    fs: Option<f64>,
    opt: &ReadOptions,
) -> Result<Annotations, Error> {
    with_default(|w| w.read_annotations_with(record, annotator, fs, opt))
}

/// Writes a record from samples in ADC units.
///
/// This creates the header `RECORD.hea` and the signal file `RECORD.dat`.
///
/// # Arguments
///
/// * `record`: the record name. A relative name is written to the output
///   directory (see [`Wfdb::wfdbx_set_output_dir`]), or to
///   [`WriteOptions::dir`].
/// * `samples`: the samples, frame by frame: `nsig` values per frame (signal
///   0, signal 1, ...). In a multi-frequency record, a frame holds
///   `samps_per_frame` values of each signal.
/// * `nsig`: the number of signals.
/// * `fs`: the sampling frequency in Hz (frames per second, > 0).
/// * `opt`: the gains, ADC resolutions and units (required), the format, the
///   names and other options (see [`WriteOptions`]).
///
/// Uses the default [`Wfdb`] value of the thread; [`Wfdb::write_record`]
/// uses a given one.
///
/// # Examples
///
/// ```no_run
/// use wfdbx::{write_record, WriteOptions};
///
/// // Two signals, three frames, at 360 Hz, written by this example as the
/// // record "example" (example.hea and example.dat in the current directory).
/// let samples = [0, 10, 5, 12, 9, 14];
/// let opt = WriteOptions {
///     gains: vec![200.0],                // ADC units per mV, for both signals
///     adcres: vec![16],                  // bits
///     units: vec![Some("mV".into())],
///     names: vec!["I".into(), "II".into()],
///     ..Default::default()
/// };
/// write_record("example", &samples, 2, 360.0, &opt)?;
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// * There are no signals, or `fs` is not positive.
/// * The gains are missing: "gains must be specified".
/// * The ADC resolutions are missing or less than 1: "ADC resolution(s) must
///   be specified".
/// * The units of a signal whose gain is not 0 are missing: "units must be
///   specified".
/// * A `samps_per_frame` value is less than 1: "samps_per_frame must hold
///   integers >= 1" (checked first, also in legacy mode).
/// * The number of samples is not a multiple of the frame size.
/// * With [`WriteOptions::dir`], the directory does not exist or `record`
///   contains a directory.
/// * The signal file or the header cannot be created.
/// * The signal file or the header cannot be written completely (for
///   example, when the disk is full): "write error on record RECORD" (also
///   in legacy mode).
///
/// Part of wfdb-x; not in the original WFDB package.
pub fn write_record(
    record: impl AsRef<[u8]>,
    samples: &[i32],
    nsig: usize,
    fs: f64,
    opt: &WriteOptions,
) -> Result<(), Error> {
    with_default(|w| w.write_record(record, samples, nsig, fs, opt))
}

/// Writes a record from samples in physical units, as [`write_record`] does
/// from ADC units.
///
/// Each value is converted to ADC units as `round(value * gain) + baseline`,
/// with halves rounded away from zero. NaN becomes an invalid sample. Uses
/// the default [`Wfdb`] value of the thread; [`Wfdb::write_record_physical`]
/// uses a given one.
///
/// # Examples
///
/// ```no_run
/// use wfdbx::{write_record_physical, WriteOptions};
///
/// // One signal at 250 Hz, in millivolts, written by this example as the
/// // record "example" (example.hea and example.dat in the current directory).
/// let x = [0.0, 0.25, 0.5, 0.25];
/// let opt = WriteOptions {
///     gains: vec![1000.0],
///     adcres: vec![16],
///     units: vec![Some("mV".into())],
///     ..Default::default()
/// };
/// write_record_physical("example", &x, 1, 250.0, &opt)?;
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// As [`write_record`]. Also if a gain is 0: "signal N is uncalibrated".
///
/// Part of wfdb-x; not in the original WFDB package.
pub fn write_record_physical(
    record: impl AsRef<[u8]>,
    samples: &[f64],
    nsig: usize,
    fs: f64,
    opt: &WriteOptions,
) -> Result<(), Error> {
    with_default(|w| w.write_record_physical(record, samples, nsig, fs, opt))
}

/// Writes an annotation file.
///
/// # Arguments
///
/// * `record`: the record name. A relative name is written to the output
///   directory (see [`Wfdb::wfdbx_set_output_dir`]), or to `dir`.
/// * `annotator`: the file suffix: `"qrs"` writes `RECORD.qrs`.
/// * `ann`: the annotations. The type of each annotation is its `symbols`
///   entry, a mnemonic such as `"N"` or `"V"`, or its `codes` entry if the
///   mnemonic is empty or missing. Missing `subtypes`, `chans`, `nums` and
///   `aux` entries are 0 or absent. An unknown mnemonic gives `NOTQRS`. Aux
///   text longer than 255 bytes is cut.
/// * `fs`: if positive, stored in the file as the frequency of its sample
///   numbers. `ann.fs` is not used.
/// * `dir`: an existing directory in which to create the file, for this call
///   only. The record name must then be a plain name, without a directory.
///
/// If the annotations are not in time order, the file is sorted when it is
/// written, unless the environment variable `WFDBANNSORT` is 0.
/// [`write_annotations_with`] decides this for one call. Uses the default
/// [`Wfdb`] value of the thread; [`Wfdb::write_annotations`] uses a given one.
///
/// # Examples
///
/// ```no_run
/// use wfdbx::{write_annotations, Annotations};
///
/// let ann = Annotations {
///     samples: vec![100, 400, 700],
///     symbols: vec!["N".into(), "V".into(), "N".into()],
///     ..Default::default()
/// };
/// // Writes the annotation file example.test, for a record "example" (such
/// // as the one written by the example of write_record).
/// write_annotations("example", "test", &ann, 0.0, None)?;
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// * The annotation file cannot be created.
/// * The annotation file cannot be written completely (for example, when
///   the disk is full): "write error on annotator ANNOTATOR for record
///   RECORD" (also in legacy mode).
/// * With `dir`, the directory does not exist ("directory DIR does not
///   exist"), or `record` contains a directory ("record name must not
///   contain a directory when dir is given").
///
/// Part of wfdb-x; not in the original WFDB package.
pub fn write_annotations(
    record: impl AsRef<[u8]>,
    annotator: impl AsRef<[u8]>,
    ann: &Annotations,
    fs: f64,
    dir: Option<&Path>,
) -> Result<(), Error> {
    with_default(|w| w.write_annotations(record, annotator, ann, fs, dir))
}

/// Writes an annotation file, as [`write_annotations`] does, with the
/// options `opt`.
///
/// [`AnnWriteOptions::dir`] is the output directory, as the `dir` argument
/// of [`write_annotations`]. [`AnnWriteOptions::sort`] decides, for this call
/// only, whether annotations that are not in time order are sorted. Uses the
/// default [`Wfdb`] value of the thread; [`Wfdb::write_annotations_with`]
/// uses a given one.
///
/// # Examples
///
/// ```no_run
/// use wfdbx::{write_annotations_with, AnnWriteOptions, Annotations};
///
/// let ann = Annotations {
///     samples: vec![700, 100, 400], // not in time order
///     symbols: vec!["N".into(), "V".into(), "N".into()],
///     ..Default::default()
/// };
/// let opt = AnnWriteOptions { sort: Some(false), ..Default::default() };
/// // Writes example.test, for a record "example" (such as the one written by
/// // the example of write_record).
/// write_annotations_with("example", "test", &ann, 0.0, &opt)?; // kept as given
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// As [`write_annotations`].
///
/// Part of wfdb-x; not in the original WFDB package.
pub fn write_annotations_with(
    record: impl AsRef<[u8]>,
    annotator: impl AsRef<[u8]>,
    ann: &Annotations,
    fs: f64,
    opt: &AnnWriteOptions,
) -> Result<(), Error> {
    with_default(|w| w.write_annotations_with(record, annotator, ann, fs, opt))
}
