// check.cpp: check_record, a checker of records (header, signal files and
// annotation files); see <wfdbx/record.hpp> and the equivalent
// python/src/wfdbx/check.py, which is the reference.
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
// check_record is a WFDB-x addition, specified in the same way for the seven
// languages (the messages, their order and the formatting of numbers are
// identical).  The checks were designed for WFDB-x; no code or text of
// Benjamin Moody's wfdbcheck was used.  The record is read with the library's
// functions (isigopen, getvecs, getseginfo, annopen, getann, annstr); the
// header file's text is read only for the checks of its lines and of the
// record name.

#include "wfdbx/record.hpp"

#include "wfdblib.hpp"

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <map>
#include <optional>
#include <set>

namespace wfdbx {

namespace {

constexpr long long INT32_MAX_ = 2147483647LL;
constexpr long CHUNK_SAMPLES = 1L << 20;    // samples read at a time

using detail::strprintf;

// Bits that each storage format can store (formats 8 and 0: no limit).
std::optional<int> capacity(int fmt)
{
    switch (fmt) {
    case 80: case 508: return 8;
    case 310: case 311: return 10;
    case 212: return 12;
    case 16: case 61: case 160: case 516: return 16;
    case 24: case 524: return 24;
    case 32: return 32;
    default: return std::nullopt;
    }
}

// ---------------------------------------------------------------------------
// Text of the messages

// A name quoted for a message: in double quotes, with each byte below 32 or
// above 126 shown as \xHH (lowercase hex).
std::string q(const std::optional<std::string> &name)
{
    std::string out = "\"";
    if (name)
        for (unsigned char c : *name) {
            if (c < 32 || c > 126)
                out += strprintf("\\x%02x", c);
            else
                out += static_cast<char>(c);
        }
    return out + "\"";
}

// "1 frame", "2 frames"
std::string counted(long long k, const char *word)
{
    return strprintf("%lld %s%s", k, word, k == 1 ? "" : "s");
}

// A message about k items: "1 NOUN VERB WHAT: ONE" or "K NOUNs VERB WHAT;
// the first is FIRST".
std::string count_form(long long k, const char *noun, const char *verb_one,
                       const char *verb_many, const std::string &what,
                       const std::string &first)
{
    if (k == 1)
        return strprintf("1 %s %s %s: %s", noun, verb_one, what.c_str(),
                         first.c_str());
    return strprintf("%lld %ss %s %s; the first is %s", k, noun, verb_many,
                     what.c_str(), first.c_str());
}

std::string g(double x) { return strprintf("%g", x); }

long long int16(long long x)
{
    x &= 0xFFFF;
    return (x & 0x8000) ? x - 0x10000 : x;
}

bool has_control(const std::string &s)
{
    for (unsigned char c : s)
        if (c < 32 || c == 127) return true;
    return false;
}

// True if s is only a number: an optional sign, digits with at most one
// '.', and at least one digit.
bool is_number(const std::string &s)
{
    size_t i = (!s.empty() && (s[0] == '+' || s[0] == '-')) ? 1 : 0;
    int dots = 0, digits = 0;
    for (; i < s.size(); i++) {
        if (s[i] == '.')
            dots++;
        else if (s[i] >= '0' && s[i] <= '9')
            digits++;
        else
            return false;
    }
    return dots <= 1 && digits > 0;
}

bool file_chars_ok(const std::string &s)
{
    for (unsigned char c : s)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.' ||
              c == '/'))
            return false;
    return true;
}

struct Rep {
    std::vector<Issue> issues;
    void add(const char *severity, const char *code, const std::string &where,
             const std::string &message)
    {
        issues.push_back(Issue{severity, code, where, message});
    }
};

// "segment s1" + "signal 0" -> "segment s1, signal 0"
std::string at(const std::string &prefix, const std::string &sub)
{
    if (!prefix.empty() && !sub.empty()) return prefix + ", " + sub;
    return prefix.empty() ? sub : prefix;
}

std::string signal_at(const std::string &prefix, size_t s)
{
    return at(prefix, "signal " + std::to_string(s));
}

const char *const LENGTH_LARGE =
    "the record has more than 2147483647 samples, which 32-bit applications "
    "cannot handle";

// ---------------------------------------------------------------------------
// The header file

struct HeaderText {
    std::string text;   // the bytes of the file
    std::string base;   // the record name that its file name gives
    std::string path;   // the file's name, as the library opened it
};

