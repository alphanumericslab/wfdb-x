// signum.cpp: print signal numbers for signals named as arguments
// (C++ port of app/signum.c)
//
// Copyright (C) 2008 George B. Moody (original C program, app/signum.c;
// revised 2021 by Benjamin Moody).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

static const char *pname;

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

static const char *help_strings[] = {
    "usage: %s -r RECORD [OPTIONS ...]\n",
    "where RECORD is the name of the input record, and OPTIONS may include:",
    " -h          print this usage summary",
    " -s SIGNAL [SIGNAL ...]  print signal number(s) for the specified signal(s)",
    nullptr
};

static void help()
{
    std::fprintf(stderr, help_strings[0], pname);
    for (int i = 1; help_strings[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", help_strings[i]);
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    const char *record = nullptr;
    int found, i, isiglist = 0, j, nsig, nosig = 0;
    std::vector<WFDB_Siginfo> si;

    pname = prog_name(argv[0]);

    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i] + 1)) {
            case 'h':   // help requested
                help();
                std::exit(0);
                break;
            case 'r':   // record name
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: record name must follow -r\n",
                                 pname);
                    std::exit(1);
                }
                record = argv[i];
                break;
            case 's':   // signal list follows
                isiglist = i + 1; // index of 1st argument with a signal name
                while (i + 1 < argc && *argv[i + 1] != '-') {
                    i++;
                    nosig++;    // number of elements in signal list
                }
                if (nosig == 0) {
                    std::fprintf(stderr, "%s: signal list must follow -s\n",
                                 pname);
                    std::exit(1);
                }
                break;
            default:
                std::fprintf(stderr, "%s: unrecognized option %s\n", pname,
                             argv[i]);
                std::exit(1);
            }
        else {
            std::fprintf(stderr, "%s: unrecognized argument %s\n", pname,
                         argv[i]);
            std::exit(1);
        }
    }
    if (record == nullptr || isiglist == 0) {
        help();
        std::exit(1);
    }
    if ((nsig = isigopen(record, nullptr, 0)) <= 0) std::exit(2);
    si.resize(nsig);
    if ((nsig = isigopen(record, si.data(), -nsig)) <= 0) std::exit(2);
    for (i = 0; i < nosig; i++) {
        found = 0;
        for (j = 0; j < nsig; j++) {
            if (si[j].desc && std::strcmp(argv[isiglist + i],
                                          si[j].desc->c_str()) == 0) {
                if (found) std::printf("\t");
                std::printf("%d", j);
                found = 1;
            }
        }
        if (!found) std::printf("X");
        std::printf("\n");
    }
    wfdbquit();
    std::exit(0);
}
