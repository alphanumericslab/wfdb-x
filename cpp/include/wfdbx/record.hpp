// wfdbx/record.hpp: high-level functions for reading and writing records
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation, either version 2.1 of the License, or (at
// your option) any later version. See LICENSE.
//
// These functions read and write whole records and annotation files in a few
// calls: read_record(), read_header(), read_annotations(), write_record(),
// write_record_physical() and write_annotations(); check_record() checks a
// record and its annotation files; read_metadata(), get_metadata(),
// set_metadata(), remove_metadata() and update_metadata() read and change
// the "Key: value" entries of a header (its metadata).  They read and write
// the same files as the WFDB library functions of <wfdbx/wfdb.hpp> and the
// command-line tools.
//
// Files are read and written exactly where they are named.  A record name is
// given without the .hea extension (the readers also accept a trailing
// ".hea").  A full path, absolute ("/data/mitdb/100") or in the home
// directory ("~/Documents/100s"), is used as given, and so is a URL
// ("https://physionet.org/files/mitdb/1.0.0/100"), which is read only if
// network access is on and cannot be written.  A relative path ("100s",
// "data/100s") is read from the input directory and written to the output
// directory if they are set, otherwise in the current directory.  Set them
// with wfdbx_set_input_dir() and wfdbx_set_output_dir(), or for one call with
// the `input_dir` option of the readers and the `dir` option of the writers.
// Network access: wfdbx_set_network(1), or the `network` option of the
// readers.
//
// No sampling frequency, gain, ADC resolution or units are assumed.  You give
// them to write_record().  A record whose header gives no frequency is read
// with fs = 0, and an operation that needs a missing value throws Error.
//
// The `legacy` option of each function makes it behave as the original WFDB
// package, for that call only.  Use it only to reproduce old results.
//
// Errors throw wfdbx::Error (the metadata functions throw its subclasses
// ArgumentError and FileError).  The functions call wfdbquit() before and
// after their work (also when they throw), which closes anything opened with
// the WFDB library functions; the metadata functions do not (they open only
// the header, and leave the library's open files as they are).  The
// functions that open a record (all but the metadata functions) leave the
// time resolution of output annotators (getafreq()) and the getvec mode
// (getgvmode()) as they were, also after reading an EDF record, whose
// opening sets both (as in C; the C-style functions keep that behavior).
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
#include <utility>
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

/// An Error for an invalid argument, thrown by the header metadata functions
/// (read_metadata() and the others) and by write_record() for an invalid
/// WriteOptions::metadata: an invalid key or value, a record name that is
/// empty or "-", a key that the header has more than once (set_metadata(),
/// update_metadata()), a header without a record line, or a header read
/// from a URL that is to be changed without `dir`.
///
/// Part of WFDB-x; not in the original WFDB package.
class ArgumentError : public Error {
public:
    using Error::Error;
};

/// An Error for a file that cannot be read or written, thrown by the header
/// metadata functions: a header that cannot be found or read ("can't read
/// header for record R"), a changed header that cannot be written ("can't
/// write header for record R"), or a `dir` that does not exist ("directory
/// D does not exist").
///
/// Part of WFDB-x; not in the original WFDB package.
class FileError : public Error {
public:
    using Error::Error;
};

/// Header metadata: the "Key: value" entries of a header, as (key, value)
/// pairs in file order (see read_metadata()).
using Metadata = std::vector<std::pair<std::string, std::string>>;

/// Changes to the metadata of a header, as (key, value) pairs applied in
/// order (see update_metadata()); a value of std::nullopt removes the entry.
using MetadataChanges =
    std::vector<std::pair<std::string, std::optional<std::string>>>;

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
    /// The sample number, if the time was given as one (not as a string);
    /// std::nullopt otherwise.
    std::optional<WFDB_Time> sample() const { return t_; }
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
    /// The input directory for this call only (optional): a local
    /// directory, a "~" path or the URL of a directory, under which relative
    /// record names are read.  It does not apply to full paths or URLs.  ""
    /// means the default: WFDBX_INPUT_DIR, or the current directory.  Not
    /// set: the current setting (see wfdbx_set_input_dir()).
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
    /// Info strings of the record: the comments of the header (its lines
    /// that begin with '#' after the record line, without the '#'), and
    /// the lines of its .info file if it has one (see getinfo()).  The
    /// record line is found as the header parser finds it: the first line
    /// that holds something other than spaces, tabs, CRs and LFs and does
    /// not begin, after them, with '#' (an empty or blank first line is not
    /// the record line, except in legacy mode).
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
/// `record` is the record name, without the .hea extension (a trailing
/// ".hea" is also accepted): a full path, absolute ("/data/mitdb/100") or in
/// the home directory ("~/Documents/100s"), used as given; a relative path
/// ("100s", "data/100s"), read from the input directory if one is set,
/// otherwise from the current directory; or a URL
/// ("https://physionet.org/files/mitdb/1.0.0/100"), read only if network
/// access is on.
///
/// Throws Error if the record cannot be read or has no signals, if a
/// requested signal does not exist, if opt.from is negative ("read_record:
/// from must not be negative") or cannot be reached.  The getvec mode
/// (getgvmode()) and the time resolution of output annotators (getafreq())
/// are the same after the call as before it (opening an EDF record sets
/// both).  A signal file that is shorter than its header says, or that
/// cannot be read or decoded, throws "can't read signal data of record R
/// (getvec status -3)", even if the checksums do not match either (the
/// frame in which the file ends is then the one at which they are
/// verified): an incomplete frame is never returned.  No more than 2^26
/// samples are allocated in advance, whatever length the header or opt.to
/// gives.  If the header gives no sampling frequency, rec.fs is
/// 0, and a time string in opt.from or opt.to that needs it throws "sampling
/// frequency of record R is not specified".  Data that do not match the
/// header's checksums are returned, with a warning (see
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
    /// The "Key: value" entries of the header, in file order, as
    /// read_metadata() returns them: from the .hea file only (not from a
    /// .info file); empty, without an error, for an EDF record (which has no
    /// .hea file) and for a header read from the standard input ("-").
    Metadata metadata;
};

