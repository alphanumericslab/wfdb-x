// test_files.cpp: unit tests of how the library finds files (WFDB-x): the
// input and output directories, the resolution of each kind of name, the
// files named in headers (in the header's directory), network access (against
// a local HTTP server on 127.0.0.1 only), the WFDB warning, the high-level
// input_dir and network options, legacy mode (the WFDB path, no network), and
// the files that the tools open themselves (wfdbx_input_path,
// wfdbx_output_path).  The expected values follow t_files and t_toolpaths in
// tests/reference/api_expect.c; the Python counterpart is
// python/tests/test_files.py.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It tests WFDB-x; it has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU Lesser General Public License as published by
// the Free Software Foundation, either version 2.1 of the License, or (at
// your option) any later version. See LICENSE.

#include "tests.hpp"
#include "http_server.hpp"

#include <wfdbx/ecgcodes.hpp>
#include <wfdbx/record.hpp>
#include <wfdbx/wfdb.hpp>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <mutex>
#include <random>
#include <string>
#include <thread>
#include <vector>
#if !defined(_WIN32)
#include <sys/wait.h>
#endif

using namespace wfdbx;
using wfdbx_tests::EnvVar;
#ifdef WFDBX_HAVE_SOCKETS
using wfdbx_tests::HttpServer;
using wfdbx_tests::have_curl;
#endif
namespace fs = std::filesystem;

namespace {

// Run the test in a fresh copy of tests/data (the current directory), with
// no input or output directory and network access forbidden.
struct DataDir {
    fs::path old, dir;
    DataDir() {
        old = fs::current_path();
        static int n = 0;
        dir = fs::temp_directory_path() /
              ("wfdbx-test-f-" + std::to_string(n++) + "-" +
               std::to_string(std::random_device{}()));
        fs::create_directories(dir);
        for (const auto &e : fs::directory_iterator(wfdbx_tests::data_dir()))
            if (e.is_regular_file())
                fs::copy_file(e.path(), dir / e.path().filename());
        dir = fs::canonical(dir);
        fs::current_path(dir);
        wfdbquit();
        wfdbx_set_input_dir(nullptr);
        wfdbx_set_output_dir(nullptr);
        wfdbx_set_network(0);
    }
    ~DataDir() {
        wfdbquit();
        wfdbx_set_input_dir(nullptr);
        wfdbx_set_output_dir(nullptr);
        wfdbx_set_network(0);
        setwfdb(".");
        fs::current_path(old);
        std::error_code ec;
        fs::remove_all(dir, ec);
    }
};

void put_file(const fs::path &name, const std::string &data)
{
    fs::create_directories(name.parent_path().empty() ? "." : name.parent_path());
    std::ofstream f(name, std::ios::binary);
    f << data;
}

int isig(const std::string &record)
{
    return isigopen(record.c_str(), nullptr, 8);
}

// getvec: the status followed by n samples.
std::vector<int> vec(int n)
{
    std::vector<WFDB_Sample> v(n + 8);
    int stat = getvec(v.data());
    std::vector<int> r{stat};
    r.insert(r.end(), v.begin(), v.begin() + n);
    return r;
}

std::optional<std::string> file(const char *type, const std::string &record)
{
    return wfdbfile(type, record.c_str());
}

const std::string single_dir_error =
    "setwfdb: WFDB-x reads from a single input directory; use "
    "wfdbx_set_input_dir (or legacy mode for the WFDB search path)\n";
const std::string not_in_dir = " is not in the header's directory\n";

// Legacy mode on for the lifetime of the object.
struct LegacyOn {
    LegacyOn() { wfdbx_set_legacy(1); }
    ~LegacyOn() { wfdbx_set_legacy(0); }
};


} // namespace

// ---------------------------------------------------------------------------
// Settings

