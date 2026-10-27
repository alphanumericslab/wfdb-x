// check_corpus.hpp: runs check_record on the cases of a corpus written by
// python/tests/check_corpus.py, in the format of its expected.txt (used by
// test_check.cpp and by the wfdbx_check_corpus program).
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

#ifndef WFDBX_CHECK_CORPUS_HPP
#define WFDBX_CHECK_CORPUS_HPP

#include <wfdbx/record.hpp>

#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace wfdbx_tests {

// For each case of DIR/cases.txt (a record name, then annotator names), a
// line "== RECORD ANN...", then the lines of check_record's report (with
// input_dir DIR), each followed by a newline.  Throws wfdbx::Error if
// cases.txt cannot be read.
inline std::string run_check_corpus(const std::string &dir)
{
    std::ifstream in(dir + "/cases.txt", std::ios::binary);
    if (!in) throw wfdbx::Error("can't read " + dir + "/cases.txt");
    std::string out, line;
    while (std::getline(in, line)) {
        std::istringstream words(line);
        std::vector<std::string> w;
        for (std::string x; words >> x;) w.push_back(x);
        if (w.empty()) continue;
        std::vector<std::string> anns(w.begin() + 1, w.end());
        out += "==";
        for (const std::string &x : w) out += " " + x;
        out += "\n";
        wfdbx::InputOptions opt;
        opt.input_dir = dir;
        for (const std::string &l : wfdbx::check_record(w[0], anns, opt).lines())
            out += l + "\n";
    }
    return out;
}

} // namespace wfdbx_tests

#endif // WFDBX_CHECK_CORPUS_HPP
