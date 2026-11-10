// record.cpp: high-level interface for reading and writing records
// (see <wfdbx/record.hpp>; the equivalent of python/src/wfdbx/highlevel.py)
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
// Like the library, these functions assume no sampling frequency, gain, ADC
// resolution or units, and find files only where they are named; the writers
// take an output directory (WriteOptions::dir, the `dir` parameter of
// write_annotations): the files are created in it, and the record opens from
// there under its plain name. The `legacy` options give the behavior of the
// original package (see docs/DIVERGENCES.md).

#include "wfdbx/record.hpp"

#include "wfdblib.hpp"      // (wfdbx_set_checksum_quiet, ...)

#include <cmath>
#include <exception>
#include <filesystem>
#include <limits>

namespace wfdbx {

namespace {

// The largest annotation code (59 to 63 are the control codes of the MIT
// format).
constexpr int MAXCODE = 58;

[[noreturn]] void fail(const std::string &msg)
{
    wfdbquit();
    throw Error(msg);
}

// WFDB-x: wfdbquit() when the object is destroyed by an exception (so that
// no input file stays open after an error, whatever its cause).  Declared
// after the other scopes of a function, it runs before they restore their
// settings.
class QuitOnErrorScope {
public:
    QuitOnErrorScope() : n_(std::uncaught_exceptions()) {}
    ~QuitOnErrorScope() { if (std::uncaught_exceptions() > n_) wfdbquit(); }
    QuitOnErrorScope(const QuitOnErrorScope &) = delete;
    QuitOnErrorScope &operator=(const QuitOnErrorScope &) = delete;
private:
    int n_;
};

// Library legacy mode on for the lifetime of the object if `on` (restoring
// the previous setting afterwards, also when an exception is thrown); no
// change otherwise.
class LegacyScope {
public:
    explicit LegacyScope(bool on)
        : on_(on), prev_(on ? wfdbx_set_legacy(1) : 0) {}
    ~LegacyScope() { if (on_) wfdbx_set_legacy(prev_); }
    LegacyScope(const LegacyScope &) = delete;
    LegacyScope &operator=(const LegacyScope &) = delete;
private:
    bool on_;
    int prev_;
};

// WFDB-x: getvec's checksum message not printed for the lifetime of the
// object (read_record reports a checksum error itself).
class ChecksumQuietScope {
public:
    ChecksumQuietScope() : prev_(detail::wfdbx_set_checksum_quiet(true)) {}
    ~ChecksumQuietScope() { detail::wfdbx_set_checksum_quiet(prev_); }
    ChecksumQuietScope(const ChecksumQuietScope &) = delete;
    ChecksumQuietScope &operator=(const ChecksumQuietScope &) = delete;
private:
    bool prev_;
};

// WFDB-x: a sample that cannot be read is a read error for the lifetime of
// the object, whatever status getvec returns: getvecs stops before the
// frame, with status -3 (see detail::wfdbx_set_read_checked; a checksum
// error found in the frame in which a signal file ends early gives -4,
// which replaces -3, and the incomplete frame was returned).  The flag is
// cleared at both ends.
class ReadCheckedScope {
public:
    ReadCheckedScope() : prev_(detail::wfdbx_set_read_checked(true)) {}
    ~ReadCheckedScope() { detail::wfdbx_set_read_checked(prev_); }
    ReadCheckedScope(const ReadCheckedScope &) = delete;
    ReadCheckedScope &operator=(const ReadCheckedScope &) = delete;
private:
    bool prev_;
};

// WFDB-x: the getvec mode (getgvmode, setgvmode) and the time resolution of
// output annotators (getafreq, setafreq) restored at the end of the lifetime
// of the object (also when an exception is thrown), in that order.  Every
// high-level function that opens a record keeps them: read_record sets the
// getvec mode, and opening an EDF record sets both, as in C (the time
// resolution to the record's sampling frequency when none is set, and the
// WFDB_HIGHRES bit of the getvec mode), and wfdbquit() resets neither;
// without this, a later write_annotations() would record that frequency, and
// later reading would be in high resolution.  (The input annotators, and
// their frequencies, are closed by wfdbquit().)  The C-style functions keep
// the behavior of C.
class SettingsScope {
public:
    SettingsScope() : gvmode_(getgvmode()), afreq_(getafreq()) {}
    ~SettingsScope()
    {
        setgvmode(gvmode_);
        setafreq(afreq_);
    }
    SettingsScope(const SettingsScope &) = delete;
    SettingsScope &operator=(const SettingsScope &) = delete;
private:
    int gvmode_;
    WFDB_Frequency afreq_;
};

// WFDB-x: the library's input directory and network access (see
// InputOptions) set for the lifetime of the object, for the options that are
// set (restoring the previous settings afterwards, also when an exception is
// thrown); no change otherwise.
class InputScope {
public:
    explicit InputScope(const InputOptions &in) : in_(in)
    {
        if (in_.input_dir) prev_dir_ = wfdbx_set_input_dir(in_.input_dir->c_str());
        if (in_.network) prev_net_ = wfdbx_set_network(*in_.network ? 1 : 0);
    }
    ~InputScope()
    {
        if (in_.network) wfdbx_set_network(prev_net_);
        // (with no previous value, nullptr restores it: there is then no
        // WFDBX_INPUT_DIR value either)
        if (in_.input_dir)
            wfdbx_set_input_dir(prev_dir_ ? prev_dir_->c_str() : nullptr);
    }
    InputScope(const InputScope &) = delete;
    InputScope &operator=(const InputScope &) = delete;
private:
    InputOptions in_;
    std::optional<std::string> prev_dir_;
    int prev_net_ = 0;
};

// WFDB-x: the library's output directory (wfdbx_set_output_dir) set to
// `dir` for the lifetime of the object, if `dir` is not empty (restoring the
// previous one afterwards, also when an exception is thrown); no change
// otherwise.  Throws Error if `record` contains a directory or if `dir` does
// not exist; the writers construct it first, so that these checks come
// before any other validation (and before anything is written).
class OutputDirScope {
public:
    OutputDirScope(const std::string &record, const std::string &dir)
        : on_(!dir.empty())
    {
        if (!on_) return;
#if defined(_WIN32)
        const char *seps = "/\\";
#else
        const char *seps = "/";
#endif
        if (record.find_first_of(seps) != std::string::npos)
            throw Error("record name must not contain a directory when dir "
                        "is given");
        std::error_code ec;
        if (!std::filesystem::is_directory(dir, ec))
            throw Error("directory " + dir + " does not exist");
        prev_ = wfdbx_set_output_dir(dir.c_str());
    }
    ~OutputDirScope()
    {
        if (on_) wfdbx_set_output_dir(prev_ ? prev_->c_str() : nullptr);
    }
    OutputDirScope(const OutputDirScope &) = delete;
    OutputDirScope &operator=(const OutputDirScope &) = delete;
private:
    bool on_;
    std::optional<std::string> prev_;
};

template <typename T>
T per_signal(const std::vector<T> &v, size_t k, T dflt)
{
    if (v.empty()) return dflt;
    return v.size() == 1 ? v[0] : (k < v.size() ? v[k] : dflt);
}

// The gain of signal k: the single value, or the k-th one.  Throws Error if
// it is not given (WFDB-x: no default gain; C assumed WFDB_DEFGAIN).
WFDB_Gain gain_of(const WriteOptions &opt, int k)
{
    // WFDB-x: legacy mode (original behavior): WFDB_DEFGAIN by default
    if (opt.legacy) return per_signal<WFDB_Gain>(opt.gains, k, WFDB_DEFGAIN);
    if (opt.gains.size() == 1) return opt.gains[0];
    if (static_cast<size_t>(k) < opt.gains.size()) return opt.gains[k];
    throw Error("write_record: gains must be specified");
}

// The options of a high-level call, in legacy mode if the call asks for it
// or if the library is in legacy mode (wfdbx_set_legacy).
template <class Options>
Options with_library_legacy(const Options &opt)
{
    Options o = opt;
    o.legacy = opt.legacy || wfdbx_get_legacy() != 0;
    return o;
}

// The ADC resolution the original package assumed for a format (legacy
// mode).
int legacy_adcres(int fmt)
{
    switch (fmt) {
    case 80: case 508: return 8;
    case 212: return 12;
    case 310: case 311: return 10;
    case 24: case 524: return 24;
    case 32: return 32;
    default: return 16;
    }
}

// The ADC resolution of signal k: the single value, or the k-th one.  Throws
// Error if it is not given or < 1 (WFDB-x: no default resolution; C inferred
// it from the format).
int adcres_of(const WriteOptions &opt, int k)
{
    // WFDB-x: legacy mode (original behavior): inferred from the format
    if (opt.legacy)
        return per_signal<int>(opt.adcres, k, legacy_adcres(opt.fmt));
    int r = per_signal<int>(opt.adcres, k, 0);
    if (r < 1)
        throw Error("write_record: ADC resolution(s) must be specified");
    return r;
}

// The base time (text and milliseconds) and date of the record opened
// last (see Record::base_time, base_time_ms and base_date), and, if `nsamp`
// is not null, the number of samples per signal its header gives.  The text
// is given only if `has_time` (a header without a sampling frequency cannot
// give a base time, except in legacy mode).
void base_time_fields(bool has_time, std::optional<std::string> &text,
                      std::optional<long long> &ms,
                      std::optional<std::array<int, 3>> &date,
                      WFDB_Time *nsamp = nullptr)
{
    WFDB_Time n;
    long btime;
    WFDB_Date bdate;
    detail::wfdbx_header_values(&n, &btime, &bdate);
    if (nsamp) *nsamp = n;
    if (has_time) {
        std::string bt = timstr(0);
        if (!bt.empty() && bt[0] == '[') {
            text = bt;
            ms = btime;
        }
    }
    if (bdate != 0) {
        std::array<int, 3> ymd;
        detail::wfdbx_julian_ymd(bdate, &ymd[0], &ymd[1], &ymd[2]);
        date = ymd;
    }
}

// WFDB-x: the sorting of out-of-order output annotation files decided by
// `sort` for the lifetime of the object, if it is given (see
// write_annotations; restored afterwards, also when an exception is
// thrown); no change otherwise.
class AnnSortScope {
public:
    explicit AnnSortScope(std::optional<bool> sort)
        : on_(sort.has_value()),
          prev_(on_ ? detail::wfdbx_set_annsort(*sort ? 1 : 0) : -1) {}
    ~AnnSortScope() { if (on_) detail::wfdbx_set_annsort(prev_); }
    AnnSortScope(const AnnSortScope &) = delete;
    AnnSortScope &operator=(const AnnSortScope &) = delete;
private:
    bool on_;
    int prev_;
};

// The white space (C isspace) that strip_desc() removes.
const char *const SPACE = " \t\n\v\f\r";

// `s` without the white space at both ends.
std::string strip_space(const std::string &s)
{
    size_t a = s.find_first_not_of(SPACE);
    if (a == std::string::npos) return std::string();
    return s.substr(a, s.find_last_not_of(SPACE) - a + 1);
}

// WFDB-x: the high-level readers give the signal descriptions without the
// white space that some headers end them with (C keeps it, as the C-style
// functions do).
void strip_desc(std::vector<WFDB_Siginfo> &si)
{
    for (WFDB_Siginfo &s : si)
        if (s.desc) s.desc = strip_space(*s.desc);
}

} // namespace

bool TimeSpec::needs_freq() const
{
    return s_ && wfdbx_time_needs_freq(s_->c_str());
}

WFDB_Time TimeSpec::resolve() const
{
    if (t_) return *t_;
    if (s_) {
        WFDB_Time t = strtim(s_->c_str());
        return t < 0 ? -t : t;
    }
    return 0;
}

double Record::physical(size_t i, int s) const
{
    WFDB_Sample v = at(i, s);
    if (v == WFDB_INVALID_SAMPLE)
        return std::numeric_limits<double>::quiet_NaN();
    double g = siginfo[s].gain;
    if (g == 0 && legacy)   // WFDB-x: legacy mode (original behavior)
        g = WFDB_DEFGAIN;
    if (g == 0) {   // WFDB-x: no default gain (C assumed WFDB_DEFGAIN)
        int n = static_cast<size_t>(s) < signals.size() ? signals[s] : s;
        throw Error("signal " + std::to_string(n) + " of record " + name +
                    " is uncalibrated");
    }
    return (static_cast<double>(v) - siginfo[s].baseline) / g;
}

std::vector<double> Record::physical_signal(int s) const
{
    size_t n = nsamples();
    std::vector<double> out(n);
    for (size_t i = 0; i < n; i++) out[i] = physical(i, s);
    return out;
}

std::vector<std::string> Record::names() const
{
    std::vector<std::string> v;
    for (const WFDB_Siginfo &si : siginfo) v.push_back(si.desc.value_or(""));
    return v;
}

Header read_header(const std::string &record, bool legacy,
                   const InputOptions &input)
{
    LegacyScope scope(legacy);
    InputScope input_scope(input);
    SettingsScope settings_scope;
    QuitOnErrorScope quit_scope;
    wfdbquit();
    int n = isigopen(record.c_str(), nullptr, 0);
    if (n < 0) fail("can't read header for record " + record);
    Header h;
    h.siginfo.resize(n);
    if (n > 0) isigopen(record.c_str(), h.siginfo.data(), -n);
    strip_desc(h.siginfo);
    h.name = record;
    h.fs = sampfreq(nullptr);
    h.counter_freq = getcfreq();
    h.base_counter = getbasecount();
    h.nsig = n;
    base_time_fields(h.fs > 0 || wfdbx_get_legacy() != 0, h.base_time,
                     h.base_time_ms, h.base_date, &h.nsamples);
    for (auto c = getinfo(record.c_str()); c; c = getinfo(nullptr))
        h.comments.push_back(*c);
    const bool edf = detail::wfdbx_input_is_edf();
    wfdbquit();
    // WFDB-x: the "Key: value" entries of the .hea file only (not of a .info
    // file), as read_metadata() reads them; none for an EDF record (which
    // has no .hea file) or a header read from the standard input.
    if (!edf && record != "-") h.metadata = read_metadata(record);
    return h;
}

Record read_record(const std::string &record, const ReadOptions &options)
{
    const ReadOptions opt = with_library_legacy(options);
    LegacyScope scope(opt.legacy);
    InputScope input_scope(opt);
    SettingsScope settings_scope;
    QuitOnErrorScope quit_scope;
    wfdbquit();
    int nsig = isigopen(record.c_str(), nullptr, 0);
    if (nsig <= 0) fail("can't read record " + record);
    std::vector<WFDB_Siginfo> si(nsig);
    nsig = isigopen(record.c_str(), si.data(), nsig);
    if (nsig <= 0) fail("can't open signals of record " + record);
    setgvmode((opt.highres ? WFDB_HIGHRES : WFDB_LOWRES) |
              (opt.pad ? WFDB_GVPAD : 0));

    Record rec;
    rec.name = record;
    rec.legacy = opt.legacy;
    rec.fs = sampfreq(nullptr);
    // WFDB-x: no default sampling frequency (C assumed 250 Hz).
    if (!opt.legacy && rec.fs <= 0 &&
        (opt.from.needs_freq() || opt.to.needs_freq()))
        fail("sampling frequency of record " + record + " is not specified");
    WFDB_Time from = opt.from.resolve();
    // (isigsettime would take a negative time as an absolute one)
    if (from < 0) fail("read_record: from must not be negative");
    std::optional<WFDB_Time> to;
    if (!opt.to.empty()) to = opt.to.resolve();

    strip_desc(si);
    std::vector<int> cols;
    if (opt.channels.empty()) {
        for (int k = 0; k < nsig; k++) cols.push_back(k);
    } else {
        for (const std::string &c : opt.channels) {
            // (a name as in Record::names(), then as findsig() finds it)
            const std::string name = strip_space(c);
            int k = 0;
            while (k < nsig && si[k].desc.value_or("") != name) k++;
            if (k == nsig) k = findsig(c.c_str());
            if (k < 0 || k >= nsig)
                fail("record " + record + " has no signal " + c);
            cols.push_back(k);
        }
    }
    base_time_fields(rec.fs > 0 || opt.legacy, rec.base_time,
                     rec.base_time_ms, rec.base_date);
    if (isigsettime(from) < 0)
        fail("can't seek to sample " + std::to_string(from) + " of record " +
             record);

    // getvec returns one value per signal in either mode.  The frames are
    // read with getvecs() straight into `all`, which is allocated for the
    // number of frames expected (to - from, or what the header gives) and
    // grows if there are more.
    std::vector<WFDB_Sample> all;
    // Vectors read per getvecs() call: whole frames, and a multiple of 6 of
    // them, so that formats 212, 310 and 311 end each call on a whole
    // packed unit (the frames are then read in blocks).  A block is at
    // least one such unit (more than 65536 vectors if a frame holds more
    // than 65536 / 6 samples of a signal), so that each call reads.
    const long long unit = 6LL * std::max(getspf(), 1);
    const long long block = std::max(65536 - 65536 % unit, unit);
    std::optional<long long> remaining;
    if (to) remaining = *to > from ? *to - from : 0;
    {
        WFDB_Time hn;
        long bt;
        WFDB_Date bd;
        detail::wfdbx_header_values(&hn, &bt, &bd);
        long long expect = remaining ? *remaining : (hn > from ? hn - from : 0);
        // (at most 2^26 samples in advance: a header or a `to` may give
        // far more frames than the files hold)
        constexpr long long max_reserve = 1LL << 26;
        if (expect > 0)
            all.reserve(static_cast<size_t>(
                std::min(expect, max_reserve / nsig + 1) * nsig));
    }
    bool checksum_error = false;
    {
        ChecksumQuietScope quiet;
        ReadCheckedScope checked;
        while (!remaining || *remaining > 0) {
            long long n = remaining ? std::min(block, *remaining) : block;
            size_t used = all.size();
            all.resize(used + static_cast<size_t>(n) * nsig);
            int stat = 0;
            long long got = getvecs(all.data() + used, n, &stat);
            if (got < 0) got = 0;
            // WFDB-x: status -4 (checksum error) is returned with valid
            // samples: for the frame at which the checksums are verified
            // (in high-resolution mode, for each of its sample vectors).
            // The vector is kept, reading continues, and the error is
            // reported after the read (a warning).  (If a sample of that
            // frame could not be read, the status is -3: see
            // ReadCheckedScope.)
            bool mismatch = got < n && stat == -4;
            if (mismatch) {
                got++;
                checksum_error = true;
            }
            all.resize(used + static_cast<size_t>(got) * nsig);
            if (remaining) *remaining -= got;
            if (mismatch) continue;
            if (got < n) {
                // WFDB-x: another status below -1 (e.g. -3, unexpected EOF: a
                // signal file shorter than its header says, or a decoder or
                // I/O error) is an error, not the end of the data (-1).
                if (stat < -1)
                    fail("can't read signal data of record " + record +
                         " (getvec status " + std::to_string(stat) + ")");
                break;
            }
        }
    }
    if (checksum_error && opt.checksum_warning)
        wfdb_error("WFDB-x: checksum error in record %s: the signal data do "
                   "not match the checksums in its header\n", record.c_str());
    rec.checksum_ok = !checksum_error;

    size_t nframes = all.size() / nsig;
    rec.nsig = static_cast<int>(cols.size());
    bool all_cols = cols.size() == static_cast<size_t>(nsig);
    for (size_t c = 0; all_cols && c < cols.size(); c++)
        all_cols = cols[c] == static_cast<int>(c);
    if (all_cols) {     // (all signals, in order: no copy)
        rec.samples = std::move(all);
    } else {
        rec.samples.resize(nframes * cols.size());
        for (size_t i = 0; i < nframes; i++)
            for (size_t c = 0; c < cols.size(); c++)
                rec.samples[i * cols.size() + c] = all[i * nsig + cols[c]];
    }
    for (int k : cols) rec.siginfo.push_back(si[k]);
    rec.signals = cols;
    rec.sampfrom = from;
    for (auto c = getinfo(record.c_str()); c; c = getinfo(nullptr))
        rec.comments.push_back(*c);
    wfdbquit();
    return rec;
}

Annotations read_annotations(const std::string &record,
                             const std::string &annotator,
                             const TimeSpec &from, const TimeSpec &to,
                             std::optional<WFDB_Frequency> fs, bool legacy,
                             const InputOptions &input)
{
    // WFDB-x: `from` is checked as read_record() checks it, before anything
    // is opened (a time string gives a positive sample number).
    if (from.sample() && *from.sample() < 0)
        throw Error("read_annotations: from must not be negative");
    if (fs && !(*fs > 0)) throw Error("read_annotations: fs must be > 0");
    legacy = legacy || wfdbx_get_legacy() != 0;    // or the library's mode
    LegacyScope scope(legacy);
    InputScope input_scope(input);
    SettingsScope settings_scope;
    QuitOnErrorScope quit_scope;
    wfdbquit();
    // WFDB-x: no default sampling frequency (C assumed 250 Hz if the record
    // had no header); `fs` gives one, as rdann -F does.
    WFDB_Frequency f = sampfreq(record.c_str());
    if (f <= 0 && fs) setsampfreq(*fs);
    else if (legacy && f < 0)   // WFDB-x: legacy mode (original behavior)
        setsampfreq(WFDB_DEFFREQ);
    WFDB_Anninfo ai;
    ai.name = annotator;
    ai.stat = WFDB_READ;
    if (annopen(record.c_str(), &ai, 1) < 0)
        fail("can't read annotator " + annotator + " for record " + record);
    if (!legacy && sampfreq(nullptr) <= 0 &&
        (from.needs_freq() || to.needs_freq()))
        fail("sampling frequency of record " + record + " is not specified");
    WFDB_Time t0 = from.resolve();
    std::optional<WFDB_Time> t1;
    if (!to.empty()) t1 = to.resolve();
    if (t0 && iannsettime(t0) < 0)
        fail("can't seek in annotator " + annotator);
    Annotations res;
    res.record = record;
    res.annotator = annotator;
    WFDB_Annotation a;
    int stat;
    while ((stat = getann(0, &a)) == 0) {
        if (t1 && a.time >= *t1) break;
        res.samples.push_back(a.time);
        res.codes.push_back(a.anntyp);
        res.symbols.push_back(annstr(a.anntyp).value_or(""));
        res.subtypes.push_back(a.subtyp);
        res.chans.push_back(a.chan);
        res.nums.push_back(a.num);
        if (a.aux && !a.aux->empty()) {
            size_t len = static_cast<unsigned char>((*a.aux)[0]);
            std::string text = a.aux->substr(1, len);
            size_t z = text.find('\0');    // as a C string
            if (z != std::string::npos) text.resize(z);
            res.aux.push_back(text);
        } else
            res.aux.push_back(std::nullopt);
    }
    // WFDB-x: a status other than 0 and -1 (end of file), such as -3
    // (unexpected end of file) or an I/O error, is an error.
    if (stat != 0 && stat != -1)
        fail("can't read annotation file " + annotator + " of record " +
             record + " (getann status " + std::to_string(stat) + ")");
    res.fs = getiafreq(0);
    wfdbquit();
    return res;
}

namespace {

// The checks of the arguments of write_record() and
// write_record_physical() that come before the samples, in this order
// (WFDB-x: every argument is checked before any file is touched): the
// record name is not empty, each frame holds samps_per_frame[k] >= 1
// samples of signal k, there is at least one signal, each per-signal vector holds
// no value, one value for all signals or one value per signal (gains and
// adcres with fewer values are missing values instead, except in legacy
// mode), the gains and the ADC resolutions (>= 1) are given (except in
// legacy mode), so are the units of each calibrated signal, no signal in
// physical units (`physical`) has a gain of 0, the sampling frequency is
// finite (and, except in legacy mode, > 0), the gains are finite, and the
// base time is one that setbasetime() accepts.  (The ADC resolutions, zeros
// and baselines are ints, so whole numbers within the range of a 32-bit
// integer, and the text is bytes, so that any record name, signal name,
// units or comment can be written.)
void check_write_args(const std::string &record, int nsig, WFDB_Frequency fs,
                      const WriteOptions &opt, bool physical)
{
    if (record.empty())
        throw Error("write_record: the record name must not be empty");
    for (int n : opt.samps_per_frame)
        if (n < 1)
            throw Error("write_record: samps_per_frame must hold integers "
                        ">= 1");
    if (nsig <= 0)
        throw Error("write_record: at least one signal is required");
    const std::pair<const char *, size_t> lens[] = {
        {"gains", opt.gains.size()}, {"baselines", opt.baselines.size()},
        {"adczeros", opt.adczeros.size()}, {"adcres", opt.adcres.size()},
        {"units", opt.units.size()}, {"names", opt.names.size()},
        {"samps_per_frame", opt.samps_per_frame.size()}};
    const size_t ns = static_cast<size_t>(nsig);
    for (const auto &l : lens) {
        bool missing = !opt.legacy && l.second < ns &&
            (l.first == std::string("gains") ||
             l.first == std::string("adcres"));
        if (l.second > 1 && l.second != ns && !missing)
            throw Error(std::string("write_record: ") + l.first +
                        " must have one value for all signals or one value "
                        "per signal (" + std::to_string(nsig) + ")");
    }
    std::vector<WFDB_Gain> gains(ns);
    for (int k = 0; k < nsig; k++) gains[k] = gain_of(opt, k);
    for (int k = 0; k < nsig; k++) (void)adcres_of(opt, k);
    for (int k = 0; k < nsig; k++) {
        auto units = per_signal<std::optional<std::string>>(opt.units, k,
                                                             std::nullopt);
        if (!opt.legacy && gains[k] != 0 && (!units || units->empty()))
            throw Error("write_record: units must be specified");
    }
    if (physical && !opt.legacy)
        for (int k = 0; k < nsig; k++)
            // WFDB-x: no default gain (C assumed WFDB_DEFGAIN)
            if (gains[k] == 0)
                throw Error("write_record: signal " + std::to_string(k) +
                            " is uncalibrated");
    // WFDB-x: no default sampling frequency (C: 250 Hz).
    if (!opt.legacy && !(fs > 0))
        throw Error("write_record: the sampling frequency must be > 0");
    if (!std::isfinite(fs))
        throw Error("write_record: the sampling frequency must be finite");
    for (WFDB_Gain g : opt.gains)
        if (!std::isfinite(g))
            throw Error("write_record: gains must be finite");
    if (opt.base_time) {
        LegacyScope scope(opt.legacy);
        if (!detail::wfdbx_check_basetime(opt.base_time->c_str()))
            throw Error("write_record: incorrect base time '" +
                        *opt.base_time + "'");
    }
}

// WFDB-x: the staging of the output files of a high-level writer (see
// detail::wfdbx_staging_begin) for the lifetime of the object: end(true)
// renames the temporary files over their destinations (false if that
// fails); otherwise (also when an exception is thrown) they are removed, and
// the existing files are left as they were.
class StagingScope {
public:
    StagingScope() { detail::wfdbx_staging_begin(); }
    ~StagingScope() { if (!ended_) detail::wfdbx_staging_end(false); }
    bool end(bool commit)
    {
        ended_ = true;
        return detail::wfdbx_staging_end(commit);
    }
    StagingScope(const StagingScope &) = delete;
    StagingScope &operator=(const StagingScope &) = delete;
private:
    bool ended_ = false;
};

void write_adc(const std::string &record,
               const std::vector<WFDB_Sample> &samples, int nsig,
               WFDB_Frequency fs, const WriteOptions &options)
{
    const WriteOptions opt = with_library_legacy(options);
    // WFDB-x: no default sampling frequency, gain, ADC resolution or units
    // (C: 250 Hz, 200 adu/mV, a resolution based on the format, mV).
    check_write_args(record, nsig, fs, opt, false);
    std::vector<WFDB_Siginfo> si(nsig);
    size_t frame = 0;
    for (int k = 0; k < nsig; k++) {
        WFDB_Siginfo &s = si[k];
        s.fname = record + ".dat";
        s.desc = per_signal<std::string>(opt.names, k, "");
        s.units = per_signal<std::optional<std::string>>(opt.units, k,
                                                          std::nullopt);
        s.gain = gain_of(opt, k);
        s.fmt = opt.fmt;
        s.spf = per_signal<int>(opt.samps_per_frame, k, 1);
        s.adczero = per_signal<int>(opt.adczeros, k, 0);
        s.baseline = per_signal<int>(opt.baselines, k, s.adczero);
        s.adcres = adcres_of(opt, k);
        frame += s.spf;
    }
    if (samples.size() % frame)
        throw Error("write_record: the number of samples is not a multiple "
                    "of the frame size");
    // WFDB-x: the info strings of opt.metadata (" Key: value"), checked
    // before anything is written.
    std::vector<std::string> meta;
    try {
        meta = detail::wfdbx_metadata_info_lines(opt.metadata, opt.comments);
    } catch (const ArgumentError &e) {
        throw ArgumentError(std::string("write_record: ") + e.what());
    }
    LegacyScope scope(opt.legacy);
    wfdbquit();
    int errors = wfdbx_write_errors();
    // WFDB-x: the signal file and the header are written to temporary files
    // in the directories of their destinations, which are renamed over them
    // when both are complete; after a failure, they are removed, and the
    // existing files are left as they were.
    StagingScope staging;
    if (osigfopen(si.data(), nsig) != nsig)
        fail("can't create signal file for record " + record);
    setsampfreq(fs);
    // The counter frequency and base count survive wfdbquit() (as in the C
    // library); a new record written here has neither.
    setcfreq(0.0);
    setbasecount(0.0);
    if (opt.base_time) setbasetime(opt.base_time->c_str());
    for (size_t i = 0; i < samples.size(); i += frame)
        putvec(&samples[i]);
    std::string name = record;
    if (newheader(name.c_str()) < 0)
        fail("can't create header for record " + record);
    for (const std::string &c : opt.comments) putinfo(c.c_str());
    for (const std::string &m : meta) putinfo(m.c_str());
    wfdbquit();
    if (!staging.end(wfdbx_write_errors() == errors))
        throw Error("write error on record " + record);
}

} // namespace

void write_record(const std::string &record_arg,
                  const std::vector<WFDB_Sample> &samples, int nsig,
                  WFDB_Frequency fs, const WriteOptions &opt)
{
    // WFDB-x: a trailing ".hea" is removed, as by the readers (1.2.2)
    const std::string record = detail::wfdb_striphea(record_arg.c_str());
    SettingsScope settings_scope;
    OutputDirScope dir_scope(record, opt.dir);  // (its checks come first)
    write_adc(record, samples, nsig, fs, opt);
}

void write_record_physical(const std::string &record_arg,
                           const std::vector<double> &samples, int nsig,
                           WFDB_Frequency fs, const WriteOptions &options)
{
    // WFDB-x: a trailing ".hea" is removed, as by the readers (1.2.2)
    const std::string record = detail::wfdb_striphea(record_arg.c_str());
    SettingsScope settings_scope;
    OutputDirScope dir_scope(record, options.dir);  // (its checks come first)
    const WriteOptions opt = with_library_legacy(options);
    // Gain and baseline of each column of a frame
    std::vector<double> g;
    std::vector<int> b;
    check_write_args(record, nsig, fs, opt, true);
    for (int k = 0; k < nsig; k++) {
        double gain = gain_of(opt, k);
        if (gain == 0 && opt.legacy)    // WFDB-x: legacy mode (original)
            gain = WFDB_DEFGAIN;
        int zero = per_signal<int>(opt.adczeros, k, 0);
        int base = per_signal<int>(opt.baselines, k, zero);
        int spf = per_signal<int>(opt.samps_per_frame, k, 1);
        for (int j = 0; j < spf; j++) {
            g.push_back(gain);
            b.push_back(base);
        }
    }
    std::vector<WFDB_Sample> adc(samples.size());
    for (size_t i = 0; i < samples.size(); i++) {
        size_t c = i % g.size();
        double v = samples[i] * g[c];
        if (std::isnan(v)) {
            adc[i] = WFDB_INVALID_SAMPLE;
            continue;
        }
        // An infinite value, or one whose ADC value is not an int, cannot
        // be stored.
        double d = (v >= 0 ? std::trunc(v + 0.5) : std::trunc(v - 0.5)) + b[c];
        if (!(d >= -2147483648.0 && d <= 2147483647.0))
            throw Error("write_record: sample " + std::to_string(i) +
                        " is out of range");
        adc[i] = static_cast<WFDB_Sample>(d);
    }
    write_adc(record, adc, nsig, fs, opt);
}

void write_annotations(const std::string &record, const std::string &annotator,
                       const Annotations &ann, WFDB_Frequency fs,
                       const std::string &dir, std::optional<bool> sort)
{
    // (fs applies to this file only: the previous time resolution is
    // restored, also on errors)
    SettingsScope settings_scope;
    OutputDirScope dir_scope(record, dir);
    size_t n = ann.samples.size();
    // WFDB-x: every argument is checked before the file is touched.  Each
    // per-annotation field is absent (empty) or has one entry per
    // annotation.
    const std::pair<const char *, size_t> fields[] = {
        {"symbols", ann.symbols.size()}, {"codes", ann.codes.size()},
        {"subtypes", ann.subtypes.size()}, {"chans", ann.chans.size()},
        {"nums", ann.nums.size()}, {"aux", ann.aux.size()}};
    for (const auto &f : fields)
        if (f.second != 0 && f.second != n)
            throw Error(std::string("write_annotations: ") + f.first +
                        " must have one entry per annotation (" +
                        std::to_string(n) + "), or none");
    // WFDB-x: a label is required for each annotation (1.2.2: as in
    // Python); with no annotations, an empty file is written
    if (n > 0 && ann.symbols.empty() && ann.codes.empty())
        throw Error("write_annotations: symbols or codes must be given");
    if (fs != 0 && !(std::isfinite(fs) && fs > 0))
        throw Error("write_annotations: fs must be finite and > 0 (or 0: "
                    "none)");
    // WFDB-x: the times that the MIT format can store: the smallest and the
    // largest 64-bit integers are reserved (putann refuses them, "time
    // overflow", and the annotation was dropped); any other time is stored
    // (with SKIPs for intervals beyond 1023 samples).
    constexpr WFDB_Time tmin = std::numeric_limits<WFDB_Time>::min();
    constexpr WFDB_Time tmax = std::numeric_limits<WFDB_Time>::max();
    for (WFDB_Time t : ann.samples)
        if (t == tmin || t == tmax)
            throw Error("write_annotations: annotation time " +
                        std::to_string(t) + " cannot be written (annotation "
                        "times must be integers from " +
                        std::to_string(tmin + 1) + " to " +
                        std::to_string(tmax - 1) + ")");
    // WFDB-x: the annotation codes are 0 to 58 (ACMAX is 49, and 50 to 58
    // are free); 59 to 63 are the control codes of the MIT format (SKIP,
    // NUM, SUB, CHN, AUX), which corrupt the file, and other values do not
    // fit in its 6 bits.
    for (int c : ann.codes) {
        if (c >= 0 && c <= MAXCODE) continue;
        if (c > MAXCODE && c <= 63)
            throw Error("write_annotations: annotation code " +
                        std::to_string(c) + " is reserved (59 to 63 are the "
                        "control codes of the annotation file format)");
        throw Error("write_annotations: annotation code " + std::to_string(c) +
                    " is out of range (0 to " + std::to_string(MAXCODE) + ")");
    }
    // WFDB-x: symbols and codes may both be given (as read_annotations()
    // returns them) if they agree: each symbol is that of its code (an
    // empty symbol leaves the code).
    if (!ann.symbols.empty() && !ann.codes.empty())
        for (size_t k = 0; k < n; k++)
            if (!ann.symbols[k].empty() &&
                strann(ann.symbols[k].c_str()) != ann.codes[k])
                throw Error("write_annotations: symbols and codes disagree "
                            "at annotation " + std::to_string(k));
    // (aux texts are bytes: any can be written)
    wfdbquit();
    int errors = wfdbx_write_errors();
    // WFDB-x: the file is written to a temporary file in the directory of
    // its destination, which is renamed over it when it is complete (and,
    // if needed, sorted); after a failure, it is removed, and the existing
    // file is left as it was.
    StagingScope staging;
    bool put_failed = false;
    {
        AnnSortScope sort_scope(sort);  // (for the file written here only)
        if (fs > 0) setafreq(fs);
        WFDB_Anninfo ai;
        ai.name = annotator;
        ai.stat = WFDB_WRITE;
        if (annopen(record.c_str(), &ai, 1) < 0)
            fail("can't create annotator " + annotator + " for record " +
                 record);
        for (size_t k = 0; k < n; k++) {
            WFDB_Annotation a;
            a.time = ann.samples[k];
            if (k < ann.symbols.size() && !ann.symbols[k].empty())
                a.anntyp = static_cast<char>(strann(ann.symbols[k].c_str()));
            else if (k < ann.codes.size())
                a.anntyp = static_cast<char>(ann.codes[k]);
            if (k < ann.subtypes.size())
                a.subtyp = static_cast<signed char>(ann.subtypes[k]);
            if (k < ann.chans.size())
                a.chan = static_cast<unsigned char>(ann.chans[k]);
            if (k < ann.nums.size())
                a.num = static_cast<signed char>(ann.nums[k]);
            if (k < ann.aux.size() && ann.aux[k]) {
                // Aux strings are stored with a one-byte length prefix.
                std::string data = ann.aux[k]->substr(0, 255);
                a.aux = std::string(1, static_cast<char>(data.size())) + data;
            }
            // WFDB-x: an error that putann reports is an error
            if (putann(0, &a) < 0) put_failed = true;
        }
        wfdbquit();
    }
    if (!staging.end(!put_failed && wfdbx_write_errors() == errors))
        throw Error("write error on annotator " + annotator + " for record " +
                    record);
}

} // namespace wfdbx