bool is_url(const std::string &s)
{
    return s.compare(0, 7, "http://") == 0 || s.compare(0, 8, "https://") == 0;
}

// The header file that the library reads for record `name`; nullopt if there
// is none (no such file, or a record read from another format, such as EDF).
std::optional<HeaderText> header_text(const std::string &name)
{
    if (name.empty()) return std::nullopt;
    size_t qp = name.size() - 1;
    while (qp > 0 && std::string("./:\\").find(name[qp]) == std::string::npos)
        qp--;
    detail::FilePtr f;
    if (name[qp] == '.') {
        if (name.substr(qp + 1) != "hea") return std::nullopt;  // (EDF)
        f = detail::wfdb_open(nullptr, name.c_str(), WFDB_READ);
    } else
        f = detail::wfdb_open("hea", name.c_str(), WFDB_READ);
    if (!f) return std::nullopt;
    HeaderText h;
    h.path = detail::wfdb_filename();
    if (h.path.empty()) h.path = name;
    char buf[65536];
    size_t k;
    while ((k = f->read(buf, 1, sizeof buf)) > 0) h.text.append(buf, k);
    f->close();
    h.base = h.path.substr(detail::wfdbx_dirname(h.path).size());
    if (h.base.size() >= 4 && h.base.compare(h.base.size() - 4, 4, ".hea") == 0)
        h.base.resize(h.base.size() - 4);
    else if (h.base.compare(0, 4, "hea.") == 0)
        h.base = h.base.substr(4);
    return h;
}

// The lines of a text (split at each LF; none after a final LF).
std::vector<std::string> split_lines(const std::string &text)
{
    std::vector<std::string> lines;
    size_t p = 0;
    while (true) {
        size_t e = text.find('\n', p);
        if (e == std::string::npos) {
            lines.push_back(text.substr(p));
            break;
        }
        lines.push_back(text.substr(p, e - p));
        p = e + 1;
    }
    if (!lines.empty() && lines.back().empty()) lines.pop_back();
    return lines;
}

// The fields of a header line, separated by spaces, tabs and CRs.
std::vector<std::string> fields_of(const std::string &line)
{
    std::vector<std::string> f;
    std::string cur;
    for (char c : line) {
        if (c == ' ' || c == '\t' || c == '\r') {
            if (!cur.empty()) f.push_back(cur);
            cur.clear();
        } else
            cur += c;
    }
    if (!cur.empty()) f.push_back(cur);
    return f;
}

// The fields of the record line of a header (the first line whose first
// field does not begin with '#'); empty if there is none.
std::vector<std::string> record_line(const std::string &text)
{
    size_t p = 0;
    while (p <= text.size()) {
        size_t e = text.find('\n', p);
        if (e == std::string::npos) e = text.size();
        std::vector<std::string> f = fields_of(text.substr(p, e - p));
        if (!f.empty() && f[0][0] != '#') return f;
        p = e + 1;
    }
    return {};
}

// Checks 1.5-1.7: the lines of the header file and its record name.
void check_text(const HeaderText &hdr, const std::string &where, Rep &rep)
{
    std::vector<std::string> lines = split_lines(hdr.text);
    for (size_t k = 0; k < lines.size(); k++) {
        size_t len = lines[k].size();
        if (len > 0 && lines[k][len - 1] == '\r') len--;
        if (len > 255)
            rep.add("error", "header_line_long", where,
                    strprintf("line %zu of the header is longer than 255 "
                              "characters", k + 1));
    }
    for (size_t k = 0; k < lines.size(); k++) {
        bool non_ascii = false;
        for (unsigned char c : lines[k])
            if (c > 127) non_ascii = true;
        if (non_ascii) {
            rep.add("warning", "header_not_ascii", where,
                    strprintf("line %zu of the header contains non-ASCII "
                              "characters", k + 1));
            break;
        }
    }
    std::vector<std::string> f = record_line(hdr.text);
    if (!f.empty()) {
        std::string x = f[0];
        if (x.find('/', 1) != std::string::npos) x = x.substr(0, x.find('/', 1));
        if (x != hdr.base)
            rep.add("warning", "header_name", where,
                    "the header names the record " + q(x) +
                    ", but its file name is " + q(hdr.base));
    }
}

