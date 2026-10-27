// test_bulk.cpp: unit tests of the bulk reader of getvecs (bulk_frames in
// src/signal.cpp): for random records in every format it decodes (also of
// several sampling frequencies, and multi-segment records), with
// invalid samples, in both getvec modes (and WFDB_GVPAD), with several
// signal groups, several input buffer sizes, records that end in the middle
// of a buffer, the frame at which the checksums are verified, headers that
// give fewer samples than the files hold, truncated files and seeks
// (isigsettime), everything that getvecs, getvec and isigsettime return
// (values, statuses, messages; the values of a frame that could not be read
// included) is the same with the bulk reader as with frame-by-frame reading
// (wfdbx_set_bulk_read(false)).
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

#include <wfdbx/record.hpp>
#include <wfdbx/wfdb.hpp>

#include "../src/wfdblib.hpp"   // (detail::wfdbx_set_bulk_read)

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <random>
#include <sstream>
#include <string>
#include <vector>

using namespace wfdbx;
namespace fs = std::filesystem;

namespace {

// Run the test in a fresh copy of tests/data (the current directory).
struct DataDir {
    fs::path old, dir;
    DataDir() {
        old = fs::current_path();
        static int n = 0;
        dir = fs::temp_directory_path() /
              ("wfdbx-test-b-" + std::to_string(n++) + "-" +
               std::to_string(std::random_device{}()));
        fs::create_directories(dir);
        for (const auto &e : fs::directory_iterator(wfdbx_tests::data_dir()))
            if (e.is_regular_file())
                fs::copy_file(e.path(), dir / e.path().filename());
        fs::current_path(dir);
        wfdbquit();
        setwfdb(".");
    }
    ~DataDir() {
        wfdbquit();
        detail::wfdbx_set_bulk_read(true);
        setibsize(0);
        setgvmode(WFDB_LOWRES);
        fs::current_path(old);
        std::error_code ec;
        fs::remove_all(dir, ec);
    }
};

const int FORMATS[] = {8, 16, 61, 80, 160, 212, 310, 311, 24, 32};

// The largest sample value of a format (the smallest, -max - 1, marks an
// invalid sample; format 8 stores differences).
int max_of(int fmt)
{
    switch (fmt) {
    case 8: return 300;
    case 80: return 127;
    case 212: return 2047;
    case 310: case 311: return 511;
    case 24: return 0x7fffff;
    case 32: return 0x7fffffff;
    default: return 32767;
    }
}

// Write record `name`: nframes frames of nsig signals of format fmt, random
// values with some invalid samples.
void write_random(const std::string &name, int fmt, int nsig, long nframes,
                  std::mt19937 &rng)
{
    std::vector<WFDB_Sample> x(static_cast<size_t>(nframes) * nsig);
    long long m = max_of(fmt);
    std::uniform_int_distribution<long long> val(-m, m);
    std::uniform_int_distribution<int> pct(0, 99);
    for (WFDB_Sample &v : x)
        v = pct(rng) < 7 ? WFDB_INVALID_SAMPLE
                         : static_cast<WFDB_Sample>(val(rng));
    WriteOptions w;
    w.fmt = fmt;
    w.gains = {100};
    w.adcres = {16};
    w.units = {std::string("mV")};
    write_record(name, x, nsig, 360, w);
}

std::vector<std::string> lines_of(const std::string &file)
{
    std::ifstream f(file);
    std::vector<std::string> v;
    std::string l;
    while (std::getline(f, l)) v.push_back(l);
    return v;
}

// Everything getvecs, getvec and isigsettime return for a random sequence
// of calls (seed), on record `rec` opened with input buffer size ibsize
// (0: the default) in getvec mode `mode`, with or without the bulk reader.
std::string trace(const std::string &rec, unsigned seed, int ibsize, int mode,
                  bool bulk)
{
    detail::wfdbx_set_bulk_read(bulk);
    setibsize(ibsize);
    std::ostringstream log;
    wfdbquiet();
    wfdb_error("(start)\n");   // (the same last message in both runs)
    int n = isigopen(rec.c_str(), nullptr, 0);
    if (n <= 0) {
        wfdbverbose();
        return "isigopen " + std::to_string(n);
    }
    std::vector<WFDB_Siginfo> si(n);
    n = isigopen(rec.c_str(), si.data(), n);
    setgvmode(mode);
    WFDB_Time len = strtim("e");
    if (len <= 0) len = 1000;
    std::mt19937 rng(seed);
    std::vector<WFDB_Sample> buf;
    int ends = 0;
    for (int op = 0; op < 60 && ends < 4; op++) {
        // (the message of this call, if any: the last message is compared
        // only if it changed)
        std::string before = wfdberror();
        int what = static_cast<int>(rng() % 100);
        if (what < 70) {
            long long k = 1 + static_cast<long long>(rng() % 4) *
                                  static_cast<long long>(rng() % 3000);
            if (rng() % 8 == 0) k = len + 10;
            // (room for one more frame: the one that could not be read)
            buf.assign(static_cast<size_t>((k + 1) * (n + 8)), -7);
            int stat = 0;
            long long m = getvecs(buf.data(), k, &stat);
            log << "getvecs " << k << " -> " << m << " " << stat << ":";
            long long frames = m < 0 ? 1 : (m < k ? m + 1 : m);
            for (long long i = 0; i < frames * n; i++) log << ' ' << buf[i];
            if (stat < 0) ends++;
        } else if (what < 85) {
            std::vector<WFDB_Sample> v(n + 8, -7);
            int stat = getvec(v.data());
            log << "getvec " << stat << ":";
            for (int i = 0; i < n; i++) log << ' ' << v[i];
            if (stat < 0) ends++;
        } else {
            WFDB_Time t = static_cast<WFDB_Time>(rng() % (len + 5));
            log << "isigsettime " << t << " -> " << isigsettime(t);
            ends = 0;
        }
        std::string after = wfdberror();
        log << " [" << (after != before ? after : "") << "]\n";
    }
    wfdbquit();
    wfdbverbose();
    detail::wfdbx_set_bulk_read(true);
    setibsize(0);
    return log.str();
}

// trace() is the same with and without the bulk reader, for a few seeds,
// buffer sizes and modes.  Returns false (after recording a failure) if
// not.
bool same(const std::string &rec, unsigned seed)
{
    for (int ibsize : {0, 7, 100})
        for (int mode : {WFDB_LOWRES, WFDB_HIGHRES,
                         WFDB_LOWRES | WFDB_GVPAD}) {
            std::string a = trace(rec, seed, ibsize, mode, true);
            std::string b = trace(rec, seed, ibsize, mode, false);
            if (a != b) {
                std::printf("    (record %s, seed %u, ibsize %d, mode %d)\n",
                            rec.c_str(), seed, ibsize, mode);
                CHECK(a == b);
                return false;
            }
        }
    return true;
}

} // namespace

