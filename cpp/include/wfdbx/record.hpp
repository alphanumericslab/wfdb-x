// wfdbx/record.hpp: high-level interface for reading and writing records
//
// These functions read and write whole records and annotation files with a
// few calls.  They are built on the WFDB library API (<wfdbx/wfdb.hpp>), so
// they read and write exactly what the WFDB library and the command-line
// tools do.  Files are found by explicit names (wfdb-x: nothing is searched):
// a relative record name is read under the input directory (the
// `input_dir` option, or wfdbx_set_input_dir(); by default the current
// directory) and written under the output directory (the `dir` option of the
// writers, or wfdbx_set_output_dir()); an absolute name, a "~" name or a URL
// is used as given.  URLs need network access (the `network` option, or
// wfdbx_set_network()).
//
// Errors are reported by throwing wfdbx::Error.  The functions call
// wfdbquit() before and after their work, closing any record opened with the
// WFDB library API; like the rest of the library, they are not thread-safe.  Results are
// returned by value and own their data.
//
// wfdb-x never assumes a sampling frequency, a gain, an ADC resolution or
// units (C: WFDB_DEFFREQ, 250 Hz, WFDB_DEFGAIN, 200 adu/mV, WFDB_DEFRES or a
// resolution based on the format, 12 bits, and millivolts): write_record()
// requires the gains, the ADC resolutions and the units of calibrated
// signals, a record without a frequency is read with fs = 0, an unspecified
// resolution is read as 0 and unspecified units as std::nullopt, and
// conversions that need a missing value throw Error (see
// docs/DIVERGENCES.md).
//
// Input directory and network access (wfdb-x): with the `input_dir` and
// `network` options of the readers (ReadOptions::input_dir and
// ReadOptions::network, an InputOptions argument of read_header() and
// read_annotations()), the setting is changed for the duration of the call
// and restored afterwards, also on errors; unset options keep the current
// settings.
//
// Output directory (wfdb-x): with WriteOptions::dir (or the `dir` parameter
// of write_annotations()), the files are created in that directory, and the
// header names the record and its signal file without it, so that the record
// opens from there under its plain name.  The library's output directory
// (wfdbx_set_output_dir()) is set for the duration of the call and restored
// afterwards, also on errors.
//
// Legacy mode: with the `legacy` option (ReadOptions::legacy,
// WriteOptions::legacy, the `legacy` parameter of read_header() and
// read_annotations()), a function behaves exactly as in the original
// package (250 Hz, 200 adu/mV, a resolution based on the format), with the
// library's legacy mode on for the duration of the call (see
// wfdbx_set_legacy()).  It is kept for compatibility only: the values it
// assumes are exactly the silent defaults this project removed, so results
// produced with it carry the same risks.
//
//     #include <wfdbx/record.hpp>
//
//     wfdbx::ReadOptions opt;
//     opt.to = "0:10";                    // the first 10 seconds
//     wfdbx::Record rec = wfdbx::read_record("100s", opt);
//     double v = rec.physical(0, 1);      // sample 0 of signal 1, in
                                        // rec.siginfo[1].units
//     wfdbx::Annotations ann = wfdbx::read_annotations("100s", "atr");
//     for (size_t i = 0; i < ann.size(); i++)
//         std::printf("%lld %s\n", ann.samples[i], ann.symbols[i].c_str());
//
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md.
// Design decision (Reza Sameni, after a code review, Oct 2026): the writers
// take an output directory (the record then opens from there under its plain
// name).
// Design decision (Reza Sameni, Oct 2026): files are found only where they are
// named (no search path), and the readers take an input directory and the
// permission to use the network, because a search can silently open the
// wrong file, and the network must not be used without being asked for. The
// original behavior remains available with --legacy (see docs/DIVERGENCES.md).
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
/// failed operation (e.g. "can't read record 100s"); the message of the WFDB
/// library, if any, is printed on stderr (see wfdbquiet()) and available
/// from wfdberror().
class Error : public std::runtime_error {
public:
    using std::runtime_error::runtime_error;
};

/// A time: a sample number, or a WFDB time string ("0:10", "s1000",
/// "[12:00:00]", "e" for the end of the record; see strtim()).  Converts
/// implicitly from integers and strings, so `opt.from = 3600;` and
/// `opt.from = "0:10";` both work.  A default-constructed TimeSpec is
/// empty (meaning "not specified").
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
    /// strtim() for the record currently open; a time of day gives the
    /// (positive) sample number it corresponds to.
    WFDB_Time resolve() const;
private:
    std::optional<WFDB_Time> t_;
    std::optional<std::string> s_;
};

