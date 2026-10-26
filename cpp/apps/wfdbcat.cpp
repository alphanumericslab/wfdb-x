// wfdbcat.cpp: copy WFDB files to the standard
// output (C++ port of app/wfdbcat.c)
//
// Copyright (C) 2000 George B. Moody (original C program, app/wfdbcat.c;
// revised 2018 by Benjamin Moody).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).
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
    // wfdb-x: --legacy as the first argument selects legacy mode (the
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