// Single-group records in every format, read from the start to the end
// (and beyond), with seeks.
WFDBX_TEST(bulk_read_formats)
{
    DataDir d;
    std::mt19937 rng(1);
    unsigned seed = 1;
    for (int fmt : FORMATS)
        for (int nsig : {1, 2, 3, 4, 5}) {
            long nframes = 1 + static_cast<long>(rng() % 9000);
            std::string name = "f" + std::to_string(fmt) + "_" +
                               std::to_string(nsig);
            wfdbquiet();
            write_random(name, fmt, nsig, nframes, rng);
            wfdbverbose();
            if (!same(name, seed++)) return;
        }
}

// Several signal groups (different formats and files), a header that gives
// fewer samples than the files hold (a checksum error, then more data), a
// header without checksums or length, and truncated files.
WFDBX_TEST(bulk_read_groups_and_ends)
{
    DataDir d;
    std::mt19937 rng(2);
    wfdbquiet();
    write_random("ga", 212, 3, 5001, rng);
    write_random("gb", 16, 2, 5001, rng);
    write_random("gc", 310, 1, 5001, rng);
    write_random("gd", 8, 2, 5001, rng);
    wfdbverbose();
    std::vector<std::string> a = lines_of("ga.hea"), b = lines_of("gb.hea"),
                             c = lines_of("gc.hea"), e = lines_of("gd.hea");
    {
        std::ofstream f("multi4.hea");
        f << "multi4 8 360 5001\n";
        for (auto *h : {&a, &b, &c, &e})
            for (size_t i = 1; i < h->size(); i++) f << (*h)[i] << "\n";
    }
    CHECK(same("multi4", 11));
    // fewer samples in the header than in the files
    {
        std::ofstream f("short4.hea");
        f << "short4 8 360 4000\n";
        for (auto *h : {&a, &b, &c, &e})
            for (size_t i = 1; i < h->size(); i++) f << (*h)[i] << "\n";
    }
    CHECK(same("short4", 12));
    // no length (nor checksums)
    {
        std::ofstream f("nolen.hea");
        f << "nolen 2 360\ngb.dat 16 100/mV 16 0\ngb.dat 16 100/mV 16 0\n";
    }
    CHECK(same("nolen", 13));
    // truncated files: in the middle of a frame, of a sample, of a packed
    // unit
    for (int fmt : {16, 212, 310, 311, 24, 8}) {
        for (int cut : {1, 2, 3, 5}) {
            std::string name = "t" + std::to_string(fmt) + "_" +
                               std::to_string(cut);
            wfdbquiet();
            write_random(name, fmt, 3, 3001, rng);
            wfdbverbose();
            fs::resize_file(name + ".dat",
                            fs::file_size(name + ".dat") - cut * 97);
            if (!same(name, 20 + cut)) return;
        }
    }
    // a record whose checksums do not match (the last frame)
    wfdbquiet();
    write_random("ck", 16, 2, 4097, rng);
    wfdbverbose();
    {
        std::fstream f("ck.dat", std::ios::in | std::ios::out |
                                 std::ios::binary);
        f.seekp(10);
        f.put(1);
    }
    CHECK(same("ck", 31));
}

