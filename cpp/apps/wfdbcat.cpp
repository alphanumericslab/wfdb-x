// wfdbcat.cpp: copy WFDB files (found in the WFDB path) to the standard
// output (C++ port of app/wfdbcat.c)
//
// Copyright (C) 2000 George B. Moody (original C program, app/wfdbcat.c;
// revised 2018 by Benjamin Moody).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).
//
// The C program opens each file with wfdb_open(), which is not part of the
// public API; this port finds it with wfdbfile() (which is wfdb_open()
// followed by wfdb_fclose()) and then reads it with stdio.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>

#include <wfdbx/wfdb.hpp>

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
    std::FILE *ifile = nullptr;

    pname = prog_name(argv[0]);
    if (argc < 2 || (argc == 2 && std::strcmp(argv[1], "-h") == 0)) {
        std::fprintf(stderr, "usage: %s FILE [FILE ...]\n", pname);
        std::exit(1);
    }

    for (i = 1; i < argc; i++) {
        std::optional<std::string> fname = wfdbfile(argv[i], nullptr);
        if (!fname || (ifile = std::fopen(fname->c_str(), "rb")) == nullptr) {
            std::fflush(stdout);
            std::fprintf(stderr, "%s: `%s' not found\n", pname, argv[i]);
        } else {
            while ((n = std::fread(buf, 1, sizeof(buf), ifile)) &&
                   (n == std::fwrite(buf, 1, n, stdout)))
                ;
            std::fclose(ifile);
        }
    }

    std::exit(0);
}
