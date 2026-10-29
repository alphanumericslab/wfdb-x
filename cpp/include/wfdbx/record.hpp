// wfdbx/record.hpp: high-level functions for reading and writing records
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// These functions read and write whole records and annotation files in a few
// calls: read_record(), read_header(), read_annotations(), write_record(),
// write_record_physical() and write_annotations(); check_record() checks a
// record and its annotation files.  They read and write the
// same files as the WFDB library functions of <wfdbx/wfdb.hpp> and the
// command-line tools.
//
// Files are read and written exactly where they are named.  A full path, a
// "~" path or a URL is used as given.  Any other name is read from the input
// directory and written to the output directory, both the current directory
// by default.  Set them with wfdbx_set_input_dir() and
// wfdbx_set_output_dir(), or for one call with the `input_dir` option of the
// readers and the `dir` option of the writers.  URLs need network access:
// wfdbx_set_network(1), or the `network` option of the readers.
//
// No sampling frequency, gain, ADC resolution or units are assumed.  You give
// them to write_record().  A record whose header gives no frequency is read
// with fs = 0, and an operation that needs a missing value throws Error.
//
// The `legacy` option of each function makes it behave as the original WFDB
// package, for that call only.  Use it only to reproduce old results.
//
// Errors throw wfdbx::Error.  The functions call wfdbquit() before and after
// their work (also when they throw), which closes anything opened with the
// WFDB library functions.
// They are not thread-safe.  Results are returned by value.
//
//     #include <wfdbx/record.hpp>
//
//     // The sample record 100s (the first minute of record 100 of the
//     // MIT-BIH Arrhythmia Database), included with WFDB-x in the tests/data
//     // directory of a copy of the repository:
//     wfdbx::wfdbx_set_input_dir("tests/data");
//     wfdbx::ReadOptions opt;
//     opt.to = "0:10";                    // the first 10 seconds
//     wfdbx::Record rec = wfdbx::read_record("100s", opt);
//     double v = rec.physical(0, 1);      // sample 0 of signal 1, in
//                                         // rec.siginfo[1].units
//     wfdbx::Annotations ann = wfdbx::read_annotations("100s", "atr");
//     for (size_t i = 0; i < ann.size(); i++)
//         std::printf("%lld %s\n", ann.samples[i], ann.symbols[i].c_str());

#ifndef WFDBX_RECORD_HPP
#define WFDBX_RECORD_HPP

#include <array>
#include <cstddef>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

#include "wfdb.hpp"

