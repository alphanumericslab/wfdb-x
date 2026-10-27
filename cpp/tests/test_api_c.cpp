// test_api_c.cpp: unit tests of the library functions that the command-line
// tools do not exercise
//
// The expected values were produced by the original C library, using
// tests/reference/api_expect.c (each test below corresponds to a function
// of that program; run it to see the values).  The Python and MATLAB/Octave
// counterparts of these tests are python/tests/test_api.py and
// matlab/tests/test_api_c.m.
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

#include <wfdbx/ecgcodes.hpp>
#include <wfdbx/record.hpp>
#include <wfdbx/wfdb.hpp>

#include "../src/wfdblib.hpp"   // (detail::AnnSortList)

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <optional>
#include <random>
#include <string>
#include <utility>
#include <vector>

#if defined(__unix__) || defined(__APPLE__)
#include <sys/wait.h>
#include <unistd.h>
#define WFDBX_HAVE_FORK 1
#endif

using namespace wfdbx;
using wfdbx_tests::EnvVar;
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
              ("wfdbx-test-c-" + std::to_string(n++) + "-" +
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

std::string slurp(const char *name)
{
    std::ifstream f(name, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(f), {});
}

// The bytes given in hexadecimal (spaces are ignored).
std::string unhex(const std::string &h)
{
    std::string out, digits;
    for (char c : h)
        if (c != ' ') digits += c;
    for (size_t i = 0; i + 1 < digits.size(); i += 2)
        out += static_cast<char>(std::stoi(digits.substr(i, 2), nullptr, 16));
    return out;
}

// Open all signals of a record (as isigopen(record, si, 8) in C).
int isig(const char *record) { return isigopen(record, nullptr, 8); }

// getvec (or getframe): the status followed by n samples.
std::vector<int> vec(int n, int (*f)(WFDB_Sample *) = getvec)
{
    std::vector<WFDB_Sample> v(n + 8);
    int stat = f(v.data());
    std::vector<int> r{stat};
    r.insert(r.end(), v.begin(), v.begin() + n);
    return r;
}

// getann: status, time, anntyp, subtyp, chan, num.
std::vector<long long> ann(unsigned n)
{
    WFDB_Annotation a;
    int stat = getann(n, &a);
    return {stat, a.time, a.anntyp, a.subtyp, a.chan, a.num};
}

struct Cal {
    int stat;
    double low, high, scale;
    int caltype;
    std::string sigtype, units;
    bool operator==(const Cal &o) const {
        return stat == o.stat && (stat != 0 ||
            (low == o.low && high == o.high && scale == o.scale &&
             caltype == o.caltype && sigtype == o.sigtype &&
             units == o.units));
    }
};

Cal cal(const char *desc, const char *units)
{
    WFDB_Calinfo c;
    int stat = getcal(desc, units, &c);
    return {stat, c.low, c.high, c.scale, c.caltype,
            c.sigtype.value_or("(null)"), c.units.value_or("(null)")};
}

WFDB_Calinfo calinfo(double low, double high, double scale,
                     const char *sigtype, const char *units, int caltype)
{
    WFDB_Calinfo c;
    c.low = low;
    c.high = high;
    c.scale = scale;
    c.sigtype = sigtype;
    c.units = units;
    c.caltype = caltype;
    return c;
}

std::vector<std::string> segs()
{
    const WFDB_Seginfo *s = nullptr;
    int n = getseginfo(&s);
    std::vector<std::string> r;
    for (int i = 0; i < n; i++)
        r.push_back(std::string(s[i].recname) + " " +
                    std::to_string(s[i].nsamp) + " " +
                    std::to_string(s[i].samp0));
    return r;
}

// Run fn in a child process (where possible), so that the library state
// that it changes, and that no library function restores, does not affect
// later tests.
void isolated(void (*fn)())
{
#ifdef WFDBX_HAVE_FORK
    std::fflush(stdout);
    std::fflush(stderr);
    pid_t pid = fork();
    REQUIRE(pid >= 0);
    if (pid == 0) {
        int before = wfdbx_tests::failure_count();
        try {
            fn();
        } catch (...) {
            _exit(2);
        }
        std::fflush(stdout);
        _exit(wfdbx_tests::failure_count() == before ? 0 : 1);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
#else
    fn();
#endif
}

} // namespace

// ---------------------------------------------------------------------------
// t_version

WFDBX_TEST(c_version_and_errors)
{
    DataDir d;
    // wfdbversion, wfdbdefwfdb, wfdbldflags and wfdbcflags depend on how
    // the C library was built (with configure); wfdb-x gives the values of
    // a release build installed in /usr/local, and empty flags strings.
    CHECK_EQ(wfdbversion(), "10.7.0");
    CHECK_EQ(wfdbdefwfdb(),
             ". /usr/local/database http://physionet.org/physiobank/database");
    CHECK_EQ(wfdbdefwfdbcal(), "wfdbcal");
    CHECK_EQ(wfdbldflags(), "");
    CHECK_EQ(wfdbcflags(), "");
    wfdbmemerr(0);
    wfdbquiet();
    CHECK_EQ(isig("nosuch"), -1);
    CHECK_EQ(wfdberror(), "init: can't open header for record nosuch\n");
    WFDB_Anninfo ai{"atr", WFDB_READ};
    CHECK_EQ(annopen("nosuch", &ai, 1), -3);
    CHECK_EQ(wfdberror(),
             "annopen: can't read annotator atr for record nosuch\n");
    wfdbverbose();
}

// ---------------------------------------------------------------------------
// t_path

WFDBX_TEST(c_path_and_wfdbfile)
{
    DataDir d;  // (setwfdb("."))
    // wfdb-x: setwfdb sets a single input directory ("a b" is an error);
    // resetwfdb restores that of the last setwfdb, and wfdbquit leaves it as
    // it is.
    wfdbquiet();
    setwfdb("a b");
    wfdbverbose();
    CHECK_EQ(getwfdb(), ".");
    resetwfdb();
    CHECK_EQ(getwfdb(), ".");
    setwfdb("c");
    wfdbquit();
    CHECK_EQ(getwfdb(), "c");
    setwfdb(".");
    CHECK_EQ(getwfdb(), ".");
    CHECK(wfdbfile("hea", "100s") == "./100s.hea");
    CHECK(wfdbfile(nullptr, nullptr) == "./100s.hea");
    CHECK(wfdbfile("hea", "100s.hea") == "./100s.hea");
    CHECK(wfdbfile("atr", "100s") == "./100s.atr");
    CHECK(!wfdbfile("dat", "nosuch"));
    CHECK(wfdbfile("wfdbcal", nullptr) == "./wfdbcal");
}

// ---------------------------------------------------------------------------
// t_bufsize

WFDBX_TEST(c_buffer_sizes)
{
    DataDir d;
    wfdbquiet();
    CHECK_EQ(setibsize(0), 8192);
    CHECK_EQ(setibsize(1000), 1000);
    CHECK_EQ(setibsize(-1), -2);
    CHECK_EQ(setobsize(0), 8192);
    CHECK_EQ(setobsize(2000), 2000);
    CHECK_EQ(setobsize(-5), -2);
    isig("100s");
    CHECK_EQ(setibsize(512), -1);
    wfdbquit();
    wfdbverbose();
    setibsize(0);
    setobsize(0);
}

// ---------------------------------------------------------------------------
// t_signals

WFDBX_TEST(c_getvec_modes_and_frequencies)
{
    DataDir d;
    CHECK_EQ(getgvmode(), 0);
    CHECK_EQ(isig("100s"), 2);
    CHECK_EQ(getifreq(), 360);
    CHECK_EQ(getspf(), 1);
    wfdbquit();
    isig("fmt16");
    CHECK(vec(3) == (std::vector<int>{3, -7, 32, -33}));
    CHECK(vec(3) == (std::vector<int>{3, 4, 53, -47}));
    CHECK(vec(3) == (std::vector<int>{3, -20, 24, -27}));
    CHECK_EQ(setifreq(100.0), 0);
    CHECK_EQ(getifreq(), 100);
    CHECK_EQ(isigsettime(0), 0);
    CHECK(vec(3) == (std::vector<int>{3, -7, 32, -33}));
    CHECK(vec(3) == (std::vector<int>{3, -21, 23, -35}));
    CHECK(vec(3) == (std::vector<int>{3, 7, -14, -44}));
    CHECK_EQ(setifreq(1000.0), 0);
    CHECK_EQ(getifreq(), 1000);
    CHECK_EQ(isigsettime(2), 0);
    CHECK(vec(3) == (std::vector<int>{3, -7, 32, -33}));
    for (int i = 0; i < 4; i++)
        CHECK(vec(3) == (std::vector<int>{3, 4, 53, -47}));
    CHECK_EQ(getafreq(), 1000);     // (setifreq also calls setafreq)
    wfdbquiet();
    CHECK_EQ(setifreq(-1.0), -1);
    wfdbverbose();
    CHECK_EQ(getifreq(), 250);
    setafreq(0.0);
    wfdbquit();
    isig("100s");
    setgvmode(WFDB_HIGHRES);
    CHECK_EQ(getgvmode(), 1);
    setgvmode(WFDB_GVPAD | WFDB_LOWRES);
    CHECK_EQ(getgvmode(), 2);
    setgvmode(WFDB_HIGHRES | WFDB_GVPAD | 4);
    CHECK_EQ(getgvmode(), 3);
    setgvmode(0);
}

WFDBX_TEST(c_amplitude_conversion)
{
    DataDir d;
    isig("100s");   // gain 200, baseline 1024
    // (wfdb-x: invalid signal numbers give WFDB_INVALID_SAMPLE or NaN; C
    // assumed the gain WFDB_DEFGAIN; see docs/DIVERGENCES.md)
    wfdbquiet();
    CHECK_EQ(adumuv(0, 200), 1000);
    CHECK_EQ(adumuv(0, -37), -185);
    CHECK_EQ(adumuv(1, 1), 5);
    CHECK_EQ(adumuv(0, -1), -5);
    CHECK_EQ(adumuv(7, 100), WFDB_INVALID_SAMPLE);
    CHECK_EQ(muvadu(0, 1000), 200);
    CHECK_EQ(muvadu(0, -333), -67);
    CHECK_EQ(muvadu(1, 2), 0);
    CHECK_EQ(muvadu(9, 1000), WFDB_INVALID_SAMPLE);
    CHECK_EQ(aduphys(0, 1224), 1.0);
    CHECK_EQ(aduphys(1, 900), -0.62);
    CHECK(std::isnan(aduphys(5, 300)));
    CHECK_EQ(physadu(0, 1.0), 1224);
    CHECK_EQ(physadu(1, -0.5023), 924);
    CHECK_EQ(physadu(5, 1.5), WFDB_INVALID_SAMPLE);
    wfdbverbose();
    wfdbquit();
    isig("fmt16");  // 100(-5)/mV, 150(5)/uV, 200(15)/mmHg
    CHECK_EQ(adumuv(0, 100), 1000);
    CHECK_EQ(adumuv(1, 150), 1000);
    CHECK_EQ(adumuv(2, -7), -35);
    CHECK_EQ(muvadu(0, 1000), 100);
    CHECK_EQ(muvadu(1, 1000), 150);
    CHECK_EQ(muvadu(2, -2500), -500);
    CHECK_EQ(aduphys(0, 95), 1.0);
    CHECK_EQ(aduphys(1, 10), 0.033333333333333333);
    CHECK_EQ(aduphys(2, -3), -0.089999999999999997);
    CHECK_EQ(physadu(0, 1.0), 95);
    CHECK_EQ(physadu(1, -2.25), -333);
    CHECK_EQ(physadu(2, 0.4), 95);
}

WFDBX_TEST(c_sample)
{
    DataDir d;
    isig("100s");
    CHECK_EQ(sample_valid(), 0);
    CHECK_EQ(sample(0, 0), 995);
    CHECK_EQ(sample_valid(), 1);
    CHECK_EQ(sample(1, 1000), 970);
    CHECK_EQ(sample_valid(), 1);
    CHECK_EQ(sample(0, 21599), 975);
    CHECK_EQ(sample_valid(), 1);
    CHECK_EQ(sample(0, 21600), 975);
    CHECK_EQ(sample_valid(), 0);
    CHECK_EQ(sample(0, 5), 995);
    CHECK_EQ(sample_valid(), 1);
    CHECK_EQ(sample(1, -3), 1011);
    CHECK_EQ(sample_valid(), 1);
    CHECK_EQ(sample(2, 0), -32768);
    CHECK_EQ(sample_valid(), -1);
}

// ---------------------------------------------------------------------------
// t_frames

WFDBX_TEST(c_getframe)
{
    DataDir d;
    isig("mfreq");  // 1, 2 and 4 samples per frame
    CHECK_EQ(getspf(), 1);
    CHECK_EQ(getifreq(), 100);
    CHECK(vec(7, getframe) ==
          (std::vector<int>{3, 138, 218, 2699, 219, -1316, 1120, 1973}));
    CHECK(vec(7, getframe) ==
          (std::vector<int>{3, 2677, 1201, 275, -989, 1822, 2762, 1927}));
    CHECK(vec(3) == (std::vector<int>{3, -597, -455, 181}));
    isigsettime(599);
    CHECK(vec(7, getframe) ==
          (std::vector<int>{3, -1394, 715, 558, 2215, -1785, 860, -491}));
    CHECK_EQ(vec(7, getframe)[0], -1);
    wfdbquit();
    setgvmode(WFDB_HIGHRES);
    isig("mfreq");
    CHECK_EQ(getspf(), 4);
    CHECK_EQ(getifreq(), 400);
    CHECK(vec(7, getframe) ==
          (std::vector<int>{3, 138, 218, 2699, 219, -1316, 1120, 1973}));
    CHECK(vec(3) == (std::vector<int>{3, 2677, 1201, -989}));
    CHECK(vec(3) == (std::vector<int>{3, 2677, 1201, 1822}));
    wfdbquit();
    setgvmode(0);
}

// ---------------------------------------------------------------------------
// t_groups

WFDBX_TEST(c_isgsettime)
{
    DataDir d;
    isig("twog");   // group 0: signal 0; group 1: signals 1 and 2
    CHECK(vec(3) == (std::vector<int>{3, 1020, 977, 316}));
    CHECK_EQ(isgsettime(1, 100), 0);
    CHECK(vec(3) == (std::vector<int>{3, 1880, -630, 83}));
    CHECK(vec(3) == (std::vector<int>{3, 325, 245, 1597}));
    CHECK_EQ(isgsettime(0, 500), 0);
    CHECK(vec(3) == (std::vector<int>{3, -1823, 338, -709}));
    CHECK_EQ(isgsettime(1, 1001), 0);
    CHECK_EQ(vec(3)[0], -1);
}

// ---------------------------------------------------------------------------
// t_segments

WFDBX_TEST(c_tnextvec_getseginfo)
{
    DataDir d;
    isig("100s");
    CHECK(segs().empty());
    CHECK_EQ(tnextvec(0, 5), 5);
    CHECK_EQ(tnextvec(1, 0), 0);
    wfdbquit();
    isig("multi");
    CHECK(segs() == (std::vector<std::string>{
                        "100s 21600 0", "null 1800 21600",
                        "100s 21600 23400"}));
    CHECK_EQ(tnextvec(0, 0), 0);
    CHECK_EQ(tnextvec(0, 21599), 21599);
    CHECK_EQ(tnextvec(1, 21700), 23500);
    CHECK_EQ(tnextvec(0, 44999), 44999);
    CHECK_EQ(tnextvec(0, 45000), -1);
    wfdbquit();
    isig("vlay");
    CHECK(segs() == (std::vector<std::string>{
                        "vlay_0 0 0", "fmt16 1500 0", "~ 200 1500",
                        "fmt212 1501 1700"}));
    wfdbquiet();
    CHECK_EQ(tnextvec(0, 0), 0);
    CHECK_EQ(tnextvec(1, 1499), 1700);
    CHECK_EQ(tnextvec(2, 1500), -1);
    CHECK_EQ(tnextvec(0, 1600), -1);
    CHECK_EQ(tnextvec(5, 0), -1);
    wfdbverbose();
}

// ---------------------------------------------------------------------------
// t_skew

WFDBX_TEST(c_skew_and_start)
{
    DataDir d;
    isig("skew");
    CHECK_EQ(wfdbgetskew(0), 0);
    CHECK_EQ(wfdbgetskew(1), 3);
    CHECK_EQ(wfdbgetskew(2), 7);
    CHECK_EQ(wfdbgetskew(3), 0);
    CHECK(vec(3) == (std::vector<int>{3, -7, 21, -32768}));
    wfdbsetiskew(1, 2);
    wfdbsetiskew(2, 100000);    // too large: ignored
    wfdbsetiskew(0, -1);        // negative: ignored
    CHECK_EQ(wfdbgetskew(0), 0);
    CHECK_EQ(wfdbgetskew(1), 2);
    CHECK_EQ(wfdbgetskew(2), 7);
    wfdbquit();
    isig("prolog");
    CHECK_EQ(wfdbgetstart(0), 100);
    CHECK_EQ(wfdbgetstart(2), 100);
    CHECK_EQ(wfdbgetstart(3), 0);
    wfdbquit();
    isig("100s");
    CHECK_EQ(wfdbgetstart(0), 0);
}

// ---------------------------------------------------------------------------
// t_output

WFDBX_TEST(c_output_prolog_skew_flush)
{
    DataDir d;
    setcfreq(0.0);      // (the counter frequency survives wfdbquit)
    WFDB_Siginfo si[2];
    for (int i = 0; i < 2; i++) {
        si[i].fname = "out.dat";
        si[i].desc = i ? "second" : "first";
        si[i].units = "mV";
        si[i].gain = 100;
        si[i].group = 0;
        si[i].fmt = 16;
        si[i].adcres = 12;
    }
    setsampfreq(100.0);
    CHECK_EQ(osigfopen(si, 2), 2);
    CHECK_EQ(wfdbputprolog("PROLOG!", 7, 0), 0);
    wfdbsetskew(1, 4);
    for (int i = 0; i < 5; i++) {
        WFDB_Sample v[2] = {i, -i};
        putvec(v);
    }
    WFDB_Anninfo ai{"tst", WFDB_WRITE};
    CHECK_EQ(annopen("out", &ai, 1), 0);
    WFDB_Annotation a;
    a.time = 3;
    a.anntyp = NORMAL;
    putann(0, &a);
    a.time = 4;
    a.anntyp = PVC;
    putann(0, &a);
    wfdbflush();
    CHECK_EQ(fs::file_size("out.dat"), 27u);
    CHECK_EQ(fs::file_size("out.tst"), 4u);
    CHECK_EQ(newheader("out"), 0);
    CHECK_EQ(putinfo("info line"), 0);
    wfdbquit();
    CHECK_EQ(slurp("out.hea"),
             "out 2 100 5\r\n"
             "out.dat 16+7 100/mV 12 0 0 10 0 first\r\n"
             "out.dat 16:4+7 100/mV 12 0 0 -10 0 second\r\n"
             "#info line\r\n");
    CHECK_EQ(slurp("out.dat"),
             unhex("50524f4c4f4721 0000 0000 0100 ffff 0200 feff 0300 fdff "
                   "0400 fcff"));
    CHECK_EQ(slurp("out.tst"), unhex("0304 0114 0000"));

    setsampfreq(100.0);
    si[0].fname = si[1].fname = "out2.dat";
    osigfopen(si, 2);
    wfdbsetstart(0, 512);
    WFDB_Sample v[2] = {1, 2};
    putvec(v);
    newheader("out2");
    wfdbquit();
    CHECK_EQ(slurp("out2.hea"),
             "out2 2 100 1\r\n"
             "out2.dat 16+512 100/mV 12 0 1 1 0 first\r\n"
             "out2.dat 16+512 100/mV 12 0 2 2 0 second\r\n");
    CHECK_EQ(fs::file_size("out2.dat"), 4u);
}

// ---------------------------------------------------------------------------
// t_info

WFDBX_TEST(c_info)
{
    DataDir d;
    const std::string xform =
        "Produced by xform from record 100, beginning at 0:0";
    CHECK(getinfo("100s") == " 69 M 1085 1629 x1");
    CHECK(getinfo(nullptr) == " Aldomet, Inderal");
    CHECK(getinfo(nullptr) == xform);
    CHECK_EQ(setinfo("newrec"), 0);
    CHECK_EQ(putinfo("first"), 0);
    CHECK_EQ(putinfo("second"), 0);
    CHECK_EQ(setinfo(nullptr), 0);
    wfdbquiet();
    CHECK_EQ(putinfo("third"), -1);
    wfdbverbose();
    CHECK_EQ(slurp("newrec.info"), "#first\r\n#second\r\n");
    CHECK(getinfo("newrec") == "first");
    CHECK(getinfo(nullptr) == "second");
    CHECK(!getinfo(nullptr));
    CHECK_EQ(setinfo("100s"), 0);
    CHECK_EQ(putinfo("extra"), 0);
    wfdbquit();
    CHECK(getinfo("100s") == " 69 M 1085 1629 x1");
    CHECK(getinfo(nullptr) == " Aldomet, Inderal");
    CHECK(getinfo(nullptr) == xform);
    CHECK(getinfo(nullptr) == "extra");
    isig("fmt16");
    CHECK(!getinfo(nullptr));
}

// ---------------------------------------------------------------------------
// t_msheader

WFDBX_TEST(c_setmsheader)
{
    DataDir d;
    const char *names[3] = {"100s", "null", "100s"};
    const char *bad[2] = {"100s", "fmt16"};
    CHECK_EQ(setmsheader("msrec", names, 3), 0);
    wfdbquiet();
    CHECK_EQ(setmsheader("msbad", names, 0), -1);
    CHECK_EQ(setmsheader("msbad", bad, 2), -4);
    wfdbverbose();
    wfdbquit();
    CHECK_EQ(slurp("msrec.hea"),
             "msrec/3 2 360 45000\r\n100s 21600\r\nnull 1800\r\n"
             "100s 21600\r\n");
    CHECK_EQ(isig("msrec"), 2);
    CHECK(segs() == (std::vector<std::string>{
                        "100s 21600 0", "null 1800 21600",
                        "100s 21600 23400"}));
    isigsettime(21599);
    CHECK(vec(2) == (std::vector<int>{2, 975, 989}));
    CHECK(vec(2) == (std::vector<int>{2, -32768, -32768}));
}

// ---------------------------------------------------------------------------
// t_counter

WFDBX_TEST(c_counter_and_base_time)
{
    DataDir d;
    isig("100s");
    CHECK_EQ(getcfreq(), 360);
    CHECK_EQ(getbasecount(), 0);
    setcfreq(1000.0);
    setbasecount(500.5);
    CHECK_EQ(getcfreq(), 1000);
    CHECK_EQ(getbasecount(), 500.5);
    CHECK_EQ(strtim("c1500.5"), 360);
    CHECK_EQ(strtim("c500.5"), 0);
    setcfreq(0.0);
    CHECK_EQ(getcfreq(), 360);
    CHECK_EQ(setbasetime("10:20:30 15/6/2001"), 0);
    CHECK_EQ(timstr(0), "[10:20:30 15/06/2001]");
    CHECK_EQ(timstr(360), "    0:01");
    CHECK_EQ(timstr(-360), "[10:20:31 15/06/2001]");
    CHECK_EQ(mstimstr(-1000), "[10:20:32.778 15/06/2001]");
    CHECK_EQ(setbasetime("8:00"), 0);
    CHECK_EQ(timstr(0), "[00:08:00]");
    CHECK_EQ(timstr(-720), "[00:08:02]");
    wfdbquiet();
    CHECK_EQ(setbasetime("garbage"), -1);
    wfdbverbose();
    setcfreq(500.0);
    wfdbquit();
    CHECK_EQ(getcfreq(), 500);
    setcfreq(0.0);
}

// ---------------------------------------------------------------------------
// t_calib

WFDBX_TEST(c_calibration)
{
    DataDir d;
    CHECK_EQ(calopen("wfdbcal"), 0);
    CHECK(cal("ECG lead II", "mV") == (Cal{0, 0, 1, 1, 4, "ECG", "mV"}));
    CHECK(cal("ECG", "uV") == (Cal{0, 0, 1, 1000, 4, "ECG", "uV"}));
    CHECK(cal("ABP", "mmHg") == (Cal{0, 0, 0, 100, 3, "ABP", "mmHg"}));
    CHECK(cal("BP", nullptr) == (Cal{0, 0, 100, 100, 3, "BP", "mmHg"}));
    CHECK(cal(nullptr, nullptr) == (Cal{0, 0, 1, 1, 4, "ECG", "mV"}));
    CHECK_EQ(cal("nosuch", "x").stat, -1);
    WFDB_Calinfo test = calinfo(-1.5, 2.5, 3, "TEST", "xu",
                                WFDB_DC_COUPLED | WFDB_CAL_SINE);
    WFDB_Calinfo ac = calinfo(0, 0, 7, "AC", "yu",
                              WFDB_AC_COUPLED | WFDB_CAL_UNDEF);
    CHECK_EQ(putcal(&test), 0);
    CHECK_EQ(putcal(&ac), 0);
    CHECK(cal("TEST signal", "xu") == (Cal{0, -1.5, 2.5, 3, 5, "TEST", "xu"}));
    flushcal();
    CHECK_EQ(cal("ECG", "mV").stat, -1);
    putcal(&test);
    putcal(&ac);
    WFDB_Calinfo c = calinfo(1, 2, 0.25, "SQ", "zu",
                             WFDB_DC_COUPLED | WFDB_CAL_SQUARE);
    putcal(&c);
    c = calinfo(1, 2, 0.25, "SAW", "zu", WFDB_AC_COUPLED | WFDB_CAL_SAWTOOTH);
    putcal(&c);
    wfdbquiet();
    CHECK_EQ(newcal("my.cal"), -1);     // illegal name
    wfdbverbose();
    CHECK_EQ(newcal("mycal"), 0);
    CHECK_EQ(slurp("mycal"),
             "TEST\t-1.5 2.5 sine 3 xu\r\n"
             "AC\t- - undefined 7 yu\r\n"
             "SQ\t1 2 square 0.25 zu\r\n"
             "SAW\t- 2 sawtooth 0.25 zu\r\n");
    CHECK_EQ(calopen("mycal"), 0);
    CHECK(cal("AC", "yu") == (Cal{0, 0, 0, 7, 0, "AC", "yu"}));
    CHECK_EQ(cal("ECG", "mV").stat, -1);
    CHECK_EQ(calopen("+wfdbcal"), 0);
    CHECK(cal("ECG", "mV") == (Cal{0, 0, 1, 1, 4, "ECG", "mV"}));
    CHECK(cal("SAW", nullptr) == (Cal{0, 0, 2, 0.25, 6, "SAW", "zu"}));
    wfdbquiet();
    CHECK_EQ(calopen("nosuch.cal"), -2);
    wfdbverbose();
    flushcal();
}

// ---------------------------------------------------------------------------
// t_annot

WFDBX_TEST(c_input_annotators)
{
    DataDir d;
    using V = std::vector<long long>;
    CHECK_EQ(getafreq(), 0);
    isig("100s");
    WFDB_Anninfo ai[2] = {{"atr", WFDB_READ}, {"ooo", WFDB_READ}};
    CHECK_EQ(annopen("100s", ai, 2), 0);
    CHECK_EQ(getiafreq(0), 360);
    CHECK_EQ(getiafreq(1), 360);
    CHECK_EQ(getiafreq(2), -2);
    CHECK_EQ(getiaorigfreq(0), 0);
    CHECK_EQ(getiaorigfreq(1), 360);
    CHECK_EQ(getiaorigfreq(2), -2);
    CHECK(ann(0) == (V{0, 18, 28, 0, 0, 0}));
    CHECK(ann(0) == (V{0, 77, 1, 0, 0, 0}));
    setiafreq(0, 1000.0);
    CHECK_EQ(getiafreq(0), 1000);
    CHECK_EQ(getiaorigfreq(0), 0);
    WFDB_Annotation a;
    CHECK_EQ(getann(0, &a), 0);
    CHECK(a.time == 1028 && a.anntyp == 1);
    wfdbquiet();
    CHECK_EQ(ungetann(0, &a), 0);
    CHECK_EQ(ungetann(0, &a), -1);     // the pushback buffer is full
    CHECK_EQ(ungetann(5, &a), -2);
    wfdbverbose();
    CHECK(ann(0) == (V{0, 1028, 1, 0, 0, 0}));
    CHECK(ann(0) == (V{0, 1839, 1, 0, 0, 0}));
    a.time = 5;
    a.anntyp = PVC;
    CHECK_EQ(ungetann(0, &a), 0);
    CHECK(ann(0) == (V{0, 5, 5, 0, 0, 0}));
    setiafreq(0, 0.0);
    CHECK_EQ(getiafreq(0), 360);
    CHECK(ann(0) == (V{0, 946, 1, 0, 0, 0}));
    iannclose(0);       // annotator 1 (ooo) becomes annotator 0
    CHECK_EQ(getiafreq(0), 360);
    CHECK_EQ(getiafreq(1), -2);
    CHECK(ann(0) == (V{0, 18, 1, 0, 0, 0}));
    wfdbquiet();
    CHECK_EQ(ann(1)[0], -2);
    iannclose(0);
    CHECK_EQ(ann(0)[0], -2);
    iannclose(3);
    wfdbverbose();
}

WFDBX_TEST(c_annotation_time_resolution)
{
    DataDir d;
    using V = std::vector<long long>;
    setafreq(1000.0);
    CHECK_EQ(getafreq(), 1000);
    WFDB_Anninfo ai{"hf", WFDB_WRITE};
    annopen("100s", &ai, 1);
    WFDB_Annotation a;
    a.anntyp = NORMAL;
    a.time = 1000;
    putann(0, &a);
    a.time = 2500;
    putann(0, &a);
    wfdbquit();
    CHECK_EQ(getafreq(), 1000);
    setafreq(0.0);
    ai.stat = WFDB_READ;
    annopen("100s", &ai, 1);
    CHECK_EQ(getiafreq(0), 1000);
    CHECK_EQ(getiaorigfreq(0), 1000);
    CHECK(ann(0) == (V{0, 1000, 1, 0, 0, 0}));
    setiafreq(0, 360.0);
    CHECK_EQ(getiafreq(0), 360);
    CHECK(ann(0) == (V{0, 900, 1, 0, 0, 0}));
}

// ---------------------------------------------------------------------------
// t_strings

WFDBX_TEST(c_ecgstr)
{
    CHECK(ecgstr(1) == "N");
    CHECK(ecgstr(0) == " ");
    CHECK(ecgstr(15) == "[15]");
    CHECK(ecgstr(22) == "\"");
    CHECK(ecgstr(50) == "[50]");
    CHECK(ecgstr(-1) == "[-1]");
    CHECK_EQ(strecg("V"), 5);
    CHECK_EQ(strecg("xx"), 0);
    CHECK_EQ(strecg(""), 0);
    CHECK_EQ(strecg("[15]"), 15);
    CHECK_EQ(setecgstr(5, "PVC"), 0);
    CHECK(ecgstr(5) == "PVC");
    CHECK(annstr(5) == "V");
    CHECK_EQ(strecg("PVC"), 5);
    CHECK_EQ(strecg("V"), 0);
    wfdbquiet();
    CHECK_EQ(setecgstr(50, "x"), -1);
    CHECK_EQ(setecgstr(-1, "x"), -1);
    wfdbverbose();
    CHECK_EQ(setecgstr(0, "Z"), 0);
    CHECK(ecgstr(0) == "Z");
    setecgstr(5, "V");
    setecgstr(0, " ");
}

// This test modifies mnemonics and descriptions in ways that the library
// cannot undo (the flags of modified codes, and NULL descriptions), so it
// runs in a child process where possible.
static void annstr_anndesc()
{
    DataDir d;
    CHECK_EQ(setannstr(5, "pvc"), 0);
    CHECK(annstr(5) == "pvc");
    CHECK(ecgstr(5) == "V");
    CHECK_EQ(strann("pvc"), 5);
    CHECK_EQ(strann("V"), 0);
    CHECK_EQ(setannstr(-6, "fus"), 0);
    CHECK(annstr(6) == "fus");
    wfdbquiet();
    CHECK_EQ(setannstr(60, "x"), -1);
    CHECK_EQ(setannstr(-60, "x"), -1);
    wfdbverbose();
    CHECK_EQ(setannstr(0, "zero"), 0);
    CHECK(annstr(0) == "zero");
    CHECK(annstr(60) == "[60]");
    CHECK_EQ(setannstr(42, "new"), 0);
    CHECK_EQ(strann("new"), 42);
    CHECK(anndesc(1) == "Normal beat");
    CHECK(!anndesc(15));
    CHECK(anndesc(60) == "illegal annotation code");
    CHECK(anndesc(-1) == "illegal annotation code");
    CHECK_EQ(setanndesc(15, "my description"), 0);
    CHECK(anndesc(15) == "my description");
    CHECK_EQ(setanndesc(-43, "negative"), 0);
    CHECK(anndesc(43) == "negative");
    wfdbquiet();
    CHECK_EQ(setanndesc(50, "x"), -1);
    wfdbverbose();

    // Modified mnemonics (but not those set with a negative code) are
    // written into output annotation files ...
    WFDB_Anninfo ai{"mod", WFDB_WRITE};
    annopen("100s", &ai, 1);
    WFDB_Annotation a;
    a.time = 10;
    a.anntyp = PVC;
    putann(0, &a);
    wfdbquit();
    CHECK_EQ(slurp("100s.mod"),
             unhex("0058 1efc") + "## annotation type definitions" +
             unhex("0058 27fc") + "5 pvc Premature ventricular contraction" +
             unhex("00 0058 16fc") + "15 [15] my description" +
             unhex("0058 07fc") + "42 new " + unhex("00 0058 15fc") +
             "## end of definitions" +
             unhex("00 00ec ffff ffff 0100 0a14 0000"));
    setannstr(5, "V");
    setannstr(-6, "F");
    setannstr(0, " ");
    setannstr(-42, "[42]");
    setanndesc(-15, "");
    setanndesc(-43, "");
    // ... and reading the file defines them again.
    ai.stat = WFDB_READ;
    annopen("100s", &ai, 1);
    CHECK(ann(0) == (std::vector<long long>{0, 10, 5, 0, 0, 0}));
    CHECK(annstr(5) == "pvc");
    CHECK(anndesc(15) == "my description");
    CHECK(anndesc(42) == "");
    wfdbquit();
}

WFDBX_TEST(c_annstr_anndesc)
{
    isolated(annstr_anndesc);
}

// ---------------------------------------------------------------------------
// t_maps

// code: isann isqrs map1 map2 annpos mamap(code, 0) mamap(code, -1)
static const int maps[52][8] = {
    {-1, 0, 0, 0, 0, 0, 79, 79}, {0, 0, 0, 0, 0, 0, 79, 79},
    {1, 1, 1, 1, 1, 1, 78, 78}, {2, 1, 1, 1, 1, 1, 78, 78},
    {3, 1, 1, 1, 1, 1, 78, 78}, {4, 1, 1, 1, 9, 1, 78, 78},
    {5, 1, 1, 5, 5, 1, 86, 86}, {6, 1, 1, 6, 6, 1, 70, 70},
    {7, 1, 1, 1, 9, 1, 78, 78}, {8, 1, 1, 1, 9, 1, 78, 78},
    {9, 1, 1, 1, 9, 1, 78, 78}, {10, 1, 1, 5, 5, 1, 69, 69},
    {11, 1, 1, 1, 1, 1, 78, 78}, {12, 1, 1, 1, 1, 1, 80, 80},
    {13, 1, 1, 1, 1, 1, 81, 81}, {14, 1, 0, 0, 0, 2, 79, 85},
    {15, 1, 0, 0, 0, 0, 79, 79}, {16, 1, 0, 0, 0, 2, 79, 79},
    {17, 1, 0, 0, 0, 0, 79, 79}, {18, 1, 0, 0, 0, 2, 79, 79},
    {19, 1, 0, 0, 0, 2, 79, 79}, {20, 1, 0, 0, 0, 2, 79, 79},
    {21, 1, 0, 0, 0, 2, 79, 79}, {22, 1, 0, 0, 0, 2, 79, 79},
    {23, 1, 0, 0, 0, 2, 79, 79}, {24, 1, 0, 0, 0, 2, 79, 79},
    {25, 1, 1, 1, 1, 1, 78, 78}, {26, 1, 0, 0, 0, 2, 79, 79},
    {27, 1, 0, 0, 0, 2, 79, 79}, {28, 1, 0, 0, 0, 3, 79, 79},
    {29, 1, 0, 0, 0, 2, 79, 79}, {30, 1, 1, 30, 30, 1, 81, 81},
    {31, 1, 1, 5, 5, 1, 79, 79}, {32, 1, 0, 0, 0, 1, 91, 91},
    {33, 1, 0, 0, 0, 1, 93, 93}, {34, 1, 1, 1, 1, 1, 78, 78},
    {35, 1, 1, 1, 1, 1, 78, 78}, {36, 1, 0, 0, 0, 2, 79, 79},
    {37, 1, 0, 0, 0, 2, 79, 79}, {38, 1, 1, 1, 1, 1, 78, 78},
    {39, 1, 0, 0, 0, 2, 79, 79}, {40, 1, 0, 0, 0, 2, 79, 79},
    {41, 1, 1, 5, 5, 1, 82, 82}, {42, 1, 0, 0, 0, 0, 79, 79},
    {43, 1, 0, 0, 0, 0, 79, 79}, {44, 1, 0, 0, 0, 0, 79, 79},
    {45, 1, 0, 0, 0, 0, 79, 79}, {46, 1, 0, 0, 0, 0, 79, 79},
    {47, 1, 0, 0, 0, 0, 79, 79}, {48, 1, 0, 0, 0, 0, 79, 79},
    {49, 1, 0, 0, 0, 0, 79, 79}, {50, 0, 0, 0, 0, 0, 79, 79}};

// ammap of the codes 'C' to '_'
static const int ammaps[29] = {0, 0, 10, 6, 0, 0, 0, 0, 0, 0, 0, 1, 22, 12, 13,
                               41, 0, 0, 14, 5, 0, 0, 0, 0, 32, 0, 33, 0, 0};

WFDBX_TEST(c_code_maps)
{
    for (const auto &m : maps) {
        int c = m[0];
        int got[7] = {wfdb_isann(c), wfdb_isqrs(c), wfdb_map1(c),
                      wfdb_map2(c), wfdb_annpos(c), wfdb_mamap(c, 0),
                      wfdb_mamap(c, -1)};
        bool ok = true;
        for (int i = 0; i < 7; i++) ok = ok && got[i] == m[i + 1];
        CHECK(ok);
        if (!ok) std::fprintf(stderr, "    (code %d)\n", c);
    }
    for (int c = 'C'; c <= '_'; c++)
        CHECK_EQ(wfdb_ammap(c), ammaps[c - 'C']);
    CHECK_EQ(wfdb_setisqrs(1, 0), 0);
    CHECK_EQ(wfdb_isqrs(1), 0);
    CHECK_EQ(wfdb_setisqrs(60, 1), 0);
    CHECK_EQ(wfdb_setisqrs(2, 300), 44);    // (stored in a char)
    CHECK_EQ(wfdb_isqrs(2), 44);
    CHECK_EQ(wfdb_setmap1(14, PVC), 5);
    CHECK_EQ(wfdb_map1(14), 5);
    CHECK_EQ(wfdb_setmap1(0, PVC), 0);
    CHECK_EQ(wfdb_setmap2(14, SVPB), 9);
    CHECK_EQ(wfdb_map2(14), 9);
    CHECK_EQ(wfdb_setmap2(-3, PVC), 0);
    CHECK_EQ(wfdb_setannpos(14, 6), 6);
    CHECK_EQ(wfdb_annpos(14), 6);
    CHECK_EQ(wfdb_setannpos(50, 2), 0);
    wfdb_setisqrs(1, 1);
    wfdb_setisqrs(2, 1);
    wfdb_setmap1(14, NOTQRS);
    wfdb_setmap2(14, NOTQRS);
    wfdb_setannpos(14, 2);
}

// ---------------------------------------------------------------------------
// t_extra

WFDBX_TEST(c_default_calibration_file)
{
    DataDir d;
    CHECK_EQ(calopen(nullptr), 0);  // $WFDBCAL (wfdbcal, set by setwfdb)
    CHECK(cal("Resp", nullptr) == (Cal{0, 0, 0, 1, 0, "Resp", "l"}));
    flushcal();
}

WFDBX_TEST(c_uncalibrated_signals)
{
    DataDir d;
    isig("null");       // gain 0
    // (wfdb-x: no default gain; C assumed WFDB_DEFGAIN)
    wfdbquiet();
    CHECK_EQ(adumuv(0, 100), WFDB_INVALID_SAMPLE);
    CHECK_EQ(muvadu(1, 100), WFDB_INVALID_SAMPLE);
    CHECK(std::isnan(aduphys(0, 100)));
    CHECK_EQ(physadu(1, 0.5), WFDB_INVALID_SAMPLE);
    wfdbverbose();
    CHECK(vec(2) == (std::vector<int>{2, -32768, -32768}));
}

WFDBX_TEST(c_getframe_deskew)
{
    DataDir d;
    isig("skew");
    CHECK(vec(3, getframe) == (std::vector<int>{3, -7, 21, -32768}));
    CHECK(vec(3, getframe) == (std::vector<int>{3, 4, -14, -85}));
    isigsettime(1497);
    CHECK(vec(3, getframe) == (std::vector<int>{-1, -32755, 16705, -32768}));
    CHECK(vec(3, getframe) == (std::vector<int>{-1, -32751, -14, 16705}));
}

WFDBX_TEST(c_multifrequency_resampling)
{
    DataDir d;
    isig("mfreq");
    CHECK_EQ(setifreq(200.0), 0);
    CHECK(vec(3) == (std::vector<int>{3, 138, 1459, 499}));
    CHECK(vec(3) == (std::vector<int>{3, 2677, 738, 1381}));
    CHECK(vec(3) == (std::vector<int>{3, 2677, 738, 1381}));
    CHECK_EQ(getafreq(), 200);      // (setifreq also calls setafreq)
    setafreq(0.0);
    wfdbquit();
    isig("mfreq");
    CHECK_EQ(sample(2, 10), 869);
    CHECK_EQ(sample_valid(), 1);
    CHECK_EQ(sample(1, 599), 637);
    CHECK_EQ(sample_valid(), 1);
    wfdbquit();
    isig("multi");
    CHECK_EQ(isigsettime(100), 0);
    CHECK_EQ(tnextvec(0, 21650), 23450);
    CHECK(vec(2) == (std::vector<int>{2, 969, 996}));
}

// After a failed seek (past the end of a FLAC stream), libFLAC aborts the
// decoding of the next block in the C library: getvec fails, and so do
// later seeks; a seek to the current time is not performed.
WFDBX_TEST(c_flac_failed_seek)
{
    DataDir d;
    CHECK_EQ(isig("flac16"), 3);
    CHECK_EQ(isigsettime(99999), -1);
    CHECK(vec(3) == (std::vector<int>{-3, 0, 0, 0}));
    CHECK_EQ(isigsettime(0), -1);
    CHECK(vec(3) == (std::vector<int>{-3, 0, 0, 0}));
    wfdbquit();
    isig("flac16");
    CHECK_EQ(isigsettime(99999), -1);
    CHECK_EQ(isigsettime(5), 0);
    CHECK(vec(3) == (std::vector<int>{3, -77, -57, -47}));
    wfdbquit();
    isig("flac16");
    CHECK(vec(3) == (std::vector<int>{3, -31, -38, -33}));
    CHECK_EQ(isigsettime(9001), -1);
    CHECK_EQ(isigsettime(1), 0);
    CHECK(vec(3) == (std::vector<int>{-3, 0, 0, 0}));
}

// ---------------------------------------------------------------------------
// t_nodefaults (wfdb-x divergence: no default sampling frequency, gain, ADC
// resolution or units; see docs/DIVERGENCES.md)

WFDBX_TEST(c_time_needs_freq)
{
    DataDir d;
    const std::vector<std::pair<const char *, int>> cases = {
        {"s10", 0}, {"e", 0}, {"i", 0}, {"o", 0}, {"c10", 1}, {"f3", 1},
        {"10", 1}, {"1:0", 1}, {"[10:00:00]", 1}, {" s5", 0}, {"", 1}};
    for (const auto &[str, expect] : cases)
        CHECK_EQ(wfdbx_time_needs_freq(str), expect);
}

WFDBX_TEST(c_no_default_frequency)
{
    DataDir d;
    wfdbquiet();
    // no input record: no sampling frequency
    CHECK_EQ(strtim("1:0"), 0);
    CHECK_EQ(wfdberror(), "strtim: sampling frequency is not specified\n");
    CHECK_EQ(strtim("s10"), 10);
    CHECK_EQ(timstr(360), "s360");
    CHECK_EQ(wfdberror(), "timstr: sampling frequency is not specified\n");
    CHECK_EQ(mstimstr(-360), "s360");
    CHECK_EQ(wfdberror(), "mstimstr: sampling frequency is not specified\n");
    // a header without a sampling frequency
    {
        std::ofstream f("nf.hea", std::ios::binary);
        f << "nf 2\n100s.dat 212 200 11 1024 995 21537 0 MLII\n"
             "100s.dat 212 200 11 1024 1011 -3962 0 V5\n";
    }
    CHECK_EQ(isig("nf"), 2);
    CHECK_EQ(sampfreq(nullptr), 0);
    CHECK_EQ(getifreq(), 0);
    CHECK_EQ(setifreq(100.), -1);
    CHECK_EQ(wfdberror(), "setifreq: sampling frequency is not specified\n");
    CHECK_EQ(strtim("2"), 0);
    CHECK_EQ(strtim("e"), 0);
    CHECK_EQ(mstimstr(100), "s100");
    wfdbquit();
    // a frequency set by the caller applies
    CHECK_EQ(setsampfreq(500.), 0);
    CHECK_EQ(isig("nf"), 2);
    CHECK_EQ(sampfreq(nullptr), 500);
    CHECK_EQ(strtim("2"), 1000);
    CHECK_EQ(mstimstr(100), "    0:00.200");
    wfdbquit();
    CHECK_EQ(sampfreq("nf"), 0);
    wfdbquit();
    wfdbverbose();
}

WFDBX_TEST(c_no_default_gain)
{
    DataDir d;
    wfdbquiet();
    // uncalibrated signals (record null) and invalid signal numbers
    isig("null");
    CHECK(std::isnan(aduphys(0, 100)));
    CHECK_EQ(wfdberror(), "aduphys: signal 0 is uncalibrated\n");
    CHECK_EQ(physadu(0, 1.0), WFDB_INVALID_SAMPLE);
    CHECK_EQ(wfdberror(), "physadu: signal 0 is uncalibrated\n");
    CHECK_EQ(adumuv(1, 100), WFDB_INVALID_SAMPLE);
    CHECK_EQ(muvadu(1, 100), WFDB_INVALID_SAMPLE);
    CHECK_EQ(wfdberror(), "muvadu: signal 1 is uncalibrated\n");
    wfdbquit();
    isig("100s");
    CHECK_EQ(aduphys(0, 1124), 0.5);
    CHECK_EQ(physadu(1, -0.5), 924);
    CHECK_EQ(adumuv(0, 100), 500);
    CHECK_EQ(muvadu(0, 1000), 200);
    CHECK(std::isnan(aduphys(5, 100)));
    CHECK_EQ(wfdberror(), "aduphys: invalid signal number 5\n");
    CHECK_EQ(physadu(5, 1.0), WFDB_INVALID_SAMPLE);
    CHECK_EQ(adumuv(2, 100), WFDB_INVALID_SAMPLE);
    CHECK_EQ(muvadu(2, 100), WFDB_INVALID_SAMPLE);
    CHECK_EQ(wfdberror(), "muvadu: invalid signal number 2\n");
    wfdbquit();
    wfdbverbose();
}

// No default ADC resolution or units: 0 and none if the header does not give
// them (C: inferred from the format, or WFDB_DEFRES; the C programs showed
// "mV").
WFDBX_TEST(c_no_default_adcres_or_units)
{
    DataDir d;
    wfdbquiet();
    {
        std::ofstream f("nr.hea", std::ios::binary);
        f << "nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n";
    }
    WFDB_Siginfo si[8];
    CHECK_EQ(isigopen("nr", si, 8), 2);
    CHECK_EQ(si[0].adcres, 0);
    CHECK_EQ(si[1].adcres, 0);
    CHECK(!si[0].units);
    wfdbquit();
    CHECK_EQ(isigopen("100s", si, 8), 2);
    CHECK_EQ(si[0].adcres, 11);
    CHECK_EQ(si[1].adcres, 11);
    wfdbquit();
    wfdbverbose();
}

// ---------------------------------------------------------------------------
// t_legacy (wfdb-x legacy mode, wfdbx_set_legacy(): the library behaves as
// the original WFDB library, with its built-in defaults; see
// docs/DIVERGENCES.md).  The values are those of the original library.

namespace {

// Legacy mode on for the lifetime of the object (off again afterwards, also
// if a REQUIRE fails).
struct LegacyOn {
    LegacyOn() { wfdbx_set_legacy(1); }
    ~LegacyOn() { wfdbx_set_legacy(0); }
};

bool near(double a, double b) { return std::fabs(a - b) < 1e-12; }

} // namespace

WFDBX_TEST(c_legacy_switch)
{
    CHECK_EQ(wfdbx_get_legacy(), 0);
    CHECK_EQ(wfdbx_set_legacy(1), 0);
    CHECK_EQ(wfdbx_get_legacy(), 1);
    CHECK_EQ(wfdbx_set_legacy(5), 1);
    CHECK_EQ(wfdbx_set_legacy(0), 1);
    CHECK_EQ(wfdbx_get_legacy(), 0);
    // --legacy is recognized only as the first argument.
    char a0[] = "rdsamp", a1[] = "--legacy", a2[] = "-r", a3[] = "100s";
    char *v1[] = {a0, a2, a1, nullptr};
    int argc = 3;
    char **argv = v1;
    CHECK_EQ(wfdbx_legacy_args(argc, argv), 0);
    CHECK(argc == 3 && argv == v1 && wfdbx_get_legacy() == 0);
    char *v2[] = {a0, a1, a2, a3, nullptr};
    argc = 4;
    argv = v2;
    CHECK_EQ(wfdbx_legacy_args(argc, argv), 1);
    CHECK_EQ(argc, 3);
    CHECK(std::string(argv[0]) == "rdsamp" && std::string(argv[1]) == "-r" &&
          std::string(argv[2]) == "100s" && argv[3] == nullptr);
    CHECK_EQ(wfdbx_get_legacy(), 1);
    wfdbx_set_legacy(0);
    char *v3[] = {a0, nullptr};
    argc = 1;
    argv = v3;
    CHECK_EQ(wfdbx_legacy_args(argc, argv), 0);
    CHECK_EQ(argc, 1);
}

WFDBX_TEST(c_legacy)
{
    DataDir d;
    LegacyOn legacy;
    WFDB_Siginfo si[8];
    // amplitude conversion (gain 200, baseline 1024; invalid signal numbers:
    // gain 200, baseline 0)
    isig("100s");
    CHECK_EQ(adumuv(0, 200), 1000);
    CHECK_EQ(adumuv(0, -37), -185);
    CHECK_EQ(adumuv(1, 1), 5);
    CHECK_EQ(adumuv(0, -1), -5);
    CHECK_EQ(adumuv(7, 100), 500);
    CHECK_EQ(muvadu(0, 1000), 200);
    CHECK_EQ(muvadu(0, -333), -67);
    CHECK_EQ(muvadu(1, 2), 0);
    CHECK_EQ(muvadu(9, 1000), 200);
    CHECK(near(aduphys(0, 1224), 1));
    CHECK(near(aduphys(1, 900), -0.62));
    CHECK(near(aduphys(5, 300), 1.5));
    CHECK_EQ(physadu(0, 1.0), 1224);
    CHECK_EQ(physadu(1, -0.5023), 924);
    CHECK_EQ(physadu(5, 1.5), 300);
    CHECK(near(aduphys(5, 100), 0.5));
    CHECK_EQ(physadu(5, 1.0), 200);
    CHECK_EQ(adumuv(2, 100), 500);
    CHECK_EQ(muvadu(2, 100), 20);
    wfdbquit();
    // uncalibrated signals (record null): gain 200
    isig("null");
    CHECK_EQ(adumuv(0, 100), 500);
    CHECK_EQ(muvadu(1, 100), 20);
    CHECK(near(aduphys(0, 100), 0.5));
    CHECK_EQ(physadu(1, 0.5), 100);
    CHECK_EQ(physadu(0, 1.0), 200);
    wfdbquit();
    wfdbquiet();
    // no input record: 1 sample per second
    CHECK_EQ(strtim("1:0"), 60);
    CHECK_EQ(strtim("s10"), 10);
    CHECK_EQ(timstr(360), "    6:00");
    CHECK_EQ(mstimstr(-360), "    6:00.000");
    // a header without a sampling frequency: 250 Hz
    {
        std::ofstream f("nf.hea", std::ios::binary);
        f << "nf 2\n100s.dat 212 200 11 1024 995 21537 0 MLII\n"
             "100s.dat 212 200 11 1024 1011 -3962 0 V5\n";
    }
    CHECK_EQ(isig("nf"), 2);
    CHECK_EQ(sampfreq(nullptr), 250);
    CHECK_EQ(getifreq(), 250);
    CHECK_EQ(strtim("2"), 500);
    CHECK_EQ(strtim("e"), 0);
    CHECK_EQ(mstimstr(100), "    0:00.400");
    CHECK_EQ(setifreq(100.), 0);
    CHECK_EQ(getifreq(), 100);
    wfdbquit();
    CHECK_EQ(sampfreq("nf"), 250);
    wfdbquit();
    // setifreq with an input record but no frequency
    isig("100s");
    setsampfreq(0.);
    CHECK_EQ(setifreq(100.), -1);
    CHECK_EQ(wfdberror(), "setifreq: no open input record\n");
    wfdbquit();
    // ADC resolution inferred from the format, or WFDB_DEFRES
    {
        std::ofstream f("nr.hea", std::ios::binary);
        f << "nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n";
    }
    CHECK_EQ(isigopen("nr", si, 8), 2);
    CHECK(si[0].adcres == 12 && si[1].adcres == 12);
    wfdbquit();
    {
        std::ofstream f("nr3.hea", std::ios::binary);
        f << "nr3 5 360 10\nfmt16.dat 16\nfmt80.dat 80\nfmt310.dat 310\n"
             "fmt160.dat 160\nfmt24.dat 24\n";
    }
    CHECK_EQ(isigopen("nr3", si, 8), 5);
    CHECK(si[0].adcres == 12 && si[1].adcres == 8 && si[2].adcres == 10 &&
          si[3].adcres == 16 && si[4].adcres == 12);
    wfdbquit();
    wfdbverbose();
}

// ---------------------------------------------------------------------------
// wfdb-x: the output directory (wfdbx_set_output_dir; t_outdir in
// api_expect.c), the sorting of out-of-order output annotation files in this
// process (legacy mode: by the sortann program), and input files named by
// absolute paths

namespace {


// Out-of-order annotations with ties in time, num and chan, duplicates (the
// last one is kept), NOTQRS (dropped), aux strings, and a time 0 annotation
// that precedes the others (wfdb-x: kept; dropped by the original sortann,
// with the one at time 5 inserted after it, see docs/KNOWN_C_BEHAVIORS.md).
// The same as TRICKY in python/tests/test_annotations.py.
Annotations tricky()
{
    struct Row { long long t; int code, sub, chan, num; const char *aux; };
    static const std::string x101(101, 'x');
    const Row rows[] = {
        {100, NORMAL, 0, 0, 0, nullptr}, {50, PVC, 0, 0, 0, "(VT"},
        {100, APC, 0, 1, 0, nullptr}, {100, NORMAL, 0, 0, 1, "num 1"},
        {100, PVC, 0, 0, 0, "replaces N"}, {75, NOTQRS, 0, 2, 0, nullptr},
        {75, NORMAL, 1, 2, 0, "odd"}, {10, NOTQRS, 0, 0, 0, nullptr},
        {200, RHYTHM, 0, 0, 0, "(AFIB"}, {150, NOISE, 0, 3, -1, nullptr},
        {150, NOISE, 0, 3, 0, nullptr}, {20, NORMAL, 0, 0, 0, x101.c_str()},
        {0, NORMAL, 0, 0, 0, nullptr}, {5, NORMAL, 0, 1, 0, nullptr},
        {5000, NORMAL, 0, 0, 0, nullptr}};
    Annotations a;
    for (const Row &r : rows) {
        a.samples.push_back(r.t);
        a.codes.push_back(r.code);
        a.subtypes.push_back(r.sub);
        a.chans.push_back(r.chan);
        a.nums.push_back(r.num);
        a.aux.push_back(r.aux ? std::optional<std::string>(r.aux)
                              : std::nullopt);
    }
    return a;
}

// Write tricky() as annotator `name` of record `record` (time resolution
// 1000), and return the contents of the file.
std::string write_tricky(const std::string &record, const char *name)
{
    write_annotations(record, name, tricky(), 1000.0);
    return slurp((record + "." + name).c_str());
}

// (time, anntyp, chan, num) of each annotation of annotator `name`, read in
// ticks of the time resolution.
std::vector<std::vector<long long>> read_back(const char *name)
{
    WFDB_Anninfo ai{name, WFDB_READ};
    std::vector<std::vector<long long>> r;
    if (annopen("100s", &ai, 1) != 0) return r;
    setiafreq(0, 1000.0);
    WFDB_Annotation a;
    while (getann(0, &a) == 0) r.push_back({a.time, a.anntyp, a.chan, a.num});
    wfdbquit();
    return r;
}

// The sortann tool built with the library, if any.
std::string tools_dir()
{
#ifdef WFDBX_TOOLS_DIR
    return WFDBX_TOOLS_DIR;
#else
    return "";
#endif
}

bool have_sortann()
{
    std::error_code ec;
    return !tools_dir().empty() &&
           (fs::exists(fs::path(tools_dir()) / "sortann", ec) ||
            fs::exists(fs::path(tools_dir()) / "sortann.exe", ec));
}

} // namespace

// This test modifies the annotation type table (a definition in the files),
// which the library cannot undo, so it runs in a child process where
// possible.
static void sort_in_process()
{
    DataDir d;
    setafreq(0.0);  // (it survives wfdbquit)
    setannstr(42, "Z");
    // Modern mode: sorted in this process (no sortann program can be found
    // in the PATH, and the test program has none next to it).
    std::string modern;
    {
        EnvVar path("PATH", "/nonexistent-wfdbx-dir");
        wfdbquiet();
        modern = write_tricky("100s", "srt");
        wfdbverbose();
        CHECK_EQ(wfdberror(), "done!\n");
    }
    // (the library's settings and tables are unchanged)
    CHECK(getafreq() == 0 && annstr(42) == "Z" && !anndesc(42));
    // The result, read back (in ticks of the time resolution).  wfdb-x:
    // nothing is lost; the original sortann loses the annotation at time 0,
    // and the one at time 5 inserted after it.
    const std::vector<std::vector<long long>> rest = {
        {20, NORMAL, 0, 0}, {50, PVC, 0, 0}, {75, NORMAL, 2, 0},
        {100, PVC, 0, 0}, {100, APC, 1, 0}, {100, NORMAL, 0, 1},
        {150, NOISE, 3, -1}, {150, NOISE, 3, 0}, {200, RHYTHM, 0, 0},
        {5000, NORMAL, 0, 0}};
    std::vector<std::vector<long long>> all = {{0, NORMAL, 0, 0},
                                               {5, NORMAL, 1, 0}};
    all.insert(all.end(), rest.begin(), rest.end());
    CHECK(read_back("srt") == all);
    CHECK(annstr(42) == "Z");

    if (have_sortann()) {
        // The in-process sort and the sortann tool give the same bytes.
        {
            EnvVar sort("WFDBANNSORT", "0");
            wfdbquiet();
            write_tricky("100s", "tool");
            wfdbverbose();
        }
        std::string cmd = "\"" + (fs::path(tools_dir()) / "sortann").string() +
                          "\" -r 100s -a tool";
        CHECK_EQ(std::system(cmd.c_str()), 0);
        CHECK(slurp("100s.tool") == modern);

        // Legacy mode: the sortann program, as the original (--legacy),
        // loss included.
        EnvVar path("PATH", tools_dir().c_str());
        LegacyOn legacy;
        wfdbquiet();
        std::string leg = write_tricky("100s", "leg");
        wfdbverbose();
        CHECK_EQ(wfdberror(), "done!\n");
        CHECK(read_back("leg") == rest);
        // It is run without a shell: names with spaces work.
        fs::create_directory("sub dir");
        fs::copy_file("100s.hea", "sub dir/100s.hea");
        wfdbquiet();
        CHECK(write_tricky("sub dir/100s", "leg") == leg);
        wfdbverbose();
        CHECK_EQ(wfdberror(), "done!\n");
    } else
        std::fprintf(stderr, "(sortann not built: legacy comparison skipped)\n");

    // Legacy mode without a sortann program: the file stays unsorted.
    {
        EnvVar path("PATH", "/nonexistent-wfdbx-dir");
        LegacyOn legacy;
        wfdbquiet();
        std::string unsorted = write_tricky("100s", "uns");
        wfdbverbose();
        CHECK(unsorted != modern);
        CHECK_EQ(wfdberror(), "to rearrange annotations in the correct order.\n");
    }
    setannstr(-42, "[42]");
}

WFDBX_TEST(c_sort_in_process)
{
    isolated(sort_in_process);
}

WFDBX_TEST(c_sort_disabled)
{
    DataDir d;
    setafreq(0.0);  // (it survives wfdbquit)
    EnvVar sort("WFDBANNSORT", "0");
    wfdbquiet();
    Annotations in = tricky();
    write_annotations("100s", "ns", in);
    CHECK_EQ(wfdberror(), "to rearrange annotations in the correct order.\n");
    Annotations a = read_annotations("100s", "ns");
    wfdbverbose();
    CHECK(a.samples == in.samples);
}

// write_annotations(..., sort): true or false decides for that call only,
// whatever WFDBANNSORT says (which is not changed); unset, WFDBANNSORT
// decides.  The same in legacy mode (true: the sortann program).
WFDBX_TEST(c_sort_option)
{
    DataDir d;
    setafreq(0.0);  // (it survives wfdbquit)
    Annotations a;
    a.samples = {300, 100, 200, 100, 50};
    a.symbols = {"N", "V", "N", "A", "N"};
    const std::vector<WFDB_Time> given = a.samples;
    // (sorted: the annotation at 100 written last replaces the other)
    const std::vector<WFDB_Time> sorted = {50, 100, 200, 300};
    auto times = [](const char *ann) {
        wfdbquiet();
        std::vector<WFDB_Time> t = read_annotations("100s", ann).samples;
        wfdbverbose();
        return t;
    };
    auto write = [&](const char *ann, std::optional<bool> sort) {
        wfdbquiet();
        write_annotations("100s", ann, a, 0, {}, sort);
        wfdbverbose();
    };
    {
        EnvVar env("WFDBANNSORT", nullptr);
        write("s0", std::nullopt);      // default: sorted
        CHECK(times("s0") == sorted);
        write("s1", false);
        CHECK(times("s1") == given);
        // (sort = false: no advice to run sortann)
        CHECK(wfdberror().find("rearrange") == std::string::npos);
        CHECK(std::getenv("WFDBANNSORT") == nullptr);
        write("s2", std::nullopt);      // (the next call: as before)
        CHECK(times("s2") == sorted);
    }
    {
        EnvVar env("WFDBANNSORT", "0");
        write("s3", true);
        CHECK(times("s3") == sorted);
        CHECK(std::string(std::getenv("WFDBANNSORT")) == "0");
        write("s4", std::nullopt);
        CHECK(times("s4") == given);
        write("s5", false);
        CHECK(times("s5") == given);
        CHECK(slurp("100s.s4") == slurp("100s.s5"));
        CHECK(slurp("100s.s0") == slurp("100s.s3"));
    }
    // legacy mode
    {
        EnvVar env("WFDBANNSORT", "1");
        LegacyOn legacy;
        write("l1", false);
        CHECK(times("l1") == given);
        CHECK(slurp("100s.l1") == slurp("100s.s4"));
    }
    if (have_sortann()) {
        EnvVar env("WFDBANNSORT", "0");
        EnvVar path("PATH", tools_dir().c_str());
        LegacyOn legacy;
        write("l2", true);
        CHECK_EQ(wfdberror(), "done!\n");
        CHECK(times("l2") == sorted);
        CHECK(slurp("100s.l2") == slurp("100s.s0"));
    }
}

WFDBX_TEST(c_sort_keeps_other_annotators)
{
    // An input annotator and the signals stay open while an output annotator
    // is closed and sorted.
    DataDir d;
    setafreq(0.0);  // (it survives wfdbquit)
    REQUIRE(isigopen("100s", nullptr, 2) == 2);
    WFDB_Anninfo ai[3] = {{"atr", WFDB_READ}, {"o1", WFDB_WRITE},
                          {"o2", WFDB_WRITE}};
    REQUIRE(annopen("100s", ai, 3) == 0);
    WFDB_Annotation first, a;
    getann(0, &first);
    for (long long t : {30, 10, 20}) {
        a.time = t;
        a.anntyp = NORMAL;
        putann(0, &a);
        a.anntyp = PVC;
        putann(1, &a);
    }
    wfdbquiet();
    oannclose(0);   // sorted now; o2 becomes output annotator 0
    wfdbverbose();
    CHECK(getann(0, &a) == 0 && a.time == 77 && first.time == 18);
    CHECK(vec(2) == (std::vector<int>{2, 995, 1011}));
    a.time = 40;
    a.anntyp = PVC;
    putann(0, &a);
    wfdbquiet();
    wfdbquit();
    wfdbverbose();
    CHECK(read_annotations("100s", "o1").samples ==
          (std::vector<WFDB_Time>{10, 20, 30}));
    CHECK(read_annotations("100s", "o2").samples ==
          (std::vector<WFDB_Time>{10, 20, 30, 40}));
}

// t_sortfix (api_expect.c, called by t_outdir): an out-of-order annotation at
// time 0 is kept (legacy mode: lost, by the sortann program), and the legacy
// sort runs in the output directory.
static void sortfix()
{
    if (!have_sortann()) {
        std::fprintf(stderr, "(sortann not built: sortfix skipped)\n");
        return;
    }
    EnvVar path("PATH", tools_dir().c_str());
    setwfdb(".");
    WFDB_Anninfo ai;
    WFDB_Annotation a;
    const long long t1[] = {5, 0, 3}, t2[] = {30, 10, 20};
    a.anntyp = NORMAL;
    ai.stat = WFDB_WRITE;
    wfdbquiet();    // ("Rearranging annotations ...")
    for (int legacy = 0; legacy <= 1; legacy++) {
        wfdbx_set_legacy(legacy);
        ai.name = legacy ? "l0" : "m0";
        annopen("100s", &ai, 1);
        for (long long t : t1) {
            a.time = t;
            putann(0, &a);
        }
        wfdbquit();
        wfdbx_set_output_dir("odir");
        ai.name = legacy ? "lsrt" : "msrt";
        annopen("orec", &ai, 1);
        for (long long t : t2) {
            a.time = t;
            putann(0, &a);
        }
        wfdbquit();
        wfdbx_set_output_dir(nullptr);
    }
    wfdbx_set_legacy(0);
    wfdbverbose();
    ai.stat = WFDB_READ;
    ai.name = "m0";
    CHECK_EQ(annopen("100s", &ai, 1), 0);
    CHECK(ann(0) == (std::vector<long long>{0, 0, 1, 0, 0, 0}));
    CHECK(ann(0) == (std::vector<long long>{0, 3, 1, 0, 0, 0}));
    CHECK(ann(0) == (std::vector<long long>{0, 5, 1, 0, 0, 0}));
    CHECK_EQ(ann(0)[0], -1);
    wfdbquit();
    ai.name = "l0";
    CHECK_EQ(annopen("100s", &ai, 1), 0);
    CHECK(ann(0) == (std::vector<long long>{0, 5, 1, 0, 0, 0}));
    CHECK_EQ(ann(0)[0], -1);
    wfdbquit();
    const std::string srt =
        unhex("0058 1efc") + "## annotation type definitions" +
        unhex("0058 16fc") + "15 [15] my description" +
        unhex("0058 07fc") + "42 new " + unhex("00 0058 15fc") +
        "## end of definitions" +
        unhex("00 00ec ffff ffff 0100 0a04 0a04 0a04 0000");
    CHECK_EQ(slurp("odir/orec.msrt"), srt);
    CHECK_EQ(slurp("odir/orec.lsrt"), srt);
}

// The expected values are those of t_outdir (api_expect.c, patched C
// library).  It depends on the annotation type table left by t_strings (code
// 15 description "my description", code 42 mnemonic "new" with description
// ""), set up here, which the library cannot undo: it runs in a child
// process where possible.
static void outdir()
{
    DataDir d;
    setcfreq(0.0);  // (these survive wfdbquit)
    setafreq(0.0);
    setanndesc(15, "my description");
    setannstr(42, "new");
    setanndesc(42, "");
    CHECK(!wfdbx_get_output_dir());
    fs::create_directory("odir");
    CHECK(!wfdbx_set_output_dir("odir"));
    CHECK(wfdbx_get_output_dir() == "odir");
    WFDB_Siginfo si;
    si.fname = "orec.dat";
    si.desc = "sig";
    si.gain = 200;
    si.fmt = 16;
    si.adcres = 12;
    setsampfreq(100.0);
    CHECK_EQ(osigfopen(&si, 1), 1);
    for (int i = 0; i < 3; i++) {
        WFDB_Sample v[1] = {10 * i - 7};
        putvec(v);
    }
    CHECK_EQ(newheader("orec"), 0);
    WFDB_Anninfo ai{"oat", WFDB_WRITE};
    CHECK_EQ(annopen("orec", &ai, 1), 0);
    WFDB_Annotation a;
    const long long t[] = {30, 10, 20, 10, 5};    // out of order, a duplicate
    for (int i = 0; i < 5; i++) {
        a.time = t[i];
        a.anntyp = i == 3 ? PVC : NORMAL;
        putann(0, &a);
    }
    wfdbquiet();    // ("Rearranging annotations ...")
    wfdbquit();
    wfdbverbose();
    CHECK(wfdbx_set_output_dir("") == "odir");
    CHECK(!wfdbx_get_output_dir());
    CHECK(!wfdbx_set_output_dir("odir2"));
    CHECK(wfdbx_set_output_dir(nullptr) == "odir2");
    CHECK(!wfdbx_get_output_dir());
    CHECK_EQ(slurp("odir/orec.hea"),
             "orec 1 100 3\r\norec.dat 16 200 12 0 -7 9 0 sig\r\n");
    CHECK_EQ(slurp("odir/orec.dat"), unhex("f9ff03000d00"));
    CHECK_EQ(slurp("odir/orec.oat"),
             unhex("0058 1efc") + "## annotation type definitions" +
             unhex("0058 16fc") + "15 [15] my description" +
             unhex("0058 07fc") + "42 new " + unhex("00 0058 15fc") +
             "## end of definitions" +
             unhex("00 00ec ffff ffff 0100 0504 0514 0a04 0a04 0000"));
    CHECK(!fs::exists("orec.hea"));
    // A missing output directory is created (as are the missing directories
    // of any output file name, by wfdb_fopen).
    wfdbx_set_output_dir("newdir");
    CHECK_EQ(osigfopen(&si, 1), 1);
    CHECK_EQ(annopen("orec", &ai, 1), 0);
    wfdbquit();
    wfdbx_set_output_dir(nullptr);
    CHECK(fs::file_size("newdir/orec.dat") == 0 &&
          fs::file_size("newdir/orec.oat") == 2);
    // reading the record from the output directory
    setwfdb("odir");
    CHECK_EQ(isig("orec"), 1);
    CHECK(vec(1) == (std::vector<int>{1, -7}));
    CHECK(vec(1) == (std::vector<int>{1, 3}));
    CHECK(vec(1) == (std::vector<int>{1, 13}));
    ai.stat = WFDB_READ;
    CHECK_EQ(annopen("orec", &ai, 1), 0);
    CHECK(ann(0) == (std::vector<long long>{0, 5, 1, 0, 0, 0}));
    CHECK(ann(0) == (std::vector<long long>{0, 10, 5, 0, 0, 0}));
    CHECK(ann(0) == (std::vector<long long>{0, 20, 1, 0, 0, 0}));
    CHECK(ann(0) == (std::vector<long long>{0, 30, 1, 0, 0, 0}));
    CHECK_EQ(ann(0)[0], -1);
    wfdbquit();
    setwfdb(".");   // (wfdb-x: the setting of the last setwfdb remains)
    sortfix();
}

WFDBX_TEST(c_outdir)
{
    isolated(outdir);
    wfdbx_set_output_dir(nullptr);
}

WFDBX_TEST(c_absolute_paths)
{
    DataDir d;
    std::string rec = (fs::canonical(fs::current_path()) / "100s").string();
    WFDB_Siginfo si[8];
    wfdbquiet();
    CHECK_EQ(isigopen(rec.c_str(), si, 8), 2);
    CHECK(vec(2) == (std::vector<int>{2, 995, 1011}));
    CHECK(wfdbfile("hea", rec.c_str()) == rec + ".hea");
    WFDB_Anninfo ai{"atr", WFDB_READ};
    CHECK_EQ(annopen(rec.c_str(), &ai, 1), 0);
    CHECK(ann(0) == (std::vector<long long>{0, 18, 28, 0, 0, 0}));
    wfdbquit();
    CHECK_EQ(sampfreq(rec.c_str()), 360);
    wfdbquit();
    std::string missing = (fs::current_path() / "nosuch").string();
    CHECK_EQ(isigopen(missing.c_str(), si, 8), -1);
    wfdbquit();
    // The high-level functions, too (the signal file is found next to the
    // header).
    CHECK(read_record(rec).nsamples() == 21600);
    {
        // Legacy mode: as in C, an absolute name is searched for in the WFDB
        // path (here "./" + the name) ...
        LegacyOn legacy;
        CHECK_EQ(isigopen(rec.c_str(), si, 8), -1);
        CHECK_EQ(annopen(rec.c_str(), &ai, 1), -3);
        wfdbquit();
        // ... unless the WFDB path has an empty component.
        setwfdb(";");
        CHECK_EQ(isigopen(rec.c_str(), si, 8), 2);
        CHECK(vec(2) == (std::vector<int>{2, 995, 1011}));
        wfdbquit();
    }
    CHECK_EQ(isigopen(rec.c_str(), si, 8), 2);
    wfdbquit();
    resetwfdb();
    wfdbverbose();
}

// The annotation list (wfdb-x: an out-of-order annotation at time 0, num 0,
// chan 0 is not lost; legacy: as by the original sortann).
WFDBX_TEST(c_annlist_time0)
{
    for (bool legacy : {false, true}) {
        detail::AnnSortList list(legacy);
        WFDB_Annotation a;
        a.anntyp = NORMAL;
        for (long long t : {5, 0, 3}) {
            a.time = t;
            list.insert(a);
        }
        std::vector<WFDB_Time> times;
        list.for_each([&](const WFDB_Annotation &x) { times.push_back(x.time); });
        CHECK(times == (legacy ? std::vector<WFDB_Time>{5}
                               : std::vector<WFDB_Time>{0, 3, 5}));
        CHECK(!list.in_order());
    }
    // A later annotation at time 0 replaces a real one (both modes), and an
    // annotation at time 0 on another channel is kept (both modes).
    for (bool legacy : {false, true}) {
        detail::AnnSortList list(legacy);
        struct { long long t; int chan, type; } in[] = {
            {0, 0, NORMAL}, {7, 0, NORMAL}, {0, 1, APC}, {0, 0, PVC}};
        for (const auto &r : in) {
            WFDB_Annotation a;
            a.time = r.t;
            a.chan = static_cast<unsigned char>(r.chan);
            a.anntyp = static_cast<char>(r.type);
            list.insert(a);
        }
        std::vector<std::vector<long long>> got;
        list.for_each([&](const WFDB_Annotation &x) {
            got.push_back({x.time, x.chan, x.anntyp});
        });
        CHECK(got == (std::vector<std::vector<long long>>{
                  {0, 0, PVC}, {0, 1, APC}, {7, 0, NORMAL}}));
    }
}

// Legacy mode with an output directory: the sortann program runs there
// (where the file is), with --legacy; the result is that of the modern sort.
WFDBX_TEST(c_legacy_sort_in_output_dir)
{
    if (!have_sortann()) return;
    DataDir d;
    setafreq(0.0);  // (it survives wfdbquit)
    fs::create_directory("out");
    Annotations a;
    a.samples = {300, 100, 200, 100, 50};
    a.symbols = {"N", "V", "N", "A", "N"};
    {
        EnvVar path("PATH", tools_dir().c_str());
        LegacyOn legacy;
        wfdbquiet();
        write_annotations("rec", "leg", a, 0, "out");
        wfdbverbose();
        CHECK_EQ(wfdberror(), "done!\n");
    }
    wfdbquiet();
    write_annotations("rec", "mod", a, 0, "out");
    wfdbverbose();
    std::vector<std::string> files;
    for (const auto &e : fs::directory_iterator("out"))
        files.push_back(e.path().filename().string());
    std::sort(files.begin(), files.end());
    CHECK(files == (std::vector<std::string>{"rec.leg", "rec.mod"}));
    CHECK(slurp("out/rec.leg") == slurp("out/rec.mod"));
    wfdbquiet();    // (out/rec has no header)
    Annotations r = read_annotations("out/rec", "leg", {}, {}, 360.0);
    wfdbverbose();
    CHECK(r.samples == (std::vector<WFDB_Time>{50, 100, 200, 300}));
    CHECK(r.symbols.size() == 4 && r.symbols[1] == "A");
}