WFDBX_TEST(files_settings)
{
    DataDir d;
    // the input directory
    CHECK(!wfdbx_get_input_dir());
    CHECK_EQ(getwfdb(), ".");
    CHECK(!wfdbx_set_input_dir("fsub"));
    CHECK(wfdbx_get_input_dir() == "fsub");
    CHECK_EQ(getwfdb(), "fsub");
    CHECK(wfdbx_set_input_dir("") == "fsub");
    CHECK(!wfdbx_get_input_dir());
    // the output directory (a URL is refused: the setting is unchanged, and
    // its value is returned)
    wfdbquiet();
    CHECK(!wfdbx_set_output_dir("http://127.0.0.1:1/out"));
    CHECK_EQ(wfdberror(), "wfdbx_set_output_dir: the output directory must "
                          "be a local directory\n");
    CHECK(!wfdbx_set_output_dir("odir3"));
    CHECK(wfdbx_set_output_dir("https://127.0.0.1:1/out") == "odir3");
    CHECK(wfdbx_get_output_dir() == "odir3");
    CHECK(wfdbx_set_output_dir(nullptr) == "odir3");
    CHECK(!wfdbx_get_output_dir());
    // network access
    CHECK_EQ(wfdbx_get_network(), 0);
    CHECK_EQ(wfdbx_set_network(1), 0);
    CHECK_EQ(wfdbx_get_network(), 1);
    CHECK_EQ(wfdbx_set_network(-1), 1);     // the default (WFDBX_NETWORK)
    int dflt = wfdbx_get_network();
    CHECK_EQ(wfdbx_set_network(0), dflt);
    // setwfdb, getwfdb and resetwfdb in normal mode
    setwfdb("fsub");
    CHECK(wfdbx_get_input_dir() == "fsub");
    setwfdb(" ;fsub2; ");
    CHECK(wfdbx_get_input_dir() == "fsub2");
    setwfdb("a b");
    CHECK_EQ(wfdberror(), single_dir_error);
    CHECK(wfdbx_get_input_dir() == "fsub2");
    setwfdb("a:b");
    CHECK(wfdbx_get_input_dir() == "fsub2");
    setwfdb("http://127.0.0.1:1/db");
    CHECK_EQ(getwfdb(), "http://127.0.0.1:1/db");
    setwfdb(";");
    CHECK(!wfdbx_get_input_dir());
    CHECK_EQ(getwfdb(), ".");
    setwfdb("fsub");
    wfdbx_set_input_dir("x");
    resetwfdb();
    CHECK(wfdbx_get_input_dir() == "fsub");
    wfdbx_set_input_dir("x");
    wfdbquit();     // (leaves the input directory as it is)
    CHECK(wfdbx_get_input_dir() == "x");
    setwfdb(nullptr);
    CHECK(!wfdbx_get_input_dir());
    wfdbverbose();
}

// The environment variables are read once per process, when first needed, so
// they are tested in a fresh process (this test program, running only
// files_fresh_process, with WFDBX_TEST_FRESH set).
WFDBX_TEST(files_environment)
{
#if defined(__linux__)
    std::string self = fs::read_symlink("/proc/self/exe").string();
    for (const char *mode : {"1", "2"}) {
        EnvVar fresh("WFDBX_TEST_FRESH", mode);
        EnvVar wfdb("WFDB", ".");
        EnvVar in("WFDBX_INPUT_DIR", "envin");
        EnvVar out("WFDBX_OUTPUT_DIR",
                   *mode == '1' ? "envout" : "http://127.0.0.1:1/out");
        EnvVar net("WFDBX_NETWORK", " 2");
        std::string cmd = "'" + self + "' files_fresh_process 2>/dev/null";
        CHECK_EQ(std::system(cmd.c_str()), 0);
    }
#endif
}