// The length (number of samples) on the record line: 0 if not given.
WFDB_Time header_length(const std::string &text)
{
    std::vector<std::string> f = record_line(text);
    if (f.size() < 4) return 0;
    WFDB_Time v = 0;
    for (char c : f[3]) {
        if (c < '0' || c > '9') break;
        if (v < INT64_MAX / 10 - 10) v = v * 10 + (c - '0');
    }
    return v;
}

// ---------------------------------------------------------------------------
// Signal specifications (section 2)

void adc_range(const WFDB_Siginfo &info, long long &lo, long long &hi)
{
    long long half = 1LL << (info.adcres - 1);
    lo = info.adczero - half;
    hi = info.adczero + half - 1;
}

// Checks 2.1-2.13 of the signals si of a record opened under the name
// opened_as.  skip_null: signals of format 0 are not checked (a segment of a
// multi-segment record).
void check_specs(const std::vector<WFDB_Siginfo> &si,
                 const std::string &opened_as, const std::string &prefix,
                 Rep &rep, bool skip_null)
{
    std::vector<std::string> descs;     // of the signals checked
    for (size_t s = 0; s < si.size(); s++) {
        const WFDB_Siginfo &info = si[s];
        bool null = info.fmt == 0;
        if (null && skip_null) continue;
        std::string where = signal_at(prefix, s);
        const std::optional<std::string> &desc = info.desc;
        if (!desc || desc->empty() ||
            *desc == "record " + opened_as + ", signal " + std::to_string(s)) {
            rep.add("warning", "desc_missing", where,
                    "the signal has no description");
        } else {
            descs.push_back(*desc);
            if (is_number(*desc))
                rep.add("warning", "desc_number", where,
                        "the description " + q(desc) + " is only a number");
            if (has_control(*desc))
                rep.add("error", "desc_control", where,
                        "the description " + q(desc) +
                        " contains control characters");
        }
        if (info.fmt == 8)
            rep.add("warning", "format_difference", where,
                    "format 8 stores first differences, which cannot follow "
                    "steep slopes");
        if (info.gain == 0)
            rep.add("warning", "gain_missing", where,
                    "the signal is uncalibrated (no gain is given)");
        else if (info.gain < 0)
            rep.add("info", "gain_negative", where,
                    "the gain is negative (" + g(info.gain) + ")");
        bool have_units = info.units && !info.units->empty();
        if (info.gain != 0 && !have_units)
            rep.add("warning", "units_missing", where,
                    "the units are not specified");
        if (have_units && has_control(*info.units))
            rep.add("error", "units_control", where,
                    "the units " + q(info.units) +
                    " contain control characters");
        int b = info.adcres;
        std::optional<int> cap = null ? std::nullopt : capacity(info.fmt);
        if (b == 0) {
            rep.add("warning", "adcres_missing", where,
                    "the ADC resolution is not specified");
        } else if (cap && b > *cap) {
            rep.add("error", "adcres_too_large", where,
                    strprintf("the ADC resolution (%d bits) exceeds what "
                              "format %d can store (%d bits)", b, info.fmt,
                              *cap));
        } else if (cap && b >= 1) {
            long long lo, hi;
            adc_range(info, lo, hi);
            long long fmin = -(1LL << (*cap - 1)), fmax = (1LL << (*cap - 1)) - 1;
            if (lo < fmin || hi > fmax)
                rep.add("error", "adc_range", where,
                        strprintf("the ADC range (%lld to %lld) does not fit "
                                  "in format %d (%lld to %lld)", lo, hi,
                                  info.fmt, fmin, fmax));
        }
        std::string fname = info.fname.value_or("");
        if (!null && fname != "-" && fname != "~" && !file_chars_ok(fname))
            rep.add("warning", "filename", where,
                    "the signal file name " + q(fname) +
                    " contains characters other than letters, digits, '_', "
                    "'-' and '.'");
    }
    std::vector<std::pair<std::string, int>> seen;  // (in first-seen order)
    for (const std::string &d : descs) {
        auto it = std::find_if(seen.begin(), seen.end(),
                               [&](const auto &e) { return e.first == d; });
        if (it == seen.end())
            seen.emplace_back(d, 1);
        else
            it->second++;
    }
    for (const auto &e : seen)
        if (e.second > 1)
            rep.add("warning", "desc_duplicate", prefix,
                    strprintf("%d signals have the description ", e.second) +
                    q(e.first));
}

// ---------------------------------------------------------------------------
// Signal data (section 3)

