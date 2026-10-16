// makeid.cpp: make an AHA-format ID block for a database record
// (C++ port of convert/makeid.c)
//
// Copyright (C) 2003 George B. Moody (original C program, convert/makeid.c).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU General Public License, version 2 or later (see LICENSE).
//
// Where the C program uses uninitialized variables (the time of the last
// annotation if there is only one, or of the first if there is none), this
// port uses 0 (see docs/KNOWN_C_BEHAVIORS.md).

#include <cstdio>
#include <cstdlib>
#include <cstring>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

// Write a 16-bit integer in PDP-11 format.
static void p16(unsigned int x, std::FILE *fp)
{
    (void)std::fputc(static_cast<char>(x), fp);
    (void)std::fputc(static_cast<char>(x >> 8), fp);
}

// Write a 32-bit integer in PDP-11 format.
static void p32(long x, std::FILE *fp)
{
    p16(static_cast<unsigned int>(x >> 16), fp);
    p16(static_cast<unsigned int>(x), fp);
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    long nsamp, first, last = 0;
    int blocks, len, nann;
    static char nulls[464];
    WFDB_Anninfo afarray[1];
    WFDB_Siginfo dfarray[2];
    WFDB_Annotation annot;

    if (argc < 3) {
        std::fprintf(stderr, "usage: %s annotator record\n", argv[0]);
        std::exit(1);
    }
    if ((len = static_cast<int>(std::strlen(argv[2]))) > 8) {
        std::fprintf(stderr, "record name must be 8 characters or less\n");
        std::exit(1);
    }
    afarray[0].name = argv[1]; afarray[0].stat = WFDB_READ;
    if (wfdbinit(argv[2], afarray, 1, dfarray, 2) < 1)
        std::exit(2);
    nsamp = dfarray[0].nsamp;
    (void)getann(0, &annot);
    first = static_cast<long>(annot.time);
    nann = 1;
    while (getann(0, &annot) >= 0) {
        last = static_cast<long>(annot.time);
        nann++;
    }
    wfdbquit();

    // Bytes 1-8: record ID (null-padded)
    std::printf("%s", argv[2]);
    if (len < 8)
        (void)std::fwrite(nulls, 1, 8 - len, stdout);
    std::fprintf(stderr, "%s\n", argv[2]);

    // Bytes 9-10: number of annotations
    p16(static_cast<unsigned>(nann), stdout);
    std::fprintf(stderr, "%d annotations\n", nann);

    // Bytes 11-16: unused
    (void)std::fwrite(nulls, 1, 6, stdout);

    // Bytes 17-20: time of first sample in the annotated segment of the
    // record, relative to the beginning of the record
    p32(0L, stdout);
    std::fprintf(stderr, "Annotated segment begins at sample 0\n");

    // Bytes 21-24: time of last sample in the annotated segment of the
    // record, relative to the beginning of the record
    p32(nsamp, stdout);
    std::fprintf(stderr, "Annotated segment ends at sample %ld\n", nsamp);

    // Bytes 25-26: number of 512-byte logical blocks of sample data
    // (nsamp * 2 bytes per sample * 2 channels / 512, rounded upward)
    blocks = static_cast<int>((nsamp + 127) >> 7);
    p16(static_cast<unsigned>(blocks), stdout);
    std::fprintf(stderr, "%d blocks of sample data\n", blocks);

    // Bytes 27-32: unused
    (void)std::fwrite(nulls, 1, 6, stdout);

    // Bytes 33-36: TOC of first annotation, relative to the beginning of the
    // annotated segment
    p32(first, stdout);
    std::fprintf(stderr, "First annotation is at sample %ld\n", first);

    // Bytes 37-40: TOC of last annotation, relative to the beginning of the
    // annotated segment
    p32(last, stdout);
    std::fprintf(stderr, "Last annotation is at sample %ld\n", last);

    // Bytes 41-42: number of 512-byte logical blocks of annotations
    // (nann * 16 bytes per annotation / 512, rounded upward)
    blocks = (nann + 31) >> 5;
    p16(static_cast<unsigned>(blocks), stdout);
    std::fprintf(stderr, "%d blocks of annotations\n", blocks);

    // Bytes 43-48: unused
    (void)std::fwrite(nulls, 1, 6, stdout);

    // Bytes 49-512: may contain information such as a copyright notice
    (void)std::fwrite(nulls, 1, 464, stdout);
    std::exit(0);
}