// The records of tests/data (including skew, multi-frequency, variable
// layout, FLAC and multi-segment records).
WFDBX_TEST(bulk_read_test_records)
{
    DataDir d;
    unsigned seed = 40;
    for (const char *rec : {"fmt212", "fmt310", "fmt311", "fmt8", "twog",
                            "100s", "skew", "mfreq", "multi", "vlay",
                            "flac16"})
        if (!same(rec, seed++)) return;
}

// read_record returns the same with and without the bulk reader (also with
// a checksum error and with signals selected).
WFDBX_TEST(bulk_read_record)
{
    DataDir d;
    std::mt19937 rng(3);
    wfdbquiet();
    for (int fmt : FORMATS) {
        std::string name = "r" + std::to_string(fmt);
        write_random(name, fmt, 3, 70001, rng);
        for (bool pad : {false, true}) {
            ReadOptions o;
            o.pad = pad;
            detail::wfdbx_set_bulk_read(true);
            Record r1 = read_record(name, o);
            detail::wfdbx_set_bulk_read(false);
            Record r2 = read_record(name, o);
            CHECK(r1.samples == r2.samples && r1.nsamples() == 70001);
            o.channels = {"2", "0"};
            o.from = 12345;
            o.to = 69999;
            detail::wfdbx_set_bulk_read(true);
            r1 = read_record(name, o);
            detail::wfdbx_set_bulk_read(false);
            r2 = read_record(name, o);
            CHECK(r1.samples == r2.samples && r1.nsamples() == 69999 - 12345);
        }
    }
    {
        std::fstream f("r16.dat", std::ios::in | std::ios::out |
                                  std::ios::binary);
        f.seekp(1000);
        f.put(3);
    }
    detail::wfdbx_set_bulk_read(true);
    Record r1 = read_record("r16");
    detail::wfdbx_set_bulk_read(false);
    Record r2 = read_record("r16");
    CHECK(r1.samples == r2.samples && !r1.checksum_ok && !r2.checksum_ok);
    detail::wfdbx_set_bulk_read(true);
    wfdbverbose();
}

