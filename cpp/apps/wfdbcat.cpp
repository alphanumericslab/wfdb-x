// wfdbcat.cpp: copy WFDB files to the standard output.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of app/wfdbcat.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior). Through
// the library, each file is read from where it is named (the input directory,
// a full path or a URL), not found by a search of the WFDB path; see
// docs/DIVERGENCES.md.
//
// Original C program: app/wfdbcat.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2000 George B. Moody; revised 2018 by Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// Like the C program, this port opens each file with the library's internal
// wfdb_open() (so that a URL is read as the library reads it).

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <wfdbx/wfdb.hpp>

#include "../src/wfdblib.hpp"

using namespace wfdbx;

#define BUFSIZE 1024    // bytes read at a time

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

int main(int argc, char **argv)
{
    // WFDB-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    const char *pname;
    int i = 0;
    size_t n;
    static char buf[BUFSIZE];

    pname = prog_name(argv[0]);
    if (argc < 2 || (argc == 2 && std::strcmp(argv[1], "-h") == 0)) {
        std::fprintf(stderr, "usage: %s FILE [FILE ...]\n", pname);
        std::exit(1);
    }

    for (i = 1; i < argc; i++) {
        detail::FilePtr ifile = detail::wfdb_open(argv[i], nullptr, WFDB_READ);
        if (!ifile) {
            std::fflush(stdout);
            std::fprintf(stderr, "%s: `%s' not found\n", pname, argv[i]);
        } else {
            while ((n = ifile->read(buf, 1, sizeof(buf))) &&
                   (n == std::fwrite(buf, 1, n, stdout)))
                ;
        }
    }

    std::exit(0);
}