WFDBX_TEST(files_fresh_process)
{
    const char *mode = std::getenv("WFDBX_TEST_FRESH");
    if (!mode) return;
    wfdbquiet();
    if (*mode == '2') {
        // a URL in WFDBX_OUTPUT_DIR is refused (and ignored)
        CHECK(!wfdbx_get_output_dir());
        CHECK_EQ(wfdberror(), "wfdbx_set_output_dir: the output directory "
                              "must be a local directory\n");
        return;
    }
    // WFDB is ignored, with a warning (once)
    CHECK_EQ(getwfdb(), "envin");
    CHECK_EQ(wfdberror(), "WFDB-x: the WFDB environment variable is ignored; "
                          "set WFDBX_INPUT_DIR instead (or use legacy mode)\n");
    // a function call overrides an environment variable; nullptr or ""
    // restores its value
    CHECK(wfdbx_set_input_dir("x") == "envin");
    CHECK(wfdbx_set_input_dir(nullptr) == "x");
    CHECK(wfdbx_get_input_dir() == "envin");
    CHECK(wfdbx_get_output_dir() == "envout");
    CHECK(wfdbx_set_output_dir("o") == "envout");
    CHECK(wfdbx_set_output_dir("") == "o");
    CHECK(wfdbx_get_output_dir() == "envout");
    CHECK_EQ(wfdbx_get_network(), 1);   // (WFDBX_NETWORK=" 2")
    CHECK_EQ(wfdbx_set_network(0), 1);
    CHECK_EQ(wfdbx_set_network(-1), 0);
    CHECK_EQ(wfdbx_get_network(), 1);
    // network off: the open fails, with a message the first time only
    wfdbx_set_network(0);
    CHECK(!file("hea", "http://127.0.0.1:1/x"));
    const std::string off = "WFDB-x: network access is disabled; set "
        "WFDBX_NETWORK=1 or call wfdbx_set_network(1) to open "
        "http://127.0.0.1:1/x.hea\n";
    CHECK_EQ(wfdberror(), off);
    CHECK(!file("hea", "http://127.0.0.1:1/y"));
    CHECK_EQ(wfdberror(), off);
    // curl missing (a PATH without it)
    wfdbx_set_network(1);
    {
        EnvVar path("PATH", "/nonexistent-wfdbx");
        CHECK(!file("hea", "http://127.0.0.1:1/z"));
    }
    CHECK_EQ(wfdberror(), "WFDB-x: network access needs the curl program, "
                          "which was not found\n");
    // another URL scheme: the open fails, with a message the first time
    // only (with or without network access)
    CHECK(!file("hea", "ftp://h/x"));
    CHECK_EQ(wfdberror(), "WFDB-x: can't open ftp://h/x.hea: only http:// and "
                          "https:// URLs can be read (mount the server as a "
                          "local folder, or download the files)\n");
    wfdbx_set_network(0);
    wfdbx_set_output_dir("ftp://h/out");    // (another message)
    CHECK(!file("hea", "sftp://h/x"));
    CHECK_EQ(wfdberror(), "wfdbx_set_output_dir: the output directory must "
                          "be a local directory\n");
}

// ---------------------------------------------------------------------------
// Names