namespace {

// Write the random multi-frequency record `name` (spf: samples per frame of
// each signal; n frames), with invalid samples (also at the start).
void mf_record(const std::string &name, std::mt19937 &rng, int fmt,
               const std::vector<int> &spf, long n,
               std::vector<WFDB_Gain> gains = {200},
               std::vector<std::string> names = {})
{
    size_t cols = 0;
    for (int k : spf) cols += static_cast<size_t>(k);
    std::vector<WFDB_Sample> x(static_cast<size_t>(n) * cols);
    if (fmt == 8) {
        std::uniform_int_distribution<int> d(-60, 60);
        for (size_t c = 0; c < cols; c++)
            for (long i = 0, v = 0; i < n; i++)
                x[static_cast<size_t>(i) * cols + c] =
                    static_cast<WFDB_Sample>(v += d(rng));
    } else {
        long long m = max_of(fmt);
        std::uniform_int_distribution<long long> val(-m + 1, m);
        std::uniform_int_distribution<int> pct(0, 999);
        for (WFDB_Sample &v : x)
            v = pct(rng) < 10 ? WFDB_INVALID_SAMPLE
                              : static_cast<WFDB_Sample>(val(rng));
        x[0] = x[cols] = WFDB_INVALID_SAMPLE;
    }
    WriteOptions w;
    w.fmt = fmt;
    w.gains = std::move(gains);
    w.adcres = {16};
    w.units = {std::string("mV")};
    w.samps_per_frame = spf;
    w.names = std::move(names);
    write_record(name, x, static_cast<int>(spf.size()), 250, w);
}

// A reading mode of the multi-frequency tests (physical: compare the
// samples in physical units too).
struct Mode {
    ReadOptions o;
    bool physical = false;
};

std::vector<Mode> mf_modes()
{
    std::vector<Mode> v(9);
    v[1].o.pad = true;
    v[2].o.highres = true;
    v[3].o.highres = v[3].o.pad = true;
    v[4].physical = true;
    v[5].o.from = 1234;
    v[6].o.from = 7;
    v[6].o.to = 15000;
    v[7].o.highres = true;
    v[7].o.from = 3;
    v[7].o.to = 9001;
    v[8].o.channels = {"1", "0", "1"};
    return v;
}

// What read_record returns (or the error it throws), as text.
std::string read_text(const std::string &rec, const Mode &m, bool bulk)
{
    detail::wfdbx_set_bulk_read(bulk);
    std::ostringstream t;
    try {
        Record r = read_record(rec, m.o);
        t << r.nsig << " " << r.nsamples() << " " << r.checksum_ok << " "
          << r.fs << ":";
        for (const std::string &n : r.names()) t << " " << n;
        t << "\n";
        for (WFDB_Sample v : r.samples) t << v << " ";
        if (m.physical)
            for (int s = 0; s < r.nsig; s++)
                for (double v : r.physical_signal(s)) t << v << " ";
    } catch (const std::exception &e) {
        t << "error: " << e.what();
    }
    detail::wfdbx_set_bulk_read(true);
    return t.str();
}

// read_record gives the same with and without the bulk reader.
bool same_read(const std::string &rec, const Mode &m)
{
    std::string a = read_text(rec, m, true), b = read_text(rec, m, false);
    if (a != b) {
        std::printf("    (record %s, highres %d, pad %d, from %lld)\n",
                    rec.c_str(), m.o.highres, m.o.pad,
                    static_cast<long long>(m.o.from.resolve()));
        CHECK(a == b);
        return false;
    }
    return true;
}

// (vectors read by read_record, vectors of them read in blocks)
std::pair<long long, long long> bulk_rows(const std::string &rec,
                                          const ReadOptions &o)
{
    long long before = detail::wfdbx_bulk_vectors();
    Record r = read_record(rec, o);
    return {static_cast<long long>(r.nsamples()),
            detail::wfdbx_bulk_vectors() - before};
}

// Write the segments name_1, name_2, ... (one per length) and return the
// lines of the master header naming them.
std::string write_segments(const std::string &name, std::mt19937 &rng,
                           int fmt, const std::vector<int> &spf,
                           const std::vector<long> &lens,
                           std::vector<WFDB_Gain> gains,
                           std::vector<std::string> names, long &total)
{
    std::string lines;
    for (size_t k = 0; k < lens.size(); k++) {
        std::string seg = name + "_" + std::to_string(k + 1);
        mf_record(seg, rng, fmt, spf, lens[k], gains, names);
        lines += seg + " " + std::to_string(lens[k]) + "\n";
        total += lens[k];
    }
    return lines;
}

} // namespace

// Records of several sampling frequencies are read in blocks: the same
// samples as frame by frame, in low- and high-resolution modes.
WFDBX_TEST(bulk_read_multifrequency)
{
    DataDir d;
    for (int fmt : FORMATS) {
        std::mt19937 rng(static_cast<unsigned>(fmt) + 1);
        for (const std::vector<int> &spf :
             std::vector<std::vector<int>>{{4, 1, 1, 1}, {2, 3}, {1, 2},
                                           {8, 1}, {3, 3, 1}}) {
            long n = 16000 + static_cast<long>(rng() % 8000);
            wfdbquiet();
            mf_record("m", rng, fmt, spf, n);
            wfdbverbose();
            for (const Mode &m : mf_modes())
                if (!same_read("m", m)) {
                    std::printf("    (format %d, spf[0] %d)\n", fmt, spf[0]);
                    return;
                }
            // (all but the frames near the end are read in blocks)
            ReadOptions o;
            o.highres = true;
            auto [rows, bulk] = bulk_rows("m", o);
            int mx = *std::max_element(spf.begin(), spf.end());
            CHECK(rows - bulk <= 6 * mx);
            o.highres = false;
            auto [rows2, bulk2] = bulk_rows("m", o);
            CHECK(rows2 - bulk2 <= 6);
        }
    }
}