/// Read the header of `record`: its frequencies, length, signal
/// specifications, start time and date, info strings and metadata (the
/// "Key: value" entries, as read_metadata() returns them, with its warning
/// for a key given more than once).  The signal files
/// are not opened.  Returns a Header.  `legacy` behaves as the original WFDB
/// package, for this call only.  `input` says where the header is found (see
/// InputOptions).  Throws Error if the header cannot be read.
///
/// `record` is the record name, without the .hea extension (a trailing
/// ".hea" is also accepted): a full path, absolute ("/data/mitdb/100") or in
/// the home directory ("~/Documents/100s"), used as given; a relative path
/// ("100s", "data/100s"), read from the input directory if one is set,
/// otherwise from the current directory; or a URL
/// ("https://physionet.org/files/mitdb/1.0.0/100"), read only if network
/// access is on.
///
/// The time resolution of output annotators (getafreq()) and the getvec
/// mode (getgvmode()) are the same after the call as before it (opening an
/// EDF record sets both).
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
/// `record` is the record name, without the .hea extension (a trailing
/// ".hea" is also accepted): a full path, absolute ("/data/mitdb/100") or in
/// the home directory ("~/Documents/100s"), used as given; a relative path
/// ("100s", "data/100s"), read from the input directory if one is set,
/// otherwise from the current directory; or a URL
/// ("https://physionet.org/files/mitdb/1.0.0/100"), read only if network
/// access is on.
///
/// The sampling frequency is that of the record's header.  If the record
/// has no header, or its header gives none, `fs` is used, as the -F option
/// of rdann.  Without either, the result's fs is the time resolution of the
/// annotation file (0 if it has none).  `legacy` behaves as the original
/// WFDB package, for this call only.  `input` says where the files are found
/// (see InputOptions).
///
/// Throws Error if `from` is a negative sample number
/// ("read_annotations: from must not be negative", as read_record()
/// checks it; checked first, before anything is opened), if the annotation
/// file cannot be read, if `fs` is given and
/// is not greater than 0 ("read_annotations: fs must be > 0"), or if a time
/// string in `from` or `to` needs a frequency that is not known ("sampling
/// frequency of record R is not specified").  A file that ends early or
/// cannot be read before `to` is reached throws "can't read annotation file
/// A of record R (getann status S)", where S is the status getann() returned
/// (e.g. -3, unexpected end of file).
///
/// Whatever happens, the annotation file is closed (wfdbquit()) before
/// the function returns, and the time resolution of output annotators
/// (getafreq()) and the getvec mode (getgvmode()) are the same after the
/// call as before it (opening an EDF record sets both).
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
    /// "Key: value" entries written to the header after the comments, as
    /// "# Key: value" (through putinfo()), in this order.  The keys and
    /// values follow the rules of set_metadata(); no two keys may differ
    /// only in letter case, and none may be the key of an entry in
    /// `comments` (ArgumentError, before any file is created).
    Metadata metadata;
    /// If not empty, the directory (which must exist) in which to create the
    /// files, for this call only.  The record name must then be a plain
    /// name, without a directory, and the record opens from that directory
    /// under its plain name.
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
/// `record` is the record name, without the .hea extension (a trailing
/// ".hea" is removed, as by the readers): a plain name ("rec") or a
/// relative path ("data/rec"), created in the output directory
/// if one is set (see wfdbx_set_output_dir()), otherwise in the current
/// directory, missing directories included; or a full path, absolute or in
/// the home directory ("~/Documents/rec"), used as given.  With a path, the
/// files are created in that directory, and the header names the record and
/// its signal file without the path ("rec", "rec.dat"), so that the record
/// opens under any path that leads to it (in legacy mode, as in the
/// original, the header gives the name with its path).  A URL cannot be
/// written.
///
/// Throws Error, in this order, if the record name is empty, if a
/// samps_per_frame value is less than 1 ("samps_per_frame must hold
/// integers >= 1"), if nsig is not greater than 0 ("at least one signal is
/// required"), if a per-signal vector of `opt` has another length than 0, 1
/// or nsig, if the gains, the ADC resolutions (each at least 1) or the
/// units of a calibrated signal are missing ("gains must be specified",
/// "ADC resolution(s) must be specified", "units must be specified"), if fs
/// is not finite or not greater than 0, if a gain is not finite ("gains
/// must be finite"), if opt.base_time is not a valid time ("incorrect base
/// time 'T'"), if samples.size() is not a multiple of the frame size, if an
/// entry of opt.metadata is not valid (ArgumentError; see
/// WriteOptions::metadata); and then if the files cannot be created, or if
/// they cannot be written completely (for example, when the disk is full:
/// "write error on record R").  Every check except the last two comes
/// before any file is created or changed.  (The ADC resolutions, zeros and
/// baselines are ints, and the text is bytes, so that any value of these
/// types can be written.)
///
/// Existing files of the same names are replaced: the header and the
/// signal file are written to temporary files in the directories of their
/// destinations (".NAME.XXXXXXXX.tmp"), which replace the existing files,
/// with their permissions (or, for a new file, 0666 less the umask), only
/// when both are complete.  An error leaves the existing files as they
/// were, and no temporary file.  For a symbolic link, the file it leads to
/// is replaced; an existing file that is not a regular file (a device, a
/// FIFO) is written directly.  With opt.dir, it also throws if
/// the directory does not exist ("directory D does not exist") or the
/// record name contains one ("record name must not contain a directory when
/// dir is given").  The output signals are closed (wfdbquit()) before the
/// function returns, and the time resolution of output annotators
/// (getafreq()) and the getvec mode (getgvmode()) are left as they were.
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
/// outside the range of a 32-bit integer; nothing is written then.  The
/// record name and opt.dir are as for write_record(), and so are the
/// settings left as they were.
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
/// is not used).
///
/// `record` is the record name, without the .hea extension (a trailing
/// ".hea" is also accepted): a plain name or a relative path ("data/100s")
/// is created in the output directory if one is set (see
/// wfdbx_set_output_dir()), otherwise in the current directory; a full
/// path, absolute or in the home directory ("~/Documents/100s"), is used as
/// given.  The file is RECORD.ANNOTATOR at that place ("data/100s.qrs").  A
/// URL cannot be written.  If `dir` is not empty, it is the directory (which
/// must exist) in which to create the file, for this call only: `record`
/// must then be a plain name, without a directory, and the file is
/// DIR/RECORD.ANNOTATOR.
///
/// If the annotations are not in time order, the file is sorted when it is
/// written.  sort = false keeps the order given (without the library's
/// advice to run sortann) and sort = true always
/// sorts, for this call only.  Without `sort`, the WFDBANNSORT environment
/// variable decides: sorting is on unless it is 0.
///
/// Throws Error, in this order, if a field has another length than 0 or
/// n, if there is at least one annotation and neither symbols nor codes is
/// given ("symbols or codes must be given"; with no annotations, an empty
/// file is written), if `fs` is not 0 and not a finite frequency > 0, if a time is the
/// smallest or the largest 64-bit integer, which the file format reserves
/// ("annotation time T cannot be written (annotation times must be integers
/// from -9223372036854775807 to 9223372036854775806)"), if a code is not
/// from 0 to 58 ("annotation code C is reserved (59 to 63 are the control
/// codes of the annotation file format)", or "annotation code C is out of
/// range (0 to 58)"), if symbols and codes are both given and disagree
/// ("symbols and codes disagree at annotation K", K counted from 0); then
/// if the file cannot be created, if it cannot be written completely or
/// putann() reports an error ("write error on annotator A for record R"),
/// or for a `dir` as write_record() does.  The arguments are checked before
/// the file is created or changed.  An existing file is replaced as by
/// write_record(): the new file is written to a temporary file in the same
/// directory, which replaces it only when it is complete (and, if needed,
/// sorted), so that an error leaves it as it was.  The
/// annotator is closed (wfdbquit()) before the function returns, and the
/// time resolution of output annotators (getafreq()) and the getvec mode
/// (getgvmode()) are left as they were (`fs` applies to this file only).
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
/// read; a signal file that ends early, or cannot be read, ends the reading
/// before its incomplete frame, and is reported as such even in the frame
/// at which the checksums are verified) and the annotation files of
/// `annotators` (such as {"atr"}).
/// Problems in the record are reported, never thrown.  `input` says where
/// the files are found (see InputOptions).  The checks run in normal mode,
/// even if legacy mode is on, and the library prints no messages during the
/// call (the previous settings are restored afterwards).  The time
/// resolution of output annotators (getafreq()) and the getvec mode
/// (getgvmode()) are left as they were (opening an EDF record sets both).
///
/// `record` is the record name, without the .hea extension (a trailing
/// ".hea" is also accepted): a full path, absolute ("/data/mitdb/100") or in
/// the home directory ("~/Documents/100s"), used as given; a relative path
/// ("100s", "data/100s"), read from the input directory if one is set,
/// otherwise from the current directory; or a URL
/// ("https://physionet.org/files/mitdb/1.0.0/100"), read only if network
/// access is on (as for read_record()).
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

