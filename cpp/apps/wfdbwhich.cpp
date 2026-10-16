// wfdbwhich.cpp: find a WFDB file and print its pathname
// (C++ port of app/wfdbwhich.c)
//
// Copyright (C) 1999 George B. Moody (original C program, app/wfdbwhich.c).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

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
