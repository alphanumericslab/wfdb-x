// test_metadata.cpp: unit tests of the header metadata functions
// (read_metadata, get_metadata, set_metadata, remove_metadata,
// update_metadata) and of the metadata of read_header and write_record.  The
// Python counterpart is python/tests/test_metadata.py.
//
// The shared cases (tests/metadata/cases.tsv, with the headers expected in
// tests/metadata/expected/) are run by every implementation of WFDB-x, which
// must give the same results and write byte-identical headers.  A URL is
// served by a local HTTP server (127.0.0.1 only).
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

#include <wfdbx/record.hpp>
#include <wfdbx/wfdb.hpp>

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <random>
#include <sstream>
#include <string>
#include <vector>

using namespace wfdbx;
using wfdbx_tests::EnvVar;
using wfdbx_tests::StderrCapture;
namespace fs = std::filesystem;

namespace {

// The directory of the shared cases (tests/metadata).
fs::path meta_dir()
{
    return fs::path(wfdbx_tests::data_dir()).parent_path() / "metadata";
}

// The library's input settings at their defaults (no input or output
// directory, network access forbidden).
void default_settings()
{
    wfdbquit();
    wfdbx_set_input_dir(nullptr);
    wfdbx_set_output_dir(nullptr);
    wfdbx_set_network(0);
}

// A new empty temporary directory, the current directory for the lifetime of
// the object, with the default settings.
struct CleanDir {
    fs::path old, dir;
    CleanDir() {
        old = fs::current_path();
        static int n = 0;
        dir = fs::temp_directory_path() /
              ("wfdbx-test-m-" + std::to_string(n++) + "-" +
               std::to_string(std::random_device{}()));
        fs::create_directories(dir);
        dir = fs::canonical(dir);
        fs::current_path(dir);
        default_settings();
    }
    ~CleanDir() {
        default_settings();
        wfdbverbose();
        fs::current_path(old);
        std::error_code ec;
        fs::remove_all(dir, ec);
    }
    // The names of the entries of the directory, sorted.
    std::vector<std::string> list(const fs::path &sub = ".") const {
        std::vector<std::string> v;
        for (const auto &e : fs::directory_iterator(dir / sub))
            v.push_back(e.path().filename().string());
        std::sort(v.begin(), v.end());
        return v;
    }
};

std::string slurp(const fs::path &name)
{
    std::ifstream f(name, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(f), {});
}

void put_file(const fs::path &name, const std::string &data)
{
    std::ofstream f(name, std::ios::binary);
    f << data;
}

// Copy the header NAME.hea of tests/metadata/headers into the directory d;
// returns the record name d/NAME.
std::string copy_header(const std::string &name, const fs::path &d)
{
    fs::copy_file(meta_dir() / "headers" / (name + ".hea"),
                  d / (name + ".hea"), fs::copy_options::overwrite_existing);
    return (d / name).string();
}

size_t count(const std::string &s, const std::string &what)
{
    size_t n = 0;
    for (size_t p = s.find(what); p != std::string::npos;
         p = s.find(what, p + 1))
        n++;
    return n;
}

const std::string dup_warning = "WFDB-x: header of record ";

// ---------------------------------------------------------------------------
// cases.tsv

// A string of cases.tsv: "x" and its bytes in hexadecimal, or "-" (none).
std::optional<std::string> unhex(const std::string &s)
{
    if (s == "-") return std::nullopt;
    if (s.empty() || s[0] != 'x')
        throw std::runtime_error("bad string in cases.tsv: " + s);
    std::string out;
    for (size_t i = 1; i + 1 < s.size(); i += 2)
        out += static_cast<char>(std::stoi(s.substr(i, 2), nullptr, 16));
    return out;
}

// A list of KEY:VALUE pairs separated by commas (empty for none).
MetadataChanges pairs(const std::string &s)
{
    MetadataChanges out;
    if (s.empty()) return out;
    std::stringstream ss(s);
    std::string item;
    while (std::getline(ss, item, ',')) {
        size_t c = item.find(':');
        out.emplace_back(*unhex(item.substr(0, c)), unhex(item.substr(c + 1)));
    }
    return out;
}

struct Case {
    std::string name, header, op, key, value, changes, error, warnings,
        result, output;
};

std::vector<Case> read_cases()
{
    std::vector<Case> cases;
    std::ifstream f(meta_dir() / "cases.tsv", std::ios::binary);
    std::string line;
    while (std::getline(f, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::vector<std::string> col;
        size_t p = 0;
        while (true) {
            size_t t = line.find('\t', p);
            col.push_back(line.substr(p, t == std::string::npos ? t : t - p));
            if (t == std::string::npos) break;
            p = t + 1;
        }
        if (col.size() != 10)
            throw std::runtime_error("bad line in cases.tsv: " + line);
        cases.push_back({col[0], col[1], col[2], col[3], col[4], col[5],
                         col[6], col[7], col[8], col[9]});
    }
    return cases;
}

void report(const Case &c, const std::string &what)
{
    wfdbx_tests::fail(__FILE__, __LINE__, "case " + c.name + ": " + what);
}

// Run one shared case in a fresh directory.
void run_case(const Case &c)
{
    CleanDir d;
    const std::string rec = copy_header(c.header, d.dir);
    const fs::path hea = rec + ".hea";
    const std::string before = slurp(hea);
    std::string error = "-";
    std::string result = "-";
    std::string err;
    {
        wfdbverbose();
        StderrCapture capture;
        try {
            if (c.op == "read") {
                Metadata m = read_metadata(rec);
                MetadataChanges e(m.begin(), m.end());
                result = c.result;
                if (e != pairs(c.result)) report(c, "entries differ");
            } else if (c.op == "get") {
                std::optional<std::string> v = get_metadata(rec, *unhex(c.key));
                result = c.result;
                if (v != unhex(c.result)) report(c, "value differs");
            } else if (c.op == "set") {
                set_metadata(rec, *unhex(c.key), *unhex(c.value));
            } else if (c.op == "remove") {
                result = std::to_string(remove_metadata(rec, *unhex(c.key)));
            } else if (c.op == "update") {
                update_metadata(rec, pairs(c.changes));
            } else
                report(c, "unknown operation " + c.op);
        } catch (const ArgumentError &) {
            error = "argument";
        } catch (const FileError &) {
            error = "file";
        }
        err = capture.text();
    }
    if (error != c.error) report(c, "error " + error + ", expected " + c.error);
    if (error == "-" && result != c.result)
        report(c, "result " + result + ", expected " + c.result);
    if (std::to_string(count(err, dup_warning)) != c.warnings)
        report(c, std::to_string(count(err, dup_warning)) + " warning(s), "
                  "expected " + c.warnings);
    const std::string after = slurp(hea);
    if (c.output != "-") {
        if (after != slurp(meta_dir() / c.output))
            report(c, "header differs from " + c.output);
    } else if (after != before)
        report(c, "header changed");
    // no temporary file is left behind
    if (d.list() != std::vector<std::string>{c.header + ".hea"})
        report(c, "other files in the directory");
}

WriteOptions write_options()
{
    WriteOptions w;
    w.gains = {200};
    w.adcres = {12};
    w.units = {"mV"};
    return w;
}

} // namespace

// ---------------------------------------------------------------------------
// The shared cases

WFDBX_TEST(metadata_shared_cases)
{
    if (!fs::is_directory(meta_dir())) {
        std::fprintf(stderr, "(tests/metadata not found: "
                             "metadata_shared_cases skipped)\n");
        return;
    }
    std::vector<Case> cases = read_cases();
    CHECK_EQ(cases.size(), size_t(56));
    for (const Case &c : cases) run_case(c);
}

// ---------------------------------------------------------------------------
// read_header and write_record

WFDBX_TEST(metadata_read_header_and_write_record)
{
    CleanDir d;
    std::vector<WFDB_Sample> x(10, 0);
    WriteOptions w = write_options();
    w.comments = {"a comment", "Site: B"};
    w.metadata = {{"Age", " 63 "}, {"Notes", ""}};
    write_record("w", x, 1, 100, w);
    const std::string data = slurp("w.hea");
    const std::string tail = "#a comment\r\n#Site: B\r\n# Age: 63\r\n"
                             "# Notes:\r\n";
    REQUIRE(data.size() > tail.size());
    CHECK_EQ(data.substr(data.size() - tail.size()), tail);
    Header h = read_header("w");
    CHECK(h.metadata == (Metadata{{"Site", "B"}, {"Age", "63"}, {"Notes", ""}}));
    CHECK(h.comments == (std::vector<std::string>{"a comment", "Site: B",
                                                  " Age: 63", " Notes:"}));
    WriteOptions v = write_options();
    v.metadata = {{"Dx", "426783006"}};
    write_record_physical("v", std::vector<double>(10, 0.0), 1, 100, v);
    CHECK(read_metadata("v") == (Metadata{{"Dx", "426783006"}}));
    // the duplicate-key warning of read_header
    copy_header("dups", d.dir);
    StderrCapture capture;
    Header hd = read_header("dups");
    CHECK_EQ(count(capture.text(), dup_warning), size_t(1));
    CHECK(hd.metadata == (Metadata{{"age", "40"}, {"Sex", "M"},
                                   {"Height", "180"}}));
}

// A record without a .hea file (EDF) is read as before, with no metadata.
WFDBX_TEST(metadata_read_header_edf)
{
    CleanDir d;
    fs::copy_file(fs::path(wfdbx_tests::data_dir()) / "100s.edf", "100s.edf");
    Header h = read_header("100s.edf");
    // (opening an EDF file sets the output annotation frequency, if none is
    // set, as in C; it is reset for the tests that follow)
    setafreq(0.0);
    CHECK_EQ(h.nsig, 2);
    CHECK(h.metadata.empty());
    fs::copy_file(fs::path(wfdbx_tests::data_dir()) / "fmt16.edf", "fmt16.edf");
    Header f = read_header("fmt16.edf");
    setafreq(0.0);
    CHECK(f.nsig > 0);
    CHECK(f.metadata.empty());
}

// A header read from the standard input ("-") has no metadata, and no error
// is raised.
WFDBX_TEST(metadata_read_header_stdin)
{
#if !defined(_WIN32)
    CleanDir d;
    copy_header("basic", d.dir);
    std::FILE *in = std::freopen("basic.hea", "rb", stdin);
    REQUIRE(in != nullptr);
    wfdbquiet();    // (the header names the record "basic", not "-")
    Header h = read_header("-");
    CHECK(h.nsig > 0);
    CHECK(h.metadata.empty());
    CHECK(std::freopen("/dev/null", "rb", stdin) != nullptr);
#endif
}

WFDBX_TEST(metadata_write_record_errors)
{
    CleanDir d;
    std::vector<WFDB_Sample> x(10, 0);
    const std::vector<Metadata> bad = {
        {{"a:b", "1"}}, {{"Age", "1\n2"}}, {{"Age", "1"}, {"AGE", "2"}},
        {{"", "x"}}, {{"#a", "x"}}, {{"Age", std::string("1\0", 2)}}};
    for (const Metadata &m : bad) {
        WriteOptions w = write_options();
        w.metadata = m;
        bool thrown = false;
        try {
            write_record("e", x, 1, 100, w);
        } catch (const ArgumentError &e) {
            thrown = true;
            CHECK(std::string(e.what()).compare(0, 14, "write_record: ") == 0);
        }
        CHECK(thrown);
    }
    WriteOptions w = write_options();
    w.comments = {"age: 1"};
    w.metadata = {{"Age", "2"}};
    bool thrown = false;
    try {
        write_record("e", x, 1, 100, w);
    } catch (const ArgumentError &e) {
        thrown = true;
        CHECK_EQ(std::string(e.what()),
                 "write_record: metadata key 'age' is also given in comments");
    }
    CHECK(thrown);
    CHECK(d.list().empty());    // nothing was written
}

// ---------------------------------------------------------------------------
// Files

WFDBX_TEST(metadata_info_file_ignored)
{
    CleanDir d;
    std::string rec = copy_header("lf", d.dir);
    put_file(rec + ".info", "#Age: 1\n");
    CHECK(read_metadata(rec).empty());
}

WFDBX_TEST(metadata_input_dir_and_dir)
{
    CleanDir d;
    fs::create_directory("in");
    fs::create_directory("out");
    copy_header("basic", "in");
    const std::string original = slurp("in/basic.hea");
    InputOptions in;
    in.input_dir = "in";
    CHECK(get_metadata("basic", "Sex", in) == std::string("F"));
    CHECK(!wfdbx_get_input_dir());      // (for that call only)
    wfdbx_set_input_dir("in");
    CHECK(get_metadata("basic.hea", "sex") == std::string("F"));
    MetadataOptions o;
    o.dir = "out";
    set_metadata("basic", "Age", "64", o);
    CHECK_EQ(slurp("in/basic.hea"), original);
    InputOptions here;
    here.input_dir = "";
    CHECK(get_metadata("out/basic", "Age", here) == std::string("64"));
    CHECK(wfdbx_get_input_dir() == std::string("in"));
    // an unchanged header is still written to dir
    CHECK_EQ(remove_metadata("basic", "Weight", o), 0);
    CHECK_EQ(slurp("out/basic.hea"), original);
    CHECK(d.list("out") == std::vector<std::string>{"basic.hea"});
    MetadataOptions none;
    none.dir = "none";
    bool thrown = false;
    try {
        set_metadata("basic", "Age", "1", none);
    } catch (const FileError &e) {
        thrown = true;
        CHECK_EQ(std::string(e.what()), "directory none does not exist");
    }
    CHECK(thrown);
    wfdbx_set_input_dir(nullptr);
    // the header is changed where it was read, not in the output directory
    wfdbx_set_output_dir("out");
    set_metadata("in/basic", "Age", "65");
    CHECK(get_metadata("in/basic", "Age") == std::string("65"));
    CHECK(get_metadata("out/basic", "Age") == std::string("63"));   // (rewritten above)
    // update_metadata with the input directory of the call
    MetadataOptions u;
    u.input_dir = "in";
    update_metadata("basic", {{"Age", "66"}, {"Sex", std::nullopt}}, u);
    CHECK(get_metadata("in/basic", "Age") == std::string("66"));
    CHECK(!get_metadata("in/basic", "Sex"));
    CHECK(d.list("in") == std::vector<std::string>{"basic.hea"});
}

WFDBX_TEST(metadata_missing_and_invalid)
{
    CleanDir d;
    wfdbquiet();
    auto file_error = [](auto f) {
        try {
            f();
        } catch (const FileError &) {
            return true;
        } catch (...) {
        }
        return false;
    };
    auto argument_error = [](auto f) {
        try {
            f();
        } catch (const ArgumentError &) {
            return true;
        } catch (...) {
        }
        return false;
    };
    CHECK(file_error([] { read_metadata("none"); }));
    CHECK(file_error([] { set_metadata("none", "Age", "1"); }));
    CHECK(argument_error([] { read_metadata(""); }));
    CHECK(argument_error([] { read_metadata("-"); }));
    CHECK(argument_error([] { get_metadata("none", "a:b"); }));  // (key first)
    try {
        read_metadata("none");
    } catch (const Error &e) {
        CHECK_EQ(std::string(e.what()), "can't read header for record none");
    }
    try {
        set_metadata("basic", " a:b ", "1");
    } catch (const Error &e) {
        CHECK_EQ(std::string(e.what()),
                 "metadata key ' a:b ' must not contain ':'");
    }
    copy_header("basic", d.dir);
    // bytes are stored as given
    set_metadata("basic", "Name", "Z\xc3\xbcrich");
    CHECK(get_metadata("basic", "Name") == std::string("Z\xc3\xbcrich"));
    put_file("norec.hea", "# only a comment\n");
    CHECK(read_metadata("norec").empty());
    CHECK(argument_error([] { set_metadata("norec", "Age", "1"); }));
    CHECK(argument_error(
        [] { update_metadata("basic", {{"Age", "1"}, {"age", std::nullopt}}); }));
    CHECK(d.list() == (std::vector<std::string>{"basic.hea", "norec.hea"}));
}

WFDBX_TEST(metadata_permissions_kept)
{
#if !defined(_WIN32)
    CleanDir d;
    std::string rec = copy_header("basic", d.dir);
    fs::permissions(rec + ".hea", static_cast<fs::perms>(0640));
    set_metadata(rec, "Age", "64");
    CHECK(get_metadata(rec, "Age") == std::string("64"));
    CHECK((fs::status(rec + ".hea").permissions() & fs::perms::mask) ==
          static_cast<fs::perms>(0640));
#endif
}

WFDBX_TEST(metadata_url)
{
#ifdef WFDBX_HAVE_SOCKETS
    if (!wfdbx_tests::have_curl()) {
        std::fprintf(stderr, "(curl not found: metadata_url skipped)\n");
        return;
    }
    CleanDir d;
    EnvVar np("NO_PROXY", "127.0.0.1,localhost");
    EnvVar np2("no_proxy", "127.0.0.1,localhost");
    copy_header("basic", d.dir);
    wfdbx_tests::HttpServer server(d.dir);
    REQUIRE(server.ok());
    wfdbquiet();
    const std::string url = server.url() + "basic";
    bool thrown = false;
    try {
        read_metadata(url);                 // network off
    } catch (const FileError &) {
        thrown = true;
    }
    CHECK(thrown);
    CHECK(server.requests().empty());
    InputOptions net;
    net.network = true;
    CHECK(get_metadata(url, "Age", net) == std::string("63"));
    CHECK_EQ(wfdbx_get_network(), 0);   // (for that call only)
    MetadataOptions o;
    o.network = true;
    thrown = false;
    try {
        set_metadata(url, "Age", "1", o);
    } catch (const ArgumentError &) {
        thrown = true;
    }
    CHECK(thrown);
    fs::create_directory("copy");
    o.dir = "copy";
    set_metadata(url, "Age", "1", o);
    CHECK(get_metadata("copy/basic", "Age") == std::string("1"));
    CHECK(get_metadata("basic", "Age") == std::string("63"));
#endif
}