// Checks 3.1-3.9: read the signals of the record opened as `name` (header
// signals si, header length ns).
void check_data(const std::string &name, const std::vector<WFDB_Siginfo> &si,
                const std::string &prefix, WFDB_Time ns, bool length_missing,
                Rep &rep)
{
    const size_t n = si.size();
    if (n == 0) return;
    for (const WFDB_Siginfo &s : si)
        if (s.fname && *s.fname == "-" && s.fmt != 0)
            return;             // (the standard input: not read)
    wfdbquit();
    std::vector<WFDB_Siginfo> opened(n);
    int k = isigopen(name.c_str(), opened.data(), static_cast<int>(n));
    if (k < static_cast<int>(n)) {
        std::set<std::optional<std::string>> have;
        for (int i = 0; i < k; i++) have.insert(opened[i].fname);
        std::vector<std::optional<std::string>> reported;
        for (const WFDB_Siginfo &s : si) {
            if (s.fmt != 0 && !have.count(s.fname) &&
                std::find(reported.begin(), reported.end(), s.fname) ==
                    reported.end()) {
                reported.push_back(s.fname);
                rep.add("error", "file_unreadable", prefix,
                        "the signal file " + q(s.fname) + " cannot be read");
            }
        }
        if (reported.empty())
            rep.add("error", "file_unreadable", prefix,
                    "the signal file " + q(si[0].fname) + " cannot be read");
        wfdbquit();
        return;
    }
    unsigned ngroups = detail::wfdbx_input_groups();
    for (unsigned grp = 0; grp < ngroups; grp++) {
        long long size = detail::wfdbx_input_file_size(grp);
        if (size > INT32_MAX_) {
            std::optional<std::string> fname;
            for (const WFDB_Siginfo &s : si)
                if (s.group == grp) {
                    fname = s.fname;
                    break;
                }
            rep.add("warning", "file_large", prefix,
                    "the signal file " + q(fname) + " has more than "
                    "2147483647 bytes, which 32-bit applications cannot "
                    "handle");
        }
    }
    setgvmode(WFDB_LOWRES);
    std::vector<bool> has_range(n);
    std::vector<long long> lo(n), hi(n);
    for (size_t s = 0; s < n; s++) {
        int b = si[s].adcres;
        has_range[s] = b >= 1 && b <= 32 && si[s].fmt != 0;
        if (has_range[s]) adc_range(si[s], lo[s], hi[s]);
    }
    std::vector<long long> n_out(n), n_inv(n);
    std::vector<long long> first_out(n, -1), first_out_v(n), first_inv(n, -1);
    long long rows = std::max<long long>(1024, CHUNK_SAMPLES / static_cast<long>(n));
    std::vector<WFDB_Sample> buf(static_cast<size_t>(rows) * n);
    long long m = 0;            // frames read
    int stat = static_cast<int>(n);
    std::optional<std::vector<int>> residual;   // checksum accumulators
                                                // after ns frames
    // (the checksums: not for EDF, nor for a record with skewed signals,
    // whose samples the library reads ahead)
    bool checked = ns > 0 && !detail::wfdbx_input_is_edf();
    for (size_t s = 0; s < n && checked; s++)
        if (wfdbgetskew(static_cast<WFDB_Signal>(s)) != 0) checked = false;

    {
        bool quiet = detail::wfdbx_set_checksum_quiet(true);
        while (true) {
            long long want = rows;
            if (checked && !residual) want = std::min(rows, ns - m);
            long long r = getvecs(buf.data(), want, &stat);
            long long got = r < 0 ? 0 : r;
            if (stat == -4) got++;  // (the frame of a checksum error is
                                    // read completely)
            for (long long i = 0; i < got; i++) {
                const WFDB_Sample *v = &buf[static_cast<size_t>(i) * n];
                for (size_t s = 0; s < n; s++) {
                    if (si[s].fmt == 0) continue;   // (a null signal)
                    if (v[s] == WFDB_INVALID_SAMPLE) {
                        if (first_inv[s] < 0) first_inv[s] = m + i;
                        n_inv[s]++;
                    } else if (has_range[s] && (v[s] < lo[s] || v[s] > hi[s])) {
                        if (first_out[s] < 0) {
                            first_out[s] = m + i;
                            first_out_v[s] = v[s];
                        }
                        n_out[s]++;
                    }
                }
            }
            m += got;
            if (checked && !residual && m >= ns) {
                residual.emplace(n);
                for (size_t s = 0; s < n; s++)
                    (*residual)[s] =
                        detail::wfdbx_input_cksum(static_cast<unsigned>(s));
            }
            if (stat == -4) continue;
            if (got < want) break;
        }
        detail::wfdbx_set_checksum_quiet(quiet);
    }
    // (with skewed signals, getvec returns the frames of the files less the
    // largest skew)
    int skew = 0;
    for (size_t s = 0; s < n; s++)
        skew = std::max(skew, wfdbgetskew(static_cast<WFDB_Signal>(s)));
    wfdbquit();
    if (skew && m > 0) m += skew;
    for (size_t s = 0; s < n; s++) {
        std::string where = signal_at(prefix, s);
        if (n_out[s]) {
            std::string x = strprintf("sample %lld (value %lld)", first_out[s],
                                      first_out_v[s]);
            rep.add("error", "sample_range", where,
                    count_form(n_out[s], "sample", "is", "are",
                               strprintf("outside the ADC range (%lld to "
                                         "%lld)", lo[s], hi[s]), x));
        }
        if (n_inv[s])
            rep.add("info", "invalid_samples", where,
                    count_form(n_inv[s], "sample", "is", "are",
                               "invalid (missing data)",
                               strprintf("sample %lld", first_inv[s])));
    }
    if (residual)
        for (size_t s = 0; s < n; s++) {
            const WFDB_Siginfo &info = si[s];
            if (info.nsamp > 0 && info.fmt != 0 && ((*residual)[s] & 0xFFFF))
                rep.add("error", "checksum", signal_at(prefix, s),
                        strprintf("the checksum does not match: the header "
                                  "gives %lld, the samples sum to %lld",
                                  int16(info.cksum),
                                  int16(static_cast<long long>(info.cksum) -
                                        (*residual)[s])));
        }
    bool end_ok = stat == -1 || stat >= 0;
    bool is_short = ns > 0 && m < ns && (stat == -1 || stat == -3);
    if (is_short)
        rep.add("error", "length_short", prefix,
                "the signal files end after " + counted(m, "frame") +
                strprintf(", before the %lld given in the header", ns));
    if (ns > 0 && m > ns)
        rep.add("warning", "length_long", prefix,
                "the signal files hold " + counted(m, "frame") +
                strprintf(", more than the %lld given in the header", ns));
    if (length_missing && end_ok)
        rep.add("info", "length_unspecified_frames", prefix,
                "the signal files hold " + counted(m, "frame"));
    if (!end_ok && !is_short)
        rep.add("error", "read_error", prefix,
                "the signal data cannot be read after " + counted(m, "frame") +
                strprintf(" (getvec status %d)", stat));
}