WFDBX_TEST(files_names)
{
    DataDir d;
    std::string cwd = d.dir.string();
    fs::create_directories("fsub/data");
    fs::copy_file("100s.dat", "fsub/sr.dat");
    fs::copy_file("100s.atr", "fsub/sr.atr");
    put_file("fsub/sr.hea", "sr 2 360 21600\n"
             "sr.dat 212 200 11 1024 995 21537 0 MLII\n"
             "sr.dat 212 200 11 1024 1011 -3962 0 V5\n");
    // a relative name, with no input directory: as given
    CHECK(file("hea", "100s") == "100s.hea");
    CHECK(file("hea", "fsub/sr") == "fsub/sr.hea");
    CHECK(file("hea", "fsub/../100s") == "fsub/../100s.hea");   // ".." allowed
    CHECK_EQ(isig("fsub/sr"), 2);
    CHECK(vec(2) == (std::vector<int>{2, 995, 1011}));
    wfdbquit();
    // the input directory: relative names only, nothing searched
    wfdbx_set_input_dir("fsub");
    CHECK_EQ(isig("sr"), 2);
    CHECK(vec(2) == (std::vector<int>{2, 995, 1011}));
    WFDB_Anninfo ai{"atr", WFDB_READ};
    CHECK_EQ(annopen("sr", &ai, 1), 0);
    WFDB_Annotation a;
    CHECK(getann(0, &a) == 0 && a.time == 18);
    CHECK(file("hea", "sr") == "fsub/sr.hea");
    CHECK(!file("hea", "100s"));    // (not searched)
    CHECK(wfdbfile("sr.dat", nullptr) == "fsub/sr.dat");
    CHECK(file("hea", cwd + "/100s") == cwd + "/100s.hea");    // absolute
    wfdbquit();
    CHECK(wfdbx_get_input_dir() == "fsub");     // (wfdbquit keeps it)
    wfdbx_set_input_dir("fsub/");   // (one separator)
    CHECK(file("hea", "sr") == "fsub/sr.hea");
    wfdbx_set_input_dir(cwd.c_str());
    CHECK(file("hea", "fsub/sr") == cwd + "/fsub/sr.hea");
    wfdbx_set_input_dir(nullptr);
    // "~" names (expanded with $HOME, and ~user)
    {
        EnvVar home("HOME", cwd.c_str());
        CHECK(file("hea", "~/100s") == cwd + "/100s.hea");
        CHECK_EQ(isig("~/fsub/sr"), 2);
        wfdbquit();
        CHECK(!file("hea", "~nosuchuser-wfdbx/100s"));
        wfdbx_set_input_dir("~/fsub");
        CHECK(file("hea", "sr") == cwd + "/fsub/sr.hea");
        wfdbx_set_input_dir(nullptr);
    }
    // the output directory: relative names only
    WFDB_Anninfo ao{"fx", WFDB_WRITE};
    a = WFDB_Annotation();
    a.anntyp = NORMAL;
    wfdbx_set_output_dir("odir3");
    CHECK_EQ(annopen("fsub/sr", &ao, 1), 0);
    putann(0, &a);
    CHECK_EQ(annopen((cwd + "/fsub/sr").c_str(), &ao, 1), 0);
    putann(0, &a);
    wfdbquit();
    CHECK(fs::exists("odir3/fsub/sr.fx") && fs::exists("fsub/sr.fx"));
    {
        EnvVar home("HOME", cwd.c_str());
        wfdbx_set_output_dir("~/odir4");
        CHECK_EQ(annopen("sr", &ao, 1), 0);
        putann(0, &a);
        wfdbquit();
        CHECK(fs::exists("odir4/sr.fx"));
    }
    // a URL cannot be written
    wfdbquiet();
    CHECK_EQ(annopen("http://127.0.0.1:1/sr", &ao, 1), -4);
    wfdbquit();
    wfdbverbose();
    wfdbx_set_output_dir(nullptr);
}

// ---------------------------------------------------------------------------
// Files named in headers

WFDBX_TEST(files_header_dir)
{
    DataDir d;
    fs::create_directories("fsub/data");
    fs::copy_file("fmt16.dat", "fsub/data/a.dat");
    put_file("fsub/dd.hea", "dd 1 360 10\ndata/a.dat 16 200 12 0 0 0 0 s\n");
    // relative to the header's directory
    CHECK_EQ(isig("fsub/dd"), 1);
    CHECK(vec(1) == (std::vector<int>{1, -7}));
    CHECK(vec(1) == (std::vector<int>{1, 32}));
    CHECK(vec(1) == (std::vector<int>{1, -33}));
    wfdbquit();
    // not in the header's directory: refused (the other group still opens)
    wfdbquiet();
    for (const char *bad : {"../100s.dat", "/100s.dat", "~/100s.dat",
                            "http://127.0.0.1:1/100s.dat", "ftp://h/100s.dat",
                            "data/../../100s.dat", ".."}) {
        put_file("fsub/bad.hea", std::string("bad 2 360 10\n") + bad +
                 " 16\ndata/a.dat 16\n");
        CHECK_EQ(isig("fsub/bad"), 1);
        CHECK_EQ(wfdberror(), std::string("init: file ") + bad +
                 " named in the header of record fsub/bad" + not_in_dir);
        wfdbquit();
    }
    put_file("fsub/ok.hea", "ok 1 360 10\nx..y.dat 16\n");
    fs::copy_file("fmt16.dat", "fsub/x..y.dat");
    CHECK_EQ(isig("fsub/ok"), 1);
    wfdbquit();
    // segments: a null segment ("~"), and a segment outside the directory
    put_file("fsub/ms.hea", "ms/3 1 360 20\nms_0 0\n~ 10\ndd 10\n");
    put_file("fsub/ms_0.hea", "ms_0 1 360 0\n~ 0 200 12 0 0 0 0 s\n");
    CHECK_EQ(isig("fsub/ms"), 1);
    std::vector<std::vector<int>> v;
    for (int i = 0; i < 12; i++) v.push_back(vec(1));
    CHECK(v[0] == (std::vector<int>{1, -32768}));
    CHECK(v[9] == (std::vector<int>{1, -32768}));
    CHECK(v[10] == (std::vector<int>{1, -7}));
    CHECK(v[11] == (std::vector<int>{1, 32}));
    wfdbquit();
    put_file("fsub/ms2.hea", "ms2/2 1 360 20\ndd 10\n../fsub/dd 10\n");
    CHECK_EQ(isig("fsub/ms2"), 1);
    CHECK_EQ(isigsettime(10), -1);
    wfdbquit();
    // in legacy mode, as in C: searched for in the WFDB path
    {
        LegacyOn legacy;
        setwfdb(". fsub");
        CHECK_EQ(isig("dd"), 1);
        CHECK(!file("hea", "fsub/../100s"));   // ".." refused
        wfdbquit();
        setwfdb(".");
    }
    wfdbverbose();
}

