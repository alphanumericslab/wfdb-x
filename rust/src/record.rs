//! High-level API: read and write whole records and annotation files
//! ([`read_record`], [`read_header`], [`read_annotations`],
//! [`write_record`], [`write_record_physical`], [`write_annotations`]).
//!
//! These functions are built on the C-style API, so they read and write
//! exactly what the WFDB library and the command-line tools do. Each is
//! available as a free function, which uses the thread-local default
//! instance, and as a method of [`Wfdb`]. A call closes any records and
//! annotators open in the instance it uses (it calls `wfdbquit` before and
//! after its work). Errors are returned as [`Error`]; the error message is
//! also printed on the standard error by the underlying C-style functions,
//! unless `wfdbquiet` has been called.
//!
//! ```no_run
//! use wfdbx::record::{read_record, read_annotations, ReadOptions};
//! let opt = ReadOptions { to: Some("0:10".into()), ..Default::default() };
//! let rec = read_record("100s", &opt).unwrap();   // the first 10 seconds
//! let v = rec.physical(0, 1).unwrap();            // sample 0 of signal 1, in mV
//! let ann = read_annotations("100s", "atr", None, None, None, false).unwrap();
//! for i in 0..ann.len() {
//!     println!("{} {}", ann.samples[i], String::from_utf8_lossy(&ann.symbols[i]));
//! }
//! # let _ = v;
//! ```
//!
//! wfdb-x never assumes a sampling frequency, a gain, an ADC resolution or
//! units (C: `WFDB_DEFFREQ`, 250 Hz, `WFDB_DEFGAIN`, 200 adu/mV, a
//! resolution based on the format or `WFDB_DEFRES`, 12 bits, and
//! millivolts): [`write_record`] requires the gains, the ADC resolutions
//! and the units of calibrated signals; a record whose header gives no
//! frequency is read with `fs` 0, one without ADC resolutions with
//! `adcres` 0, one without units with `units` `None`; and conversions that
//! need a missing value return an [`Error`] (see `docs/DIVERGENCES.md`).
//!
//! # Legacy mode
//!
//! Each function also has a legacy option ([`ReadOptions::legacy`],
//! [`WriteOptions::legacy`], and the `legacy` argument of [`read_header`]
//! and [`read_annotations`]): with it, the function behaves as in the
//! original package, with library legacy mode on for the duration of the
//! call (see [`Wfdb::wfdbx_set_legacy`]): a header without a sampling
//! frequency means 250 Hz, a missing ADC resolution is inferred from the
//! format, [`Record::physical`] assumes a gain of 200 for uncalibrated
//! signals, [`read_annotations`] assumes 250 Hz for a record without a
//! header, and [`write_record`] uses a gain of 200, an ADC resolution based
//! on the format and no units by default. It is kept for compatibility
//! only: the values it assumes are exactly the silent defaults this project
//! removed, so results produced with it carry the same risks.
//!
//! # Input directory and network access
//!
//! wfdb-x: [`ReadOptions::input_dir`] and [`ReadOptions::network`] set the
//! input directory (a local directory or a URL) and network access for the
//! duration of a call, restoring the previous settings afterwards (see
//! [`Wfdb::wfdbx_set_input_dir`], [`Wfdb::wfdbx_set_network`]); for
//! [`read_header`] and [`read_annotations`], use [`read_header_with`] and
//! [`read_annotations_with`].
//!
//! # Output directory
//!
//! [`WriteOptions::dir`] and the `dir` argument of [`write_annotations`]
//! (wfdb-x) create the files in a directory, which must exist; the header
//! then names the record and its signal file without the directory (see
//! [`Wfdb::wfdbx_set_output_dir`], which these functions set for the
//! duration of the call).
//!
//! Strings read from files (signal descriptions, comments, annotation
//! mnemonics and aux strings) are byte strings, as everywhere in the
//! library (WFDB files are not UTF-8); `Vec<u8>` fields can be set from
//! `&str` with `.into()`.
//
// Rust implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md. The original behavior
// remains available with --legacy (see docs/DIVERGENCES.md).
// Design decision (Reza Sameni, after a code review, Oct 2026): the writers
// take an output directory (WriteOptions::dir, the dir argument of
// write_annotations), so that a record can be written to a directory and
// opened from there under its plain name (with a record name containing the
// directory, the header records that name). This is an addition, the same in
// legacy mode.
// Design decision (Reza Sameni, Oct 2026): the readers take an input
// directory and network access options (ReadOptions::input_dir, network):
// files are found only where they are named (a search of the WFDB path can
// silently open the wrong file), and the network is used only when asked
// for. The original behavior remains available with --legacy (see
// docs/DIVERGENCES.md).
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

