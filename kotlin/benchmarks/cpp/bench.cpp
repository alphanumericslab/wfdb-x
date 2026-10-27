// The benchmark program of the C++ implementation, with the operations of
// kotlin/benchmarks/src/Bench.kt (see kotlin/benchmarks/run.sh):
//
//   bench read   DIR REC REPS
//   bench write  DIR REC OUTDIR REPS
//   bench ann    OUTDIR REPS
//   bench getvec DIR REC REPS
//
// Each prints the best time of REPS runs (after one untimed run) and a
// digest of the data (FNV-1a of the samples).
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

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <string>
#include <vector>

using namespace wfdbx;

static uint64_t fnv(uint64_t h, int v)
{
    return (h ^ static_cast<uint32_t>(v)) * 1099511628211ULL;
}

static const uint64_t FNV0 = 14695981039346656037ULL;

static double best_ms(int reps, const std::function<void()> &f)
{
    f();    // (warm-up, as for the JVM)
    double best = 1e300;
    for (int i = 0; i < reps; i++) {
        auto t = std::chrono::steady_clock::now();
        f();
        double ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t).count();
        if (ms < best) best = ms;
    }
    return best;
}

int main(int argc, char **argv)
{
    std::string cmd = argv[1];
    if (cmd == "read") {
        ReadOptions o;
        o.input_dir = argv[2];
        Record r;
        double ms = best_ms(atoi(argv[4]), [&] { r = read_record(argv[3], o); });
        uint64_t h = FNV0;
        for (int v : r.samples) h = fnv(h, v);
        std::printf("read_record %.1f ms frames=%zu nsig=%d digest=%llx\n", ms,
                    r.samples.size() / r.nsig, r.nsig, (unsigned long long)h);
    } else if (cmd == "write") {
        ReadOptions o;
        o.input_dir = argv[2];
        Record r = read_record(argv[3], o);
        WriteOptions w;
        w.fmt = 16;
        for (auto &s : r.siginfo) {
            w.gains.push_back(s.gain);
            w.baselines.push_back(s.baseline);
        }
        w.adcres = {16};
        w.units = {std::string("mV")};
        w.names = r.names();
        w.dir = argv[4];
        double ms = best_ms(atoi(argv[5]), [&] {
            write_record(argv[3], r.samples, r.nsig, r.fs, w);
        });
        std::printf("write_record %.1f ms\n", ms);
    } else if (cmd == "ann") {
        const int n = 200000;
        static const int cyc[8] = {1, 1, 1, 5, 8, 1, 12, 1};
        Annotations a;
        for (int k = 0; k < n; k++) {
            a.samples.push_back(10LL * k + (7LL * k) % 9);
            a.codes.push_back(cyc[k % 8]);
            a.subtypes.push_back(k % 50 == 0 ? 1 : 0);
            a.chans.push_back(0);
            a.nums.push_back(0);
            if (k % 1000 == 0) a.aux.push_back(std::string("(N"));
            else a.aux.push_back(std::nullopt);
        }
        double ms = best_ms(atoi(argv[3]), [&] {
            write_annotations("big", "bench", a, 0, argv[2]);
        });
        std::printf("write_annotations %.1f ms\n", ms);
    } else if (cmd == "getvec") {
        wfdbx_set_input_dir(argv[2]);
        uint64_t h = FNV0;
        long long frames = 0;
        double ms = best_ms(atoi(argv[4]), [&] {
            wfdbquit();
            int n = isigopen(argv[3], nullptr, 0);
            std::vector<WFDB_Siginfo> si(n);
            isigopen(argv[3], si.data(), n);
            std::vector<WFDB_Sample> v(n);
            h = FNV0;
            frames = 0;
            while (getvec(v.data()) >= 0) {
                for (int x : v) h = fnv(h, x);
                frames++;
            }
            wfdbquit();
        });
        std::printf("getvec %.1f ms frames=%lld digest=%llx\n", ms, frames,
                    (unsigned long long)h);
    }
    return 0;
}
