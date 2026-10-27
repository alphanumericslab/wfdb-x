// test_bulk.cpp: unit tests of the bulk reader of getvecs (bulk_frames in
// src/signal.cpp): for random records in every format it decodes, with
// invalid samples, in both getvec modes (and WFDB_GVPAD), with several
// signal groups, several input buffer sizes, records that end in the middle
// of a buffer, the frame at which the checksums are verified, headers that
// give fewer samples than the files hold, truncated files and seeks
// (isigsettime), everything that getvecs, getvec and isigsettime return
// (values, statuses, messages; the values of a frame that could not be read
// included) is the same with the bulk reader as with frame-by-frame reading
// (wfdbx_set_bulk_read(false)).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It tests wfdb-x; it has no counterpart in the original package.
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

// The records of tests/data (including those the bulk reader does not
// read: skew, multi-frequency, variable layout, FLAC, multi-segment).
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