// ---------------------------------------------------------------------------
// A record (sections 1-4)

struct HeaderInfo {
    int nsig = 0;
    std::vector<WFDB_Siginfo> si;
    WFDB_Frequency fs = 0;
    WFDB_Time nsamples = 0;
    std::vector<std::pair<std::string, WFDB_Time>> segs;
};

// Open the header of record `name` (wfdbquit first); nullopt if it cannot
// be read.
std::optional<HeaderInfo> open_header(const std::string &name)
{
    wfdbquit();
    int n = isigopen(name.c_str(), nullptr, 0);
    if (n < 0) {
        wfdbquit();
        return std::nullopt;
    }
    HeaderInfo h;
    h.nsig = n;
    if (n > 0) {
        h.si.resize(n);
        isigopen(name.c_str(), h.si.data(), -n);
    }
    const WFDB_Seginfo *sp = nullptr;
    int nseg = getseginfo(&sp);
    for (int i = 0; i < nseg; i++)
        h.segs.emplace_back(sp[i].recname, sp[i].nsamp);
    h.nsamples = detail::wfdbx_header_nsamples(!h.segs.empty());
    h.fs = sampfreq(nullptr);
    wfdbquit();
    return h;
}

// Sections 1.2-1.8 and 2 for a single-segment record.  Returns true if the
// header gives no length (length_missing).
bool check_single(const std::string &record, const HeaderInfo &info,
                  const std::optional<HeaderText> &hdr, Rep &rep)
{
    if (info.nsig == 0)
        rep.add("info", "no_signals", "", "the record has no signals");
    if (info.fs == 0)
        rep.add("warning", "fs_missing", "",
                "the sampling frequency is not specified");
    if (info.nsamples == 0)
        rep.add("warning", "length_missing", "",
                "the record length is not specified");
    if (hdr) check_text(*hdr, "", rep);
    if (info.nsamples > INT32_MAX_)
        rep.add("info", "length_large", "", LENGTH_LARGE);
    if (info.nsig > 0) check_specs(info.si, record, "", rep, false);
    return info.nsamples == 0;
}