use std::path::{Path, PathBuf};

use crate::cstd::{self, d2i};
use crate::types::*;
use crate::wfdb::{with_default, Wfdb, NULL};

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
    fn new(message: impl Into<String>) -> Error {
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
    /// Sampling frequency (Hz) of the returned samples (in
    /// [`ReadOptions::highres`] mode, that of the fastest signal); 0 if the
    /// header does not specify it (wfdb-x: no default frequency).
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
    /// Base time and date of the record, as `timstr(0)` gives it (e.g.
    /// `"[08:45:00 01/01/2001]"`), or `None` if the header defines none.
    pub base_time: Option<String>,
    /// Sample number of the first returned sample.
    pub sampfrom: i64,
    /// Info strings (comment lines) of the header and of the `.info` file,
    /// if any.
    pub comments: Vec<Vec<u8>>,
    /// Read in legacy mode ([`ReadOptions::legacy`], or library legacy mode
    /// already on): [`Record::physical`] then assumes a gain of 200 for
    /// uncalibrated signals, as the original package did.
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
    /// `(value - baseline) / gain`; NaN for an invalid sample.
    ///
    /// # Errors
    ///
    /// If the signal is uncalibrated (gain 0): `signal N of record R is
    /// uncalibrated` (wfdb-x: no default gain; C assumed 200 adu/mV, as
    /// a record read in legacy mode does).
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

    /// Returns all samples of signal `s` in physical units (see
    /// [`physical`](Record::physical)).
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

/// Options of [`read_record`]. The default reads all signals of the whole
/// record.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ReadOptions {
    /// Signals to read, by number (`"0"`, `"1"`, ...) or name (as
    /// `findsig` accepts them); empty: all signals.
    pub channels: Vec<String>,
    /// First sample (default: 0).
    pub from: Option<TimeSpec>,
    /// End, exclusive (default: end of record).
    pub to: Option<TimeSpec>,
    /// For multi-frequency records: read in `WFDB_HIGHRES` mode (every sample
    /// of the oversampled signals, others repeated) instead of the default
    /// `WFDB_LOWRES` mode (samples of oversampled signals averaged over each
    /// frame). See `setgvmode`.
    pub highres: bool,
    /// Replace invalid samples by the previous valid sample (`WFDB_GVPAD`)
    /// instead of returning [`WFDB_INVALID_SAMPLE`].
    pub pad: bool,
    /// Legacy mode: read as the original package did, with library legacy
    /// mode on during the call (a header without a sampling frequency means
    /// 250 Hz, a missing ADC resolution is inferred from the format, and
    /// [`Record::physical`] assumes a gain of 200 for uncalibrated signals).
    /// For compatibility only: these are the silent defaults wfdb-x removed,
    /// with the same risks.
    pub legacy: bool,
    /// wfdb-x: the input directory for the call (a local directory, `~...`,
    /// or the URL of a directory; see [`Wfdb::wfdbx_set_input_dir`]); an
    /// empty string means the default. `None`: the current setting.
    pub input_dir: Option<String>,
    /// wfdb-x: allow (`Some(true)`) or forbid (`Some(false)`) network
    /// access for the call (see [`Wfdb::wfdbx_set_network`]). `None`: the
    /// current setting.
    pub network: Option<bool>,
    /// wfdb-x: warn (on the standard error, through the library's message
    /// path, so that `wfdbquiet` silences it) when the signal data do not
    /// match the checksums in the header; the data are returned either way.
    /// Default: true.
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

/// The annotations of an annotation file, as parallel vectors (one entry
/// per annotation in each), as read by [`read_annotations`] and written by
/// [`write_annotations`].
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Annotations {
    /// Record name.
    pub record: Vec<u8>,
    /// Annotator name.
    pub annotator: Vec<u8>,
    /// Time resolution of `samples` (ticks per second, as `getiafreq`
    /// gives it). Not used by [`write_annotations`], which takes its own
    /// `fs` argument.
    pub fs: f64,
    /// Times (sample numbers).
    pub samples: Vec<i64>,
    /// Annotation types (`NORMAL`, `PVC`, ...).
    pub codes: Vec<i32>,
    /// Mnemonics, as `annstr` returns them (empty: use `codes` when
    /// writing).
    pub symbols: Vec<Vec<u8>>,
    /// Subtypes.
    pub subtypes: Vec<i32>,
    /// Channel numbers.
    pub chans: Vec<i32>,
    /// Annotator numbers (the `num` fields).
    pub nums: Vec<i32>,
    /// Auxiliary data (`None` if absent), without the leading length byte
    /// of [`Annotation::aux`].
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
/// Each per-signal vector may be empty (the default value is used), hold a
/// single value (used for all signals), or hold one value per signal (the
/// default value is used for signals beyond its end). The default writes
/// format 16 with an ADC zero of 0.
///
/// The gains and the ADC resolutions have no default (wfdb-x: C assumed
/// 200 adu/mV, and a resolution based on the format): `gains` and `adcres`
/// must hold one value, or one value per signal. The units have no default
/// either (C: millivolts): `units` must give those of every signal whose
/// gain is not 0. With [`legacy`](WriteOptions::legacy), the original
/// defaults apply instead.
#[derive(Clone, Debug, PartialEq)]
pub struct WriteOptions {
    /// Storage format (the same for all signals; default 16).
    pub fmt: i32,
    /// Gains, in ADC units per physical unit: required (one value, or one
    /// per signal). A gain of 0 declares a signal uncalibrated, which is
    /// allowed only by [`write_record`] (samples in ADC units).
    pub gains: Vec<f64>,
    /// Baselines (default: the ADC zeros).
    pub baselines: Vec<i32>,
    /// ADC zeros (default: 0).
    pub adczeros: Vec<i32>,
    /// ADC resolutions in bits (>= 1): required (one value, or one per
    /// signal).
    pub adcres: Vec<i32>,
    /// Units: required (one value, or one per signal) for each signal whose
    /// gain is not 0; `None` (or empty) for an uncalibrated signal.
    pub units: Vec<Option<Vec<u8>>>,
    /// Signal descriptions.
    pub names: Vec<Vec<u8>>,
    /// Samples per frame (default 1; more for the oversampled signals of
    /// a multi-frequency record).
    pub samps_per_frame: Vec<i32>,
    /// Base time and date, as `setbasetime` accepts it (e.g.
    /// `"12:00:00 01/01/2020"`); default: none.
    pub base_time: Option<Vec<u8>>,
    /// Info strings (comment lines), written at the end of the header.
    pub comments: Vec<Vec<u8>>,
    /// Legacy mode: write as the original package did, with library legacy
    /// mode on during the call (default gain 200, ADC resolution based on
    /// the format, no units required, and gain 200 for uncalibrated signals
    /// in [`write_record_physical`]). For compatibility only: these are the
    /// silent defaults wfdb-x removed, with the same risks.
    pub legacy: bool,
    /// wfdb-x: the directory (which must exist) in which the files are
    /// created; `record` must then be a plain name, without a directory.
    /// The header names the record and its signal file without the
    /// directory, so that the record opens from that directory under its
    /// plain name. Default: none (the current directory, or the directory
    /// part of the record name).
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
    fn with_input<T>(&mut self, opt: &ReadOptions, f: impl FnOnce(&mut Wfdb) -> T) -> T {
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

    /// Reads the signal specifications of a record's header, using this
    /// instance (see [`read_header`]).
    ///
    /// # Errors
    ///
    /// If the header cannot be read.
    pub fn read_header(
        &mut self,
        record: impl AsRef<[u8]>,
        legacy: bool,
    ) -> Result<Vec<Siginfo>, Error> {
        let opt = ReadOptions {
            legacy,
            ..Default::default()
        };
        self.read_header_with(record, &opt)
    }

    /// Reads the signal specifications of a record's header, with the
    /// `legacy`, `input_dir` and `network` options of `opt` (the others are
    /// not used), using this instance (see [`read_header`]).
    ///
    /// # Errors
    ///
    /// If the header cannot be read.
    pub fn read_header_with(
        &mut self,
        record: impl AsRef<[u8]>,
        opt: &ReadOptions,
    ) -> Result<Vec<Siginfo>, Error> {
        let record = record.as_ref();
        self.with_legacy(opt.legacy, |w| {
            w.with_input(opt, |w| w.read_header_impl(record))
        })
    }

    fn read_header_impl(&mut self, record: &[u8]) -> Result<Vec<Siginfo>, Error> {
        self.wfdbquit();
        let n = self.isigopen(record, &mut [], 0);
        if n < 0 {
            return self.hl_fail(format!("can't read header for record {}", lossy(record)));
        }
        let mut si = vec![Siginfo::default(); n as usize];
        if n > 0 {
            self.isigopen(record, &mut si, -n);
        }
        self.wfdbquit();
        Ok(si)
    }

    /// Reads the signals of a record, using this instance (see
    /// [`read_record`]).
    ///
    /// # Errors
    ///
    /// If the record or its signals cannot be opened, a signal of `opt` does
    /// not exist, the start time cannot be reached, or a time string of
    /// `opt` needs the sampling frequency and the header does not give it;
    /// also if reading stops with a `getvec` status below -1 (e.g. -3: a
    /// signal file shorter than its header says, or a read or decoding
    /// error), with the message "can't read signal data of record R (getvec
    /// status S)" (also in legacy mode; reaching the end of the record
    /// before `opt.to` is not an error).
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
        // (A header without a sampling frequency cannot give a base time.)
        if rec.fs > 0.0 {
            let bt = self.timstr(0);
            if bt.first() == Some(&b'[') {
                rec.base_time = Some(lossy(&bt));
            }
        }
        if self.isigsettime(from) < 0 {
            return self.hl_fail(format!("can't seek to sample {from} of record {rname}"));
        }

        // getvec returns one value per signal in either mode.
        let mut all: Vec<i32> = Vec::new();
        const BLOCK: i64 = 65536; // frames read per getvecs call
        let mut remaining = to.map(|t| if t > from { t - from } else { 0 });
        let mut buf: Vec<i32> = Vec::new();
        let mut checksum_error = false;
        // (getvec's own checksum message is replaced by the warning below)
        self.sig.cksum_quiet = true;
        while remaining.map_or(true, |r| r > 0) {
            let n = match remaining {
                Some(r) => r.min(BLOCK),
                None => BLOCK,
            };
            buf.resize(n as usize * nsig, 0);
            let (mut got, stat) = self.getvecs_status(&mut buf, n);
            if got > 0 {
                all.extend_from_slice(&buf[..got as usize * nsig]);
            }
            if got < 0 {
                got = 0;
            }
            if let Some(r) = remaining.as_mut() {
                *r -= got;
            }
            if stat == -4 {
                // wfdb-x: a checksum error: the frame read last is complete
                // (it is the last one of the record) and is returned; a
                // warning follows.
                let g = got as usize * nsig;
                all.extend_from_slice(&buf[g..g + nsig]);
                checksum_error = true;
                break;
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

        let nframes = all.len() / nsig;
        rec.nsig = cols.len();
        rec.samples = Vec::with_capacity(nframes * cols.len());
        for i in 0..nframes {
            for &c in &cols {
                rec.samples.push(all[i * nsig + c]);
            }
        }
        for &k in &cols {
            rec.siginfo.push(si[k].clone());
        }
        rec.signals = cols;
        rec.sampfrom = from;
        let mut c = self.getinfo(record);
        while let Some(s) = c {
            rec.comments.push(s);
            c = self.getinfo(NULL);
        }
        self.wfdbquit();
        Ok(rec)
    }

    /// Reads an annotation file, using this instance (see
    /// [`read_annotations`]).
    ///
    /// # Errors
    ///
    /// If `fs` is given and not positive, the annotation file cannot be
    /// opened, `from` cannot be reached, or a time string needs the sampling
    /// frequency and none is known.
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

    /// Reads an annotation file, with the `from`, `to`, `legacy`,
    /// `input_dir` and `network` options of `opt` (the others are not
    /// used), using this instance (see [`read_annotations`]).
    ///
    /// # Errors
    ///
    /// As [`Wfdb::read_annotations`].
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
        while self.getann(0, &mut a) == 0 {
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
            frame += s.spf.max(1) as usize;
        }
        if samples.len() % frame != 0 {
            return Err(Error::new(
                "write_record: the number of samples is not a multiple of the frame size",
            ));
        }
        self.wfdbquit();
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
        Ok(())
    }

    /// Writes a record from samples in ADC units, using this instance (see
    /// [`write_record`]).
    ///
    /// # Errors
    ///
    /// If there are no signals, `fs` is not positive, the gains or the ADC
    /// resolutions are not specified, the units of a calibrated signal are
    /// not specified, the number of samples is not a multiple of the frame
    /// size, or the signal or header file cannot be written.
    pub fn write_record(
        &mut self,
        record: impl AsRef<[u8]>,
        samples: &[i32],
        nsig: usize,
        fs: f64,
        opt: &WriteOptions,
    ) -> Result<(), Error> {
        let record = record.as_ref();
        self.with_output_dir(opt.dir.as_deref(), record, |w| {
            w.with_legacy(opt.legacy, |w| w.write_adc(record, samples, nsig, fs, opt))
        })
    }

    /// Writes a record from samples in physical units, using this instance
    /// (see [`write_record_physical`]).
    ///
    /// # Errors
    ///
    /// As [`Wfdb::write_record`]; also if a gain is 0 (uncalibrated).
    pub fn write_record_physical(
        &mut self,
        record: impl AsRef<[u8]>,
        samples: &[f64],
        nsig: usize,
        fs: f64,
        opt: &WriteOptions,
    ) -> Result<(), Error> {
        let record = record.as_ref();
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
            for _ in 0..spf.max(1) {
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

    /// Writes an annotation file, using this instance (see
    /// [`write_annotations`]).
    ///
    /// # Errors
    ///
    /// If the annotation file cannot be created, or, with `dir`, if `dir`
    /// does not exist or `record` contains a directory.
    pub fn write_annotations(
        &mut self,
        record: impl AsRef<[u8]>,
        annotator: impl AsRef<[u8]>,
        ann: &Annotations,
        fs: f64,
        dir: Option<&Path>,
    ) -> Result<(), Error> {
        let record = record.as_ref();
        let annotator = annotator.as_ref();
        self.with_output_dir(dir, record, |w| w.write_ann(record, annotator, ann, fs))
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
        Ok(())
    }
}

/// Reads the signals of a record: all of it, or the part and the signals
/// selected by `opt`.
///
/// The record is found as [`Wfdb::wfdb_open`] finds files (wfdb-x: under
/// the input directory, [`ReadOptions::input_dir`], or as given; in legacy
/// mode, in the WFDB path). Samples are returned in ADC
/// units, frame by frame, one value per signal and frame as `getvec`
/// returns them (for multi-frequency records, see
/// [`ReadOptions::highres`]). Uses the default instance; see
/// [`Wfdb::read_record`] for an explicit one.
///
/// # Examples
///
/// ```no_run
/// use wfdbx::{read_record, ReadOptions};
///
/// // Signals "MLII" and "V5" from 1 minute to 1 minute 10 seconds.
/// let opt = ReadOptions {
///     channels: vec!["MLII".into(), "V5".into()],
///     from: Some("1:00".into()),
///     to: Some("1:10".into()),
///     ..Default::default()
/// };
/// let rec = read_record("100s", &opt)?;
/// let mlii: Vec<f64> = rec.physical_signal(0)?; // in physical units (mV)
/// println!("{} samples at {} Hz", mlii.len(), rec.fs);
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// If the header does not specify the sampling frequency, `fs` is 0 in the
/// result (wfdb-x: no default frequency), and time strings that need it
/// (see [`wfdbx_time_needs_freq`](crate::wfdbx_time_needs_freq)) are
/// errors. [`Record::physical`] fails for an uncalibrated signal. With
/// [`ReadOptions::legacy`], the record is read as by the original package
/// (250 Hz without a frequency in the header, gain 200 for uncalibrated
/// signals): for compatibility only, with the risks of these silent
/// defaults.
///
/// # Errors
///
/// If the record or its signals cannot be opened, a signal of `opt` does
/// not exist, the start time cannot be reached, or a time string needs the
/// sampling frequency and the header does not specify it (`sampling
/// frequency of record R is not specified`); also if reading stops with a
/// `getvec` status below -1 (e.g. -3: a signal file shorter than its header
/// says, or a read or decoding error): `can't read signal data of record R
/// (getvec status S)`, also in legacy mode (reaching the end of the record
/// before `opt.to` is not an error). A checksum error (status -4) is not an
/// error (wfdb-x): every frame is returned, with a warning on the standard
/// error unless [`ReadOptions::checksum_warning`] is false.
pub fn read_record(record: impl AsRef<[u8]>, opt: &ReadOptions) -> Result<Record, Error> {
    with_default(|w| w.read_record(record, opt))
}

/// Reads the signal specifications of a record's header: one [`Siginfo`]
/// per signal (file name, format, gain, units, description, ...), without
/// reading any samples.
///
/// Uses the default instance; see [`Wfdb::read_header`] for an explicit
/// one. Other header data (sampling frequency, base time, info strings)
/// can be read with the C-style functions (`sampfreq`, `timstr`,
/// `getinfo`).
///
/// # Examples
///
/// ```no_run
/// let signals = wfdbx::read_header("100s", false)?;
/// for s in &signals {
///     let desc = s.desc.as_deref().unwrap_or(b"");
///     println!("{} (format {})", String::from_utf8_lossy(desc), s.fmt);
/// }
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// With `legacy`, the header is read as by the original package (library
/// legacy mode on during the call): a missing ADC resolution is inferred
/// from the format, or 12 bits. For compatibility only: this is one of the
/// silent defaults wfdb-x removed, with the same risks.
///
/// # Errors
///
/// If the header cannot be read.
pub fn read_header(record: impl AsRef<[u8]>, legacy: bool) -> Result<Vec<Siginfo>, Error> {
    with_default(|w| w.read_header(record, legacy))
}

/// Reads the signal specifications of a record's header, as
/// [`read_header`] does, with the `legacy`, `input_dir` and `network`
/// options of `opt` (wfdb-x; the others are not used). Uses the default
/// instance.
///
/// # Errors
///
/// If the header cannot be read.
pub fn read_header_with(
    record: impl AsRef<[u8]>,
    opt: &ReadOptions,
) -> Result<Vec<Siginfo>, Error> {
    with_default(|w| w.read_header_with(record, opt))
}

/// Reads the annotation file of `record` written by `annotator` (for
/// example `"atr"`), optionally from time `from` to time `to` (exclusive).
///
/// The file is found as [`Wfdb::wfdb_open`] finds files (wfdb-x: under the
/// input directory, or as given; see [`read_annotations_with`] for the
/// `input_dir` and `network` options; in legacy mode, in the WFDB path).
/// Annotation times are sample
/// numbers. Uses the default instance; see [`Wfdb::read_annotations`] for
/// an explicit one.
///
/// The sampling frequency is that of the record's header. If the record has
/// no header, or its header does not specify one, `fs` (if positive) is
/// used, as by the `-F` option of `rdann` (wfdb-x: there is no default
/// frequency; C assumed 250 Hz); when `fs` is `None`, nothing is set.
/// Without either, the result's `fs` is the
/// time resolution of the annotation file (0 if it has none), and time
/// strings in `from` or `to` that need the frequency are errors.
///
/// With `legacy`, the file is read as by the original package (library
/// legacy mode on during the call): a record without a header (and without
/// `fs`) is read at 250 Hz, as is one whose header gives no frequency. For
/// compatibility only: this is one of the silent defaults wfdb-x removed,
/// with the same risks.
///
/// # Examples
///
/// ```no_run
/// use wfdbx::{read_annotations, PVC};
///
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
/// If `fs` is given and not positive (`fs must be > 0`), the annotation
/// file cannot be opened, `from` cannot be reached, or a time string needs the sampling frequency and none is known (`sampling
/// frequency of record R is not specified`).
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

/// Reads an annotation file, as [`read_annotations`] does, with the
/// `from`, `to`, `legacy`, `input_dir` and `network` options of `opt`
/// (wfdb-x; the others are not used). Uses the default instance.
///
/// ```no_run
/// use wfdbx::{read_annotations_with, ReadOptions};
///
/// // mitdb record 100, from PhysioNet
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
pub fn read_annotations_with(
    record: impl AsRef<[u8]>,
    annotator: impl AsRef<[u8]>,
    fs: Option<f64>,
    opt: &ReadOptions,
) -> Result<Annotations, Error> {
    with_default(|w| w.read_annotations_with(record, annotator, fs, opt))
}

/// Writes a record (signal file `RECORD.dat` and header `RECORD.hea`) from
/// samples in ADC units.
///
/// # Arguments
///
/// * `record`: the record name; the files are created in the current
///   directory (or in the directory part of the name), or in
///   [`WriteOptions::dir`].
/// * `samples`: the samples, frame by frame: `nsig` values per frame
///   (signal 0, signal 1, ...), or, for multi-frequency records, the sum of
///   the `samps_per_frame` values per frame.
/// * `nsig`: the number of signals.
/// * `fs`: the sampling frequency (frames per second, > 0).
/// * `opt`: format, gains, ADC resolutions and units (required), names, ...
///   (see [`WriteOptions`]).
///
/// Uses the default instance; see [`Wfdb::write_record`] for an explicit
/// one.
///
/// # Examples
///
/// ```no_run
/// use wfdbx::{write_record, WriteOptions};
///
/// // Two signals, three frames, at 360 Hz.
/// let samples = [0, 10, 5, 12, 9, 14];
/// let opt = WriteOptions {
///     gains: vec![200.0],      // adu/mV, for both signals (required)
///     adcres: vec![16],        // bits (required)
///     units: vec![Some("mV".into())], // required for calibrated signals
///     names: vec!["I".into(), "II".into()],
///     ..Default::default()
/// };
/// write_record("example", &samples, 2, 360.0, &opt)?;
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// If there are no signals, `fs` is not positive, the gains are not
/// specified (`gains must be specified`), the ADC resolutions are not
/// specified or are less than 1 (`ADC resolution(s) must be specified`),
/// the units of a signal whose gain is not 0 are not specified (`units must
/// be specified`), the number of samples is not a multiple of the frame
/// size, or the signal or header file cannot be written.
pub fn write_record(
    record: impl AsRef<[u8]>,
    samples: &[i32],
    nsig: usize,
    fs: f64,
    opt: &WriteOptions,
) -> Result<(), Error> {
    with_default(|w| w.write_record(record, samples, nsig, fs, opt))
}

/// Writes a record from samples in physical units, as [`write_record`]
/// does from ADC units.
///
/// Each value is converted to ADC units with the gain and baseline of its
/// signal (`round(value * gain) + baseline`, rounding halves away from zero
/// as `physadu` does); NaN becomes an invalid sample
/// ([`WFDB_INVALID_SAMPLE`]). Uses the default instance; see
/// [`Wfdb::write_record_physical`] for an explicit one.
///
/// # Errors
///
/// As [`write_record`]; also if a gain is 0 (`signal N is uncalibrated`):
/// physical values cannot be converted without a gain.
pub fn write_record_physical(
    record: impl AsRef<[u8]>,
    samples: &[f64],
    nsig: usize,
    fs: f64,
    opt: &WriteOptions,
) -> Result<(), Error> {
    with_default(|w| w.write_record_physical(record, samples, nsig, fs, opt))
}

/// Writes the annotation file of `record` for `annotator` (as `wrann`
/// does). The file is created in the current directory (or in the
/// directory part of the record name), or, with `dir` (wfdb-x), in that
/// directory, which must exist (`record` must then be a plain name, without
/// a directory).
///
/// The annotation type of each annotation is given by its `symbols` entry
/// (a mnemonic such as `"N"` or `"V"`, converted with `strann`; an unknown
/// mnemonic gives `NOTQRS`), or, if
/// that entry is empty or missing, by its `codes` entry. Missing
/// `subtypes`, `chans`, `nums` and `aux` entries are 0 or absent; aux data
/// longer than 255 bytes are truncated. The annotations should be in time
/// order; otherwise the file is sorted when it is closed, unless the
/// environment variable `WFDBANNSORT` is 0 (wfdb-x: in this process, with
/// the result of the `sortann` program; in library legacy mode, by running
/// `sortann`, as the C library does). If `fs > 0`, it is
/// recorded in the file as its time resolution (ticks per second); `ann.fs`
/// is not used. Uses the default instance; see [`Wfdb::write_annotations`]
/// for an explicit one.
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
/// write_annotations("example", "test", &ann, 0.0, None)?;
/// # Ok::<(), wfdbx::record::Error>(())
/// ```
///
/// # Errors
///
/// If the annotation file cannot be created, or, with `dir`, if `dir` does
/// not exist (`directory DIR does not exist`) or `record` contains a
/// directory (`record name must not contain a directory when dir is
/// given`).
pub fn write_annotations(
    record: impl AsRef<[u8]>,
    annotator: impl AsRef<[u8]>,
    ann: &Annotations,
    fs: f64,
    dir: Option<&Path>,
) -> Result<(), Error> {
    with_default(|w| w.write_annotations(record, annotator, ann, fs, dir))
}