// ---------------------------------------------------------------------------
// Network access (a local server)

WFDBX_TEST(files_network)
{
#ifdef WFDBX_HAVE_SOCKETS
    if (!have_curl()) {
        std::fprintf(stderr, "(curl not found: files_network skipped)\n");
        return;
    }
    DataDir d;
    EnvVar np("NO_PROXY", "127.0.0.1,localhost");
    EnvVar np2("no_proxy", "127.0.0.1,localhost");
    fs::create_directories("www/sub/data");
    for (const char *f : {"100s.hea", "100s.dat", "100s.atr"})
        fs::copy_file(f, fs::path("www") / f);
    fs::copy_file("fmt16.dat", "www/sub/data/a.dat");
    put_file("www/sub/dd.hea", "dd 1 360 10\ndata/a.dat 16 200 12 0 0 0 0 s\n");
    put_file("www/sub/bad.hea", "bad 1 360 10\n../100s.dat 212\n");
    HttpServer server(d.dir / "www");
    REQUIRE(server.ok());
    const std::string url = server.url();
    wfdbquiet();
    // network off: nothing is requested
    CHECK(!file("hea", url + "100s"));
    CHECK(server.requests().empty());
    // network on
    CHECK_EQ(wfdbx_set_network(1), 0);
    CHECK_EQ(isig(url + "100s"), 2);
    CHECK(vec(2) == (std::vector<int>{2, 995, 1011}));
    WFDB_Anninfo ai{"atr", WFDB_READ};
    CHECK_EQ(annopen((url + "100s").c_str(), &ai, 1), 0);
    WFDB_Annotation a;
    CHECK(getann(0, &a) == 0 && a.time == 18 && a.anntyp == RHYTHM);
    wfdbquit();
    CHECK(file("hea", url + "100s") == url + "100s.hea");
    // a file read is requested once (it is kept); a failure is not kept,
    // and is requested again
    CHECK_EQ(server.count("/100s.hea"), 1u);
    CHECK_EQ(server.count("/100s.dat"), 1u);
    CHECK(!file("hea", url + "nosuch"));
    CHECK(!file("hea", url + "nosuch"));
    CHECK_EQ(server.count("/nosuch.hea"), 2u);
    // a URL input directory; a header naming data/a.dat; containment
    wfdbx_set_input_dir((url + "sub").c_str());     // (one '/' is added)
    CHECK_EQ(isig("dd"), 1);
    CHECK(vec(1) == (std::vector<int>{1, -7}));
    wfdbquit();
    CHECK_EQ(server.count("/sub/data/a.dat"), 1u);
    CHECK(isig("bad") <= 0);
    CHECK_EQ(wfdberror(), "isigopen: none of the signals for record bad is "
                          "readable\n");
    CHECK_EQ(server.count("/100s.dat"), 1u);    // (not requested again)
    wfdbquit();
    wfdbx_set_input_dir(nullptr);
    // redirections are followed (the files named in the header are then
    // requested under the URL given)
    CHECK_EQ(isig(url + "redir/100s"), 2);
    CHECK(vec(2) == (std::vector<int>{2, 995, 1011}));
    wfdbquit();
    CHECK_EQ(server.count("/redir/100s.dat"), 1u);
    // the high-level options
    wfdbx_set_network(0);
    wfdbx_set_input_dir("prev");
    ReadOptions opt;
    opt.input_dir = url;
    opt.network = true;
    opt.to = 10;
    Record rec = read_record("100s", opt);
    CHECK(rec.nsamples() == 10 && rec.at(0, 0) == 995);
    CHECK(wfdbx_get_input_dir() == "prev" && wfdbx_get_network() == 0);
    InputOptions in;
    in.input_dir = url;
    in.network = true;
    CHECK(read_header("100s", false, in).siginfo.size() == 2);
    CHECK(read_annotations("100s", "atr", {}, {}, std::nullopt, false, in)
              .size() == 75);
    CHECK(wfdbx_get_input_dir() == "prev" && wfdbx_get_network() == 0);
    bool thrown = false;
    try {
        read_record("nosuch", opt);
    } catch (const Error &) {
        thrown = true;
    }
    CHECK(thrown);
    CHECK(wfdbx_get_input_dir() == "prev" && wfdbx_get_network() == 0);
    opt.network = false;    // (forbidden for the call)
    thrown = false;
    try {
        read_record("100s", opt);
    } catch (const Error &) {
        thrown = true;
    }
    CHECK(thrown);
    wfdbx_set_input_dir(nullptr);
    // legacy mode: no network access at all
    {
        LegacyOn legacy;
        wfdbx_set_network(1);
        size_t n = server.requests().size();
        CHECK(!file("hea", url + "100s"));
        CHECK(server.requests().size() == n);
        wfdbx_set_network(0);
    }
    wfdbverbose();
#endif
}

