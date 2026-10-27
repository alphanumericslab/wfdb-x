// test_read_status.cpp: unit tests of the status handling of the high-level
// readers: read_record with a checksum error (in particular in
// high-resolution mode), read_annotations on a truncated annotation file,
// and the curl command line of the remote file reader.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It tests WFDB-x; it has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

#include "tests.hpp"

#include <wfdbx/ecgcodes.hpp>
#include <wfdbx/record.hpp>
#include <wfdbx/wfdb.hpp>

#include "../src/wfdblib.hpp"   // (detail::wfdbx_curl_args)

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <random>
#include <string>
#include <vector>

#if defined(__unix__) || defined(__APPLE__)
#include <unistd.h>
#define WFDBX_HAVE_DUP 1
#endif

using namespace wfdbx;
namespace fs = std::filesystem;

namespace {

// Run the test in a fresh empty directory (the current directory).
struct TempDir {
    fs::path old, dir;
    TempDir() {
        old = fs::current_path();
        static int n = 0;
        dir = fs::temp_directory_path() /
              ("wfdbx-status-" + std::to_string(n++) + "-" +
               std::to_string(std::random_device{}()));
        fs::create_directories(dir);
        fs::current_path(dir);
        wfdbquit();
        setwfdb(".");
    }
    ~TempDir() {
        wfdbquit();
        fs::current_path(old);
        std::error_code ec;
        fs::remove_all(dir, ec);
    }
};

std::string slurp(const std::string &name)
{
    std::ifstream f(name, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(f), {});
}

void spit(const std::string &name, const std::string &data)
{
    std::ofstream f(name, std::ios::binary | std::ios::trunc);
    f << data;
}

// What fn prints on stderr (POSIX; "" elsewhere, with fn still called).
template <class F>
std::string capture_stderr(F fn)
{
#ifdef WFDBX_HAVE_DUP
    std::fflush(stderr);
    std::FILE *tf = std::tmpfile();
    if (!tf) {
        fn();
        return "";
    }
    int saved = dup(2);
    dup2(fileno(tf), 2);
    try {
        fn();
    } catch (...) {
        std::fflush(stderr);
        dup2(saved, 2);
        close(saved);
        std::fclose(tf);
        throw;
    }
    std::fflush(stderr);
    dup2(saved, 2);
    close(saved);
    std::rewind(tf);
    std::string out;
    char buf[4096];
    size_t n;
    while ((n = std::fread(buf, 1, sizeof buf, tf)) > 0) out.append(buf, n);
    std::fclose(tf);
    return out;
#else
    fn();
    return "";
#endif
}

size_t count(const std::string &s, const std::string &what)
{
    size_t n = 0;
    for (size_t p = s.find(what); p != std::string::npos;
         p = s.find(what, p + 1))
        n++;
    return n;
}

WriteOptions mv_options(std::vector<int> spf)
{
    WriteOptions w;
    w.gains = {100};
    w.adcres = {16};
    w.units = {std::string("mV")};
    w.samps_per_frame = std::move(spf);
    return w;
}

// Write record "r" (format 16) whose signal file holds `bad` and whose
// header holds the checksums of `good`.  Returns what read_record(opt)
// gives for `bad` with matching checksums.
Record write_mismatched(const std::vector<WFDB_Sample> &good,
                        const std::vector<WFDB_Sample> &bad,
                        const std::vector<int> &spf, const ReadOptions &opt)
{
    int nsig = static_cast<int>(spf.size());
    write_record("r", bad, nsig, 100, mv_options(spf));
    Record expected = read_record("r", opt);
    CHECK(expected.checksum_ok);
    std::string dat = slurp("r.dat");
    write_record("r", good, nsig, 100, mv_options(spf));
    spit("r.dat", dat);
    return expected;
}

} // namespace

// ---------------------------------------------------------------------------
// read_record: a checksum error keeps every sample of the record