// Multi-segment records, of fixed and of variable layout (with signals
// missing from some segments, other gains, and null segments), are read in
// blocks: the same samples as frame by frame.
WFDBX_TEST(bulk_read_multisegment)
{
    DataDir d;
    std::mt19937 rng(11);
    std::vector<std::string> names = {"ECG", "ABP", "RESP"};
    wfdbquiet();
    // fixed layout
    long total = 0;
    std::string segs = write_segments("fx", rng, 212, {4, 1, 1},
                                      {9000, 7001, 12000}, {200}, names,
                                      total);
    {
        std::ofstream f("fx.hea");
        f << "fx/3 3 250 " << total << "\n" << segs;
    }
    std::vector<Mode> modes = mf_modes();
    modes.emplace_back();
    modes.back().o.from = 8999;
    modes.back().o.to = 16002;
    for (const Mode &m : modes)
        if (!same_read("fx", m)) return;
    CHECK_EQ(read_record("fx").nsamples(), size_t(28001));
    {
        auto [rows, bulk] = bulk_rows("fx", ReadOptions());
        CHECK(rows - bulk <= 2 * 3);
        ReadOptions o;
        o.highres = true;
        auto [rows2, bulk2] = bulk_rows("fx", o);
        CHECK(rows2 - bulk2 <= 2 * 3 * 4);
    }
    // variable layout
    {
        std::ofstream f("vl_0.hea");
        f << "vl_0 3 250 0\n"
             "~ 0x4 400(10)/mV 12 0 0 0 0 ECG\n"
             "~ 0 100/mV 16 0 0 0 0 ABP\n"
             "~ 0 50/mV 16 0 0 0 0 RESP\n";
    }
    total = 2500;
    std::string s1 = write_segments("va", rng, 16, {4, 1, 1}, {5000},
                                    {400, 100, 50}, names, total);
    std::string s2 = write_segments("vb", rng, 16, {1, 4}, {6003},
                                    {25, 200}, {"RESP", "ECG"}, total);
    std::string s3 = write_segments("vc", rng, 212, {1}, {4000}, {100},
                                    {"ABP"}, total);
    {
        std::ofstream f("vl.hea");
        f << "vl/5 3 250 " << total << "\nvl_0 0\n" << s1 << "~ 2500\n"
          << s2 << s3;
    }
    modes.back().o.from = 4990;
    modes.back().o.to = 9000;
    for (const Mode &m : modes)
        if (!same_read("vl", m)) return;
    {
        auto [rows, bulk] = bulk_rows("vl", ReadOptions());
        CHECK(rows - bulk <= 2 * 6);
        ReadOptions o;
        o.highres = true;
        auto [rows2, bulk2] = bulk_rows("vl", o);
        CHECK(rows2 - bulk2 <= 2 * 6 * 4);
    }
    Record r = read_record("vl");
    wfdbverbose();
    CHECK_EQ(r.nsamples(), size_t(17503));
    bool nan = true;
    for (size_t i = 5000; i < 7500; i++)
        for (int s = 0; s < 3; s++) nan = nan && std::isnan(r.physical(i, s));
    CHECK(nan);
}

// Every record of tests/data (but those read from the standard input, 8
// and 16): the same in blocks as frame by frame, in every reading mode (or
// the same error).
WFDBX_TEST(bulk_read_all_test_records)
{
    DataDir d;
    std::vector<std::string> recs;
    for (const auto &e : fs::directory_iterator("."))
        if (e.path().extension() == ".hea" && e.path().stem() != "8" &&
            e.path().stem() != "16")
            recs.push_back(e.path().stem().string());
    std::sort(recs.begin(), recs.end());
    std::vector<Mode> modes(5);
    modes[1].o.pad = true;
    modes[2].o.highres = true;
    modes[3].o.highres = modes[3].o.pad = true;
    modes[4].o.from = 3;
    wfdbquiet();
    for (const std::string &rec : recs)
        for (const Mode &m : modes)
            if (!same_read(rec, m)) {
                wfdbverbose();
                return;
            }
    wfdbverbose();
}

