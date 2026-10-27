// cemul.hpp: emulation of C behaviors shared by several command-line tools
//
// The output of the C tools depends on how the reference platform (x86-64,
// glibc) evaluates a few operations that C leaves undefined or
// implementation-defined.  These helpers reproduce them, so that the tools
// give the same results on every platform.  fclose_output closes a file that
// a tool writes itself, as the reference C package does.
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

#ifndef WFDBX_APPS_CEMUL_HPP
#define WFDBX_APPS_CEMUL_HPP

#include <climits>
#include <cstdint>
#include <cstdio>

#include <wfdbx/wfdb.hpp>

namespace cemul {

// Conversion of a double to int as on x86: INT_MIN if the value is out of
// range (or NaN).
inline int d2i(double x)
{
    if (!(x > -2147483649.0 && x < 2147483648.0)) return INT_MIN;
    return static_cast<int>(x);
}

// int addition and subtraction with wrap-around.
inline int iadd(int a, int b)
{
    return static_cast<int>(static_cast<unsigned>(a) + static_cast<unsigned>(b));
}

inline int isub(int a, int b)
{
    return static_cast<int>(static_cast<unsigned>(a) - static_cast<unsigned>(b));
}

// glibc's rand() (the TYPE_3 additive feedback generator, x[i] = x[i-31] +
// x[i-3]), seeded as by srand(): the state is filled by the "minimal
// standard" generator (16807 * x mod 2^31 - 1, by Schrage's method), and the
// first 310 outputs are discarded.
class GlibcRand {
public:
    static constexpr int RAND_MAX_ = 2147483647;

    explicit GlibcRand(unsigned seed = 1) { srand(seed); }

    void srand(unsigned seed)
    {
        constexpr int32_t A = 16807, M = 2147483647;
        constexpr int32_t Q = M / A, R = M % A;     // 127773, 2836
        if (seed == 0) seed = 1;
        int32_t r[LEN];
        r[0] = static_cast<int32_t>(seed);
        for (int i = 1; i < DEG; i++) {
            int32_t hi = r[i - 1] / Q, lo = r[i - 1] % Q;
            int32_t word = A * lo - R * hi;
            if (word < 0) word += M;
            r[i] = word;
        }
        for (int i = DEG; i < LEN; i++) r[i] = r[i - DEG];
        for (int i = 0; i < LEN; i++) r_[i] = static_cast<uint32_t>(r[i]);
        i_ = LEN;
        for (int i = 0; i < 10 * DEG; i++) next();
    }

    int rand() { return static_cast<int>(next()); }

private:
    static constexpr int DEG = 31;          // degree of the generator
    static constexpr int SEP = 3;           // separation of its taps
    static constexpr int LEN = DEG + SEP;   // history kept

    uint32_t next()
    {
        uint32_t v = r_[(i_ - DEG) % LEN] + r_[(i_ - SEP) % LEN];
        r_[i_ % LEN] = v;
        i_++;
        return v >> 1;
    }

    uint32_t r_[LEN];
    unsigned long long i_ = 0;
};

// wfdb-x: close fp, a file named name that a tool has written itself, and
// return the result of fclose.  In normal mode, if the file could not be
// written or closed, print "PNAME: write error on NAME" and count a write
// error (see wfdbx_write_errors).  (wfdbx_fclose_output of the reference C
// package.)
inline int fclose_output(std::FILE *fp, const char *pname, const char *name)
{
    int err = std::ferror(fp), status = std::fclose(fp);
    if ((err || status) && !wfdbx::wfdbx_get_legacy()) {
        std::fprintf(stderr, "%s: write error on %s\n", pname, name);
        wfdbx::wfdbx_note_write_error();
    }
    return status;
}

} // namespace cemul

#endif // WFDBX_APPS_CEMUL_HPP