/// Where the readers find files (wfdb-x): each option that is set changes the
/// library's setting for the duration of the call (restored afterwards, also
/// on errors); unset options keep the current settings.
struct InputOptions {
    /// The input directory (see wfdbx_set_input_dir()): a local directory or
    /// the URL of a directory; "" means the default (WFDBX_INPUT_DIR, or the
    /// current directory).
    std::optional<std::string> input_dir;
    /// Network access (see wfdbx_set_network()): true allows opening URLs,
    /// false forbids it.
    std::optional<bool> network;
};

/// Signals of a record (or of a part of one), read by read_record().
struct Record {
    std::string name;           ///< record name, as given to read_record()
    /// Sampling frequency of the returned samples; 0 if the header does not
    /// specify it (wfdb-x: no default frequency).
    WFDB_Frequency fs = 0;
    int nsig = 0;               ///< number of (returned) signals
    /// Signal number, in the record, of each returned signal.
    std::vector<int> signals;
    /// Samples in ADC units, frame by frame: samples[i * nsig + s] is
    /// sample i of signal s.  Invalid samples are WFDB_INVALID_SAMPLE.
    std::vector<WFDB_Sample> samples;
    std::vector<WFDB_Siginfo> siginfo;  ///< one per returned signal
    /// Base time of the record, as timstr(0) gives it (to the second), e.g.
    /// "[08:45:00 01/01/2001]"; nullopt if the header has none.
    std::optional<std::string> base_time;
    /// Base time of the record in milliseconds after midnight (the
    /// library's base time, with its milliseconds: "14:00:03.500" gives
    /// 50403500); given exactly when base_time is, nullopt otherwise.
    std::optional<long long> base_time_ms;
    /// Base date of the record as {year, month, day} (computed as datstr()
    /// does); nullopt if the header gives no date.
    std::optional<std::array<int, 3>> base_date;
    WFDB_Time sampfrom = 0;     ///< sample number of the first returned sample
    /// Info strings of the record (header comments and .info file; see
    /// getinfo()).
    std::vector<std::string> comments;
    /// false if the signal data were found not to match the checksums in
    /// the header (getvec status -4 during the read; see
    /// ReadOptions::checksum_warning, which does not change this field),
    /// true otherwise.  The checksums are verified only when a read reaches
    /// the end of the record: a read that stops before it gives true.
    bool checksum_ok = true;
    /// Read in legacy mode (ReadOptions::legacy): physical() then assumes
    /// WFDB_DEFGAIN for uncalibrated signals, as the original package did.
    bool legacy = false;

    /// Number of samples per signal.
    size_t nsamples() const { return nsig ? samples.size() / nsig : 0; }
    /// Sample i of signal s, in ADC units (not bounds-checked).
    WFDB_Sample at(size_t i, int s) const { return samples[i * nsig + s]; }
    /// Sample i of signal s in physical units: (value - baseline) / gain;
    /// NaN if the sample is invalid.  The units are siginfo[s].units
    /// (std::nullopt if the header does not specify them; wfdb-x: they are
    /// not assumed to be millivolts).  Throws Error ("signal N of record R is uncalibrated") if
    /// the gain of the signal is 0 (wfdb-x: no default gain).
    double physical(size_t i, int s) const;
    /// All samples of signal s in physical units (see physical()).
    std::vector<double> physical_signal(int s) const;
    /// The signal descriptions (siginfo[s].desc, "" if absent).
    std::vector<std::string> names() const;
};

/// Options of read_record().  The InputOptions (input_dir, network) say
/// where the files are found.
struct ReadOptions : InputOptions {
    /// Signals to return, in this order, by number ("0", "1", ...) or
    /// description (as findsig() accepts them); empty: all signals.
    std::vector<std::string> channels;
    TimeSpec from;              ///< first sample (default: 0)
    TimeSpec to;                ///< end, exclusive (default: end of record)
    /// Multi-frequency records: return every sample of oversampled signals,
    /// repeating those of the other signals (WFDB_HIGHRES mode); otherwise
    /// oversampled signals are averaged to one sample per frame.
    bool highres = false;
    /// Replace invalid samples by the previous valid sample (WFDB_GVPAD).
    bool pad = false;
    /// wfdb-x: if the signal data do not match the checksums of the header
    /// (getvec status -4), the data are returned all the same (every frame),
    /// and, if this is true (the default), the warning "wfdb-x: checksum
    /// error in record REC: the signal data do not match the checksums in
    /// its header" is printed on stderr as a library message (silenced by
    /// wfdbquiet(); getvec's own checksum message is not printed during the
    /// read).
    bool checksum_warning = true;
    /// Legacy mode (original behavior, for compatibility only: a header
    /// without a frequency means 250 Hz, a missing resolution is inferred
    /// from the format, and physical() assumes 200 adu/unit for uncalibrated
    /// signals; see the note at the top of this header).
    bool legacy = false;
};