// The example of a single signal with 2 samples per frame and its first
// sample changed.
WFDBX_TEST(read_record_highres_checksum_example)
{
    TempDir d;
    wfdbquiet();
    std::vector<WFDB_Sample> x = {1, 2, 3, 4, 5, 6, 7, 8};
    write_record("mf", x, 1, 100, mv_options({2}));
    std::string dat = slurp("mf.dat");
    dat[0] = 99;
    dat[1] = 0;
    spit("mf.dat", dat);
    ReadOptions o;
    o.highres = true;
    o.checksum_warning = false;
    Record r = read_record("mf", o);
    CHECK(r.samples ==
          (std::vector<WFDB_Sample>{99, 2, 3, 4, 5, 6, 7, 8}));
    CHECK(!r.checksum_ok);
    // spf 3: 12 samples
    std::vector<WFDB_Sample> y = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12};
    write_record("mf", y, 1, 100, mv_options({3}));
    spit("mf.dat", std::string("\x63\x00", 2) + slurp("mf.dat").substr(2));
    r = read_record("mf", o);
    y[0] = 99;
    CHECK(r.samples == y);
    CHECK(!r.checksum_ok);
    wfdbverbose();
}

// Every combination of samples per frame, corrupt frame, resolution and
// signal selection: the samples are those of the data read with matching
// checksums, and checksum_ok is false.
WFDBX_TEST(read_record_checksum_error_all_samples)
{
    TempDir d;
    wfdbquiet();
    const std::vector<std::vector<int>> layouts = {
        {2}, {3}, {1, 2}, {2, 3}};
    const int nframes = 4;
    for (const std::vector<int> &spf : layouts) {
        int frame = 0;
        for (int s : spf) frame += s;
        std::vector<WFDB_Sample> good(static_cast<size_t>(frame) * nframes);
        for (size_t i = 0; i < good.size(); i++)
            good[i] = static_cast<WFDB_Sample>(i + 1);
        // the first sample of the first frame, and the last sample of the
        // last frame
        for (size_t where : {size_t(0), good.size() - 1}) {
            std::vector<WFDB_Sample> bad = good;
            bad[where] = 999;
            std::vector<std::vector<std::string>> selections = {{}};
            if (spf.size() == 2) selections.push_back({"1"});
            if (spf.size() == 2) selections.push_back({"1", "0"});
            for (const auto &channels : selections)
                for (bool highres : {false, true})
                    for (bool warn : {false, true}) {
                        ReadOptions o;
                        o.highres = highres;
                        o.channels = channels;
                        o.checksum_warning = warn;
                        Record expected = write_mismatched(good, bad, spf, o);
                        Record r = read_record("r", o);
                        CHECK(r.samples == expected.samples);
                        CHECK(!r.checksum_ok);
                        int maxspf = 1;
                        for (int s : spf) maxspf = std::max(maxspf, s);
                        size_t n = static_cast<size_t>(nframes) *
                                   (highres ? maxspf : 1);
                        CHECK_EQ(r.nsamples(), n);
                        if (r.samples != expected.samples || r.checksum_ok)
                            std::printf("    (spf %d%s, sample %zu, "
                                        "highres %d, %zu channels)\n",
                                        spf[0],
                                        spf.size() > 1 ? "+" : "", where,
                                        highres, channels.size());
                    }
        }
    }
    wfdbverbose();
}

// A read that ends before the last frame does not reach the checksum
// verification: every requested sample, and checksum_ok true.
WFDBX_TEST(read_record_checksum_not_reached)
{
    TempDir d;
    wfdbquiet();
    std::vector<WFDB_Sample> good = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12};
    std::vector<WFDB_Sample> bad = good;
    bad[0] = 99;
    for (bool highres : {false, true}) {
        ReadOptions o;
        o.highres = highres;
        o.to = highres ? 9 : 3;     // the first 3 of 4 frames
        Record expected = write_mismatched(good, bad, {3}, o);
        Record r = read_record("r", o);
        CHECK(r.samples == expected.samples);
        CHECK_EQ(r.nsamples(), size_t(highres ? 9 : 3));
        CHECK(r.checksum_ok);
    }
    wfdbverbose();
}

// The warning is printed once, and only with checksum_warning.
WFDBX_TEST(read_record_checksum_warning_once)
{
    TempDir d;
    wfdbquiet();
    std::vector<WFDB_Sample> good = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12};
    std::vector<WFDB_Sample> bad = good;
    bad[11] = 99;
    ReadOptions o;
    o.highres = true;
    write_mismatched(good, bad, {3}, o);
    wfdbverbose();
    for (bool warn : {true, false}) {
        o.checksum_warning = warn;
        Record r;
        std::string err = capture_stderr([&] { r = read_record("r", o); });
        CHECK(!r.checksum_ok);
        CHECK_EQ(r.nsamples(), size_t(12));
#ifdef WFDBX_HAVE_DUP
        CHECK_EQ(count(err, "wfdb-x: checksum error in record r"),
                 size_t(warn ? 1 : 0));
        CHECK_EQ(count(err, "checksum error"), size_t(warn ? 1 : 0));
#endif
    }
}

