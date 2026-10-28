// bench.cpp: benchmark driver for the C++ implementation of WFDB-x
//
// Usage: wfdbx_bench OP DATADIR REPS
//
// See benchmarks/README.md for the operations and the output (one JSON
// line).
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

#include <wfdbx/record.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <exception>
#include <filesystem>
#include <functional>
#include <random>
#include <string>
#include <system_error>
#include <vector>

namespace fs = std::filesystem;

namespace {

// The shortest text that reads back as x.
std::string json_number(double x)
{
    char buf[40];
    if (x == std::trunc(x) && std::fabs(x) < 1e15) {
        std::snprintf(buf, sizeof buf, "%.0f", x);
        return buf;
    }
    for (int prec = 1; prec <= 17; prec++) {
        std::snprintf(buf, sizeof buf, "%.*g", prec, x);
        if (std::strtod(buf, nullptr) == x) break;
    }
    return buf;
}

// A new, empty temporary directory.
fs::path make_temp_dir()
{
    std::random_device rd;
    for (;;) {
        char name[32];
        std::snprintf(name, sizeof name, "wfdbx-bench-%08x", (unsigned)rd());
        fs::path p = fs::temp_directory_path() / name;
        if (fs::create_directory(p)) return p;
    }
}

int64_t sum(const std::vector<wfdbx::WFDB_Sample> &v)
{
    int64_t s = 0;
    for (wfdbx::WFDB_Sample x : v) s += x;
    return s;
}

}  // namespace

int main(int argc, char **argv)
{
    if (argc != 4) {
        std::fprintf(stderr, "usage: %s OP DATADIR REPS\n", argv[0]);
        return 2;
    }
    const std::string op = argv[1];
    const int reps = std::atoi(argv[3]);
    if (reps < 1) {
        std::fprintf(stderr, "%s: REPS must be at least 1\n", argv[0]);
        return 2;
    }
    wfdbx::wfdbx_set_input_dir(argv[2]);
    fs::path out = make_temp_dir();
    int status = 0;
    try {
        wfdbx::Record src;
        wfdbx::Annotations ann;
        if (op == "write_long") {
            src = wfdbx::read_record("long");
        } else if (op == "write_ann") {
            wfdbx::Annotations a = wfdbx::read_annotations("long", "atr");
            ann.samples = std::move(a.samples);
            ann.codes = std::move(a.codes);
            ann.aux = std::move(a.aux);
        }
        std::function<double()> run;
        if (op == "read_long") {
            run = [] { return (double)sum(wfdbx::read_record("long").samples); };
        } else if (op == "read_long_phys") {
            run = [] {
                wfdbx::Record rec = wfdbx::read_record("long");
                double s = 0;
                for (int i = 0; i < rec.nsig; i++)
                    for (double v : rec.physical_signal(i))
                        if (!std::isnan(v)) s += v;
                return std::round(s * 1000) / 1000;
            };
        } else if (op == "read_mimic") {
            run = [] { return (double)sum(wfdbx::read_record("mimic").samples); };
        } else if (op == "read_wide") {
            run = [] { return (double)sum(wfdbx::read_record("wide").samples); };
        } else if (op == "write_long") {
            run = [&] {
                wfdbx::WriteOptions w;
                w.fmt = 16;
                w.adcres = {16};
                for (const wfdbx::WFDB_Siginfo &si : src.siginfo) {
                    w.gains.push_back(si.gain);
                    w.units.push_back(si.units);
                }
                w.dir = out.string();
                wfdbx::write_record("out", src.samples, src.nsig, src.fs, w);
                return (double)fs::file_size(out / "out.dat");
            };
        } else if (op == "read_ann") {
            run = [] { return (double)wfdbx::read_annotations("long", "atr").size(); };
        } else if (op == "write_ann") {
            run = [&] {
                wfdbx::write_annotations("out", "atr", ann, 0, out.string());
                return (double)fs::file_size(out / "out.atr");
            };
        } else {
            std::fprintf(stderr, "%s: unknown operation %s\n", argv[0],
                         op.c_str());
            status = 2;
        }
        if (run) {
            using clock = std::chrono::steady_clock;
            auto t = clock::now();
            double check = run();
            double first = std::chrono::duration<double>(clock::now() - t).count();
            std::vector<double> times;
            for (int i = 0; i < reps; i++) {
                t = clock::now();
                run();
                times.push_back(
                    std::chrono::duration<double>(clock::now() - t).count());
            }
            std::string ts;
            for (double x : times) ts += (ts.empty() ? "" : ", ") + json_number(x);
            std::printf("{\"op\": \"%s\", \"first\": %s, \"best\": %s, "
                        "\"times\": [%s], \"check\": %s}\n",
                        op.c_str(), json_number(first).c_str(),
                        json_number(*std::min_element(times.begin(),
                                                      times.end())).c_str(),
                        ts.c_str(), json_number(check).c_str());
        }
    } catch (const std::exception &e) {
        std::fprintf(stderr, "%s: %s: %s\n", argv[0], op.c_str(), e.what());
        status = 1;
    }
    std::error_code ec;
    fs::remove_all(out, ec);
    return status;
}
