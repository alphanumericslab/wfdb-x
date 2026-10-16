// readid.cpp: read an AHA-format ID block, write record name and file lengths
// (C++ port of convert/readid.c)
//
// Copyright (C) 1983-2005 George B. Moody (original C program,
// convert/readid.c).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).
//
// The C program reads the record ID into a 9-byte buffer, which overflows
// for longer IDs; this port prints the whole ID, as the C program does (see
// docs/KNOWN_C_BEHAVIORS.md).

#include <cstdio>
#include <cstdlib>

#include <wfdbx/wfdb.hpp>   // wfdb-x: for wfdbx_legacy_args

static int g16(std::FILE *fp)
{
    int h, l;

    l = std::fgetc(fp);
    h = std::fgetc(fp);
    return (((h << 8) & 0xff00) | (l & 0xff));
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
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
