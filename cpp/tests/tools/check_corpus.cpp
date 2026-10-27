// check_corpus.cpp: prints check_record's reports for the cases of a corpus
// written by python/tests/check_corpus.py, in the format of its expected.txt
//
// Usage: wfdbx_check_corpus DIR
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
// It tests WFDB-x; it has no counterpart in the original package.
//
// Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

#include "../check_corpus.hpp"

#include <cstdio>
#include <exception>

int main(int argc, char **argv)
{
    if (argc != 2) {
        std::fprintf(stderr, "usage: %s DIR\n", argv[0]);
        return 2;
    }
    try {
        std::string out = wfdbx_tests::run_check_corpus(argv[1]);
        std::fwrite(out.data(), 1, out.size(), stdout);
    } catch (const std::exception &e) {
        std::fprintf(stderr, "%s\n", e.what());
        return 1;
    }
    return 0;
}