// Check 4.4: the signals of a segment of a fixed-layout record match the
// record's signals.
void check_layout(const std::vector<WFDB_Siginfo> &ssi,
                  const std::vector<WFDB_Siginfo> &si,
                  const std::string &prefix, Rep &rep)
{
    if (ssi.size() != si.size())
        rep.add("error", "layout_signals", prefix,
                "the segment has " + counted(static_cast<long long>(ssi.size()),
                                             "signal") +
                strprintf(", but the record has %zu", si.size()));
    for (size_t s = 0; s < std::min(ssi.size(), si.size()); s++) {
        const WFDB_Siginfo &a = ssi[s], &b = si[s];
        if (a.fmt == 0) continue;
        std::string where = signal_at(prefix, s);
        const std::pair<const char *, std::pair<std::string, std::string>>
            fields[] = {
                {"description", {q(a.desc), q(b.desc)}},
                {"units", {q(a.units), q(b.units)}},
                {"gain", {g(a.gain), g(b.gain)}},
                {"baseline", {std::to_string(a.baseline),
                              std::to_string(b.baseline)}},
                {"samples per frame", {std::to_string(a.spf),
                                       std::to_string(b.spf)}}};
        for (const auto &f : fields)
            if (f.second.first != f.second.second)
                rep.add("error", "layout_mismatch", where,
                        strprintf("the signal differs from the record's "
                                  "signal %zu in its %s (%s, expected %s)", s,
                                  f.first, f.second.first.c_str(),
                                  f.second.second.c_str()));
    }
}

// The absolute form of a local directory name (as Python's os.path.abspath),
// with a final separator.
std::string absolute_dir(const std::string &d)
{
    namespace fs = std::filesystem;
    std::error_code ec;
    fs::path p = fs::absolute(fs::path(d.empty() ? "." : d), ec);
    std::string s = p.lexically_normal().string();
    while (s.size() > 1 && (s.back() == '/' || s.back() == '\\')) s.pop_back();
    return s + static_cast<char>(fs::path::preferred_separator);
}

