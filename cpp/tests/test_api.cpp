// test_api.cpp: unit tests of the library API and the high-level interface
// (the C++ counterparts of python/tests/test_signals.py, test_time.py, and
// test_annotations.py)
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

#include <wfdbx/ecgmap.hpp>
#include <wfdbx/record.hpp>
#include <wfdbx/wfdb.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <map>
#include <random>
#include <string>
#include <vector>

using namespace wfdbx;
namespace fs = std::filesystem;

namespace {

// Run the test in a fresh copy of tests/data (the current directory), with
// the WFDB path set to ".".
struct DataDir {
    fs::path old, dir;
    DataDir() {
        old = fs::current_path();
        static int n = 0;
        dir = fs::temp_directory_path() /
              ("wfdbx-test-" + std::to_string(n++) + "-" +
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

} // namespace

// ---------------------------------------------------------------------------
// Time and date conversion

WFDBX_TEST(interval_strings)
{
    DataDir d;
    REQUIRE(isigopen("100s", nullptr, 0) == 2);
    CHECK_EQ(strtim("1:0"), 21600);
    CHECK_EQ(timstr(21600), "    1:00");
    CHECK_EQ(mstimstr(1234), "    0:03.428");
    CHECK_EQ(strtim("s7"), 7);
    CHECK_EQ(strtim("e"), 21600);
}

WFDBX_TEST(absolute_times)
{
    DataDir d;
    isigopen("fmt16", nullptr, 0);
    CHECK_EQ(timstr(0), "[12:34:56 31/12/1999]");
    CHECK_EQ(strtim("[12:35:00]"), -803);
    CHECK_EQ(mstimstr(-2500), "[12:35:06.789 31/12/1999]");
}

WFDBX_TEST(dates)
{
    for (const char *s : {"01/01/2000", "29/02/2000", "15/10/1582",
                          "31/12/1999"})
        CHECK_EQ(datstr(strdat(s)), std::string(" ") + s);
    CHECK_EQ(datstr(strdat("29/02/1900")), " 01/03/1900");
    CHECK_EQ(strdat("bogus"), 0);
}

// ---------------------------------------------------------------------------
// Signals

// Every storage format round-trips exactly, through write_record and
// read_record, and through sample().
WFDBX_TEST(signal_roundtrip)
{
    DataDir d;
    const std::map<int, int> ranges = {
        {8, 1000}, {16, 32767}, {61, 32767}, {80, 127}, {160, 32767},
        {212, 2047}, {310, 511}, {311, 511}, {24, 8388607},
        {32, 2147483647}, {508, 127}, {516, 32767}, {524, 8388607}};
    for (const auto &[fmt, hi] : ranges) {
        for (int nsig = 1; nsig <= 3; nsig++) {
            std::mt19937_64 rng(fmt * 10 + nsig);
            int n = fmt >= 500 ? 5003 : 1001;
            std::vector<WFDB_Sample> x(static_cast<size_t>(n) * nsig);
            if (fmt == 8) {
                std::uniform_int_distribution<int> step(-60, 60);
                for (int s = 0; s < nsig; s++) {
                    int v = 0;
                    for (int i = 0; i < n; i++)
                        x[i * nsig + s] = v += step(rng);
                }
            } else {
                std::uniform_int_distribution<long long> u(-hi + 1, hi);
                for (auto &v : x) v = static_cast<WFDB_Sample>(u(rng));
            }
            WriteOptions w;
            w.fmt = fmt;
            w.gains = {200};
            w.adcres = {16};
            w.units = {std::string("mV")};
            write_record("rt", x, nsig, 250, w);
            Record r = read_record("rt");
            std::vector<WFDB_Sample> y = r.samples;
            if ((fmt == 310 || fmt == 311) && (n * nsig) % 3 == 2) {
                // A final group of two samples is written in 4 bytes, so
                // the file appears to contain an extra (zero) sample.
                for (int s = 0; s < nsig; s++)
                    CHECK_EQ(y[y.size() - nsig + s], 0);
                y.resize(y.size() - nsig);
            }
            CHECK(y == x);
            if (y != x)
                std::printf("    (format %d, %d signals)\n", fmt, nsig);
            isigopen("rt", nullptr, nsig);
            for (int t : {n - 1, 0, n / 2, 3, n - 2})
                for (int s = 0; s < nsig; s++)
                    CHECK_EQ(sample(s, t), x[t * nsig + s]);
            wfdbquit();
        }
    }
}

// getvecs (used by read_record) returns exactly what getvec does.
WFDBX_TEST(getvecs_equals_getvec)
{
    DataDir d;
    wfdbquiet();
    for (const char *rec : {"fmt212", "fmt310", "fmt311", "fmt8", "twog",
                            "100s", "skew", "mfreq", "multi", "vlay",
                            "flac16"}) {
        int n = isigopen(rec, nullptr, 0);
        REQUIRE(n > 0);
        std::vector<WFDB_Siginfo> si(n);
        isigopen(rec, si.data(), n);
        std::vector<WFDB_Sample> v(n), ref;
        while (getvec(v.data()) >= 0) ref.insert(ref.end(), v.begin(), v.end());
        wfdbquit();
        Record r = read_record(rec);
        CHECK(r.samples == ref);
    }
    wfdbverbose();
}

// A signal file shorter than its header says (getvec status -3,
// unexpected EOF) is an error of read_record, not the end of the data; the
// low-level API is unchanged.
WFDBX_TEST(read_record_truncated_signal_file)
{
    DataDir d;
    wfdbquiet();
    const std::vector<WFDB_Sample> x = {1, 2, 3, 4, 5, 6, 7, 8};
    WriteOptions w;
    w.gains = {100};
    w.adcres = {16};
    w.units = {std::string("mV")};
    write_record("tr", x, 2, 100, w);
    write_record("ok", x, 2, 100, w);
    fs::resize_file("tr.dat", 8);   // 2 of the 4 frames (format 16)
    for (bool legacy : {false, true}) {
        ReadOptions o;
        o.legacy = legacy;
        // (1) the error, and the library is left usable
        std::string msg;
        try {
            read_record("tr", o);
        } catch (const Error &e) {
            msg = e.what();
        }
        CHECK_EQ(msg, std::string("can't read signal data of record tr "
                                  "(getvec status -3)"));
        CHECK(read_record("ok", o).samples == x);
        // reading only what the file holds is not an error
        ReadOptions o2 = o;
        o2.to = 2;
        CHECK(read_record("tr", o2).samples ==
              std::vector<WFDB_Sample>(x.begin(), x.begin() + 4));
        // (2) a sub-interval, and sampto past the end of a record whose
        // header gives its length (what there is, no error)
        o2.from = 1;
        o2.to = 3;
        CHECK(read_record("ok", o2).samples ==
              std::vector<WFDB_Sample>(x.begin() + 2, x.begin() + 6));
        o2.from = 0;
        o2.to = 10;
        CHECK(read_record("ok", o2).samples == x);
    }
    // (3) the low-level API: getvec returns -3 at the end of the truncated
    // file, getvecs the frames read
    std::vector<WFDB_Siginfo> si(2);
    REQUIRE(isigopen("tr", si.data(), 2) == 2);
    WFDB_Sample v[2];
    CHECK_EQ(getvec(v), 2);
    CHECK_EQ(getvec(v), 2);
    CHECK_EQ(getvec(v), -3);
    wfdbquit();
    REQUIRE(isigopen("tr", si.data(), 2) == 2);
    std::vector<WFDB_Sample> buf(20);
    int stat = 0;
    CHECK_EQ(getvecs(buf.data(), 10, &stat), 2LL);
    CHECK_EQ(stat, -3);
    wfdbquit();
    REQUIRE(isigopen("ok", si.data(), 2) == 2);
    CHECK_EQ(getvecs(buf.data(), 10, &stat), 4LL);
    CHECK_EQ(stat, -1);
    wfdbquit();
    wfdbverbose();
}

WFDBX_TEST(physical_units)
{
    DataDir d;
    ReadOptions o;
    o.to = 3;
    Record r = read_record("100s", o);
    REQUIRE(r.nsamples() == 3);
    for (size_t i = 0; i < 3; i++) {
        CHECK(std::fabs(r.physical(i, 0) + 0.145) < 1e-12);
        CHECK(std::fabs(r.physical(i, 1) + 0.065) < 1e-12);
    }
    CHECK_EQ(r.names()[0], "MLII");
}

WFDBX_TEST(multifrequency)
{
    DataDir d;
    ReadOptions lo_opt, hi_opt;
    lo_opt.to = 10;
    hi_opt.to = 20;
    hi_opt.highres = true;
    Record lo = read_record("mfreq", lo_opt);
    Record hi = read_record("mfreq", hi_opt);
    CHECK(lo.nsamples() == 10 && lo.nsig == 3);
    CHECK(hi.nsamples() == 20 && hi.nsig == 3);
    CHECK(hi.fs == 400 && lo.fs == 100);
}

WFDBX_TEST(variable_layout)
{
    DataDir d;
    wfdbquiet();
    ReadOptions o;
    o.from = 1498;
    o.to = 1502;
    Record r = read_record("vlay", o);
    wfdbverbose();
    REQUIRE(r.nsamples() == 4);
    for (int s = 0; s < r.nsig; s++)
        CHECK_EQ(r.at(2, s), WFDB_INVALID_SAMPLE);
}

WFDBX_TEST(time_strings_in_options)
{
    DataDir d;
    ReadOptions o;
    o.from = "0:1";
    o.to = "0:2";
    o.channels = {"V5"};
    Record r = read_record("100s", o);
    CHECK(r.nsig == 1 && r.nsamples() == 360 && r.sampfrom == 360);
    CHECK_EQ(*r.siginfo[0].desc, "V5");
}

WFDBX_TEST(header_writing)
{
    DataDir d;
    std::vector<WFDB_Sample> x(20, 0);
    WriteOptions w;
    w.gains = {100, 0};
    w.units = {std::string("mV"), std::string("uV")};
    w.adcres = {16};
    w.names = {"lead I", "pressure"};
    w.base_time = "12:00:00 01/02/2003";
    w.comments = {"c1"};
    write_record("hw", x, 2, 125.5, w);
    std::string text = slurp("hw.hea");
    CHECK(text.rfind("hw 2 125.5 10 12:00:00 01/02/2003\r\n", 0) == 0);
    CHECK(text.find("hw.dat 16 100/mV 16 0 0 0 0 lead I\r\n") !=
          std::string::npos);
    CHECK(text.size() >= 5 && text.compare(text.size() - 5, 5, "#c1\r\n") == 0);
}

WFDBX_TEST(physical_writing)
{
    DataDir d;
    std::vector<double> x = {0.0, 1.0, -0.5, 0.0025, NAN, 2.0};
    WriteOptions w;
    w.gains = {200};
    w.adcres = {12};
    w.units = {std::string("mV")};
    write_record_physical("ph", x, 2, 100, w);
    Record r = read_record("ph");
    std::vector<WFDB_Sample> expect = {0, 200, -100, 1, WFDB_INVALID_SAMPLE,
                                       400};
    CHECK(r.samples == expect);
    CHECK(std::isnan(r.physical(2, 0)));
}

WFDBX_TEST(errors_throw)
{
    DataDir d;
    wfdbquiet();
    bool thrown = false;
    try {
        read_record("nosuch");
    } catch (const Error &) {
        thrown = true;
    }
    CHECK(thrown);
    thrown = false;
    try {
        read_annotations("100s", "nosuch");
    } catch (const Error &) {
        thrown = true;
    }
    CHECK(thrown);
    wfdbverbose();
}

// ---------------------------------------------------------------------------
// No default sampling frequency or gain (WFDB-x divergence; see
// docs/DIVERGENCES.md)

namespace {

// The message of the Error thrown by f, or "" if none is thrown.
template <typename F>
std::string error_of(F f)
{
    try {
        f();
    } catch (const Error &e) {
        return e.what();
    }
    return "";
}

// Write record "nf": the signals of 100s, with a header that specifies
// neither the sampling frequency nor (for signal 1) the gain.
void write_nofreq_record()
{
    std::ofstream f("nf.hea", std::ios::binary);
    f << "nf 2\n100s.dat 212 200 11 1024 995 21537 0 MLII\n"
         "100s.dat 212 0 11 1024 1011 -3962 0 V5\n";
}

} // namespace

WFDBX_TEST(write_record_requires_gains)
{
    DataDir d;
    std::vector<WFDB_Sample> x(6, 1);
    std::vector<double> p(6, 0.5);
    WriteOptions w;
    w.adcres = {16};
    w.units = {std::string("mV")};
    CHECK_EQ(error_of([&] { write_record("g", x, 2, 100, w); }),
             "write_record: gains must be specified");
    CHECK_EQ(error_of([&] { write_record_physical("g", p, 2, 100, w); }),
             "write_record: gains must be specified");
    w.gains = {100, 50, 25};
    CHECK_EQ(error_of([&] { write_record("g", x, 3, 100, w); }), "");
    w.gains = {100, 50};
    CHECK_EQ(error_of([&] { write_record("g", x, 3, 100, w); }),
             "write_record: gains must be specified");
    // A gain of 0 (uncalibrated) is allowed for ADC units only.
    w.gains = {100, 0};
    w.units = {std::string("mV"), std::nullopt};
    CHECK_EQ(error_of([&] { write_record("g", x, 2, 100, w); }), "");
    CHECK(slurp("g.hea").find("g.dat 16 0 16 0 1 ") != std::string::npos);
    CHECK_EQ(error_of([&] { write_record_physical("g", p, 2, 100, w); }),
             "write_record: signal 1 is uncalibrated");
    // The sampling frequency must be > 0.
    w.gains = {100};
    for (double fs : {0.0, -1.0}) {
        CHECK_EQ(error_of([&] { write_record("g", x, 2, fs, w); }),
                 "write_record: the sampling frequency must be > 0");
        CHECK_EQ(error_of([&] { write_record_physical("g", p, 2, fs, w); }),
                 "write_record: the sampling frequency must be > 0");
    }
}

// No built-in ADC resolution or units (WFDB-x divergence, round 2).
WFDBX_TEST(write_record_requires_adcres_and_units)
{
    DataDir d;
    std::vector<WFDB_Sample> x(6, 1);
    std::vector<double> p(6, 0.5);
    WriteOptions w;
    w.gains = {100};
    w.units = {std::string("mV")};
    // The ADC resolutions are required (no format-based default), >= 1.
    CHECK_EQ(error_of([&] { write_record("r", x, 2, 100, w); }),
             "write_record: ADC resolution(s) must be specified");
    CHECK_EQ(error_of([&] { write_record_physical("r", p, 2, 100, w); }),
             "write_record: ADC resolution(s) must be specified");
    for (int bad : {0, -1}) {
        w.adcres = {bad};
        CHECK_EQ(error_of([&] { write_record("r", x, 2, 100, w); }),
                 "write_record: ADC resolution(s) must be specified");
    }
    w.adcres = {12, 0};
    CHECK_EQ(error_of([&] { write_record("r", x, 2, 100, w); }),
             "write_record: ADC resolution(s) must be specified");
    w.adcres = {12, 10, 8};
    CHECK_EQ(error_of([&] { write_record("r", x, 3, 100, w); }), "");
    CHECK(slurp("r.hea").find("r.dat 16 100/mV 10 0 1 ") != std::string::npos);
    w.adcres = {12, 10};
    CHECK_EQ(error_of([&] { write_record("r", x, 3, 100, w); }),
             "write_record: ADC resolution(s) must be specified");
    // The units of every calibrated signal are required.
    w.adcres = {12};
    w.units = {};
    CHECK_EQ(error_of([&] { write_record("r", x, 2, 100, w); }),
             "write_record: units must be specified");
    CHECK_EQ(error_of([&] { write_record_physical("r", p, 2, 100, w); }),
             "write_record: units must be specified");
    w.units = {std::string("mV"), std::nullopt};
    CHECK_EQ(error_of([&] { write_record("r", x, 2, 100, w); }),
             "write_record: units must be specified");
    w.units = {std::string("")};
    CHECK_EQ(error_of([&] { write_record("r", x, 2, 100, w); }),
             "write_record: units must be specified");
    // ... but not those of uncalibrated signals.
    w.gains = {100, 0};
    w.units = {std::string("mV"), std::nullopt};
    CHECK_EQ(error_of([&] { write_record("r", x, 2, 100, w); }), "");
    std::vector<WFDB_Siginfo> si = read_header("r").siginfo;
    REQUIRE(si.size() == 2);
    CHECK(si[0].units && *si[0].units == "mV");
    CHECK(!si[1].units);
}

WFDBX_TEST(read_record_no_adcres_or_units)
{
    DataDir d;
    {
        std::ofstream f("nr.hea", std::ios::binary);
        f << "nr 2 100\n100s.dat 212 200 11 1024 995 21537 0 MLII\n"
             "100s.dat 212 200\n";
    }
    std::vector<WFDB_Siginfo> si = read_header("nr").siginfo;
    REQUIRE(si.size() == 2);
    CHECK_EQ(si[0].adcres, 11);
    CHECK(!si[0].units);
    CHECK_EQ(si[1].adcres, 0);  // C: 12 (from the format)
    CHECK(!si[1].units);        // C programs: mV
    ReadOptions o;
    o.to = 3;
    Record r = read_record("nr", o);
    CHECK_EQ(r.siginfo[1].adcres, 0);
    CHECK(!r.siginfo[1].units);
}

WFDBX_TEST(read_record_no_frequency)
{
    DataDir d;
    write_nofreq_record();
    Record r = read_record("nf");
    CHECK_EQ(r.fs, 0);
    CHECK(!r.base_time);
    CHECK(r.nsamples() > 0 && r.nsig == 2);
    // Sample numbers and "e" do not need the frequency; other times do.
    ReadOptions o;
    o.from = "s10";
    o.to = 20;
    r = read_record("nf", o);
    CHECK(r.sampfrom == 10 && r.nsamples() == 10);
    o.to = "e";
    CHECK_EQ(error_of([&] { read_record("nf", o); }), "");
    o.to = "0:1";
    CHECK_EQ(error_of([&] { read_record("nf", o); }),
             "sampling frequency of record nf is not specified");
    o.to = {};
    o.from = "1";
    CHECK_EQ(error_of([&] { read_record("nf", o); }),
             "sampling frequency of record nf is not specified");
}

WFDBX_TEST(physical_units_need_gain)
{
    DataDir d;
    write_nofreq_record();
    ReadOptions o;
    o.to = 3;
    Record r = read_record("nf", o);
    CHECK(std::fabs(r.physical(0, 0) + 0.145) < 1e-12);
    CHECK_EQ(error_of([&] { r.physical(0, 1); }),
             "signal 1 of record nf is uncalibrated");
    CHECK_EQ(error_of([&] { r.physical_signal(1); }),
             "signal 1 of record nf is uncalibrated");
    // The signal number is that of the record, not of the selection.
    o.channels = {"V5"};
    r = read_record("nf", o);
    CHECK(r.signals == std::vector<int>{1});
    CHECK_EQ(error_of([&] { r.physical(0, 0); }),
             "signal 1 of record nf is uncalibrated");
}

WFDBX_TEST(read_annotations_frequency)
{
    DataDir d;
    // 100s has a header (360 Hz): the fs argument is not used.
    Annotations a = read_annotations("100s", "atr", {}, "0:5", 100);
    Annotations b = read_annotations("100s", "atr", {}, "s1800");
    CHECK(a.size() == b.size() && a.size() > 0 && a.fs == 360);
    // Without a header: no default frequency.
    std::filesystem::copy_file("100s.atr", "nohea.atr");
    wfdbquiet();
    a = read_annotations("nohea", "atr");
    CHECK(a.size() == 75 && a.fs == 0);
    CHECK_EQ(error_of([&] { read_annotations("nohea", "atr", {}, "0:5"); }),
             "sampling frequency of record nohea is not specified");
    CHECK_EQ(error_of([&] { read_annotations("nohea", "atr", "1"); }),
             "sampling frequency of record nohea is not specified");
    b = read_annotations("nohea", "atr", {}, "s1800");
    a = read_annotations("nohea", "atr", {}, "0:5", 360);
    CHECK(a.size() == b.size() && a.size() > 0 && a.fs == 360);
    a = read_annotations("nohea", "atr", {}, "0:10", 180);
    CHECK(a.size() == b.size() && a.fs == 180);
    // An explicit fs must be > 0.
    for (double f : {0.0, -360.0})
        CHECK_EQ(error_of([&] { read_annotations("nohea", "atr", {}, {}, f); }),
                 "read_annotations: fs must be > 0");
    CHECK_EQ(error_of([&] { read_annotations("100s", "atr", {}, {}, 0.0); }),
             "read_annotations: fs must be > 0");
    // A header without a frequency: the same rule.
    write_nofreq_record();
    std::filesystem::copy_file("100s.atr", "nf.atr");
    CHECK_EQ(error_of([&] { read_annotations("nf", "atr", {}, "0:5"); }),
             "sampling frequency of record nf is not specified");
    a = read_annotations("nf", "atr", {}, "0:5", 360);
    CHECK(a.size() == b.size() && a.fs == 360);
    wfdbverbose();
}

// Legacy mode (the `legacy` options): the original behavior, with the
// library's legacy mode on for the duration of the call only.
WFDBX_TEST(legacy_write_record)
{
    DataDir d;
    std::vector<WFDB_Sample> x(6, 1);
    WriteOptions w;
    w.legacy = true;
    // No gains, ADC resolutions or units: 200, from the format, none.
    CHECK_EQ(error_of([&] { write_record("lg", x, 2, 100, w); }), "");
    CHECK_EQ(wfdbx_get_legacy(), 0);
    CHECK(slurp("lg.hea").find("lg.dat 16 200 16 0 1 ") != std::string::npos);
    w.fmt = 212;
    w.gains = {100};
    CHECK_EQ(error_of([&] { write_record("lg", x, 2, 100, w); }), "");
    CHECK(slurp("lg.hea").find("lg.dat 212 100 12 0 1 ") != std::string::npos);
    // write_record_physical: a gain of 0 means 200 (the header keeps 0).
    w.fmt = 16;
    w.gains = {0};
    std::vector<double> p(6, 0.5);
    CHECK_EQ(error_of([&] { write_record_physical("lp", p, 2, 100, w); }), "");
    ReadOptions o;
    o.legacy = true;
    Record r = read_record("lp", o);
    CHECK_EQ(r.siginfo[0].gain, 0);
    CHECK(r.nsamples() == 3 && r.at(0, 0) == 100 && r.physical(0, 1) == 0.5);
    // Without legacy, the same calls fail.
    w.legacy = false;
    w.gains = {};
    CHECK_EQ(error_of([&] { write_record("lg", x, 2, 100, w); }),
             "write_record: gains must be specified");
    // ... unless the library is in legacy mode (wfdbx_set_legacy).
    wfdbx_set_legacy(1);
    CHECK_EQ(error_of([&] { write_record("lg", x, 2, 100, w); }), "");
    CHECK_EQ(wfdbx_get_legacy(), 1);
    wfdbx_set_legacy(0);
    CHECK(slurp("lg.hea").find("lg.dat 16 200 16 0 1 ") != std::string::npos);
}

WFDBX_TEST(legacy_read_record)
{
    DataDir d;
    // Uncalibrated signals: physical units with gain 200.  (The samples of
    // the uncalibrated record null are invalid: NaN.)
    ReadOptions o;
    o.to = 3;
    o.legacy = true;
    Record r = read_record("null", o);
    CHECK(r.legacy && std::isnan(r.physical(0, 0)));
    CHECK_EQ(error_of([&] { r.physical_signal(1); }), "");
    CHECK_EQ(wfdbx_get_legacy(), 0);
    WriteOptions w;
    w.gains = {0};
    w.adcres = {12};
    write_record("uc", {300, -50}, 2, 100, w);
    r = read_record("uc", o);
    CHECK(r.physical(0, 0) == 1.5 && r.physical(0, 1) == -0.25);
    o.legacy = false;
    r = read_record("uc", o);
    CHECK_EQ(error_of([&] { r.physical(0, 0); }),
             "signal 0 of record uc is uncalibrated");
    o.legacy = true;
    // A header without a frequency (and a gain): 250 Hz, gain 200.
    write_nofreq_record();
    o.from = "0:1";
    o.to = "0:2";
    r = read_record("nf", o);
    CHECK(r.fs == 250 && r.sampfrom == 250 && r.nsamples() == 250);
    CHECK(std::fabs(r.physical(0, 1) - (r.at(0, 1) - 1024) / 200.) < 1e-12);
    // A missing ADC resolution: from the format.
    {
        std::ofstream f("nr.hea", std::ios::binary);
        f << "nr 2 100\n100s.dat 212 200\n100s.dat 212 200\n";
    }
    CHECK_EQ(read_header("nr").siginfo[1].adcres, 0);
    CHECK_EQ(read_header("nr", true).siginfo[1].adcres, 12);
    // The previous setting is restored, also when an error is thrown.
    wfdbquiet();
    CHECK(!error_of([&] { read_record("nonexistent", o); }).empty());
    CHECK_EQ(wfdbx_get_legacy(), 0);
    wfdbx_set_legacy(1);
    CHECK(!error_of([&] { read_record("nonexistent", o); }).empty());
    CHECK_EQ(wfdbx_get_legacy(), 1);
    wfdbx_set_legacy(0);
    wfdbverbose();
}

WFDBX_TEST(legacy_read_annotations)
{
    DataDir d;
    std::filesystem::copy_file("100s.atr", "nohea.atr");
    wfdbquiet();
    // Without a header: 250 Hz.
    Annotations a = read_annotations("nohea", "atr", {}, "0:5", {}, true);
    Annotations b = read_annotations("nohea", "atr", {}, "s1250");
    CHECK(a.size() == b.size() && a.size() > 0 && a.fs == 250);
    CHECK_EQ(wfdbx_get_legacy(), 0);
    // A given fs still applies.
    a = read_annotations("nohea", "atr", {}, "0:5", 360, true);
    CHECK(a.fs == 360);
    wfdbverbose();
}

// ---------------------------------------------------------------------------
// Annotations

WFDBX_TEST(annotations_read)
{
    DataDir d;
    Annotations a = read_annotations("100s", "atr");
    CHECK_EQ(a.size(), 75u);
    CHECK(a.symbols[0] == "+" && a.symbols[1] == "N" && a.symbols[2] == "N");
    CHECK(a.aux[0] && *a.aux[0] == "(N");
}

WFDBX_TEST(annotations_roundtrip)
{
    DataDir d;
    Annotations w;
    w.samples = {0, 5, 5, 5, 300, 70000, 70001, 5000000000LL, 5000000000LL};
    w.codes = {NOTE, NORMAL, NORMAL, NORMAL, PVC, ARFCT, RHYTHM, NORMAL,
               NOISE};
    w.chans = {0, 0, 1, 1, 0, 3, 0, 0, 2};
    w.nums = {0, 0, 0, 2, 0, -1, 0, 0, 1};
    w.subtypes = {0, 0, 0, 0, 3, 0, 0, 0, -1};
    w.aux = {std::string("start"), std::nullopt, std::nullopt, std::nullopt,
             std::nullopt, std::nullopt, std::string("(AFIB"), std::nullopt,
             std::string(200, 'x')};
    write_annotations("100s", "rt", w);
    wfdbquiet();
    Annotations a = read_annotations("100s", "rt");
    wfdbverbose();
    // (the NOTE at time 0 is consumed as a modification label by annopen)
    REQUIRE(a.size() == w.size() - 1);
    for (size_t i = 0; i < a.size(); i++) {
        CHECK_EQ(a.samples[i], w.samples[i + 1]);
        CHECK_EQ(a.codes[i], w.codes[i + 1]);
        CHECK_EQ(a.chans[i], w.chans[i + 1]);
        CHECK_EQ(a.nums[i], w.nums[i + 1]);
        CHECK_EQ(a.subtypes[i], w.subtypes[i + 1]);
        CHECK(a.aux[i] == w.aux[i + 1]);
    }
}

WFDBX_TEST(mnemonics)
{
    CHECK_EQ(*annstr(NORMAL), "N");
    CHECK_EQ(strann("V"), PVC);
    CHECK_EQ(*anndesc(PVC), "Premature ventricular contraction");
    CHECK_EQ(*ecgstr(99), "[99]");
    CHECK(isqrs(NORMAL) && !isqrs(NOTE));
    CHECK(map1(APC) == NORMAL && map2(APC) == SVPB);
}

// ---------------------------------------------------------------------------
// The output directory of the writers (WFDB-x: WriteOptions::dir and the dir
// parameter of write_annotations())

namespace {

std::vector<std::string> list_dir(const std::string &d)
{
    std::vector<std::string> v;
    for (const auto &e : fs::directory_iterator(d))
        v.push_back(e.path().filename().string());
    std::sort(v.begin(), v.end());
    return v;
}

template <class F>
bool throws_with(F fn, const std::string &what)
{
    try {
        fn();
    } catch (const Error &e) {
        return std::string(e.what()).find(what) != std::string::npos;
    }
    return false;
}

const std::vector<WFDB_Sample> dir_samples = {0, 1, 2, 3, 4, 5, 6, 7, 8, 9,
                                              10, 11, 12, 13, 14, 15, 16, 17,
                                              18, 19};

WriteOptions dir_options(const std::string &dir)
{
    WriteOptions w;
    w.gains = {200};
    w.adcres = {12};
    w.units = {"mV"};
    w.dir = dir;
    return w;
}

} // namespace

WFDBX_TEST(write_record_dir)
{
    DataDir d;
    fs::create_directory("out");
    auto prev = wfdbx_set_output_dir("elsewhere");
    write_record("rec", dir_samples, 2, 360, dir_options("out"));
    CHECK(wfdbx_get_output_dir() == "elsewhere");     // restored
    wfdbx_set_output_dir(prev ? prev->c_str() : nullptr);
    CHECK(list_dir("out") == (std::vector<std::string>{"rec.dat", "rec.hea"}));
    CHECK(!fs::exists("rec.hea") && !fs::exists("rec.dat"));
    std::string hea = slurp("out/rec.hea");
    CHECK(hea.rfind("rec 2 360 10\r\nrec.dat 16 ", 0) == 0);
    setwfdb("out");
    CHECK(read_record("rec").samples == dir_samples);
    setwfdb(".");
    CHECK(read_record("out/rec").samples == dir_samples);
    CHECK(!wfdbx_get_output_dir());
    wfdbquiet();
    CHECK(throws_with([] {
        write_record("rec", dir_samples, 2, 360, dir_options("nosuch"));
    }, "directory nosuch does not exist"));
    CHECK(throws_with([] {
        write_record("sub/rec", dir_samples, 2, 360, dir_options("out"));
    }, "record name must not contain a directory when dir is given"));
    // restored after an error, too
    CHECK(throws_with([] {
        WriteOptions w = dir_options("out");
        w.gains.clear();
        write_record("rec", dir_samples, 2, 360, w);
    }, "gains must be specified"));
    wfdbverbose();
    CHECK(!wfdbx_get_output_dir());
    CHECK(!fs::exists("nosuch"));
    // the same in legacy mode
    WriteOptions w;
    w.dir = "out";
    w.legacy = true;
    write_record("leg", dir_samples, 2, 360, w);
    CHECK(slurp("out/leg.hea").rfind("leg 2 360 10\r\nleg.dat 16 ", 0) == 0);
    CHECK(!wfdbx_get_output_dir());
}

WFDBX_TEST(write_annotations_dir)
{
    DataDir d;
    setafreq(0.0);  // (it survives wfdbquit)
    fs::create_directory("out");
    Annotations a;
    a.samples = {30, 10, 20};
    a.symbols = {"N", "V", "N"};
    wfdbquiet();
    write_annotations("rec", "atr", a, 0, "out");
    wfdbverbose();
    CHECK(list_dir("out") == std::vector<std::string>{"rec.atr"});
    CHECK(!wfdbx_get_output_dir());
    Annotations r = read_annotations("out/rec", "atr");    // sorted in place
    CHECK(r.samples == (std::vector<WFDB_Time>{10, 20, 30}));
    CHECK(r.symbols[0] == "V");
    CHECK(throws_with([] {
        write_annotations("rec", "atr", Annotations(), 0, "nosuch");
    }, "directory nosuch does not exist"));
    CHECK(throws_with([] {
        write_annotations("x/rec", "atr", Annotations(), 0, "out");
    }, "record name must not contain a directory when dir is given"));
    CHECK(!wfdbx_get_output_dir());
}

// sort = false: the caller chose the order, so the library does not advise
// running sortann; WFDBANNSORT=0 (and the C-style API) still does.
WFDBX_TEST(write_annotations_sort_false_no_advice)
{
    DataDir d;
    setafreq(0.0);
    Annotations a;
    a.samples = {300, 100, 200};
    a.symbols = {"N", "V", "N"};
    const std::string advice = "Use the command:\n  sortann -r rec -a %s\n"
        "to rearrange annotations in the correct order.\n";
    auto advice_for = [&](const char *an) {
        std::string s = advice;
        return s.replace(s.find("%s"), 2, an);
    };
    for (const char *env : {static_cast<const char *>(nullptr), "0", "1"}) {
        wfdbx_tests::EnvVar sort("WFDBANNSORT", env);
        for (int legacy = 0; legacy < 2; legacy++) {
            int prev = wfdbx_set_legacy(legacy);
            wfdbx_tests::StderrCapture cap;
            write_annotations("rec", "uns", a, 0, {}, false);
            CHECK_EQ(cap.text(), "");
            wfdbx_set_legacy(prev);
        }
    }
    wfdbx_tests::EnvVar sort("WFDBANNSORT", "0");
    {
        wfdbx_tests::StderrCapture cap;
        write_annotations("rec", "env0", a);
        CHECK_EQ(cap.text(), advice_for("env0"));
    }
    {
        wfdbx_tests::StderrCapture cap;
        WFDB_Anninfo ai;
        ai.name = "low";
        ai.stat = WFDB_WRITE;
        REQUIRE(annopen("rec", &ai, 1) == 0);
        for (int k = 0; k < 3; k++) {
            WFDB_Annotation x;
            x.time = a.samples[k];
            x.anntyp = 1;
            putann(0, &x);
        }
        wfdbquit();
        CHECK_EQ(cap.text(), advice_for("low"));
    }
    CHECK(read_annotations("rec", "uns", {}, {}, 360.0).samples ==
          (std::vector<WFDB_Time>{300, 100, 200}));
}

// Record names: outside legacy mode, only the last component of the name is
// checked, and the header names the record and its files relative to its
// directory.  Legacy mode checks the whole name, and writes names as given.
WFDBX_TEST(record_names_last_component)
{
    DataDir d;
    const std::vector<WFDB_Sample> v = {1, 2, 3, 4, 5, 6};
    WriteOptions w;
    w.gains = {200};
    w.adcres = {12};
    w.units = {"mV"};
    fs::create_directory("my.data");
    write_record("my.data/rec", v, 2, 360, w);
    CHECK(slurp("my.data/rec.hea").rfind("rec 2 360 3\r\nrec.dat 16 ", 0) == 0);
    Record r = read_record("my.data/rec");
    CHECK(r.samples == v);
    // an absolute path with a dot in a directory name
    fs::create_directories("a.b/c.d");
    std::string abs = (fs::current_path() / "a.b" / "c.d" / "rec").string();
    write_record(abs, v, 2, 360, w);
    CHECK(read_record(abs).samples == v);
    CHECK(slurp("a.b/c.d/rec.hea").rfind("rec 2 360 3\r\n", 0) == 0);
    // newheader with a dotted directory
    WFDB_Siginfo si;
    si.fname = "my.data/n.dat";
    si.desc = "x";
    si.units = "mV";
    si.gain = 200;
    si.fmt = 16;
    si.adcres = 12;
    REQUIRE(osigfopen(&si, 1) == 1);
    setsampfreq(360);
    WFDB_Sample x = 7;
    putvec(&x);
    CHECK(newheader("my.data/n") == 0);
    wfdbquit();
    CHECK(slurp("my.data/n.hea").rfind("n 1 360 1\r\nn.dat 16 ", 0) == 0);
    // a last component with an illegal character is refused
    wfdbquiet();
    CHECK(throws_with([&] { write_record("rec.1", v, 2, 360, w); },
                      "can't create header for record rec.1"));
    wfdbverbose();
    CHECK_EQ(wfdberror(), "init: illegal character 46 in record name\n");
    // legacy mode: the whole name is checked; names are written as given
    WriteOptions lw = w;
    lw.legacy = true;
    wfdbquiet();
    CHECK(throws_with([&] { write_record("my.data/rec2", v, 2, 360, lw); },
                      "my.data/rec2"));
    wfdbverbose();
    CHECK_EQ(wfdberror(), "init: illegal character 46 in record name\n");
    fs::create_directory("out");
    write_record("out/rec", v, 2, 360, lw);
    CHECK(slurp("out/rec.hea").rfind("out/rec 2 360 3\r\nout/rec.dat 16 ", 0) == 0);
}

// The dir checks come before any other validation (WFDB-x), with exactly
// these messages.
WFDBX_TEST(dir_checks_first)
{
    DataDir d;
    fs::create_directory("out");
    auto message = [](void (*fn)()) -> std::string {
        try {
            fn();
        } catch (const Error &e) {
            return e.what();
        }
        return "";
    };
    const std::string in_dir =
        "record name must not contain a directory when dir is given";
    const std::string missing = "directory nosuch does not exist";
    // (no gains, resolutions or units, and fs 0)
    CHECK_EQ(message([] {
        WriteOptions o;
        o.dir = "out";
        write_record("sub/rec", {0, 1}, 2, 0, o);
    }), in_dir);
    CHECK_EQ(message([] {
        WriteOptions o;
        o.dir = "nosuch";
        write_record("rec", {0, 1}, 2, 0, o);
    }), missing);
    CHECK_EQ(message([] {
        WriteOptions o;
        o.dir = "out";
        write_record_physical("sub/rec", {0, 1}, 2, 0, o);
    }), in_dir);
    CHECK_EQ(message([] {
        WriteOptions o;
        o.dir = "nosuch";
        write_record_physical("rec", {0, 1}, 2, 0, o);
    }), missing);
    CHECK_EQ(message([] {
        WriteOptions o;
        o.dir = "out";
        write_record("rec", {0, 1}, 2, 360, o);
    }), "write_record: gains must be specified");
    CHECK_EQ(message([] {
        write_annotations("x/rec", "atr", Annotations(), 0, "out");
    }), in_dir);
    CHECK_EQ(message([] {
        write_annotations("rec", "atr", Annotations(), 0, "nosuch");
    }), missing);
    CHECK(fs::is_empty("out"));
    CHECK(!wfdbx_get_output_dir());
}

// read_header returns the header (frequencies, length, signals, base time
// and date, info strings); Record and Header give the base time in
// milliseconds and the base date as numbers.
WFDBX_TEST(read_header_and_base_time)
{
    DataDir d;
    {
        std::ofstream f("z.dat", std::ios::binary);
        for (int i = 0; i < 20; i++) f.put(0);  // 10 samples of 0
    }
    auto header = [](const char *name, const std::string &line) {
        std::ofstream f(std::string(name) + ".hea", std::ios::binary);
        f << name << " 1" << line << "\nz.dat 16 100/mV 16 0 0 0 0 x\n"
          << "#first comment\n";
    };
    header("bt", " 250/1000(5) 10 14:00:03.500 21/06/2024");
    header("bt2", " 250 10 14:00:03");
    header("bt3", " 250 10");
    header("nf", "");

    Header h = read_header("bt");
    CHECK_EQ(h.name, std::string("bt"));
    CHECK(h.fs == 250 && h.counter_freq == 1000 && h.base_counter == 5);
    CHECK(h.nsamples == 10 && h.nsig == 1 && h.siginfo.size() == 1);
    CHECK(h.siginfo[0].desc && *h.siginfo[0].desc == "x");
    CHECK(h.base_time && *h.base_time == "[14:00:03 21/06/2024]");
    CHECK(h.base_time_ms && *h.base_time_ms == 50403500);
    CHECK(h.base_date && *h.base_date == (std::array<int, 3>{2024, 6, 21}));
    CHECK(h.comments == std::vector<std::string>{"first comment"});
    Record r = read_record("bt");
    CHECK(r.nsamples() == 10 && r.checksum_ok);
    CHECK(r.base_time == h.base_time && r.base_time_ms == h.base_time_ms &&
          r.base_date == h.base_date && r.comments == h.comments);

    h = read_header("bt2");     // a time, no date
    CHECK(h.base_time && *h.base_time == "[14:00:03]");
    CHECK(h.base_time_ms && *h.base_time_ms == 50403000);
    CHECK(!h.base_date);
    CHECK(h.counter_freq == 250 && h.base_counter == 0);
    r = read_record("bt2");
    CHECK(r.base_time_ms == h.base_time_ms && !r.base_date);

    h = read_header("bt3");     // neither
    CHECK(!h.base_time && !h.base_time_ms && !h.base_date);
    r = read_record("bt3");
    CHECK(!r.base_time && !r.base_time_ms && !r.base_date);

    // No sampling frequency: 0 (legacy mode: 250), and no length.
    h = read_header("nf");
    CHECK(h.fs == 0 && h.nsamples == 0 && h.nsig == 1);
    CHECK(!h.base_time && !h.base_time_ms && !h.base_date);
    h = read_header("nf", true);
    CHECK(h.fs == 250 && h.nsamples == 0);

    // The date as datstr() gives it.
    for (const char *date : {"01/01/1970", "29/02/2000", "15/10/1582",
                             "04/10/1582", "31/12/1999", "01/03/1"}) {
        header("bd", std::string(" 250 10 0:0:0 ") + date);
        h = read_header("bd");
        REQUIRE(h.base_date);
        char buf[40];
        std::snprintf(buf, sizeof buf, " %02d/%02d/%d", (*h.base_date)[2],
                      (*h.base_date)[1], (*h.base_date)[0]);
        CHECK_EQ(std::string(buf), datstr(strdat(date)));
    }
}

namespace {

const char *const dev_full = "/dev/full";   // every write fails (ENOSPC)

} // namespace

// A signal file or header that cannot be written throws an error, in both
// modes, after the library's messages.
WFDBX_TEST(write_record_write_error)
{
    if (!fs::exists(dev_full)) return;      // (skipped: no /dev/full)
    for (const char *target : {"full.dat", "full.hea"})
        for (size_t n : {size_t(10), size_t(100000)})
            for (bool legacy : {false, true}) {
                DataDir d;
                fs::create_symlink(dev_full, target);
                std::vector<WFDB_Sample> x(2 * n, 0);
                WriteOptions w;
                w.gains = {200};
                w.adcres = {16};
                w.units = {"mV"};
                w.legacy = legacy;
                int before = wfdbx_write_errors();
                std::string err;
                {
                    wfdbx_tests::StderrCapture cap;
                    err = error_of([&] { write_record("full", x, 2, 250, w); });
                    CHECK(cap.text().find("osigclose: write error") !=
                          std::string::npos);
                }
                CHECK_EQ(err, "write error on record full");
                CHECK(wfdbx_write_errors() > before);
                CHECK_EQ(wfdbx_get_legacy(), 0);
            }
}

// An annotation file that cannot be written throws an error, in both modes,
// after the library's message.
WFDBX_TEST(write_annotations_write_error)
{
    if (!fs::exists(dev_full)) return;      // (skipped: no /dev/full)
    for (size_t n : {size_t(3), size_t(100000)})
        for (bool legacy : {false, true}) {
            DataDir d;
            setafreq(0.0);
            fs::create_symlink(dev_full, "100s.full");
            Annotations a;
            for (size_t k = 1; k <= n; k++) {
                a.samples.push_back(static_cast<WFDB_Time>(k));
                a.symbols.push_back("N");
            }
            int prev = wfdbx_set_legacy(legacy);
            std::string err;
            {
                wfdbx_tests::StderrCapture cap;
                err = error_of([&] { write_annotations("100s", "full", a); });
                CHECK(cap.text().find("write error on annotation file full") !=
                      std::string::npos);
            }
            wfdbx_set_legacy(prev);
            CHECK_EQ(err, "write error on annotator full for record 100s");
        }
}

// Each signal has at least one sample per frame (checked first, before any
// file is opened), and the samples fill whole frames; nothing is written
// otherwise.
WFDBX_TEST(write_record_frame_checks)
{
    DataDir d;
    std::vector<WFDB_Sample> x = {0, 1, 2, 3, 4, 5, 6, 7};
    std::vector<double> p(8, 0.5);
    const std::string spf_error =
        "write_record: samps_per_frame must hold integers >= 1";
    for (bool legacy : {false, true}) {
        WriteOptions w;
        w.gains = {200};
        w.adcres = {16};
        w.units = {"mV"};
        w.legacy = legacy;
        for (const std::vector<int> &spf : {std::vector<int>{0},
                                            std::vector<int>{0, 2},
                                            std::vector<int>{2, 0},
                                            std::vector<int>{-1, 3}}) {
            w.samps_per_frame = spf;
            int nsig = static_cast<int>(spf.size());
            CHECK_EQ(error_of([&] { write_record("bad", x, nsig, 250, w); }),
                     spf_error);
            CHECK_EQ(error_of([&] {
                         write_record_physical("bad", p, nsig, 250, w);
                     }), spf_error);
            // before the other checks
            CHECK_EQ(error_of([&] { write_record("bad", x, 0, 0, w); }),
                     spf_error);
        }
        w.samps_per_frame = {3};
        CHECK_EQ(error_of([&] { write_record("bad", x, 1, 250, w); }),
                 "write_record: the number of samples is not a multiple of "
                 "the frame size");
        w.samps_per_frame = {1, 2};
        CHECK_EQ(error_of([&] { write_record("bad", x, 2, 250, w); }),
                 "write_record: the number of samples is not a multiple of "
                 "the frame size");
        CHECK(!fs::exists("bad.hea") && !fs::exists("bad.dat"));
    }
    WriteOptions w;
    w.gains = {200};
    w.adcres = {16};
    w.units = {"mV"};
    w.samps_per_frame = {2};
    write_record("good", x, 1, 250, w);
    Record r = read_record("good");
    CHECK(r.nsig == 1 && r.nsamples() == 4);
    w.samps_per_frame = {1, 1};
    write_record("good", x, 2, 250, w);
    CHECK(read_record("good").samples == x);
}

// read_record leaves the getvec mode as it was, also when it throws.
WFDBX_TEST(read_record_restores_gvmode)
{
    DataDir d;
    const int prev = getgvmode();
    setgvmode(WFDB_LOWRES);
    ReadOptions o;
    o.highres = true;
    o.pad = true;
    o.to = 20;
    Record r = read_record("mfreq", o);
    CHECK(r.fs == 400 && r.nsamples() == 20);
    CHECK_EQ(getgvmode(), WFDB_LOWRES);
    CHECK(sampfreq("mfreq") == 100);    // (the base frequency)
    wfdbquit();
    o.from = -1;
    CHECK_EQ(error_of([&] { read_record("mfreq", o); }),
             "read_record: from must not be negative");
    CHECK_EQ(getgvmode(), WFDB_LOWRES);
    setgvmode(prev);
}

// A negative `from` is an error; `to` far beyond the end reads to the end.
WFDBX_TEST(read_record_from_to_limits)
{
    DataDir d;
    ReadOptions o;
    o.from = -5;
    o.to = 3;
    CHECK_EQ(error_of([&] { read_record("100s", o); }),
             "read_record: from must not be negative");
    Record all = read_record("100s");
    o.from = 5;
    o.to = std::numeric_limits<long long>::max();
    Record r = read_record("100s", o);
    REQUIRE(r.nsamples() == all.nsamples() - 5);
    CHECK(r.sampfrom == 5);
    CHECK(std::equal(r.samples.begin(), r.samples.end(),
                     all.samples.begin() + 5 * all.nsig));
}

// Infinite samples, and samples whose ADC values are out of the range of an
// int, are errors (nothing is written); NaN is an invalid sample.
WFDBX_TEST(write_record_physical_out_of_range)
{
    DataDir d;
    WriteOptions w;
    w.gains = {200};
    w.adcres = {16};
    w.units = {"mV"};
    for (double bad : {std::numeric_limits<double>::infinity(),
                       -std::numeric_limits<double>::infinity(), 1.1e7,
                       -1.1e7}) {
        std::vector<double> x = {0.0, bad};
        CHECK_EQ(error_of([&] { write_record_physical("big", x, 1, 100, w); }),
                 "write_record: sample 1 is out of range");
        CHECK(!fs::exists("big.hea") && !fs::exists("big.dat"));
    }
    // (the largest value that fits, and a later call that works)
    w.fmt = 32;
    w.adcres = {32};
    std::vector<double> x = {0.0, 2147483647.0 / 200, NAN};
    write_record_physical("big", x, 1, 100, w);
    std::vector<WFDB_Sample> expect = {0, 2147483647, WFDB_INVALID_SAMPLE};
    CHECK(read_record("big").samples == expect);
}

// Each per-annotation field is empty or has one entry per annotation;
// nothing is written otherwise, and a later call works.
WFDBX_TEST(write_annotations_field_lengths)
{
    DataDir d;
    Annotations a;
    a.samples = {10, 20, 30};
    a.symbols = {"N", "V", "N"};
    a.aux = {std::string("x")};
    CHECK_EQ(error_of([&] { write_annotations("100s", "bad", a); }),
             "write_annotations: aux must have one entry per annotation (3), "
             "or none");
    a.aux.clear();
    a.subtypes = {1, 2};
    CHECK_EQ(error_of([&] { write_annotations("100s", "bad", a); }),
             "write_annotations: subtypes must have one entry per annotation "
             "(3), or none");
    a.subtypes.clear();
    a.codes = {NORMAL, PVC, NORMAL, NORMAL};
    CHECK_EQ(error_of([&] { write_annotations("100s", "bad", a); }),
             "write_annotations: codes must have one entry per annotation "
             "(3), or none");
    CHECK(!fs::exists("100s.bad"));
    a.codes.clear();
    a.nums = {0, 1, 2};
    write_annotations("100s", "bad", a);
    Annotations r = read_annotations("100s", "bad");
    REQUIRE(r.size() == 3);
    CHECK(r.codes[1] == PVC && r.nums[2] == 2);
}

// subtypes, chans and nums are stored in 8 bits, as C stores them (the
// expected bytes are those written by the C tool wrann for the same
// annotations).
WFDBX_TEST(write_annotations_byte_fields)
{
    DataDir d;
    Annotations a;
    a.samples = {1, 2, 3};
    a.symbols = {"N", "V", "N"};
    a.subtypes = {300, -200, 0};
    a.chans = {300, 5, 0};
    a.nums = {300, -7, 0};
    write_annotations("100s", "sub", a, 360);
    const unsigned char expect[] = {
        0x00, 0x58, 0x17, 0xfc, 0x23, 0x23, 0x20, 0x74, 0x69, 0x6d, 0x65,
        0x20, 0x72, 0x65, 0x73, 0x6f, 0x6c, 0x75, 0x74, 0x69, 0x6f, 0x6e,
        0x3a, 0x20, 0x33, 0x36, 0x30, 0x00, 0x00, 0xec, 0xff, 0xff, 0xff,
        0xff, 0x01, 0x00, 0x01, 0x04, 0x2c, 0xf4, 0x2c, 0xf8, 0x2c, 0xf0,
        0x01, 0x14, 0x38, 0xf4, 0x05, 0xf8, 0xf9, 0xf3, 0x01, 0x04, 0x00,
        0xf8, 0x00, 0xf0, 0x00, 0x00};
    CHECK(slurp("100s.sub") ==
          std::string(reinterpret_cast<const char *>(expect), sizeof(expect)));
    Annotations r = read_annotations("100s", "sub");
    REQUIRE(r.size() == 3);
    CHECK(r.subtypes[0] == 44 && r.chans[0] == 44 && r.nums[0] == 44);
    CHECK(r.subtypes[1] == 56 && r.nums[1] == -7);
}

// An EDF file whose data records hold no samples: the signals end at once.
WFDBX_TEST(edf_no_samples_per_record)
{
    DataDir d;
    const int prev = getgvmode();   // (opening an EDF record changes it)
    std::string edf = slurp("fmt16.edf");
    REQUIRE(edf.size() > 256);
    int ns = std::atoi(edf.substr(252, 4).c_str());
    for (const char *field : {"        ", "0       "}) {
        std::string x = edf;
        for (int s = 0; s < ns; s++)
            x.replace(256 + ns * 216 + 8 * s, 8, field);
        std::ofstream("z.edf", std::ios::binary) << x;
        Record r = read_record("z.edf");
        CHECK(r.nsamples() == 0 && r.nsig == ns);
        std::vector<WFDB_Siginfo> si(ns);
        REQUIRE(isigopen("z.edf", si.data(), ns) == ns);
        std::vector<WFDB_Sample> v(ns + 1);
        CHECK(getvec(v.data()) == -1);
        CHECK(getframe(v.data()) == -1);
        CHECK(getvecs(v.data(), 1, nullptr) == -1);
        wfdbquit();
    }
    setgvmode(prev);
}

// ---------------------------------------------------------------------------
// Decisions on the arguments of the high-level functions (WFDB-x)

namespace {

// True if no input signal and no annotator is open.
bool library_clean()
{
    std::vector<WFDB_Sample> v(1 << 20);
    WFDB_Annotation a;
    wfdbquiet();
    bool clean = getvec(v.data()) == 0 && getann(0, &a) == -2;
    wfdbverbose();
    return clean;
}

WriteOptions mv_write_options()
{
    WriteOptions w;
    w.gains = {200};
    w.adcres = {16};
    w.units = {std::string("mV")};
    return w;
}

} // namespace

// A high-resolution read whose frames hold many vectors (the block size,
// rounded down to whole units of 6 frames, would be 0) ends at once.
WFDBX_TEST(read_record_highres_large_frames)
{
    DataDir d;
    // 512 signals: the first one with 1024 samples per frame
    std::vector<int> spf(512, 1);
    spf[0] = 1024;
    WriteOptions w = mv_write_options();
    w.samps_per_frame = spf;
    std::vector<WFDB_Sample> x(1024 + 511);
    for (size_t i = 0; i < x.size(); i++) x[i] = static_cast<int>(i);
    write_record("mixed", x, 512, 250, w);
    ReadOptions o;
    o.highres = true;
    o.to = 1;
    Record r = read_record("mixed", o);
    REQUIRE(r.nsig == 512 && r.nsamples() == 1);
    CHECK(r.at(0, 0) == 0 && r.at(0, 1) == 1024 && r.at(0, 511) == 1534);
    o.to = {};
    r = read_record("mixed", o);
    REQUIRE(r.nsamples() == 1024);
    CHECK(r.at(1023, 0) == 1023 && r.at(1023, 511) == 1534);
    // One signal with 16384 samples per frame (3 frames)
    w.samps_per_frame = {16384};
    x.resize(3 * 16384);
    for (size_t i = 0; i < x.size(); i++) x[i] = static_cast<int>(i % 30000);
    write_record("big", x, 1, 250, w);
    o.to = 1;
    r = read_record("big", o);
    CHECK(r.nsamples() == 1 && r.at(0, 0) == 0);
    o.to = {};
    r = read_record("big", o);
    CHECK(r.samples == x);
    o.from = 16385;
    o.to = 16387;
    r = read_record("big", o);
    CHECK(r.samples == (std::vector<WFDB_Sample>{16385, 16386}));
    CHECK(read_record("big").nsamples() == 3);
    CHECK(library_clean());
}

// write_record and write_record_physical check their arguments before any
// file is created.
WFDBX_TEST(write_record_checks_before_writing)
{
    DataDir d;
    std::vector<WFDB_Sample> x = {1, 2, 3, 4};
    std::vector<double> p = {0.5, 1, 1.5, 2};
    const double inf = std::numeric_limits<double>::infinity();
    const double nan = std::numeric_limits<double>::quiet_NaN();
    auto check = [&](const WriteOptions &w, int nsig, double fs,
                     const std::string &msg, const std::string &rec = "v") {
        wfdbquiet();
        CHECK_EQ(error_of([&] { write_record(rec, x, nsig, fs, w); }), msg);
        CHECK_EQ(error_of([&] { write_record_physical(rec, p, nsig, fs, w); }),
                 msg);
        wfdbverbose();
        CHECK(!fs::exists(rec + ".hea") && !fs::exists(rec + ".dat"));
        CHECK(library_clean());
    };
    WriteOptions w = mv_write_options();
    // the sampling frequency: finite and > 0
    check(w, 2, inf, "write_record: the sampling frequency must be finite");
    check(w, 2, -inf, "write_record: the sampling frequency must be > 0");
    check(w, 2, nan, "write_record: the sampling frequency must be > 0");
    w.legacy = true;
    check(w, 2, inf, "write_record: the sampling frequency must be finite");
    check(w, 2, nan, "write_record: the sampling frequency must be finite");
    w.legacy = false;
    // the gains: finite (0, uncalibrated, and negative gains are allowed)
    for (double g : {nan, inf, -inf}) {
        w.gains = {g};
        check(w, 2, 250, "write_record: gains must be finite");
        w.gains = {200, g};
        check(w, 2, 250, "write_record: gains must be finite");
    }
    w.gains = {-200};
    CHECK_EQ(error_of([&] { write_record("v", x, 2, 250, w); }), "");
    CHECK(read_header("v").siginfo[1].gain == -200);
    w.gains = {0};
    CHECK_EQ(error_of([&] { write_record("v", x, 2, 250, w); }), "");
    fs::remove("v.hea");
    fs::remove("v.dat");
    w.gains = {200};
    // the base time must be valid
    w.base_time = "garbage";
    check(w, 2, 250, "write_record: incorrect base time 'garbage'");
    w.base_time = "12:00:00 01/02/2003";
    CHECK_EQ(error_of([&] { write_record("v", x, 2, 250, w); }), "");
    CHECK(read_header("v").base_time == std::string("[12:00:00 01/02/2003]"));
    fs::remove("v.hea");
    fs::remove("v.dat");
    w.base_time.reset();
    // the record name, and at least one signal
    check(w, 2, 250, "write_record: the record name must not be empty", "");
    check(w, 0, 250, "write_record: at least one signal is required");
    // per-signal vectors: one value for all signals, or one per signal
    const std::string per = " must have one value for all signals or one "
                            "value per signal (2)";
    w.gains = {200, 300, 400};
    check(w, 2, 250, "write_record: gains" + per);
    w.gains = {200};
    w.adcres = {12, 12, 12};
    check(w, 2, 250, "write_record: adcres" + per);
    w.adcres = {16};
    w.units = {std::string("mV"), std::string("mV"), std::string("mV")};
    check(w, 2, 250, "write_record: units" + per);
    w.units = {std::string("mV")};
    w.baselines = {5, 6, 7};
    check(w, 2, 250, "write_record: baselines" + per);
    w.baselines = {};
    w.adczeros = {0, 0, 0};
    check(w, 2, 250, "write_record: adczeros" + per);
    w.adczeros = {0};
    w.names = {"a", "b", "c"};
    check(w, 2, 250, "write_record: names" + per);
    w.names = {};
    w.samps_per_frame = {1, 1, 1};
    check(w, 2, 250, "write_record: samps_per_frame" + per);
    w.samps_per_frame = {};
    w.legacy = true;
    w.gains = {200, 300, 400};
    check(w, 2, 250, "write_record: gains" + per);
    // (legacy mode: fewer gains than signals are not missing values)
    w.gains = {};
    x.resize(6);
    p.resize(6, 0.5);
    w.adcres = {12, 12};
    const std::string per3 = " must have one value for all signals or one "
                             "value per signal (3)";
    check(w, 3, 250, "write_record: adcres" + per3);
    CHECK_EQ(wfdbx_get_legacy(), 0);
}

// write_annotations checks its arguments before any file is created.
WFDBX_TEST(write_annotations_checks_before_writing)
{
    DataDir d;
    Annotations a;
    a.samples = {10, 20, 30};
    a.symbols = {"N", "V", "N"};
    a.codes = {NORMAL, PVC, NORMAL};
    auto check = [&](double fs, const std::string &msg) {
        CHECK_EQ(error_of([&] { write_annotations("100s", "chk", a, fs); }),
                 msg);
        CHECK(!fs::exists("100s.chk"));
        CHECK(library_clean());
    };
    // Symbols and codes that agree are accepted; any disagreement is an
    // error.
    a.codes = {NORMAL, NORMAL, NORMAL};
    check(0, "write_annotations: symbols and codes disagree at annotation 1");
    a.symbols = {"N", "V", ""};     // (an empty symbol leaves the code)
    a.codes = {NORMAL, PVC, PVC};
    CHECK_EQ(error_of([&] { write_annotations("100s", "agr", a); }), "");
    Annotations g = read_annotations("100s", "agr");
    CHECK(g.codes == (std::vector<int>{NORMAL, PVC, PVC}));
    a.symbols = {"N", "V", "N"};
    a.codes.clear();
    const char *fs_msg = "write_annotations: fs must be finite and > 0 (or 0: "
                         "none)";
    for (double f : {std::numeric_limits<double>::quiet_NaN(),
                     std::numeric_limits<double>::infinity(), -360.0})
        check(f, fs_msg);
    write_annotations("100s", "chk", a, 360);
    Annotations r = read_annotations("100s", "chk");
    CHECK(r.symbols == a.symbols && r.samples == a.samples);
    // An annotation file that was read gives both: it is written back as
    // it is (here, 100s.atr, whose types include codes without a
    // mnemonic: none of them disagrees).
    r = read_annotations("100s", "atr");
    CHECK_EQ(error_of([&] { write_annotations("100s", "cp", r); }), "");
    Annotations c = read_annotations("100s", "cp");
    CHECK(c.samples == r.samples && c.codes == r.codes &&
          c.symbols == r.symbols && c.subtypes == r.subtypes &&
          c.chans == r.chans && c.nums == r.nums && c.aux == r.aux);
    // ... also with codes that have no mnemonic.
    Annotations u;
    u.samples = {5, 6};
    u.codes = {42, 43};
    write_annotations("100s", "un", u);
    r = read_annotations("100s", "un");
    CHECK(r.codes == u.codes);
    CHECK_EQ(error_of([&] { write_annotations("100s", "un2", r); }), "");
    CHECK(read_annotations("100s", "un2").codes == u.codes);
}

// read_record closes the input signals on every error after opening them,
// and restores the library's settings.
WFDBX_TEST(read_record_errors_close_signals)
{
    DataDir d;
    const int mode = getgvmode();
    ReadOptions o;
    o.from = -1;
    CHECK_EQ(error_of([&] { read_record("100s", o); }),
             "read_record: from must not be negative");
    CHECK(library_clean());
    o.from = {};
    o.channels = {"nosuch"};
    CHECK_EQ(error_of([&] { read_record("100s", o); }),
             "record 100s has no signal nosuch");
    CHECK(library_clean());
    o.channels = {};
    o.from = 1000000;
    o.highres = true;
    wfdbquiet();
    CHECK_EQ(error_of([&] { read_record("100s", o); }),
             "can't seek to sample 1000000 of record 100s");
    wfdbverbose();
    CHECK(library_clean());
    CHECK_EQ(getgvmode(), mode);
    CHECK_EQ(wfdbx_get_legacy(), 0);
}