// ---------------------------------------------------------------------------
// Other URL schemes

// A name with a URL scheme other than http:// and https:// is refused, with
// or without network access, and is never opened as a local name: ftp:/h
// (the local path that the name ftp://h/... would designate) is not read.
// (The message, printed the first time, is tested in files_fresh_process.)
WFDBX_TEST(files_other_schemes)
{
#if !defined(_WIN32)    // (':' cannot be in a file name)
    DataDir d;
    using O = std::optional<std::string>;
    for (const char *dir : {"ftp:/h", "c:"}) {
        fs::create_directories(dir);
        for (const char *f : {"100s.hea", "100s.dat"})
            fs::copy_file(f, fs::path(dir) / f);
    }
    wfdbquiet();
    wfdbx_set_network(1);
    CHECK_EQ(isig("ftp://h/100s"), -1);
    CHECK_EQ(wfdberror(), "init: can't open header for record ftp://h/100s\n");
    CHECK_EQ(isig("sftp://h/100s"), -1);
    CHECK(!wfdbx_input_path("ftp://h/100s.hea"));
    CHECK(!wfdbx_output_path("ftp://h/x.wav"));
    CHECK(!fs::exists("ftp:/h/x.wav"));
    CHECK(!wfdbx_set_input_dir("ftp://h"));
    CHECK_EQ(isig("100s"), -1);
    CHECK(!wfdbx_input_path("100s.hea"));
    wfdbx_set_input_dir(nullptr);
    wfdbx_set_network(0);
    CHECK_EQ(isig("ftp://h/100s"), -1);
    // an output directory with a URL scheme is refused
    CHECK(!wfdbx_set_output_dir("ftp://h/out"));
    CHECK_EQ(wfdberror(), "wfdbx_set_output_dir: the output directory must "
                          "be a local directory\n");
    CHECK(!wfdbx_get_output_dir());
    // a one-letter prefix is not a scheme (a local directory c:)
    CHECK_EQ(isig("c://100s"), 2);
    wfdbquit();
    CHECK(wfdbx_input_path("c://a.txt") == O("c://a.txt"));
    // legacy mode refuses every name containing ://
    {
        LegacyOn legacy;
        CHECK_EQ(isig("ftp://h/100s"), -1);
        CHECK_EQ(wfdberror(),
                 "init: can't open header for record ftp://h/100s\n");
    }
    wfdbverbose();
#endif
}

// ---------------------------------------------------------------------------
// The high-level input_dir option (local)