// The low-level API is unchanged: in high-resolution mode, getvec returns
// -4 for each sample vector of the frame at which the checksums are
// verified, then -1.
WFDBX_TEST(getvec_highres_checksum_status)
{
    TempDir d;
    wfdbquiet();
    std::vector<WFDB_Sample> good = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12};
    std::vector<WFDB_Sample> bad = good;
    bad[0] = 99;
    write_mismatched(good, bad, {3}, ReadOptions{});
    WFDB_Siginfo si;
    REQUIRE(isigopen("r", &si, 1) == 1);
    setgvmode(WFDB_HIGHRES);
    WFDB_Sample v;
    std::vector<int> stats;
    std::vector<WFDB_Sample> values;
    for (int k = 0; k < 14; k++) {
        int s = getvec(&v);
        stats.push_back(s);
        if (s != -1) values.push_back(v);
        if (s == -1) break;
    }
    CHECK(stats == (std::vector<int>{1, 1, 1, 1, 1, 1, 1, 1, 1, -4, -4, -4,
                                     -1}));
    CHECK(values == bad);
    wfdbquit();
    setgvmode(WFDB_LOWRES);
    wfdbverbose();
}

// ---------------------------------------------------------------------------
// read_annotations: a truncated annotation file is an error

namespace {

struct GetannResult {
    bool opened = false;
    int status = 0;
    std::vector<WFDB_Time> samples;
    std::vector<int> codes;
    std::vector<std::optional<std::string>> aux;
};

// The annotations getann returns for record "ann", annotator "t", and the
// status that ends the reading.
GetannResult read_with_getann()
{
    GetannResult g;
    wfdbquit();
    sampfreq("ann");
    WFDB_Anninfo ai;
    ai.name = "t";
    ai.stat = WFDB_READ;
    if (annopen("ann", &ai, 1) < 0) {
        wfdbquit();
        return g;
    }
    g.opened = true;
    WFDB_Annotation a;
    while ((g.status = getann(0, &a)) == 0) {
        g.samples.push_back(a.time);
        g.codes.push_back(a.anntyp);
        if (a.aux && !a.aux->empty())
            g.aux.push_back(a.aux->substr(
                1, static_cast<unsigned char>((*a.aux)[0])));
        else
            g.aux.push_back(std::nullopt);
    }
    wfdbquit();
    return g;
}

} // namespace

// Truncation at every byte position of a small annotation file (with an aux
// string, a SKIP and a channel change): read_annotations returns what getann
// returns when getann ends with 0 or -1, and otherwise throws, with the
// message naming getann's status.
WFDBX_TEST(read_annotations_truncated_file)
{
    TempDir d;
    wfdbquiet();
    write_record("ann", std::vector<WFDB_Sample>(100, 1), 1, 100,
                 mv_options({}));
    Annotations w;
    w.samples = {10, 20, 5000, 5010, 5020};
    w.codes = {NORMAL, PVC, NORMAL, NOTE, NORMAL};
    w.chans = {0, 0, 1, 1, 0};
    w.aux = {std::nullopt, std::nullopt, std::nullopt,
             std::string("(N hello"), std::nullopt};
    write_annotations("ann", "full", w);
    const std::string full = slurp("ann.full");
    REQUIRE(full.size() > 12);
    int errors = 0;
    for (size_t len = 0; len <= full.size(); len++) {
        spit("ann.t", full.substr(0, len));
        GetannResult g = read_with_getann();
        std::string msg;
        Annotations a;
        bool threw = false;
        try {
            a = read_annotations("ann", "t");
        } catch (const Error &e) {
            threw = true;
            msg = e.what();
        }
        if (!g.opened) {
            CHECK(threw);
            CHECK_EQ(msg, std::string("can't read annotator t for record ann"));
        } else if (g.status == 0 || g.status == -1) {
            CHECK(!threw);
            CHECK(a.samples == g.samples);
            CHECK(a.codes == g.codes);
            CHECK(a.aux == g.aux);
        } else {
            errors++;
            CHECK(threw);
            CHECK_EQ(msg, "can't read annotation file t of record ann "
                          "(getann status " + std::to_string(g.status) + ")");
        }
        if (len == full.size()) {
            CHECK(!threw && g.status == -1);
            CHECK(a.samples == w.samples);
        }
    }
    CHECK(errors > 0);
    // the library is usable after the error
    CHECK_EQ(read_annotations("ann", "full").size(), w.samples.size());
    wfdbverbose();
}