namespace wfdbx {

/// Exception thrown by the functions of this header.  what() describes the
/// failed operation, such as "can't read record 100s".  The library's own
/// message, if any, is printed on stderr (see wfdbquiet()) and returned by
/// wfdberror().
class Error : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

/// A time: a sample number, or a WFDB time string such as "0:10" (10
/// seconds), "s1000" (sample 1000), "[12:00:00]" (a time of day) or "e" (the
/// end of the record); see strtim().  It converts from integers and strings,
/// so `opt.from = 3600;` and `opt.from = "0:10";` both work.  A
/// default-constructed TimeSpec is empty: no time is given.
class TimeSpec {
public:
    TimeSpec() = default;
    TimeSpec(WFDB_Time t) : t_(t) {}
    TimeSpec(int t) : t_(t) {}
    TimeSpec(long t) : t_(t) {}
    TimeSpec(const char *s) : s_(s) {}
    TimeSpec(std::string s) : s_(std::move(s)) {}
    /// True if no time was given.
    bool empty() const { return !t_ && !s_; }
    /// True if the time is a string that needs a sampling frequency to be
    /// converted (see wfdbx_time_needs_freq()).
    bool needs_freq() const;
    /// The sample number (0 if empty).  Time strings are converted with
    /// strtim() for the record currently open.  A time of day gives the
    /// positive sample number it corresponds to.
    WFDB_Time resolve() const;
private:
    std::optional<WFDB_Time> t_;
    std::optional<std::string> s_;
};

/// Where read_header() and read_annotations() find files, for one call.
/// An option that is set applies to that call only.  An option that is not
/// set keeps the current setting.
///
///     // Record 100 of the MIT-BIH Arrhythmia Database, from PhysioNet:
///     wfdbx::InputOptions in;
///     in.input_dir = "https://physionet.org/files/mitdb/1.0.0/";
///     in.network = true;
///     wfdbx::Header hdr = wfdbx::read_header("100", false, in);
struct InputOptions {
    /// The input directory (see wfdbx_set_input_dir()): a local directory or
    /// the URL of a directory.  "" means the default: WFDBX_INPUT_DIR, or the
    /// current directory.
    std::optional<std::string> input_dir;
    /// Network access (see wfdbx_set_network()): true allows opening URLs,
    /// false forbids it.
    std::optional<bool> network;
};

/// The signals of a record, or of a part of one, as read_record() returns
/// them.
struct Record {
    std::string name;           ///< record name, as given to read_record()
    /// Sampling frequency of the returned samples, in Hz; 0 if the header
    /// does not give it.
    WFDB_Frequency fs = 0;
    int nsig = 0;               ///< number of (returned) signals
    /// Signal number, in the record, of each returned signal.
    std::vector<int> signals;
    /// Samples in ADC units, frame by frame: samples[i * nsig + s] is
    /// sample i of signal s.  Invalid samples are WFDB_INVALID_SAMPLE.
    std::vector<WFDB_Sample> samples;
    /// One per returned signal; its desc has no white space at either end.
    std::vector<WFDB_Siginfo> siginfo;
    /// Start time and date of the record as text, to the second, such as
    /// "[08:45:00 01/01/2001]"; nullopt if the header gives none.
    std::optional<std::string> base_time;
    /// Start time in milliseconds after midnight: "14:00:03.500" gives
    /// 50403500.  Given exactly when base_time is, nullopt otherwise.
    std::optional<long long> base_time_ms;
    /// Start date as {year, month, day}; nullopt if the header gives no
    /// date.
    std::optional<std::array<int, 3>> base_date;
    WFDB_Time sampfrom = 0;     ///< sample number of the first returned sample
    /// Info strings of the record: the comments of the header, and the
    /// lines of its .info file if it has one (see getinfo()).
    std::vector<std::string> comments;
    /// false if the signal data do not match the checksums in the header,
    /// true otherwise.  Checksums are only checked when a read reaches the
    /// end of the record.  ReadOptions::checksum_warning does not change
    /// this field.
    bool checksum_ok = true;
    /// true if the record was read in legacy mode (ReadOptions::legacy).
    /// physical() then uses a gain of 200 for uncalibrated signals.
    bool legacy = false;