// ---------------------------------------------------------------------------
// Header metadata
//
// The info strings of a header are its comment lines (lines that begin with
// '#') after the record line, as getinfo() reads them.  Many datasets store
// facts about the recording in them as "Key: value" pairs, such as
// "# Age: 63", "# Sex: F" or "# Dx: 164889003".  These functions read and
// change such entries, without touching the rest of the header:
//
// * Reading.  An info string is an entry if it contains a colon (':').  The
//   key is the text between the '#' and the first colon, and the value is
//   the rest of the line; spaces, tabs, VT, FF and CR at either end of each
//   are removed.  So "#Age:45", "# Age: 45" and "#  Age : 45" all give
//   ("Age", "45").  An info string without a colon, or whose key is empty or
//   contains '#', is a free comment: it is not returned, and it is never
//   changed.  The record line is the first line that holds something other
//   than spaces, tabs, CRs and LFs (up to a NUL) and does not begin, after
//   them, with '#', as the header parser finds it, in every mode.  Comment
//   lines (and empty or blank lines) before the record line are not info
//   strings, and are never read or changed.  Only the header file (.hea) is read, not the
//   .info file that getinfo() also reads.
// * Keys are compared without regard to letter case (A-Z and a-z only), so
//   get_metadata(record, "age") finds "Age".  If a header holds several
//   entries whose keys differ only in letter case (a file written by other
//   software), reading returns the first of them, with a warning;
//   set_metadata() and update_metadata() refuse to change that key
//   (ArgumentError), and remove_metadata() removes all of them.  A key must
//   not be empty, and must not contain ':', '#', CR, LF or NUL; it may
//   contain spaces, as in "Date of birth".
// * Values are text, which may be a whole sentence.  Spaces at either end
//   are removed; a value must not contain CR, LF or NUL.  The empty string
//   is allowed.  Keys and values are bytes, as everywhere in the library
//   (UTF-8 text is stored as its bytes).
// * Writing.  An entry is written as "# Key: value" ("# Key:" if the value
//   is empty), with the caller's spelling of the key.  A changed entry
//   replaces its line, at the same position, keeping its line ending; a new
//   entry is added after the last info string (or, if the header has none,
//   after its last line that is not blank), with the line ending of the
//   record line ("\r\n" in the headers written by WFDB).  Every other byte of
//   the header is kept.  All the arguments are checked before anything is
//   written.  The new header is written to a temporary file in the directory
//   of the destination, which then replaces the destination (keeping its
//   permissions), so that an error never leaves a partly written header; the
//   temporary file is removed on any failure.  If nothing changes (and `dir`
//   is not given), nothing is written.
// * Which file.  The header is opened as the library opens the header of a
//   record (wfdb_open, after removing a trailing ".hea" from the name): under
//   the input directory, or as given for an absolute path, a "~" path or a
//   URL (if network access is on).  A change is written to the header that
//   was read, or, with MetadataOptions::dir, to the file of the same name in
//   that directory, leaving the original unchanged (the signal files are not
//   copied).  A header read from a URL can be read, but changed only with
//   `dir`.  Only the named header is read or changed: for a multi-segment
//   record, that is the master header, unless the name of a segment is
//   given.
//
// Warnings (a key given more than once) are printed on stderr with the
// library's messages, as the checksum warning of read_record() (wfdbquiet()
// silences them; wfdberror() returns the last).  Errors throw ArgumentError
// (invalid arguments) or FileError (a file that cannot be read or written),
// both subclasses of Error.  These functions do not call wfdbquit().
//
// Metadata often holds information about patients.  WFDB-x stores it as
// plain text, exactly as given, and does not de-identify it.