// Sections 1-4.  Returns the record length in samples for the annotation
// checks (0 if unknown), or nullopt if the header cannot be read.
std::optional<WFDB_Time> check_record_signals(const std::string &record,
                                              Rep &rep)
{
    std::optional<HeaderText> hdr = header_text(record);
    std::optional<HeaderInfo> info = open_header(record);
    if (!info) {
        rep.add("error", "header_unreadable", "", "the header cannot be read");
        if (hdr) check_text(*hdr, "", rep);
        return std::nullopt;
    }
    if (info->segs.empty()) {
        bool length_missing = check_single(record, *info, hdr, rep);
        if (info->nsig > 0)
            check_data(record, info->si, "", info->nsamples, length_missing,
                       rep);
        return info->nsamples;
    }
    // A multi-segment record: the master header
    if (info->nsig == 0)
        rep.add("info", "no_signals", "", "the record has no signals");
    if (info->fs == 0)
        rep.add("warning", "fs_missing", "",
                "the sampling frequency is not specified");
    WFDB_Time given = hdr ? header_length(hdr->text) : info->nsamples;
    if (given == 0)
        rep.add("warning", "length_missing", "",
                "the record length is not specified");
    if (hdr) check_text(*hdr, "", rep);
    if (info->nsamples > INT32_MAX_)
        rep.add("info", "length_large", "", LENGTH_LARGE);
    // The segments, next to the master header
    std::string hpath;
    if (hdr)
        hpath = hdr->path;
    else if (auto p = wfdbfile("hea", record.c_str()))
        hpath = *p;
    std::string d = detail::wfdbx_dirname(hpath);
    namespace fs = std::filesystem;
    if (!d.empty() && !is_url(d) && !fs::path(d).is_absolute())
        d = absolute_dir(d);
    else if (d.empty())
        d = absolute_dir(".");
    bool variable = info->segs[0].second == 0;
    std::optional<std::vector<std::optional<std::string>>> layout_descs;
    std::set<std::string> done;
    for (size_t k = 0; k < info->segs.size(); k++) {
        const std::string &seg = info->segs[k].first;
        if (seg == "~" || done.count(seg)) continue;
        done.insert(seg);
        std::string prefix = "segment " + seg;
        bool is_layout = variable && k == 0;
        if (!detail::wfdbx_in_header_dir(seg)) {
            rep.add("error", "segment_unreadable", prefix,
                    "the segment cannot be read");
            continue;
        }
        std::string path = d + seg;
        std::optional<HeaderText> seg_hdr = header_text(path);
        std::optional<HeaderInfo> sinfo = open_header(path);
        if (sinfo && !sinfo->segs.empty()) {
            rep.add("error", "nested", prefix,
                    "the segment is itself a multi-segment record");
            continue;
        }
        if (!sinfo) {
            rep.add("error", "segment_unreadable", prefix,
                    "the segment cannot be read");
            continue;
        }
        if (sinfo->fs > 0 && info->fs > 0 && sinfo->fs != info->fs)
            rep.add("error", "segment_fs", prefix,
                    "the segment's sampling frequency (" + g(sinfo->fs) +
                    ") differs from the record's (" + g(info->fs) + ")");
        if (sinfo->nsig == 0)
            rep.add("info", "no_signals", prefix, "the record has no signals");
        if (seg_hdr) check_text(*seg_hdr, prefix, rep);
        if (sinfo->nsamples > INT32_MAX_)
            rep.add("info", "length_large", prefix, LENGTH_LARGE);
        if (sinfo->nsig > 0)
            check_specs(sinfo->si, path, prefix, rep, !is_layout);
        if (is_layout) {
            layout_descs.emplace();
            for (const WFDB_Siginfo &x : sinfo->si)
                layout_descs->push_back(x.desc);
            continue;
        }
        if (variable) {
            for (size_t s = 0; s < sinfo->si.size(); s++) {
                const WFDB_Siginfo &x = sinfo->si[s];
                if (x.fmt == 0) continue;
                bool found = layout_descs &&
                    std::find(layout_descs->begin(), layout_descs->end(),
                              x.desc) != layout_descs->end();
                if (!found)
                    rep.add("error", "layout_missing_signal",
                            signal_at(prefix, s),
                            "the signal " + q(x.desc) +
                            " is not in the layout");
            }
        } else
            check_layout(sinfo->si, info->si, prefix, rep);
        if (sinfo->nsig > 0)
            check_data(path, sinfo->si, prefix, sinfo->nsamples, false, rep);
    }
    WFDB_Time total = 0;
    for (const auto &s : info->segs) total += s.second;
    if (given > 0 && total != given)
        rep.add("warning", "segment_lengths", "",
                "the segment lengths add up to " + counted(total, "sample") +
                strprintf(", but the master header gives %lld", given));
    return total;   // (the end of the signals)
}

// ---------------------------------------------------------------------------
// Annotators (section 5)

struct FirstOf {
    long long count = 0;
    WFDB_Time t = 0, p = 0;
    void add(WFDB_Time t_, WFDB_Time p_ = 0)
    {
        if (count++ == 0) {
            t = t_;
            p = p_;
        }
    }
};

