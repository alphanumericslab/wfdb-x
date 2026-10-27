// test_files.cpp: unit tests of how the library finds files (wfdb-x): the
// input and output directories, the resolution of each kind of name, the
// files named in headers (in the header's directory), network access (against
// a local HTTP server on 127.0.0.1 only), the WFDB warning, the high-level
// input_dir and network options, and legacy mode (the WFDB path, no network).
// The expected values follow t_files in tests/reference/api_expect.c; the
// Python counterpart is python/tests/test_files.py.
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

#if defined(__unix__) || defined(__APPLE__)
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#define WFDBX_HAVE_SOCKETS 1
#endif

using namespace wfdbx;
using wfdbx_tests::EnvVar;
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

std::string slurp(const fs::path &name)
{
    std::ifstream f(name, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(f), {});
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
    "setwfdb: wfdb-x reads from a single input directory; use "
    "wfdbx_set_input_dir (or legacy mode for the WFDB search path)\n";
const std::string not_in_dir = " is not in the header's directory\n";

// Legacy mode on for the lifetime of the object.
struct LegacyOn {
    LegacyOn() { wfdbx_set_legacy(1); }
    ~LegacyOn() { wfdbx_set_legacy(0); }
};

#ifdef WFDBX_HAVE_SOCKETS
// A minimal HTTP server on 127.0.0.1 (a free port), serving the files of a
// directory: GET /NAME returns the file NAME (404 if there is none), and
// GET /redir/NAME redirects to /NAME.  The paths requested are logged.
class HttpServer {
public:
    explicit HttpServer(fs::path root) : root_(std::move(root)) {
        fd_ = socket(AF_INET, SOCK_STREAM, 0);
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        a.sin_port = 0;
        socklen_t len = sizeof(a);
        if (fd_ < 0 || bind(fd_, reinterpret_cast<sockaddr *>(&a), len) != 0 ||
            listen(fd_, 16) != 0 ||
            getsockname(fd_, reinterpret_cast<sockaddr *>(&a), &len) != 0) {
            ok_ = false;
            return;
        }
        port_ = ntohs(a.sin_port);
        thread_ = std::thread([this] { serve(); });
    }
    ~HttpServer() {
        stop_ = true;
        if (fd_ >= 0) {
            shutdown(fd_, SHUT_RDWR);   // (wakes up accept)
            close(fd_);
        }
        if (thread_.joinable()) thread_.join();
    }
    bool ok() const { return ok_; }
    std::string url() const {
        return "http://127.0.0.1:" + std::to_string(port_) + "/";
    }
    std::vector<std::string> requests() {
        std::lock_guard<std::mutex> lock(mutex_);
        return log_;
    }
    size_t count(const std::string &path) {
        size_t n = 0;
        for (const std::string &p : requests()) n += (p == path);
        return n;
    }

private:
    void serve() {
        while (!stop_) {
            int c = accept(fd_, nullptr, nullptr);
            if (c < 0) {
                if (stop_) return;
                continue;
            }
            std::string req;
            char buf[4096];
            ssize_t n;
            while (req.find("\r\n\r\n") == std::string::npos &&
                   (n = recv(c, buf, sizeof(buf), 0)) > 0)
                req.append(buf, n);
            std::string path;
            size_t sp = req.find(' ');
            if (sp != std::string::npos)
                path = req.substr(sp + 1, req.find(' ', sp + 1) - sp - 1);
            {
                std::lock_guard<std::mutex> lock(mutex_);
                log_.push_back(path);
            }
            std::string resp;
            std::error_code ec;
            if (path.compare(0, 7, "/redir/") == 0)
                resp = "HTTP/1.0 302 Found\r\nLocation: " + path.substr(6) +
                       "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
            else if (path.size() > 1 && path.find("..") == std::string::npos &&
                     fs::is_regular_file(root_ / path.substr(1), ec)) {
                std::string body = slurp(root_ / path.substr(1));
                resp = "HTTP/1.0 200 OK\r\nContent-Length: " +
                       std::to_string(body.size()) +
                       "\r\nConnection: close\r\n\r\n" + body;
            } else
                resp = "HTTP/1.0 404 Not Found\r\nContent-Length: 0\r\n"
                       "Connection: close\r\n\r\n";
            for (size_t off = 0; off < resp.size();) {
                ssize_t w = send(c, resp.data() + off, resp.size() - off, 0);
                if (w <= 0) break;
                off += static_cast<size_t>(w);
            }
            close(c);
        }
    }

    fs::path root_;
    int fd_ = -1;
    int port_ = 0;
    bool ok_ = true;
    std::atomic<bool> stop_{false};
    std::thread thread_;
    std::mutex mutex_;
    std::vector<std::string> log_;
};

bool have_curl()
{
    return std::system("curl --version >/dev/null 2>&1") == 0;
}
#endif

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
    CHECK_EQ(wfdberror(), "wfdb-x: the WFDB environment variable is ignored; "
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
    const std::string off = "wfdb-x: network access is disabled; set "
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
    CHECK_EQ(wfdberror(), "wfdb-x: network access needs the curl program, "
                          "which was not found\n");
    wfdbx_set_network(0);
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
                            "http://127.0.0.1:1/100s.dat",
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
    // each URL is requested once (successes and failures are cached)
    CHECK_EQ(server.count("/100s.hea"), 1u);
    CHECK_EQ(server.count("/100s.dat"), 1u);
    CHECK(!file("hea", url + "nosuch"));
    CHECK(!file("hea", url + "nosuch"));
    CHECK_EQ(server.count("/nosuch.hea"), 1u);
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