/// Read the signals of `record` from opt.from to opt.to (the samples
/// available, if the record ends before opt.to).  Throws Error if the record
/// cannot be read or has no signals, if a requested signal does not exist,
/// or if opt.from cannot be reached; also if reading stops with a getvec
/// status below -1 (e.g. -3: a signal file shorter than its header says,
/// or a read or decoding error), with the message "can't read signal data
/// of record R (getvec status S)" (also in legacy mode; reaching the end of
/// the record before opt.to is not an error).  wfdb-x: a checksum error
/// (status -4) is not an error: every frame is returned, with a warning
/// (see ReadOptions::checksum_warning).  If the header does not specify the
/// sampling frequency, rec.fs is 0, and a time string in opt.from or opt.to
/// that needs it throws Error ("sampling frequency of record R is not
/// specified").
Record read_record(const std::string &record, const ReadOptions &opt = {});

/// The header of a record, read by read_header().
struct Header {
    std::string name;           ///< record name, as given to read_header()
    /// Sampling frequency, as sampfreq() gives it; 0 if the header does not
    /// specify it (wfdb-x: no default frequency; in legacy mode, the
    /// original default, 250 Hz).
    WFDB_Frequency fs = 0;
    WFDB_Frequency counter_freq = 0;    ///< counter frequency (getcfreq())
    double base_counter = 0;    ///< base counter value (getbasecount())
    /// Number of samples per signal, from the record line of the header (0
    /// if the header does not give it).
    WFDB_Time nsamples = 0;
    int nsig = 0;               ///< number of signals
    /// The signal specifications, one per signal (empty if the record has
    /// none).
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
/// specifications, base time and date and info strings (see Header).  The
/// signal files are not opened.  `input` says where the header is found
/// (see InputOptions).  Throws Error if the header cannot be read.  With
/// `legacy` (for compatibility only), the header is read as by the original
/// package (250 Hz if it has no frequency, ADC resolutions inferred from the
/// format).
Header read_header(const std::string &record, bool legacy = false,
                   const InputOptions &input = {});

/// An annotation file, as parallel arrays: annotation i is samples[i],
/// codes[i], symbols[i], ...  Returned by read_annotations(); also the input
/// of write_annotations().
struct Annotations {
    std::string record, annotator;  ///< e.g. "100s" and "atr"
    WFDB_Frequency fs = 0;      ///< time resolution (ticks per second)
    std::vector<WFDB_Time> samples;     ///< times (sample numbers)
    std::vector<int> codes;     ///< annotation types (NORMAL, PVC, ...)
    std::vector<std::string> symbols;   ///< mnemonics, as annstr() returns
    std::vector<int> subtypes, chans, nums;  ///< subtyp, chan, num fields
    /// Auxiliary information as text (without the length byte of
    /// WFDB_Annotation::aux; up to its first null byte); nullopt if absent.
    std::vector<std::optional<std::string>> aux;

