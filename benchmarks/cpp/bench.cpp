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
#include <wfdbx/wfdb.hpp>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <functional>
#include <random>
#include <stdexcept>
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

// The result of a call: what it read (the physical values too, for
// read_long_phys).
struct Result {
    wfdbx::Record rec;
    std::vector<std::vector<double>> phys;
    wfdbx::Annotations ann;
};

// Append the bytes of x (little-endian on the machines we run on).
template <typename T> void put(std::string &b, T x)
{
    char c[sizeof x];
    std::memcpy(c, &x, sizeof x);
    b.append(c, sizeof x);
}

void write_file(const fs::path &p, const std::string &b)
{
    std::ofstream f(p, std::ios::binary);
    f.write(b.data(), (std::streamsize)b.size());
    if (!f) throw std::runtime_error("can't write " + p.string());
}

// Save the result of the first call of op as dump/op.* (see
// benchmarks/python/bench.py).
void save(const std::string &op, const Result &r, const fs::path &out,
          const fs::path &dump)
{
    fs::path p = dump / op;
    std::string b;
    if (op == "read_long" || op == "read_long_getvec" || op == "read_mimic" ||
        op == "read_wide") {
        for (wfdbx::WFDB_Sample x : r.rec.samples) put<int32_t>(b, x);
        write_file(p.string() + ".bin", b);
    } else if (op == "read_long_phys") {
        for (size_t i = 0; i < r.rec.nsamples(); i++)
            for (int s = 0; s < r.rec.nsig; s++) put<double>(b, r.phys[s][i]);
        write_file(p.string() + ".bin", b);
    } else if (op == "read_ann") {
        const wfdbx::Annotations &a = r.ann;
        for (size_t k = 0; k < a.size(); k++) {
            put<int64_t>(b, a.samples[k]);
            put<int32_t>(b, a.codes[k]);
            put<int32_t>(b, a.subtypes[k]);
            put<int32_t>(b, a.chans[k]);
            put<int32_t>(b, a.nums[k]);
            if (a.aux[k]) {
                put<int32_t>(b, (int32_t)a.aux[k]->size());
                b += *a.aux[k];
            } else {
                put<int32_t>(b, -1);
            }
        }
        write_file(p.string() + ".ann", b);
    } else if (op == "write_long") {
        fs::copy_file(out / "out.hea", p.string() + ".hea",
                      fs::copy_options::overwrite_existing);
        fs::copy_file(out / "out.dat", p.string() + ".dat",
                      fs::copy_options::overwrite_existing);
    } else if (op == "write_ann") {
        fs::copy_file(out / "out.atr", p.string() + ".atr",
                      fs::copy_options::overwrite_existing);
    }
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
        // run(r) is the timed call: the operation alone, its result in r.
        // check(r) is computed from the first call's result, outside the
        // timed calls.
        std::function<void(Result &)> run;
        std::function<double(const Result &)> check;
        auto read = [](const char *name) {
            return [name](Result &r) { r.rec = wfdbx::read_record(name); };
        };
        auto sample_sum = [](const Result &r) { return (double)sum(r.rec.samples); };
        if (op == "read_long") {
            run = read("long");
            check = sample_sum;
        } else if (op == "read_long_getvec") {
            // The C library's way: the library functions, one frame per
            // getvec call (for comparison with the original C library).
            run = [](Result &r) {
                const int maxsig = 32;
                wfdbx::WFDB_Siginfo si[maxsig];
                int nsig = wfdbx::isigopen("long", si, maxsig);
                if (nsig < 1) throw std::runtime_error("can't open long");
                std::vector<wfdbx::WFDB_Sample> frame(nsig);
                r.rec.nsig = nsig;
                r.rec.samples.reserve((size_t)si[0].nsamp * nsig);
                while (wfdbx::getvec(frame.data()) == nsig)
                    r.rec.samples.insert(r.rec.samples.end(), frame.begin(),
                                         frame.end());
                wfdbx::wfdbquit();
            };
            check = sample_sum;
        } else if (op == "read_long_phys") {
            run = [](Result &r) {
                r.rec = wfdbx::read_record("long");
                r.phys.clear();
                for (int i = 0; i < r.rec.nsig; i++)
                    r.phys.push_back(r.rec.physical_signal(i));
            };
            check = [](const Result &r) {
                double s = 0;
                for (const std::vector<double> &v : r.phys)
                    for (double x : v)
                        if (!std::isnan(x)) s += x;
                return std::round(s * 1000) / 1000;
            };
        } else if (op == "read_mimic") {
            run = read("mimic");
            check = sample_sum;
        } else if (op == "read_wide") {
            run = read("wide");
            check = sample_sum;
        } else if (op == "write_long") {
            run = [&](Result &) {
                wfdbx::WriteOptions w;
                w.fmt = 16;
                w.adcres = {16};
                for (const wfdbx::WFDB_Siginfo &si : src.siginfo) {
                    w.gains.push_back(si.gain);
                    w.units.push_back(si.units);
                }
                w.dir = out.string();
                wfdbx::write_record("out", src.samples, src.nsig, src.fs, w);
            };
            check = [&](const Result &) { return (double)fs::file_size(out / "out.dat"); };
        } else if (op == "read_ann") {
            run = [](Result &r) { r.ann = wfdbx::read_annotations("long", "atr"); };
            check = [](const Result &r) { return (double)r.ann.size(); };
        } else if (op == "write_ann") {
            run = [&](Result &) {
                wfdbx::write_annotations("out", "atr", ann, 0, out.string());
            };
            check = [&](const Result &) { return (double)fs::file_size(out / "out.atr"); };
        } else {
            std::fprintf(stderr, "%s: unknown operation %s\n", argv[0],
                         op.c_str());
            status = 2;
        }
        if (run) {
            using clock = std::chrono::steady_clock;
            const char *dump = std::getenv("WFDBX_BENCH_DUMP");
            double value;
            double first;
            {
                Result r;
                auto t = clock::now();
                run(r);
                first = std::chrono::duration<double>(clock::now() - t).count();
                value = check(r);
                if (dump && *dump) save(op, r, out, dump);
            }
            std::vector<double> times;
            for (int i = 0; i < reps; i++) {
                Result r;
                auto t = clock::now();
                run(r);
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
                        ts.c_str(), json_number(value).c_str());
        }
    } catch (const std::exception &e) {
        std::fprintf(stderr, "%s: %s: %s\n", argv[0], op.c_str(), e.what());
        status = 1;
    }
    std::error_code ec;
    fs::remove_all(out, ec);
    return status;
}