// getvecs (bulk) mixed with getvec and isigsettime on a multi-frequency
// record, in high resolution also from the middle of a frame: the same
// vectors, statuses and library state as frame by frame.
WFDBX_TEST(bulk_multifrequency_interleaved)
{
    DataDir d;
    std::mt19937 rng(5);
    wfdbquiet();
    mf_record("mf", rng, 212, {4, 1, 3}, 20001);
    wfdbverbose();
    const std::pair<char, long long> steps[] = {
        {'f', 999}, {'v', 3}, {'f', 4097}, {'t', 17}, {'v', 1},
        {'f', 9001}, {'v', 2}, {'t', 30}, {'f', 200000}};
    for (bool hr : {false, true}) {
        std::string out[2];
        for (int run = 0; run < 2; run++) {
            detail::wfdbx_set_bulk_read(run == 0);
            std::ostringstream t;
            std::vector<WFDB_Siginfo> si(3);
            CHECK_EQ(isigopen("mf", si.data(), 3), 3);
            setgvmode((hr ? WFDB_HIGHRES : WFDB_LOWRES) | WFDB_GVPAD);
            for (auto [op, k] : steps) {
                if (op == 'f') {
                    std::vector<WFDB_Sample> buf(static_cast<size_t>(k) * 3);
                    int stat = 0;
                    long long m = getvecs(buf.data(), k, &stat);
                    t << "getvecs " << m << " " << stat << ":";
                    for (long long i = 0; i < std::max(m, 0LL) * 3; i++)
                        t << ' ' << buf[static_cast<size_t>(i)];
                } else if (op == 'v') {
                    for (long long i = 0; i < k; i++) {
                        WFDB_Sample v[3];
                        t << "getvec " << getvec(v) << ": " << v[0] << ' '
                          << v[1] << ' ' << v[2] << "\n";
                    }
                } else
                    t << "isigsettime " << isigsettime(k);
                t << "\n" << detail::wfdbx_input_state() << "\n";
            }
            wfdbquit();
            out[run] = t.str();
        }
        detail::wfdbx_set_bulk_read(true);
        CHECK(out[0] == out[1]);
    }
}

// Descriptions that end (or begin) with white space in the header are
// given without it by the high-level readers, and found by that name; the
// C-style functions keep it, as in C.
WFDBX_TEST(names_without_spaces)
{
    DataDir d;
    {
        std::ofstream f("sp.hea");
        f << "sp 3 250 4\n"
             "fmt16.dat 16 200/mV 16 0 0 0 0 III \n"
             "fmt16.dat 16 200/mV 16 0 0 0 0 ABP\t \n"
             "fmt16.dat 16 200/mV 16 0 0 0 0 PLETH\n";
    }
    const std::vector<std::string> want = {"III", "ABP", "PLETH"};
    for (bool legacy : {false, true}) {
        ReadOptions o;
        o.legacy = legacy;
        o.checksum_warning = false;
        Record r = read_record("sp", o);
        CHECK(r.names() == want);
        std::vector<std::string> descs;
        for (const WFDB_Siginfo &s : r.siginfo) descs.push_back(*s.desc);
        CHECK(descs == want);
        Header h = read_header("sp", legacy);
        descs.clear();
        for (const WFDB_Siginfo &s : h.siginfo) descs.push_back(*s.desc);
        CHECK(descs == want);
        ReadOptions o2;
        o2.checksum_warning = false;
        o2.channels = {"ABP", "III ", "2"};
        Record r2 = read_record("sp", o2);
        CHECK(r2.names() == (std::vector<std::string>{"ABP", "III", "PLETH"}));
        bool same = r2.nsamples() == r.nsamples();
        for (size_t i = 0; same && i < r.nsamples(); i++)
            same = r2.at(i, 0) == r.at(i, 1) && r2.at(i, 1) == r.at(i, 0) &&
                   r2.at(i, 2) == r.at(i, 2);
        CHECK(same);
    }
    std::vector<WFDB_Siginfo> si(3);
    CHECK_EQ(isigopen("sp", si.data(), 3), 3);
    CHECK(*si[0].desc == "III " && *si[1].desc == "ABP\t " &&
          *si[2].desc == "PLETH");
    wfdbquit();
}
