// test_integrity.cpp: unit tests of two wfdb-x protections of the data: a
// checksum error is a warning of read_record (the data are returned), and an
// output signal file is never one of the input files (osigfopen/osigopen
// refuse to create it).  The expected values of the second follow t_alias in
// tests/reference/api_expect.c; the Python counterparts are
// python/tests/test_signals.py::test_read_record_checksum_warning and
// python/tests/test_api.py::test_output_file_is_input_file.
//
// Part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

#include "tests.hpp"

#include <wfdbx/record.hpp>
#include <wfdbx/wfdb.hpp>

#include <cmath>
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

// Run the test in a fresh copy of tests/data (the current directory).
struct DataDir {
    fs::path old, dir;
    DataDir() {
        old = fs::current_path();
        static int n = 0;
        dir = fs::temp_directory_path() /
              ("wfdbx-test-i-" + std::to_string(n++) + "-" +
               std::to_string(std::random_device{}()));
        fs::create_directories(dir);
        for (const auto &e : fs::directory_iterator(wfdbx_tests::data_dir()))
            if (e.is_regular_file())
                fs::copy_file(e.path(), dir / e.path().filename());
        fs::current_path(dir);
        wfdbquit();
        setwfdb(".");
        setafreq(0.0);
    }
    ~DataDir() {
        wfdbquit();
        wfdbx_set_legacy(0);
        fs::current_path(old);
        std::error_code ec;
        fs::remove_all(dir, ec);
    }
};

#ifdef WFDBX_HAVE_DUP
// The standard error output, captured for the lifetime of the object
// (text() returns what was written).
class StderrCapture {
public:
    StderrCapture() : tmp_(std::tmpfile()) {
        std::fflush(stderr);
        saved_ = dup(2);
        dup2(fileno(tmp_), 2);
    }
    ~StderrCapture() { restore(); if (tmp_) std::fclose(tmp_); }
    std::string text() {
        restore();
        std::string s;
        std::rewind(tmp_);
        int c;
        while ((c = std::getc(tmp_)) != EOF) s += static_cast<char>(c);
        return s;
    }
private:
    void restore() {
        if (saved_ < 0) return;
        std::fflush(stderr);
        dup2(saved_, 2);
        close(saved_);
        saved_ = -1;
    }
    std::FILE *tmp_;
    int saved_ = -1;
};
#endif

WriteOptions options()
{
    WriteOptions w;
    w.gains = {100};
    w.adcres = {16};
    w.units = {"mV"};
    return w;
}

const std::string checksum_warning =
    "wfdb-x: checksum error in record ck: the signal data do not match the "
    "checksums in its header\n";

// Record ck: 4 frames of 2 signals, whose .dat is changed after writing
// (sample (1, 0): 3 -> 9), so that its checksum no longer matches; record
// good: the changed samples, with correct checksums.  Returns them.
std::vector<WFDB_Sample> write_checksum_records()
{
    std::vector<WFDB_Sample> x = {1, 2, 3, 4, 5, 6, 7, 8};
    write_record("ck", x, 2, 100, options());
    {
        std::fstream f("ck.dat", std::ios::in | std::ios::out |
                                 std::ios::binary);
        f.seekp(4);
        f.put(9);
        f.put(0);
    }
    x[2] = 9;
    write_record("good", x, 2, 100, options());
    return x;
}

std::string slurp(const char *name)
{
    std::ifstream f(name, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(f), {});
}

bool throws_with(const std::string &record, const ReadOptions &opt,
                 const std::string &what)
{
    try {
        read_record(record, opt);
    } catch (const Error &e) {
        return std::string(e.what()).find(what) != std::string::npos;
    }
    return false;
}

// The output specification of t_alias: 3 signals of format 16 in fname.
std::vector<WFDB_Siginfo> alias_spec(const char *fname)
{
    std::vector<WFDB_Siginfo> si(3);
    for (WFDB_Siginfo &s : si) {
        s.fname = fname;
        s.desc = "s";
        s.units = "mV";
        s.gain = 100;
        s.fmt = 16;
        s.adcres = 12;
        s.group = 0;
    }
    return si;
}

int getvec3()
{
    WFDB_Sample v[8];
    return getvec(v);
}

} // namespace

// ---------------------------------------------------------------------------
// A. A checksum error is a warning of read_record