    /// Number of annotations.
    size_t size() const { return samples.size(); }
};

/// Read the annotations of `annotator` for `record` (as rdann does), from
/// time `from` (default: the start) up to `to`, exclusive (default: the
/// end); `input` says where the files are found (see InputOptions).  The
/// sampling frequency is that of the record's header; if the
/// record has no header, or its header does not specify one, `fs` (if
/// given) is used, as by the -F option of rdann (wfdb-x: there is no default
/// frequency).  A given `fs` must be > 0 (otherwise Error "read_annotations:
/// fs must be > 0" is thrown); std::nullopt (the default) gives none.  Without either, the result's fs is the time resolution of
/// the annotation file (0 if it has none), and a time string in `from` or
/// `to` that needs the frequency throws Error ("sampling frequency of record
/// R is not specified").  Throws Error if the annotation file cannot be
/// read.  With `legacy` (for compatibility only), the original behavior:
/// WFDB_DEFFREQ (250 Hz) if the record has no header or its header has no
/// frequency (and `fs` is not given).
Annotations read_annotations(const std::string &record,
                             const std::string &annotator,
                             const TimeSpec &from = {},
                             const TimeSpec &to = {},
                             std::optional<WFDB_Frequency> fs = std::nullopt,
                             bool legacy = false,
                             const InputOptions &input = {});

/// Options of write_record() and write_record_physical().  Each per-signal
/// vector may hold one value (used for every signal) or one value per
/// signal; signals without a value get the default.
struct WriteOptions {
    int fmt = 16;               ///< storage format (the same for all signals)
    /// Gains (adu per physical unit): REQUIRED, one value or one per signal
    /// (wfdb-x: there is no default gain).  A gain of 0 declares a signal
    /// uncalibrated, which is allowed only by write_record() (ADC units).
    std::vector<WFDB_Gain> gains;
    std::vector<int> baselines;         ///< default: the adczeros values
    std::vector<int> adczeros{0};       ///< ADC output for 0 V input
    /// ADC resolutions in bits: REQUIRED, one value or one per signal, each
    /// >= 1 (wfdb-x: no default; C inferred them from the format).
    std::vector<int> adcres;
    /// Units: REQUIRED (not empty) for every signal whose gain is not 0
    /// (wfdb-x: units are not assumed to be millivolts); optional for
    /// uncalibrated signals.
    std::vector<std::optional<std::string>> units;
    std::vector<std::string> names;     ///< signal descriptions (default: "")
    /// Samples per frame of each signal, for multi-frequency records
    /// (default: 1).
    std::vector<int> samps_per_frame;
    std::optional<std::string> base_time;   ///< e.g. "12:00:00 01/01/2020"
    std::vector<std::string> comments;  ///< info strings (header comments)
    /// If not empty, the directory (which must exist) in which the files are
    /// created; the header then names the record and its signal file without
    /// the directory, so that the record opens from that directory under its
    /// plain name (the record name must not contain a directory).  The same
    /// in legacy mode.  (wfdb-x addition; see wfdbx_set_output_dir().)
    std::string dir;
    /// Legacy mode (original behavior, for compatibility only): gains
    /// default to WFDB_DEFGAIN (200; write_record_physical() also uses it
    /// for a gain of 0), ADC resolutions to a value based on the format, and
    /// neither the units nor fs > 0 are required (see the note at the top
    /// of this header).
    bool legacy = false;
};

/// Write a record: the signal file "<record>.dat" and the header
/// "<record>.hea".  `samples` holds the samples in ADC units, frame by frame
/// (nsig values per frame, or the sum of opt.samps_per_frame values per
/// frame for multi-frequency records); WFDB_INVALID_SAMPLE marks invalid
/// samples.  Throws Error if nsig <= 0, if fs <= 0, if the gains are not
/// specified ("gains must be specified"), if the ADC resolutions are not
/// specified or < 1 ("ADC resolution(s) must be specified"), if the units of
/// a signal whose gain is not 0 are not specified ("units must be
/// specified"), if samples.size() is not a
/// multiple of the frame size, if the files cannot be created, or, with
/// opt.dir, if the directory does not exist ("directory D does not exist") or
/// the record name contains one ("record name must not contain a directory
/// when dir is given").
void write_record(const std::string &record,
                  const std::vector<WFDB_Sample> &samples, int nsig,
                  WFDB_Frequency fs, const WriteOptions &opt = {});

/// As write_record(), with samples in physical units: each is converted to
/// round(v * gain) + baseline (as physadu() does), and NaN becomes an
/// invalid sample.  Throws Error ("signal N is uncalibrated") if a gain is 0
/// (wfdb-x: no default gain).
void write_record_physical(const std::string &record,
                           const std::vector<double> &samples, int nsig,
                           WFDB_Frequency fs, const WriteOptions &opt = {});

/// Write the annotation file of `annotator` for `record` (as wrann does),
/// "<record>.<annotator>".  The type of each annotation is given by its
/// `symbols` entry (converted with strann(); unknown mnemonics give NOTQRS),
/// or by its `codes` entry if the symbol is empty or missing; missing
/// subtypes, chans, nums and aux entries are 0 or absent, and aux texts are
/// truncated to 255 bytes.  If fs > 0, it is recorded as the time
/// resolution of the file (ann.fs is not used).  Annotations should be in
/// time order; otherwise, the file is sorted when it is closed (see
/// oannclose(); wfdb-x: in this process, whereas the C library, as legacy
/// mode, runs sortann) if `sort` says so: std::nullopt (the default): as
/// the WFDBANNSORT environment variable says (by default, sorted); true:
/// sorted; false: left in the order given (for this call only, whatever
/// WFDBANNSORT says; the environment is not changed; the same in legacy
/// mode).  If `dir` is not empty, the file is created in that directory,
/// which must exist (the record name must not contain a directory).  Throws
/// Error if the file cannot be created, or for a `dir` as write_record()
/// does.
void write_annotations(const std::string &record, const std::string &annotator,
                       const Annotations &ann, WFDB_Frequency fs = 0,
                       const std::string &dir = {},
                       std::optional<bool> sort = std::nullopt);

} // namespace wfdbx

#endif // WFDBX_RECORD_HPP
