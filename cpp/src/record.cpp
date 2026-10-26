// record.cpp: high-level interface for reading and writing records
// (see <wfdbx/record.hpp>; the equivalent of python/src/wfdbx/highlevel.py)
//
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
// gain, ADC resolution or units. Values that the record or the user does not
// give are never assumed (the original package assumed 250 Hz, 200 adu/mV,
// 12 bits and millivolts), because a silently assumed value corrupts every
// result derived from it. See docs/DIVERGENCES.md. The original behavior
// remains available with --legacy (see docs/DIVERGENCES.md).
// Design decision (Reza Sameni, after a code review, Oct 2026): the writers
// take an output directory (WriteOptions::dir, the `dir` parameter of
// write_annotations()): the files are created in it, and the record opens
// from there under its plain name.
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

#include "wfdbx/record.hpp"

#include "wfdblib.hpp"      // (wfdbx_set_checksum_quiet)

#include <cmath>
#include <filesystem>
#include <limits>

namespace wfdbx {

namespace {

[[noreturn]] void fail(const std::string &msg)
{
    wfdbquit();
    throw Error(msg);
}

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

// wfdb-x: getvec's checksum message not printed for the lifetime of the
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

// wfdb-x: the library's input directory and network access (see
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

// wfdb-x: the library's output directory (wfdbx_set_output_dir) set to
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
// it is not given (wfdb-x: no default gain; C assumed WFDB_DEFGAIN).
WFDB_Gain gain_of(const WriteOptions &opt, int k)
{
    // wfdb-x: legacy mode (original behavior): WFDB_DEFGAIN by default
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
// Error if it is not given or < 1 (wfdb-x: no default resolution; C inferred
// it from the format).
int adcres_of(const WriteOptions &opt, int k)
{
    // wfdb-x: legacy mode (original behavior): inferred from the format
    if (opt.legacy)
        return per_signal<int>(opt.adcres, k, legacy_adcres(opt.fmt));
    int r = per_signal<int>(opt.adcres, k, 0);
    if (r < 1)
        throw Error("write_record: ADC resolution(s) must be specified");
    return r;
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
    if (g == 0 && legacy)   // wfdb-x: legacy mode (original behavior)
        g = WFDB_DEFGAIN;
    if (g == 0) {   // wfdb-x: no default gain (C assumed WFDB_DEFGAIN)
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

std::vector<WFDB_Siginfo> read_header(const std::string &record, bool legacy,
                                      const InputOptions &input)
{
    LegacyScope scope(legacy);
    InputScope input_scope(input);
    wfdbquit();
    int n = isigopen(record.c_str(), nullptr, 0);
    if (n < 0) fail("can't read header for record " + record);
    std::vector<WFDB_Siginfo> si(n);
    if (n > 0) isigopen(record.c_str(), si.data(), -n);
    wfdbquit();
    return si;
}

Record read_record(const std::string &record, const ReadOptions &options)
{
    const ReadOptions opt = with_library_legacy(options);
    LegacyScope scope(opt.legacy);
    InputScope input_scope(opt);
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
    // wfdb-x: no default sampling frequency (C assumed 250 Hz).
    if (!opt.legacy && rec.fs <= 0 &&
        (opt.from.needs_freq() || opt.to.needs_freq()))
        fail("sampling frequency of record " + record + " is not specified");
    WFDB_Time from = opt.from.resolve();
    std::optional<WFDB_Time> to;
    if (!opt.to.empty()) to = opt.to.resolve();

    std::vector<int> cols;
    if (opt.channels.empty()) {
        for (int k = 0; k < nsig; k++) cols.push_back(k);
    } else {
        for (const std::string &c : opt.channels) {
            int k = findsig(c.c_str());
            if (k < 0 || k >= nsig)
                fail("record " + record + " has no signal " + c);
            cols.push_back(k);
        }
    }
    // (A header without a sampling frequency cannot give a base time.)
    if (rec.fs > 0 || opt.legacy) {
        std::string bt = timstr(0);
        if (!bt.empty() && bt[0] == '[') rec.base_time = bt;
    }
    if (isigsettime(from) < 0)
        fail("can't seek to sample " + std::to_string(from) + " of record " +
             record);

    // getvec returns one value per signal in either mode.
    std::vector<WFDB_Sample> all;
    constexpr long long block = 65536;     // frames read per getvecs() call
    std::optional<long long> remaining;
    if (to) remaining = *to > from ? *to - from : 0;
    std::vector<WFDB_Sample> buf;
    bool checksum_error = false;
    {
        ChecksumQuietScope quiet;
        while (!remaining || *remaining > 0) {
            long long n = remaining ? std::min(block, *remaining) : block;
            buf.resize(static_cast<size_t>(n) * nsig);
            int stat = 0;
            long long got = getvecs(buf.data(), n, &stat);
            if (got < 0) got = 0;
            // wfdb-x: status -4 (checksum error) is returned with the last
            // frame of the record, whose samples are filled in: the frame is
            // kept, and the error is reported after the read (a warning).
            if (got < n && stat == -4) {
                got++;
                checksum_error = true;
            }
            all.insert(all.end(), buf.begin(), buf.begin() + got * nsig);
            if (remaining) *remaining -= got;
            if (checksum_error) break;
            if (got < n) {
                // wfdb-x: another status below -1 (e.g. -3, unexpected EOF: a
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
        wfdb_error("wfdb-x: checksum error in record %s: the signal data do "
                   "not match the checksums in its header\n", record.c_str());

    size_t nframes = all.size() / nsig;
    rec.nsig = static_cast<int>(cols.size());
    rec.samples.resize(nframes * cols.size());
    for (size_t i = 0; i < nframes; i++)
        for (size_t c = 0; c < cols.size(); c++)
            rec.samples[i * cols.size() + c] = all[i * nsig + cols[c]];
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
    if (fs && !(*fs > 0)) throw Error("read_annotations: fs must be > 0");
    legacy = legacy || wfdbx_get_legacy() != 0;    // or the library's mode
    LegacyScope scope(legacy);
    InputScope input_scope(input);
    wfdbquit();
    // wfdb-x: no default sampling frequency (C assumed 250 Hz if the record
    // had no header); `fs` gives one, as rdann -F does.
    WFDB_Frequency f = sampfreq(record.c_str());
    if (f <= 0 && fs) setsampfreq(*fs);
    else if (legacy && f < 0)   // wfdb-x: legacy mode (original behavior)
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
    while (getann(0, &a) == 0) {
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
    res.fs = getiafreq(0);
    wfdbquit();
    return res;
}

namespace {

void write_adc(const std::string &record,
               const std::vector<WFDB_Sample> &samples, int nsig,
               WFDB_Frequency fs, const WriteOptions &options)
{
    const WriteOptions opt = with_library_legacy(options);
    if (nsig <= 0) throw Error("write_record: no signals");
    // wfdb-x: no default sampling frequency, gain, ADC resolution or units
    // (C: 250 Hz, 200 adu/mV, a resolution based on the format, mV).
    if (!opt.legacy && !(fs > 0))
        throw Error("write_record: the sampling frequency must be > 0");
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
        if (!opt.legacy && s.gain != 0 && (!s.units || s.units->empty()))
            throw Error("write_record: units must be specified");
        frame += s.spf;
    }
    if (samples.size() % frame)
        throw Error("write_record: the number of samples is not a multiple "
                    "of the frame size");
    LegacyScope scope(opt.legacy);
    wfdbquit();
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
    wfdbquit();
}

} // namespace

void write_record(const std::string &record,
                  const std::vector<WFDB_Sample> &samples, int nsig,
                  WFDB_Frequency fs, const WriteOptions &opt)
{
    OutputDirScope dir_scope(record, opt.dir);  // (its checks come first)
    write_adc(record, samples, nsig, fs, opt);
}

void write_record_physical(const std::string &record,
                           const std::vector<double> &samples, int nsig,
                           WFDB_Frequency fs, const WriteOptions &options)
{
    OutputDirScope dir_scope(record, options.dir);  // (its checks come first)
    const WriteOptions opt = with_library_legacy(options);
    // Gain and baseline of each column of a frame
    std::vector<double> g;
    std::vector<int> b;
    if (nsig <= 0) throw Error("write_record: no signals");
    if (!opt.legacy && !(fs > 0))
        throw Error("write_record: the sampling frequency must be > 0");
    for (int k = 0; k < nsig; k++) {
        double gain = gain_of(opt, k);
        if (gain == 0 && opt.legacy)    // wfdb-x: legacy mode (original)
            gain = WFDB_DEFGAIN;
        if (gain == 0)  // wfdb-x: no default gain (C assumed WFDB_DEFGAIN)
            throw Error("write_record: signal " + std::to_string(k) +
                        " is uncalibrated");
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
        if (std::isnan(v))
            adc[i] = WFDB_INVALID_SAMPLE;
        else
            adc[i] = static_cast<WFDB_Sample>(
                (v >= 0 ? std::trunc(v + 0.5) : std::trunc(v - 0.5)) + b[c]);
    }
    write_adc(record, adc, nsig, fs, opt);
}

void write_annotations(const std::string &record, const std::string &annotator,
                       const Annotations &ann, WFDB_Frequency fs,
                       const std::string &dir)
{
    OutputDirScope dir_scope(record, dir);
    size_t n = ann.samples.size();
    wfdbquit();
    if (fs > 0) setafreq(fs);
    WFDB_Anninfo ai;
    ai.name = annotator;
    ai.stat = WFDB_WRITE;
    if (annopen(record.c_str(), &ai, 1) < 0) {
        if (fs > 0) setafreq(0.0);
        fail("can't create annotator " + annotator + " for record " + record);
    }
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
        putann(0, &a);
    }
    wfdbquit();
    if (fs > 0) setafreq(0.0);
}

} // namespace wfdbx