void check_annotator(const std::string &record, const std::string &an,
                     std::optional<WFDB_Time> length, Rep &rep)
{
    std::string where = "annotator " + an;
    if (!an.empty() &&
        std::all_of(an.begin(), an.end(),
                    [](char c) { return c >= '0' && c <= '9'; }))
        rep.add("warning", "annotator_name", where,
                "the annotator name consists only of digits");
    wfdbquit();
    if (length) sampfreq(record.c_str());   // (for getann's times)
    std::shared_ptr<void> saved = detail::wfdbx_save_anndefs();
    struct Restore {
        std::shared_ptr<void> &saved;
        ~Restore()
        {
            wfdbquit();
            detail::wfdbx_restore_anndefs(saved);
        }
    } restore{saved};
    WFDB_Anninfo ai;
    ai.name = an;
    ai.stat = WFDB_READ;
    if (annopen(record.c_str(), &ai, 1) < 0) {
        rep.add("error", "annotations_unreadable", where,
                "the annotation file cannot be read");
        return;
    }
    WFDB_Annotation a;
    long long count = 0;
    std::optional<WFDB_Time> prev;
    FirstOf order, code, null, undef, after;
    int stat;
    while ((stat = getann(0, &a)) == 0) {
        count++;
        WFDB_Time t = a.time;
        int c = static_cast<unsigned char>(a.anntyp);
        if (prev && t < *prev) order.add(t, *prev);
        prev = t;
        if (c > ACMAX)
            code.add(t, c);
        else if (c == 0)
            null.add(t);
        else if (annstr(c) == strprintf("[%d]", c))
            undef.add(t, c);
        if (length && *length && t >= *length) after.add(t);
    }
    if (stat != -1)
        rep.add("error", "annotations_truncated", where,
                "the annotation file ends unexpectedly after " +
                counted(count, "annotation"));
    if (order.count) {
        std::string x = strprintf("at sample %lld, after sample %lld", order.t,
                                  order.p);
        rep.add("error", "annotations_order", where,
                count_form(order.count, "annotation", "is", "are",
                           "out of order", x));
    }
    if (code.count) {
        std::string x = strprintf("at sample %lld (code %lld)", code.t, code.p);
        rep.add("error", "annotation_code", where,
                count_form(code.count, "annotation", "has", "have",
                           "an invalid code", x));
    }
    if (null.count)
        rep.add("warning", "annotation_null", where,
                count_form(null.count, "annotation", "has", "have",
                           "code 0 (NOTQRS)",
                           strprintf("at sample %lld", null.t)));
    if (undef.count) {
        std::string x = strprintf("at sample %lld (code %lld)", undef.t,
                                  undef.p);
        rep.add("warning", "annotation_undefined", where,
                undef.count == 1
                    ? "1 annotation uses a code without a mnemonic: " + x
                    : strprintf("%lld annotations use codes without a "
                                "mnemonic; the first is ", undef.count) + x);
    }
    if (after.count)
        rep.add("warning", "annotations_after_end", where,
                count_form(after.count, "annotation", "is", "are",
                           "after the end of the record (" +
                               counted(*length, "sample") + ")",
                           strprintf("at sample %lld", after.t)));
}

// The library's settings for the duration of check_record, restored
// afterwards (also when an exception is thrown).
class CheckScope {
public:
    explicit CheckScope(const InputOptions &in) : in_(in)
    {
        if (in_.input_dir)
            prev_dir_ = wfdbx_set_input_dir(in_.input_dir->c_str());
        if (in_.network) prev_net_ = wfdbx_set_network(*in_.network ? 1 : 0);
        legacy_ = wfdbx_set_legacy(0);
        print_ = detail::wfdb_set_error_print(false);
        gvmode_ = getgvmode();
        wfdbquit();
    }
    ~CheckScope()
    {
        wfdbquit();
        setgvmode(gvmode_);
        detail::wfdb_set_error_print(print_);
        wfdbx_set_legacy(legacy_);
        if (in_.network) wfdbx_set_network(prev_net_);
        if (in_.input_dir)
            wfdbx_set_input_dir(prev_dir_ ? prev_dir_->c_str() : nullptr);
    }
    CheckScope(const CheckScope &) = delete;
    CheckScope &operator=(const CheckScope &) = delete;
private:
    InputOptions in_;
    std::optional<std::string> prev_dir_;
    int prev_net_ = 0;
    int legacy_ = 0;
    bool print_ = true;
    int gvmode_ = 0;
};

} // namespace

std::string Issue::to_string() const
{
    if (!where.empty()) return severity + ": " + where + ": " + message;
    return severity + ": " + message;
}

std::vector<std::string> CheckReport::lines() const
{
    if (issues.empty()) return {"no problems found"};
    std::vector<std::string> out;
    for (const Issue &i : issues) out.push_back(i.to_string());
    return out;
}

std::string CheckReport::to_string() const
{
    std::string out;
    for (const std::string &l : lines()) {
        if (!out.empty()) out += '\n';
        out += l;
    }
    return out;
}

CheckReport check_record(const std::string &record,
                         const std::vector<std::string> &annotators,
                         const InputOptions &input)
{
    if (record.empty()) throw Error("record must not be empty");
    Rep rep;
    {
        CheckScope scope(input);
        std::optional<WFDB_Time> length = check_record_signals(record, rep);
        for (const std::string &a : annotators)
            check_annotator(record, a, length, rep);
    }
    CheckReport r;
    r.record = record;
    r.issues = std::move(rep.issues);
    r.ok = std::none_of(r.issues.begin(), r.issues.end(),
                        [](const Issue &i) { return i.severity == "error"; });
    return r;
}

} // namespace wfdbx