/// Options of set_metadata(), remove_metadata() and update_metadata().  The
/// fields inherited from InputOptions (input_dir, network) say where the
/// header is read from, for that call only.
struct MetadataOptions : InputOptions {
    /// If not empty, the directory (which must exist; a "~" path is
    /// expanded) in which the changed header is written, under the file name
    /// of the header that was read, instead of changing that header.  The
    /// header is then written even if nothing changes.  The signal files are
    /// not copied.
    std::string dir;
};

/// Read the metadata of `record`: the "Key: value" entries of its header
/// (see "Header metadata" above for the rules).
///
/// `record` is the record name, without the .hea extension (a trailing
/// ".hea" is also accepted): a full path, absolute ("/data/mitdb/100") or in
/// the home directory ("~/Documents/100s"), used as given; a relative path
/// ("100s", "data/100s"), read from the input directory if one is set,
/// otherwise from the current directory; or a URL
/// ("https://physionet.org/files/mitdb/1.0.0/100"), read only if network
/// access is on.  `input` gives the input directory and network access for
/// this call only (see InputOptions).
///
/// Returns the entries as (key, value) pairs, in file order.  A key that
/// appears more than once (ignoring letter case) is returned once, with its
/// first value, and the warning "WFDB-x: header of record R has more than
/// one entry for key K (lines L1, L2); the first is used" is printed (see
/// wfdbquiet()).
///
/// Throws FileError ("can't read header for record R") if the header cannot
/// be found or read, and ArgumentError if `record` is empty ("record name
/// must not be empty") or "-" (the standard input).
///
///     wfdbx::Metadata m = wfdbx::read_metadata("rec");
///     // {{"Age", "63"}, {"Sex", "F"}}
///
/// Part of WFDB-x; not in the original WFDB package.
Metadata read_metadata(const std::string &record,
                       const InputOptions &input = {});

