// test_check.cpp: tests of check_record (see python/tests/test_check.py)
//
// The corpus of python/tests/check_corpus.py (one broken record for each
// issue code, a clean record, records of tests/data, annotation files) is
// written into a temporary directory by running that script (python3, or
// the program named by WFDBX_PYTHON, with python/src on PYTHONPATH), and
// check_record must print exactly its expected.txt (the Python reports).
// Without Python, the corpus tests are skipped (with a message).
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
#include "check_corpus.hpp"

#include <wfdbx/record.hpp>
#include <wfdbx/wfdb.hpp>

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <random>
#include <sstream>
#include <string>
#include <vector>

using namespace wfdbx;
namespace fs = std::filesystem;

namespace {

std::string slurp(const fs::path &p)
{
    std::ifstream f(p, std::ios::binary);
    std::ostringstream s;
    s << f.rdbuf();
    return s.str();
}

std::string quote(const std::string &s) { return "\"" + s + "\""; }

// The corpus, written once into a temporary directory (removed at exit);
// "" if it cannot be written (no Python).
const std::string &corpus()
{
    struct Corpus {
        std::string dir;
        Corpus() {
#ifdef WFDBX_PYTHON_DIR
            fs::path d = fs::temp_directory_path() /
                ("wfdbx-check-" + std::to_string(std::random_device{}()));
            std::string py = std::getenv("WFDBX_PYTHON")
                ? std::getenv("WFDBX_PYTHON") : "python3";
            fs::path pydir = WFDBX_PYTHON_DIR;
            wfdbx_tests::EnvVar path("PYTHONPATH",
                                     (pydir / "src").string().c_str());
            std::string cmd = quote(py) + " " +
                quote((pydir / "tests" / "check_corpus.py").string()) + " " +
                quote(d.string()) + " " + quote(wfdbx_tests::data_dir());
#if defined(_WIN32)
            cmd = "\"" + cmd + " > NUL 2>&1\"";
#else
            cmd += " > /dev/null 2>&1";
#endif
            if (std::system(cmd.c_str()) == 0 &&
                fs::exists(d / "expected.txt"))
                dir = d.string();
            else
                std::fprintf(stderr, "  (check_record corpus not written: "
                             "%s with wfdbx not available; skipped)\n",
                             py.c_str());
#endif
        }
        ~Corpus() {
            if (dir.empty()) return;
            std::error_code ec;
            fs::remove_all(dir, ec);
        }
    };
    static Corpus c;
    return c.dir;
}

InputOptions in(const std::string &dir)
{
    InputOptions o;
    o.input_dir = dir;
    return o;
}

} // namespace

// Every case of the corpus gives exactly the lines of expected.txt.
WFDBX_TEST(check_record_corpus)
{
    const std::string &d = corpus();
    if (d.empty()) return;
    std::string expected = slurp(fs::path(d) / "expected.txt");
    std::string got = wfdbx_tests::run_check_corpus(d);
    CHECK(!expected.empty());
    if (got != expected) {
        // (the first line that differs)
        std::istringstream a(expected), b(got);
        std::string x, y;
        int line = 1;
        while (true) {
            bool ha = static_cast<bool>(std::getline(a, x));
            bool hb = static_cast<bool>(std::getline(b, y));
            if (!ha && !hb) break;
            if (!ha || !hb || x != y) {
                std::fprintf(stderr, "  line %d: expected [%s], got [%s]\n",
                             line, ha ? x.c_str() : "", hb ? y.c_str() : "");
                break;
            }
            line++;
        }
    }
    CHECK(got == expected);
}

