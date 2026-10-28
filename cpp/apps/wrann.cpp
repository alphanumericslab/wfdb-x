// wrann.cpp: translate an ASCII annotation file to binary format.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of app/wrann.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: none, apart from the language and the --legacy
// option (as the first argument, it restores the original behavior).
//
// Original C program: app/wrann.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2010 George B. Moody; revised 2018 by Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// The input is in the format produced by `rdann'.  Where the C program has
// undefined behavior (a line with no space after column 9, or a mnemonic
// longer than 9 characters), this port treats the remainder of the line as
// empty, and uses the full mnemonic (see docs/KNOWN_C_BEHAVIORS.md).

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <wfdbx/ecgcodes.hpp>
#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

static const char *pname;

// Size of the C program's aux string buffer (a length byte, the data, and
// a null)
constexpr size_t AUXBUFSIZE = 256;
// Columns of the time field of 'rdann' output (when it is not bracketed)
constexpr size_t TIMECOLS = 9;

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);
    while (p >= s && *p != '/') p--;
    return p + 1;
}

static void help()
{
    std::fprintf(stderr, "usage: %s -r RECORD -a ANNOTATOR <TEXT-FILE\n",
                 pname);
    std::fprintf(stderr,
                 "TEXT-FILE should be in the format produced by `rdann'.\n");
}

int main(int argc, char **argv)
{
    // WFDB-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    WFDB_Anninfo ai;
    WFDB_Annotation annot;
    static char line[400];
    static char annstr[sizeof(line)];   // (10 bytes in the C version)
    const char *record = nullptr, *ainame = nullptr;
    int i, sub = 0, ch = 0, nm = 0;
    long long tm = 0;

    pname = prog_name(argv[0]);

    // Interpret command-line options.
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i] + 1)) {
            case 'a':   // annotator follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: annotator must follow -a\n",
                                 pname);
                    std::exit(1);
                }
                ainame = argv[i];
                break;
            case 'h':   // print usage summary and quit
                help();
                std::exit(0);
                break;
            case 'r':   // input record name follows
                if (++i >= argc) {
                    std::fprintf(stderr,
                                 "%s: input record name must follow -r\n",
                                 pname);
                    std::exit(1);
                }
                record = argv[i];
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
    if (record == nullptr || ainame == nullptr) {
        help();
        std::exit(1);
    }

    setafreq(sampfreq(record));
    ai.name = ainame;
    ai.stat = WFDB_WRITE;
    if (annopen(record, &ai, 1) < 0)    // open annotation file
        std::exit(2);
    while (std::fgets(line, sizeof(line), stdin) != nullptr) {
        size_t n = std::strlen(line), p = TIMECOLS;

        if (line[0] == '[')
            while (p < n && line[p] != ']') p++;
        while (p < n && line[p] != ' ') p++;
        const char *rest = p < n ? line + p + 1 : "";
        (void)std::sscanf(rest, "%lld%s%d%d%d", &tm, annstr, &sub, &ch, &nm);
        annot.anntyp = static_cast<char>(strann(annstr));
        if (line[0] == '[') {
            annot.time = -strtim(line);
            if (annot.time < 0) continue;
        } else
            annot.time = tm;
        annot.subtyp = static_cast<signed char>(sub);
        annot.chan = static_cast<unsigned char>(ch);
        annot.num = static_cast<signed char>(nm);
        // If annstr does not contain a recognizable mnemonic, write a NOTE
        // annotation and put annstr at the beginning of the aux field.
        std::string astr;
        if (annot.anntyp == NOTQRS) {
            annot.anntyp = NOTE;
            astr = annstr;
        } else
            *annstr = '\0';
        const char *tab = std::strchr(rest, '\t');
        bool have_ap = tab != nullptr;
        std::string ap;
        if (have_ap) {      // auxinfo at end of line
            ap = tab;
            long cut;
            if (astr.size() + ap.size() + 2 > AUXBUFSIZE)
                cut = static_cast<long>(AUXBUFSIZE) -
                      static_cast<long>(astr.size()) - 3;
            else
                cut = -1;   // discard trailing newline
            if (cut < 0) cut += static_cast<long>(ap.size());
            if (cut < 0) cut = 0;
            if (static_cast<size_t>(cut) < ap.size()) ap.resize(cut);
        }
        // Create an aux string if needed.
        if (!astr.empty() || have_ap) {
            std::string tail = ap.size() > 1 ? ap.substr(1) : std::string();
            std::string s;
            if (!astr.empty() && have_ap)
                s = astr + " " + tail;
            else if (!astr.empty())
                s = astr;
            else
                s = tail;
            annot.aux = std::string(1, static_cast<char>(s.size() & 0xff)) + s;
        } else
            annot.aux.reset();
        (void)putann(0, &annot);
    }
    wfdbquit();
    std::exit(0);
}
