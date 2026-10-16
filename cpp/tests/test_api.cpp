// test_api.cpp: unit tests of the library API and the high-level interface
// (the C++ counterparts of python/tests/test_signals.py, test_time.py, and
// test_annotations.py)
//
// Part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

#include "tests.hpp"

#include <wfdbx/ecgmap.hpp>
#include <wfdbx/record.hpp>
#include <wfdbx/wfdb.hpp>

#include <cmath>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <iterator>
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
// No default sampling frequency or gain (wfdb-x divergence; see
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

// No built-in ADC resolution or units (wfdb-x divergence, round 2).
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
    std::vector<WFDB_Siginfo> si = read_header("r");
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
    std::vector<WFDB_Siginfo> si = read_header("nr");
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
    CHECK_EQ(read_header("nr")[1].adcres, 0);
    CHECK_EQ(read_header("nr", true)[1].adcres, 12);
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