WFDBX_TEST(check_record_issue_fields)
{
    const std::string &d = corpus();
    if (d.empty()) return;
    CheckReport r = check_record("d_cksum", {}, in(d));
    REQUIRE(!r.ok && r.issues.size() == 1);
    const Issue &i = r.issues[0];
    CHECK(i.severity == "error" && i.code == "checksum" &&
          i.where == "signal 1");
    CHECK_EQ(i.message, "the checksum does not match: the header gives 1, "
                        "the samples sum to 0");
    CHECK_EQ(i.to_string(), "error: signal 1: " + i.message);
    CHECK_EQ(r.record, "d_cksum");
    r = check_record("clean", {"atr"}, in(d));
    CHECK(r.ok && r.issues.empty() && r.to_string() == "no problems found");
    CHECK(r.lines() == std::vector<std::string>{"no problems found"});
    // warnings and infos only: ok
    r = check_record("nolen", {}, in(d));
    REQUIRE(r.issues.size() == 2);
    CHECK(r.ok && r.issues[0].severity == "warning" &&
          r.issues[1].severity == "info");
    CHECK_EQ(r.issues[0].to_string(),
             "warning: the record length is not specified");
    CHECK_EQ(r.to_string(), r.issues[0].to_string() + "\n" +
                            r.issues[1].to_string());
}

WFDBX_TEST(check_record_arguments)
{
    bool thrown = false;
    try {
        check_record("");
    } catch (const Error &e) {
        thrown = std::string(e.what()) == "record must not be empty";
    }
    CHECK(thrown);
}

// The sample record: its header gives no units (as in the MIT-BIH
// Arrhythmia Database), which is all that is reported.
WFDBX_TEST(check_record_sample_record)
{
    CheckReport r = check_record("100s", {"atr"}, in(wfdbx_tests::data_dir()));
    CHECK(r.ok);
    CHECK(r.lines() == (std::vector<std::string>{
        "warning: signal 0: the units are not specified",
        "warning: signal 1: the units are not specified"}));
}

// Legacy mode is off during the call and restored; the library prints
// nothing, and prints again afterwards; the input directory is restored.
WFDBX_TEST(check_record_settings_restored)
{
    const std::string &d = corpus();
    if (d.empty()) return;
    std::optional<std::string> prev_dir = wfdbx_get_input_dir();
    wfdbx_set_legacy(1);
    CheckReport r;
    std::string err;
    {
        wfdbx_tests::StderrCapture cap;
        r = check_record("nofs", {"nofile"}, in(d));
        err = cap.text();
    }
    CHECK(wfdbx_get_legacy() == 1);
    wfdbx_set_legacy(0);
    // (legacy mode would assume 250 Hz: the frequency is reported missing)
    REQUIRE(!r.issues.empty());
    CHECK_EQ(r.issues[0].code, "fs_missing");
    CHECK_EQ(err, "");
    CHECK(wfdbx_get_input_dir() == prev_dir);
    {
        wfdbx_tests::StderrCapture cap;
        isigopen("no_such_record", nullptr, 0);
        err = cap.text();
    }
    CHECK(err.find("no_such_record") != std::string::npos);
    wfdbquit();
}

// Codes defined by the modification labels of the file have a mnemonic (no
// warning); the definitions do not outlive the check.
WFDBX_TEST(check_record_modification_labels)
{
    const std::string &d = corpus();
    if (d.empty()) return;
    fs::path dir = fs::temp_directory_path() /
        ("wfdbx-check-lab-" + std::to_string(std::random_device{}()));
    fs::create_directories(dir);
    fs::copy_file(fs::path(d) / "clean.hea", dir / "rec.hea");
    // (the header names "clean.dat" in its directory)
    fs::copy_file(fs::path(d) / "clean.dat", dir / "clean.dat");
    std::string hea = slurp(dir / "rec.hea");
    hea.replace(0, 5, "rec");
    {
        std::ofstream f(dir / "rec.hea", std::ios::binary);
        f << hea;
    }
    setannstr(42, "QQ");
    setanndesc(42, "my beat");
    Annotations a;
    a.samples = {10, 20, 30};
    a.codes = {42, 1, 43};
    write_annotations("rec", "lab", a, 0, dir.string());
    setannstr(-42, "[42]");
    setanndesc(-42, nullptr);
    CheckReport r = check_record("rec", {"lab"}, in(dir.string()));
    CHECK(r.lines() == (std::vector<std::string>{
        "warning: annotator lab: 1 annotation uses a code without a "
        "mnemonic: at sample 30 (code 43)"}));
    CHECK(annstr(42) == "[42]");
    std::error_code ec;
    fs::remove_all(dir, ec);
}