/// The value of the metadata entry `key` of `record`, or std::nullopt if
/// its header has none.
///
/// `key` is compared without regard to letter case, after removing the
/// spaces at either end; it must be a valid key (see set_metadata()).
/// `record` and `input` are as for read_metadata().
///
/// Returns the value ("" for an entry with an empty value).  If the header
/// has several entries for `key`, the first is returned, with the warning
/// of read_metadata().
///
/// Throws as read_metadata() does, and ArgumentError if `key` is not valid.
///
///     std::optional<std::string> age = wfdbx::get_metadata("rec", "age");
///     // "63"
///
/// Part of WFDB-x; not in the original WFDB package.
std::optional<std::string> get_metadata(const std::string &record,
                                        const std::string &key,
                                        const InputOptions &input = {});

/// Set the value of the metadata entry `key` in the header of `record`.
///
/// If the header has an entry for `key` (ignoring letter case), its line is
/// replaced by "# Key: value", at the same position, with the spelling of
/// `key` given here (even if the value is the same).  Otherwise the entry is
/// added after the last info string of the header.  Every other byte of the
/// header is kept.
///
/// `key`, such as "Age" or "Date of birth", has the spaces at either end
/// removed; it must not then be empty, and must not contain ':', '#', CR,
/// LF or NUL.  `value`, which may be a sentence, has the spaces at either
/// end removed; it must not contain CR, LF or NUL, and may be empty.
/// `record` is as for read_metadata(); the header is changed where it was
/// read, unless opt.dir is given; a header read from a URL can only be
/// written elsewhere, with opt.dir.  `opt` gives the input directory and
/// network access for reading the header, and the directory in which to
/// write the changed header (see MetadataOptions), for this call only.
///
/// Throws ArgumentError if `key` or `value` is not valid, if the header has
/// more than one entry for `key` ("... remove them first"), if it has no
/// record line, if it was read from a URL and opt.dir is not given, or if
/// `record` is empty or "-"; FileError if the header cannot be read, if the
/// changed header cannot be written ("can't write header for record R"), or
/// if opt.dir does not exist ("directory D does not exist").  The arguments
/// are checked before anything is written, and the header is replaced in one
/// step, so that an error leaves it unchanged.
///
///     wfdbx::set_metadata("rec", "Age", "63");    // writes "# Age: 63"
///
/// Part of WFDB-x; not in the original WFDB package.
void set_metadata(const std::string &record, const std::string &key,
                  const std::string &value, const MetadataOptions &opt = {});