// The example: without its EOF word, a file of three annotations is an
// error, and getann's own message is still printed; a read that ends
// before the truncation point is not; a complete file reads as before.
WFDBX_TEST(read_annotations_truncated_message)
{
    TempDir d;
    write_record("ann", std::vector<WFDB_Sample>(100, 1), 1, 100,
                 mv_options({}));
    Annotations w;
    w.samples = {10, 20, 30};
    w.codes = {1, 5, 1};
    write_annotations("ann", "atr", w);
    std::string full = slurp("ann.atr");
    Annotations a = read_annotations("ann", "atr");
    CHECK(a.samples == w.samples && a.codes == w.codes);
    spit("ann.atr", full.substr(0, full.size() - 2));
    for (bool legacy : {false, true}) {
        std::string msg;
        std::string err = capture_stderr([&] {
            try {
                read_annotations("ann", "atr", {}, {}, std::nullopt, legacy);
            } catch (const Error &e) {
                msg = e.what();
            }
        });
        CHECK_EQ(msg, std::string("can't read annotation file atr of record "
                                  "ann (getann status -3)"));
#ifdef WFDBX_HAVE_DUP
        CHECK_EQ(count(err, "getann: unexpected EOF in annotator atr"),
                 size_t(1));
#endif
        // the annotator was closed
        CHECK(read_annotations("ann", "atr", {}, 20, std::nullopt, legacy)
                  .samples == (std::vector<WFDB_Time>{10}));
    }
    // sampto: the reading stops at the first annotation at or after it.
    // getann does not return the annotation at 30 (its status is -3), so a
    // read up to 30 or beyond is an error, and one up to 20 is not.
    wfdbquiet();
    a = read_annotations("ann", "atr", {}, 20);
    CHECK(a.samples == (std::vector<WFDB_Time>{10}));
    a = read_annotations("ann", "atr", 15, 20);
    CHECK(a.samples.empty());
    a = read_annotations("ann", "atr", {}, 11);
    CHECK(a.samples == (std::vector<WFDB_Time>{10}));
    for (WFDB_Time to : {21, 30, 31}) {
        std::string msg;
        try {
            read_annotations("ann", "atr", {}, to);
        } catch (const Error &e) {
            msg = e.what();
        }
        CHECK_EQ(msg, std::string("can't read annotation file atr of record "
                                  "ann (getann status -3)"));
    }
    wfdbverbose();
}

// ---------------------------------------------------------------------------
// The curl command line of the remote file reader

WFDBX_TEST(curl_command_line)
{
    const std::vector<std::string> options = {
        "curl", "--silent", "--fail", "--location", "--connect-timeout", "30",
        "--speed-limit", "1", "--speed-time", "30"};
    const std::string url = "https://physionet.org/files/mitdb/1.0.0/100.hea";
    for (bool quote : {false, true}) {
        std::vector<std::string> a = detail::wfdbx_curl_args(url, quote);
        REQUIRE(a.size() == options.size() + 1);
        CHECK(std::vector<std::string>(a.begin(), a.end() - 1) == options);
        CHECK_EQ(a.back(), url);    // (nothing to quote)
        size_t urls = 0;
        for (const std::string &s : a)
            if (s.find("://") != std::string::npos) urls++;
        CHECK_EQ(urls, size_t(1));
    }
    // A URL with a space and a quote: quoted only when asked
    const std::string odd = "https://h/a b\"c\\";
    std::vector<std::string> a = detail::wfdbx_curl_args(odd, false);
    CHECK_EQ(a.back(), odd);
    a = detail::wfdbx_curl_args(odd, true);
    CHECK_EQ(a.back(), std::string("\"https://h/a b\\\"c\\\\\""));
    CHECK(std::vector<std::string>(a.begin(), a.end() - 1) == options);
    CHECK_EQ(detail::wfdbx_quote_arg(""), std::string("\"\""));
    CHECK_EQ(detail::wfdbx_quote_arg("a\\\\b"), std::string("a\\\\b"));
}