WFDBX_TEST(files_high_level_input_dir)
{
    DataDir d;
    fs::create_directories("fsub");
    fs::copy_file("100s.dat", "fsub/100s.dat");
    fs::copy_file("100s.hea", "fsub/100s.hea");
    fs::copy_file("100s.atr", "fsub/100s.atr");
    fs::remove("100s.hea");
    ReadOptions opt;
    opt.input_dir = "fsub";
    opt.to = 5;
    CHECK(read_record("100s", opt).nsamples() == 5);
    CHECK(!wfdbx_get_input_dir());
    InputOptions in;
    in.input_dir = "fsub";
    CHECK(read_annotations("100s", "atr", {}, {}, std::nullopt, false, in)
              .fs == 360);
    CHECK(!wfdbx_get_input_dir());
    // "": the default for the call
    wfdbx_set_input_dir("fsub");
    wfdbquiet();
    in.input_dir = "";
    bool thrown = false;
    try {
        read_header("100s", false, in);
    } catch (const Error &) {
        thrown = true;
    }
    wfdbverbose();
    CHECK(thrown);
    CHECK(wfdbx_get_input_dir() == "fsub");
    // legacy mode: the input directory is not used (the WFDB path is)
    opt.legacy = true;
    wfdbquiet();
    thrown = false;
    try {
        read_record("100s", opt);
    } catch (const Error &) {
        thrown = true;
    }
    wfdbverbose();
    CHECK(thrown);
    CHECK(wfdbx_get_input_dir() == "fsub");
}

// ---------------------------------------------------------------------------
// The files that a program opens itself (the Python counterparts are
// test_tool_file_paths and test_tool_files)

// wfdbx_input_path and wfdbx_output_path: where a program opens the files
// that it reads or creates itself (the counterparts of the files of
// wfdb_open with an empty file type).
WFDBX_TEST(files_tool_file_paths)
{
    DataDir d;
    using O = std::optional<std::string>;
    const std::string cwd = d.dir.string();
    EnvVar home_env("HOME", (cwd + "/home").c_str());
    const std::string home = cwd + "/home";
    // no directories set: names as given (~ expanded), URLs refused
    for (auto f : {wfdbx_input_path, wfdbx_output_path}) {
        CHECK(f("a.txt") == O("a.txt"));
        CHECK(f("sub/a.txt") == O("sub/a.txt"));
        CHECK(f((cwd + "/a.txt").c_str()) == cwd + "/a.txt");
        CHECK(f("~/a.txt") == home + "/a.txt");
        CHECK(f("-") == O("-") && f("") == O("") && !f(nullptr));
        CHECK(!f("http://127.0.0.1:1/a.txt"));
        CHECK(!f("https://127.0.0.1:1/a.txt"));
    }
    CHECK(!fs::exists("sub"));
    // the input directory
    wfdbx_set_input_dir("sub");
    CHECK(wfdbx_input_path("a.txt") == O("sub/a.txt"));
    CHECK(wfdbx_input_path("../a.txt") == O("sub/../a.txt"));
    CHECK(wfdbx_input_path((cwd + "/a.txt").c_str()) == cwd + "/a.txt");
    CHECK(wfdbx_input_path("~/a.txt") == home + "/a.txt");
    CHECK(wfdbx_input_path("-") == O("-"));
    CHECK(wfdbx_output_path("a.txt") == O("a.txt"));
    wfdbx_set_input_dir("~/in/");
    CHECK(wfdbx_input_path("a.txt") == home + "/in/a.txt");
    wfdbx_set_input_dir("http://127.0.0.1:1/d");
    CHECK(!wfdbx_input_path("a.txt"));      // (a URL)
    CHECK(wfdbx_input_path((cwd + "/a.txt").c_str()) == cwd + "/a.txt");
    wfdbx_set_input_dir(nullptr);
    // the output directory: its missing directories are created
    wfdbx_set_output_dir("out/deep");
    CHECK(wfdbx_output_path("a.wav") == O("out/deep/a.wav"));
    CHECK(fs::is_directory("out/deep") && fs::is_empty("out/deep"));
    CHECK(wfdbx_output_path("s/a.wav") == O("out/deep/s/a.wav"));
    CHECK(fs::is_directory("out/deep/s"));
    CHECK(wfdbx_output_path((cwd + "/n/a.wav").c_str()) == cwd + "/n/a.wav");
    CHECK(wfdbx_output_path("~/m/a.wav") == home + "/m/a.wav");
    CHECK(!fs::exists("n") && !fs::exists("home/m"));
    CHECK(wfdbx_output_path("-") == O("-"));
    CHECK(wfdbx_input_path("a.txt") == O("a.txt"));
    wfdbx_set_output_dir("~/o");
    CHECK(wfdbx_output_path("a.wav") == home + "/o/a.wav");
    CHECK(fs::is_directory("home/o"));
    // legacy mode: inputs as named; the output directory as a plain prefix
    {
        LegacyOn legacy;
        wfdbx_set_input_dir("sub");
        wfdbx_set_output_dir("lout");
        CHECK(wfdbx_input_path("a.txt") == O("a.txt"));
        CHECK(wfdbx_input_path("~/a.txt") == O("~/a.txt"));
        CHECK(!wfdbx_input_path("http://127.0.0.1:1/a.txt"));
        CHECK(wfdbx_output_path("a.wav") == O("lout/a.wav"));
        CHECK(wfdbx_output_path((cwd + "/a.wav").c_str()) ==
              "lout/" + cwd + "/a.wav");
        CHECK(fs::is_directory("lout" + cwd));
        CHECK(wfdbx_output_path("~/a.wav") == O("lout/~/a.wav"));
        CHECK(wfdbx_output_path("-") == O("-"));
        wfdbx_set_output_dir(nullptr);
        CHECK(wfdbx_output_path("a.wav") == O("a.wav"));
        CHECK(wfdbx_output_path("~/a.wav") == O("~/a.wav"));
        wfdbx_set_input_dir(nullptr);
    }
}

