// readid.cpp: read an AHA-format ID block, write record name and file lengths.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of convert/readid.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: convert/readid.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2005 George B. Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// The C program reads the record ID into a 9-byte buffer, which overflows
// for longer IDs; this port prints the whole ID, as the C program does (see
// docs/KNOWN_C_BEHAVIORS.md).

#include <cstdio>
#include <cstdlib>

#include <wfdbx/wfdb.hpp>   // WFDB-x: for wfdbx_legacy_args

static int g16(std::FILE *fp)
{
    int h, l;

    l = std::fgetc(fp);
    h = std::fgetc(fp);
    return (((h << 8) & 0xff00) | (l & 0xff));
}

int main(int argc, char **argv)
{
    // WFDB-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx::wfdbx_legacy_args(argc, argv);

    int dasize, ansize;
    long dcount, acount;
    static char buf[512], name[sizeof(buf)];   // (name[9] in the C version)

    if (argc < 3) {
        std::fprintf(stderr, "usage: %s data-block-size annot-block-size\n",
                     argv[0]);
        std::exit(1);
    }
    dasize = std::atoi(argv[1]);
    ansize = std::atoi(argv[2]);
    if (dasize < 1) dasize = 1;
    if (ansize < 1) ansize = 1;
    if (std::fread(buf, 1, 24, stdin) != 24) {}
    (void)std::sscanf(buf, "%s", name);
    dcount = (g16(stdin) * 512L + dasize - 1) / dasize;
    if (std::fread(buf, 1, 14, stdin) != 14) {}
    acount = (g16(stdin) * 512L + ansize - 1) / ansize;
    std::printf("%s %ld %ld\n", name, dcount, acount);
    std::exit(0);
}