/// Remove the metadata entry `key` from the header of `record`.
///
/// Every entry for `key` (ignoring letter case) is removed, with its line
/// ending, so this also repairs a header that has more than one.  Every
/// other byte is kept.  Nothing is written if the header has no entry for
/// `key` (unless opt.dir is given).  `record`, `key` and `opt` are as for
/// set_metadata().
///
/// Returns the number of lines removed (0 if the header has no entry for
/// `key`).  Throws as set_metadata() does.
///
///     int n = wfdbx::remove_metadata("rec", "Age");    // 1
///
/// Part of WFDB-x; not in the original WFDB package.
int remove_metadata(const std::string &record, const std::string &key,
                    const MetadataOptions &opt = {});

/// Make several changes to the metadata of `record` in one write.
///
/// Each (key, value) of `changes` is applied in order, as set_metadata()
/// does, or, if the value is std::nullopt, as remove_metadata() does.  No
/// two keys may differ only in letter case.  Empty `changes` change nothing
/// (and write nothing, unless opt.dir is given).  `record` and `opt` are as
/// for set_metadata().
///
/// Throws as set_metadata() does.  All the changes are checked first: if one
/// is not valid, none is made.
///
///     wfdbx::update_metadata("rec", {{"Age", "64"}, {"Dx", std::nullopt}});
///
/// Part of WFDB-x; not in the original WFDB package.
void update_metadata(const std::string &record, const MetadataChanges &changes,
                     const MetadataOptions &opt = {});

} // namespace wfdbx

#endif // WFDBX_RECORD_HPP