#if defined(WFDBX_TOOLS_DIR) && !defined(_WIN32)
namespace {

// Run a tool built with the library (in the current directory, with the
// given settings of WFDBX_INPUT_DIR and WFDBX_OUTPUT_DIR, and without WFDB
// and WFDBX_NETWORK); return its exit status.
int tool(const std::string &args, const char *input_dir,
         const char *output_dir)
{
    EnvVar wfdb("WFDB", nullptr);
    EnvVar net("WFDBX_NETWORK", nullptr);
    EnvVar in("WFDBX_INPUT_DIR", input_dir);
    EnvVar out("WFDBX_OUTPUT_DIR", output_dir);
    std::string cmd = std::string("'") + WFDBX_TOOLS_DIR + "/" + args +
                      " >/dev/null 2>&1";
    int stat = std::system(cmd.c_str());
    return WIFEXITED(stat) ? WEXITSTATUS(stat) : -1;
}

std::vector<std::string> list_dir(const fs::path &dir)
{
    std::vector<std::string> v;
    for (const auto &e : fs::directory_iterator(dir))
        v.push_back(e.path().filename().string());
    std::sort(v.begin(), v.end());
    return v;
}

} // namespace

// The tools read and create their own files under the input and output
// directories (see the toolfiles-* cases of the conformance suite).
WFDBX_TEST(files_tool_files)
{
    DataDir d;
    std::string text;
    for (int i = 0; i < 50; i++)
        text += std::to_string(i) + " " + std::to_string(-i) + "\n";
    put_file("sub/in.txt", text);
    CHECK_EQ(tool("wrsamp' -i in.txt -o w1 -F 250 -G 200 -R 16 -U mV", "sub",
                  "out"), 0);
    CHECK(fs::exists("out/w1.hea") && fs::exists("out/w1.dat"));
    const std::vector<std::string> before = list_dir(".");
    CHECK_EQ(tool("mit2wav' -r 100s -o x.wav", nullptr, "out"), 0);
    CHECK_EQ(tool("mit2edf' -r fmt16 -o x.edf", nullptr, "out"), 0);
    CHECK(list_dir(".") == before);         // nothing in .
    std::ifstream f("out/x.wav", std::ios::binary);
    std::string wav((std::istreambuf_iterator<char>(f)), {});
    CHECK(wav.compare(0, 4, "RIFF") == 0 && wav.size() == 44 + 2 * 2 * 21600);
    CHECK(fs::exists("out/x.edf") && fs::file_size("out/x.edf") > 0);
}
#endif