    /// Number of samples per signal.
    size_t nsamples() const { return nsig ? samples.size() / nsig : 0; }
    /// Sample i of signal s, in ADC units (not bounds-checked).
    WFDB_Sample at(size_t i, int s) const { return samples[i * nsig + s]; }
    /// Sample i of signal s in physical units: (value - baseline) / gain;
    /// NaN if the sample is invalid.  The units are siginfo[s].units
    /// (std::nullopt if the header does not give them).  Throws Error
    /// ("signal N of record R is uncalibrated") if the gain of the signal is
    /// 0.
    double physical(size_t i, int s) const;
    /// All samples of signal s in physical units (see physical()).
    std::vector<double> physical_signal(int s) const;
    /// The signal descriptions (siginfo[s].desc, "" if absent), without the
    /// white space that a header may put at either end of them.
    std::vector<std::string> names() const;
};

/// Options of read_record().  The fields inherited from InputOptions
/// (input_dir, network) say where the files are found, for that call only.
struct ReadOptions : InputOptions {
    /// Signals to return, in this order, by number ("0", "1", ...) or by
    /// name ("V5", as in Record::names()); empty: all signals.
    std::vector<std::string> channels;
    TimeSpec from;              ///< first sample (default: 0)
    TimeSpec to;                ///< end, exclusive (default: end of record)
    /// For a multi-frequency record: true returns every sample of the
    /// oversampled signals, repeating those of the other signals; false
    /// averages oversampled signals to one sample per frame.
    bool highres = false;
    /// Replace invalid samples by the previous valid sample.
    bool pad = false;
    /// When the signal data do not match the checksums of the header, all
    /// the data are returned.  If this is true, the warning "WFDB-x: checksum
    /// error in record REC: the signal data do not match the checksums in
    /// its header" is also printed on stderr (wfdbquiet() silences it).
    bool checksum_warning = true;
    /// Behave as the original WFDB package, for this call only (see
    /// docs/DIVERGENCES.md).  Use it only to reproduce old results.
    bool legacy = false;
};

/// Read the signals of `record` from opt.from up to opt.to, exclusive.  If
/// the record ends before opt.to, the samples up to its end are returned.
/// Returns a Record, with the samples in ADC units.
///
/// Throws Error if the record cannot be read or has no signals, if a
/// requested signal does not exist, if opt.from is negative ("read_record:
/// from must not be negative") or cannot be reached.  The getvec mode
/// (getgvmode()) is the same after the call as before it.  A
/// signal file that is shorter than its header says, or that cannot be read
/// or decoded, throws "can't read signal data of record R (getvec status
/// S)".  If the header gives no sampling frequency, rec.fs is 0, and a time
/// string in opt.from or opt.to that needs it throws "sampling frequency of
/// record R is not specified".  Data that do not match the header's
/// checksums are returned, with a warning (see
/// ReadOptions::checksum_warning).
///
///     // The sample record 100s (the first minute of record 100 of the
///     // MIT-BIH Arrhythmia Database), included with WFDB-x in tests/data:
///     wfdbx::ReadOptions opt;
///     opt.input_dir = "tests/data";
///     opt.channels = {"MLII"};
///     opt.from = "0:10";
///     opt.to = "0:20";
///     wfdbx::Record rec = wfdbx::read_record("100s", opt);
///     std::vector<double> mlii = rec.physical_signal(0);
///
/// Part of WFDB-x; not in the original WFDB package.
Record read_record(const std::string &record, const ReadOptions &opt = {});

/// The header of a record, as read_header() returns it.
struct Header {
    std::string name;           ///< record name, as given to read_header()
    /// Sampling frequency in Hz, as sampfreq() gives it; 0 if the header does
    /// not give it.
    WFDB_Frequency fs = 0;
    WFDB_Frequency counter_freq = 0;    ///< counter frequency (getcfreq())
    double base_counter = 0;    ///< base counter value (getbasecount())
    /// Number of samples per signal, from the record line of the header (0
    /// if the header does not give it).
    WFDB_Time nsamples = 0;
    int nsig = 0;               ///< number of signals
    /// The signal specifications, one per signal (empty if the record has
    /// none); their desc has no white space at either end.
    std::vector<WFDB_Siginfo> siginfo;
    /// Base time, as Record::base_time.
    std::optional<std::string> base_time;
    /// Base time in milliseconds after midnight, as Record::base_time_ms.
    std::optional<long long> base_time_ms;
    /// Base date {year, month, day}, as Record::base_date.
    std::optional<std::array<int, 3>> base_date;
    /// Info strings of the record, as Record::comments.
    std::vector<std::string> comments;
};

/// Read the header of `record`: its frequencies, length, signal
/// specifications, start time and date, and info strings.  The signal files
/// are not opened.  Returns a Header.  `legacy` behaves as the original WFDB
/// package, for this call only.  `input` says where the header is found (see
/// InputOptions).  Throws Error if the header cannot be read.
///
///     // The sample record 100s (see read_record()), in tests/data:
///     wfdbx::InputOptions in;
///     in.input_dir = "tests/data";
///     wfdbx::Header hdr = wfdbx::read_header("100s", false, in);
///     for (const wfdbx::WFDB_Siginfo &s : hdr.siginfo)
///         std::printf("%s %d %g\n", s.desc->c_str(), s.fmt, s.gain);
///
/// Part of WFDB-x; not in the original WFDB package.
Header read_header(const std::string &record, bool legacy = false,
                   const InputOptions &input = {});

/// An annotation file, as parallel arrays: annotation i is samples[i],
/// codes[i], symbols[i], ...  read_annotations() returns it, and
/// write_annotations() writes it.
struct Annotations {
    std::string record, annotator;  ///< e.g. "100s" and "atr"
    WFDB_Frequency fs = 0;      ///< frequency of `samples` (0 if unknown)
    std::vector<WFDB_Time> samples;     ///< times (sample numbers)
    std::vector<int> codes;     ///< annotation types (NORMAL, PVC, ...)
    std::vector<std::string> symbols;   ///< mnemonics, as annstr() returns
    std::vector<int> subtypes, chans, nums;  ///< subtyp, chan, num fields
    /// Auxiliary text of each annotation, up to its first null byte;
    /// nullopt if absent.
    std::vector<std::optional<std::string>> aux;