WFDBX_TEST(read_record_checksum_warning)
{
    DataDir d;
    std::vector<WFDB_Sample> y = write_checksum_records();
    for (bool legacy : {false, true}) {
        ReadOptions opt;
        opt.legacy = legacy;
        Record good = read_record("good", opt);
        CHECK(good.samples == y);
#ifdef WFDBX_HAVE_DUP
        // every frame, the last one included, with the warning only
        {
            StderrCapture cap;
            Record r = read_record("ck", opt);
            CHECK_EQ(cap.text(), checksum_warning);
            CHECK(r.samples == y && r.nsamples() == good.nsamples());
            CHECK(std::fabs(r.physical(1, 0) - 0.09) < 1e-12);
        }
        CHECK_EQ(wfdberror(), checksum_warning);
        // option off: the same frames, no message
        {
            StderrCapture cap;
            opt.checksum_warning = false;
            CHECK(read_record("ck", opt).samples == y);
            // not read to the end: no checksum is verified
            opt.checksum_warning = true;
            opt.to = 3;
            CHECK(read_record("ck", opt).samples ==
                  std::vector<WFDB_Sample>(y.begin(), y.begin() + 6));
            opt.from = 1;
            opt.to = "e";
            opt.checksum_warning = false;
            CHECK(read_record("ck", opt).samples ==
                  std::vector<WFDB_Sample>(y.begin() + 2, y.end()));
            CHECK_EQ(cap.text(), "");
        }
        // wfdbquiet() silences the warning
        {
            ReadOptions o;
            o.legacy = legacy;
            StderrCapture cap;
            wfdbquiet();
            CHECK(read_record("ck", o).samples == y);
            wfdbverbose();
            CHECK_EQ(cap.text(), "");
            CHECK_EQ(wfdberror(), checksum_warning);
        }
#endif
    }
    // a truncated signal file is still an error (status -3)
    std::vector<WFDB_Sample> x = {1, 2, 3, 4, 5, 6, 7, 8};
    write_record("tr", x, 2, 100, options());
    fs::resize_file("tr.dat", 8);
    wfdbquiet();
    CHECK(throws_with("tr", ReadOptions(), "getvec status -3"));
    wfdbverbose();
#ifdef WFDBX_HAVE_DUP
    // the low-level API is unchanged: getvec returns -4 for the last frame
    // (filled in), getvecs stops before it, and the message is printed
    StderrCapture cap;
    REQUIRE(isigopen("ck", nullptr, 2) == 2);
    WFDB_Sample v[2];
    std::vector<int> stats;
    for (int i = 0; i < 4; i++) stats.push_back(getvec(v));
    CHECK(stats == (std::vector<int>{2, 2, 2, -4}));
    CHECK(v[0] == 7 && v[1] == 8);
    wfdbquit();
    REQUIRE(isigopen("ck", nullptr, 2) == 2);
    std::vector<WFDB_Sample> buf(20);
    int stat = 0;
    CHECK_EQ(getvecs(buf.data(), 10, &stat), 3);
    CHECK_EQ(stat, -4);
    wfdbquit();
    CHECK_EQ(cap.text(), "getvec: checksum error in signal 0\n"
                         "getvec: checksum error in signal 0\n");
#endif
}

// ---------------------------------------------------------------------------
// B. An output signal file is never one of the input files (t_alias)

WFDBX_TEST(output_file_is_input_file)
{
    DataDir d;
    const char *names[][2] = {
        {"fmt16", "fmt16.dat"}, {"fmt16", "./fmt16.dat"},
        {"fmt16", "ahard16.dat"}, {"skew", "fmt16.dat"},
        {"vlay", "fmt16.dat"}, {"vlay", "fmt212.dat"},
        {"vlay", "fmt8.dat"}, {"vlay", "anew.dat"}};
    // refused: the file itself, another name for it, a hard link to it, a
    // file named by another header (skew), a segment of a multi-segment
    // record (fmt16, open; fmt212, the last segment, not open yet)
    std::error_code ec;
    fs::create_hard_link("fmt16.dat", "ahard16.dat", ec);
    bool have_link = !ec;
    wfdbquiet();
    for (const auto &n : names) {
        if (!have_link && std::string(n[1]) == "ahard16.dat") continue;
        wfdbquit();
        CHECK_EQ(isigopen(n[0], nullptr, 3), 3);
        setsampfreq(250.0);
        std::vector<WFDB_Siginfo> si = alias_spec(n[1]);
        int st = osigfopen(si.data(), 3);
        bool refused = std::string(n[1]) != "fmt8.dat" &&
                       std::string(n[1]) != "anew.dat";
        CHECK_EQ(st, refused ? -3 : 3);
        if (refused)
            CHECK_EQ(wfdberror(), std::string("osigfopen: output file ") +
                                  n[1] + " is also an input file\n");
        CHECK_EQ(getvec3(), 3);     // (the input is still readable)
    }
    wfdbquit();
    CHECK_EQ(isigopen("fmt16", nullptr, 3), 3);
    std::vector<WFDB_Siginfo> si = alias_spec("fmt16.dat");
    CHECK_EQ(osigopen("fmt16", si.data(), 3), -3);
    CHECK_EQ(wfdberror(), "osigopen: output file fmt16.dat is also an input "
                          "file\n");
    wfdbquit();
    // the inputs are intact
    CHECK(fs::file_size("fmt16.dat") == 9000 &&
          fs::file_size("fmt212.dat") == 6755);
    // legacy mode: no check (the original truncates its input)
    wfdbx_set_legacy(1);
    CHECK_EQ(isigopen("fmt16", nullptr, 3), 3);
    setsampfreq(250.0);
    si = alias_spec("fmt16.dat");
    CHECK_EQ(osigfopen(si.data(), 3), 3);
    wfdbquit();
    wfdbx_set_legacy(0);
    CHECK(fs::file_size("fmt16.dat") == 0);
    wfdbverbose();
}

// The high-level writer is protected too (it closes the input record first,
// so writing over a record's own files works as before).
WFDBX_TEST(output_file_high_level)
{
    DataDir d;
    std::vector<WFDB_Sample> x = {1, 2, 3, 4};
    write_record("hl", x, 2, 100, options());
    write_record("hl", x, 2, 100, options());   // (nothing is open)
    CHECK(read_record("hl").samples == x);
    CHECK(slurp("hl.dat").size() == 8);
}
