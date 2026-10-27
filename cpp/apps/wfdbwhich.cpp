// wfdbwhich.cpp: find a WFDB file and print its pathname.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of app/wfdbwhich.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior). Through
// the library, the file is looked for only where it is named (the input
// directory, a full path or a URL), not by a search of the WFDB path; see
// docs/DIVERGENCES.md.
//
// Original C program: app/wfdbwhich.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1999 George B. Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    const char *pname;
    std::optional<std::string> filename;
    int status = 0;

    pname = prog_name(argv[0]);
    if (argc == 2 && std::strcmp(argv[1], "-h") == 0)
        argc = 0;   // give usage instructions and quit
    switch (argc) {
    case 2:
        if ((filename = wfdbfile(argv[1], nullptr)))
            std::printf("%s\n", filename->c_str());
        else {
            std::fprintf(stderr, "`%s' not found\n", argv[1]);
            std::fprintf(stderr, "(WFDB path = %s)\n", getwfdb().c_str());
            status = 2;
        }
        break;
    case 3:
        wfdbquiet();
        (void)isigopen(argv[2], nullptr, 0);
        if ((filename = wfdbfile(argv[1], argv[2])))
            std::printf("%s\n", filename->c_str());
        else {
            std::fprintf(stderr,
                         "No file of type `%s' found for record `%s'\n",
                         argv[1], argv[2]);
            std::fprintf(stderr, "(WFDB path = %s)\n", getwfdb().c_str());
            status = 2;
        }
        break;
    default:
        if (argc != 4 || std::strcmp(argv[1], "-r") != 0) {
            std::fprintf(stderr, "usage: %s [-r RECORD ] FILENAME\n", pname);
            std::fprintf(stderr, " -or-  %s FILE-TYPE RECORD\n", pname);
            status = 1;
        } else {
            (void)isigopen(argv[2], nullptr, 0);
            if ((filename = wfdbfile(argv[3], nullptr)))
                std::printf("%s\n", filename->c_str());
            else {
                std::fprintf(stderr, "`%s' not found\n", argv[3]);
                std::fprintf(stderr, "(WFDB path = %s)\n", getwfdb().c_str());
                status = 2;
            }
        }
        break;
    }
    std::exit(status);
}