    /// Number of annotations.
    size_t size() const { return samples.size(); }
};

/// Read the annotation file of `annotator` for `record`, such as "atr" for
/// "100s.atr", from time `from` (default: the start) up to `to`, exclusive
/// (default: the end).  Returns the annotations in file order.
///
/// The sampling frequency is that of the record's header.  If the record
/// has no header, or its header gives none, `fs` is used, as the -F option
/// of rdann.  Without either, the result's fs is the time resolution of the
/// annotation file (0 if it has none).  `legacy` behaves as the original
/// WFDB package, for this call only.  `input` says where the files are found
/// (see InputOptions).
///
/// Throws Error if the annotation file cannot be read, if `fs` is given and
/// is not greater than 0 ("read_annotations: fs must be > 0"), or if a time
/// string in `from` or `to` needs a frequency that is not known ("sampling
/// frequency of record R is not specified").  A file that ends early or
/// cannot be read before `to` is reached throws "can't read annotation file
/// A of record R (getann status S)", where S is the status getann() returned
/// (e.g. -3, unexpected end of file).
///
///     // The sample record 100s (see read_record()), in tests/data:
///     wfdbx::wfdbx_set_input_dir("tests/data");
///     wfdbx::Annotations ann = wfdbx::read_annotations("100s", "atr", "0:10", "0:30");
///
/// Part of WFDB-x; not in the original WFDB package.
Annotations read_annotations(const std::string &record,
                             const std::string &annotator,
                             const TimeSpec &from = {},
                             const TimeSpec &to = {},
                             std::optional<WFDB_Frequency> fs = std::nullopt,
                             bool legacy = false,
                             const InputOptions &input = {});

/// Options of write_record() and write_record_physical().  Each per-signal
/// vector holds one value for all signals, or one value per signal (or
/// none, for those that have a default); any other length throws Error.
/// gains, adcres and units have no default: you must give them.
struct WriteOptions {
    int fmt = 16;               ///< storage format (the same for all signals)
    /// Gains, in ADC units per physical unit: required, and finite.  A gain
    /// of 0 marks a signal as uncalibrated, which only write_record() (ADC
    /// units) allows.  Negative gains are allowed.
    std::vector<WFDB_Gain> gains;
    std::vector<int> baselines;         ///< default: the adczeros values
    std::vector<int> adczeros{0};       ///< ADC output for 0 V input
    /// ADC resolutions in bits: required, each at least 1.
    std::vector<int> adcres;
    /// Physical units, such as "mV": required for every signal whose gain is
    /// not 0; optional for uncalibrated signals.
    std::vector<std::optional<std::string>> units;
    std::vector<std::string> names;     ///< signal descriptions (default: "")
    /// Samples per frame of each signal, for multi-frequency records
    /// (default: 1).
    std::vector<int> samps_per_frame;
    /// Start time and date, e.g. "12:00:00 01/01/2020" (see setbasetime());
    /// one that setbasetime() rejects throws Error.
    std::optional<std::string> base_time;
    std::vector<std::string> comments;  ///< info strings (header comments)
    /// If not empty, the directory in which the files are created.  The
    /// directory must exist, and the record name must not contain a
    /// directory.  The record then opens from that directory under its
    /// plain name.
    std::string dir;
    /// Behave as the original WFDB package, for this call only (see
    /// docs/DIVERGENCES.md).  Use it only to reproduce old results.
    bool legacy = false;
};

/// Write a record: the header "<record>.hea" and the signal file
/// "<record>.dat".  `samples` holds the samples in ADC units, frame by
/// frame: nsig values per frame, or the sum of opt.samps_per_frame for a
/// multi-frequency record.  WFDB_INVALID_SAMPLE marks invalid samples.  `fs`
/// is the sampling frequency in Hz.
///
/// Throws Error if a samps_per_frame value is less than 1
/// ("samps_per_frame must hold integers >= 1", checked first), if the
/// record name is empty, if nsig is not greater than 0 ("at least one signal
/// is required"), if a per-signal vector of `opt` has another length than
/// 0, 1 or nsig, if fs is not finite or not greater than 0, if a gain is not
/// finite ("gains must be finite"), if the gains, the ADC resolutions or the
/// units of a calibrated signal are missing ("gains must be specified", "ADC
/// resolution(s) must be specified", "units must be specified"), if
/// samples.size() is not a multiple of the frame size, if opt.base_time is
/// not a valid time ("incorrect base time 'T'"), if the files cannot be
/// created, or if they cannot be written completely (for example, when the
/// disk is full: "write error on record R").  Every check except the last
/// two comes before any file is created.  With opt.dir, it also throws if
/// the directory does not exist ("directory D does not exist") or the
/// record name contains one ("record name must not contain a directory when
/// dir is given").
///
///     wfdbx::WriteOptions w;
///     w.fmt = 212;
///     w.gains = {200};
///     w.adcres = {11};
///     w.units = {"mV"};
///     // writes the new record "new" (new.hea, new.dat) from `samples`
///     wfdbx::write_record("new", samples, 2, 360, w);
///
/// Part of WFDB-x; not in the original WFDB package.
void write_record(const std::string &record,
                  const std::vector<WFDB_Sample> &samples, int nsig,
                  WFDB_Frequency fs, const WriteOptions &opt = {});

/// As write_record(), with samples in physical units.  Each sample v is
/// stored as round(v * gain) + baseline, and NaN is stored as an invalid
/// sample.  Throws Error ("signal N is uncalibrated") if a gain is 0, and
/// ("sample I is out of range") if a sample is infinite or its ADC value is
/// outside the range of a 32-bit integer; nothing is written then.
///
/// Part of WFDB-x; not in the original WFDB package.
void write_record_physical(const std::string &record,
                           const std::vector<double> &samples, int nsig,
                           WFDB_Frequency fs, const WriteOptions &opt = {});

/// Write the annotation file of `annotator` for `record`,
/// "<record>.<annotator>".  The type of each annotation is its `symbols`
/// entry ("N", "V", ...; an unknown mnemonic gives NOTQRS), or its `codes`
/// entry.  Both may be given (as read_annotations() returns them) if they
/// agree: the code of each non-empty symbol (strann()) is the code given
/// for that annotation; an empty symbol leaves the code.  Each of
/// symbols, codes, subtypes, chans, nums and aux is either empty (subtypes,
/// chans and nums are then 0, and there is no aux) or has one entry per
/// annotation; any other length throws Error before anything is written.
/// subtypes, chans and nums are stored in 8 bits, as by putann() (300 is
/// stored as 44, as in C), and aux texts are cut to 255 bytes.  `fs` is 0
/// (none) or a finite frequency > 0, which is recorded in the file (ann.fs
/// is not used).  If `dir` is not empty, the file is created in that
/// directory, which must exist.
///
/// If the annotations are not in time order, the file is sorted when it is
/// written.  sort = false keeps the order given (without the library's
/// advice to run sortann) and sort = true always
/// sorts, for this call only.  Without `sort`, the WFDBANNSORT environment
/// variable decides: sorting is on unless it is 0.
///
/// Throws Error if symbols and codes are both given and disagree
/// ("symbols and codes disagree at annotation K", K counted from 0), if
/// `fs` is not 0 and not a finite frequency > 0, if
/// the file cannot be created, if it cannot be written completely ("write
/// error on annotator A for record R"), or for a `dir` as write_record()
/// does.  The arguments are checked before the file is created.
///
///     wfdbx::Annotations qrs;
///     qrs.samples = {100, 460, 820};
///     qrs.symbols = {"N", "N", "V"};
///     // writes the annotation file rec.qrs of a record "rec"
///     wfdbx::write_annotations("rec", "qrs", qrs);
///
/// Part of WFDB-x; not in the original WFDB package.
void write_annotations(const std::string &record, const std::string &annotator,
                       const Annotations &ann, WFDB_Frequency fs = 0,
                       const std::string &dir = {},
                       std::optional<bool> sort = std::nullopt);

/// A problem found by check_record().
struct Issue {
    /// "error" (the record is damaged or does not follow the WFDB format),
    /// "warning" (something is missing or unusual, and may give wrong
    /// results) or "info" (a fact worth knowing).
    std::string severity;
    /// A stable identifier, such as "checksum" or "gain_missing".
    std::string code;
    /// "" (the record), "signal N", "segment SEG", "segment SEG, signal N"
    /// or "annotator ANN".
    std::string where;
    std::string message;    ///< the description of the problem
    /// One line: "SEVERITY: WHERE: MESSAGE" ("SEVERITY: MESSAGE" if `where`
    /// is empty).
    std::string to_string() const;
};

/// The result of check_record().
struct CheckReport {
    std::string record;     ///< the record name, as given
    bool ok = true;         ///< true if no issue has the severity "error"
    std::vector<Issue> issues;  ///< the problems, in the order of the checks
    /// The text form, one line per issue (Issue::to_string()), or the single
    /// line "no problems found".
    std::vector<std::string> lines() const;
    /// The lines of lines(), joined by newlines (no final newline).
    std::string to_string() const;
};

/// Check a record and its annotation files, and report every problem: the
/// header, the signal specifications, the signal files (all samples are
/// read) and the annotation files of `annotators` (such as {"atr"}).
/// Problems in the record are reported, never thrown.  `input` says where
/// the files are found (see InputOptions).  The checks run in normal mode,
/// even if legacy mode is on, and the library prints no messages during the
/// call (the previous settings are restored afterwards).
///
/// Throws Error ("record must not be empty") if `record` is empty.
///
///     // The sample record 100s (see read_record()), in tests/data:
///     wfdbx::InputOptions in;
///     in.input_dir = "tests/data";
///     wfdbx::CheckReport r = wfdbx::check_record("100s", {"atr"}, in);
///     std::printf("%s\n", r.to_string().c_str());  // or "no problems found"
///     if (!r.ok) ...                               // there is an error
///
/// A line of the report reads, for example:
///
///     error: signal 1: the checksum does not match: the header gives 12, the samples sum to 13
///
/// It checks for problems similar to those found by Benjamin Moody's
/// wfdbcheck (https://github.com/bemoody/wfdbcheck).
///
/// Part of WFDB-x; not in the original WFDB package.
CheckReport check_record(const std::string &record,
                         const std::vector<std::string> &annotators = {},
                         const InputOptions &input = {});

} // namespace wfdbx

#endif // WFDBX_RECORD_HPP
