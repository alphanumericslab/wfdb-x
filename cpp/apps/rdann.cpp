// rdann.cpp: print an annotation file in ASCII form.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of app/rdann.c from the WFDB Software Package
// 10.7.0, by T. Baker and George B. Moody. The translation follows the logic
// and behavior of the original program, but it is new code, not the original C
// code.
//
// Changes from the original: no built-in sampling frequency: the new option -F
// FREQ gives it when the record has no header or its header gives none, and is
// then required (the original assumed 250 Hz); --legacy, as the first
// argument, restores the original behavior. Each change is marked "wfdb-x:" in
// the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C program: app/rdann.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1981-2010 George B. Moody; revised 2017-2018 by
//   Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// Caution: If the output format of 'rdann' is modified, 'wrann' will require
// modification as well!

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include <wfdbx/ecgmap.hpp>
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
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -c CHAN             print annotations with specified CHAN only",
    " -e                  * show annotation times as elapsed times",
    " -f TIME             start at specified TIME",
    " -F FREQ             sampling frequency, if the record header does not",
    "                      specify one",
    " -h                  print this usage summary",
    " -n NUM              print annotations with specified NUM only",
    " -p TYPE [TYPE ...]  print annotations of specified TYPEs only",
    " -s SUBTYPE          print annotations with specified SUBTYPE only",
    " -t TIME             stop at specified TIME",
    " -v                  print column headings",
    " -x                  * use alternate time format (seconds, minutes, hours)",
    "* Only one of -e and -x can be used.",
    nullptr
};

// wfdb-x: the help text of the original program, printed in legacy mode
static const char *legacy_help_strings[] = {
    "usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n",
    "where RECORD and ANNOTATOR specify the input, and OPTIONS may include:",
    " -c CHAN             print annotations with specified CHAN only",
    " -e                  * show annotation times as elapsed times",
    " -f TIME             start at specified TIME",
    " -h                  print this usage summary",
    " -n NUM              print annotations with specified NUM only",
    " -p TYPE [TYPE ...]  print annotations of specified TYPEs only",
    " -s SUBTYPE          print annotations with specified SUBTYPE only",
    " -t TIME             stop at specified TIME",
    " -v                  print column headings",
    " -x                  * use alternate time format (seconds, minutes, hours)",
    "* Only one of -e and -x can be used.",
    nullptr
};

static void help()
{
    // wfdb-x: the original help text in legacy mode
    const char **hs = wfdbx_get_legacy() ? legacy_help_strings : help_strings;

    std::fprintf(stderr, hs[0], pname);
    for (int i = 1; hs[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", hs[i]);
}

// Exit after reporting an unrecognized option (wfdb-x: also the wfdb-x
// options, in legacy mode).
[[noreturn]] static void unrecognized(const char *arg)
{
    std::fprintf(stderr, "%s: unrecognized option %s\n", pname, arg);
    std::exit(1);
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    const char *record = nullptr, *ainame = nullptr;
    signed char cflag = 0, chanmatch = 0, nflag = 0, nummatch = 0, sflag = 0,
                submatch = 0;
    double Ffreq = 0., sps, tps, tpm, tph, n;
    int sprec, mprec, hprec;
    int eflag = 0, i, j, vflag = 0, xflag = 0;
    long afrom = 0, anum = 0, ato = 0, bfrom = 0, bnum = 0, bto = 0;
    WFDB_Time from = 0, to = 0;
    static char flag[ACMAX + 1];
    WFDB_Anninfo ai;
    WFDB_Annotation annot;
    WFDB_Time sample_num;

    pname = prog_name(argv[0]);

    // Accept old syntax.
    if (argc >= 3 && argv[1][0] != '-') {
        ainame = argv[1];
        record = argv[2];
        i = 3;
        if (argc > 3) {
            from = 3;
            i = 4;
        }
        if (argc > 4) {
            to = 4;
            i = 5;
        }
        if (argc <= 5)
            flag[0] = 1;
        else
            while (i < argc && argv[i][0] != '-') {
                if (isann(j = strann(argv[i]))) flag[j] = 1;
                i++;
            }
    } else
        i = flag[0] = 1;

    // Interpret command-line options.
    for (; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i] + 1)) {
            case 'a':   // annotator follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: annotator must follow -a\n",
                                 pname);
                    std::exit(1);
                }
                ainame = argv[i];
                break;
            case 'c':   // chan value follows
                if (++i >= argc) {
                    std::fprintf(stderr,
                        "%s: chan value (between -128 and 127) must follow -c\n",
                        pname);
                    std::exit(1);
                }
                chanmatch = static_cast<signed char>(std::atoi(argv[i]));
                cflag = 1;
                break;
            case 'e':   // show elapsed time
                eflag = 1;
                xflag = 0;
                break;
            case 'f':   // starting time follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: starting time must follow -f\n",
                                 pname);
                    std::exit(1);
                }
                from = i;   // to be converted to sample intervals below
                break;
            case 'F':   // sampling frequency follows (wfdb-x)
                if (wfdbx_get_legacy())   // wfdb-x: not in the original
                    unrecognized(argv[i]);
                if (++i >= argc || std::sscanf(argv[i], "%lf", &Ffreq) != 1 ||
                    Ffreq <= 0.) {
                    std::fprintf(stderr,
                                 "%s: sampling frequency (> 0) must follow -F\n",
                                 pname);
                    std::exit(1);
                }
                break;
            case 'h':   // print usage summary and quit
                help();
                std::exit(0);
                break;
            case 'n':   // num value follows
                if (++i >= argc) {
                    std::fprintf(stderr,
                        "%s: num value (between -128 and 127) must follow -n\n",
                        pname);
                    std::exit(1);
                }
                nummatch = static_cast<signed char>(std::atoi(argv[i]));
                nflag = 1;
                break;
            case 'p':   // annotation mnemonic(s) follow
                if (++i >= argc || !isann(j = strann(argv[i]))) {
                    std::fprintf(stderr,
                                 "%s: annotation mnemonic(s) must follow -p\n",
                                 pname);
                    std::exit(1);
                }
                flag[j] = 1;
                // Pick up any other mnemonics (arguments beginning with `-'
                // are assumed to be options, not mnemonics).
                while (++i < argc && argv[i][0] != '-')
                    if (isann(j = strann(argv[i]))) flag[j] = 1;
                if (i == argc || argv[i][0] == '-') i--;
                flag[0] = 0;
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
            case 's':   // subtyp value follows
                if (++i >= argc) {
                    std::fprintf(stderr,
                        "%s: subtyp value (between -128 and 127) must follow -s\n",
                        pname);
                    std::exit(1);
                }
                submatch = static_cast<signed char>(std::atoi(argv[i]));
                sflag = 1;
                break;
            case 't':   // ending time follows
                if (++i >= argc) {
                    std::fprintf(stderr, "%s: end time must follow -t\n",
                                 pname);
                    std::exit(1);
                }
                to = i;
                break;
            case 'v':   // show column headings
                vflag = 1;
                break;
            case 'x':   // use alternate time format
                xflag = 1;
                eflag = 0;
                break;
            default:
                unrecognized(argv[i]);
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

    // wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
    // the record had no header, as legacy mode does); -F specifies one.
    if (wfdbx_get_legacy()) {
        if ((sps = sampfreq(record)) < 0.)
            (void)setsampfreq(sps = WFDB_DEFFREQ);
    } else if ((sps = sampfreq(record)) <= 0. && Ffreq > 0.)
        (void)setsampfreq(sps = Ffreq);
    if (!wfdbx_get_legacy() && sps <= 0.) {
        std::fprintf(stderr,
                     "%s: sampling frequency of record %s is not specified "
                     "(use -F)\n", pname, record);
        std::exit(1);
    }

    ai.name = ainame;
    ai.stat = WFDB_READ;
    if (annopen(record, &ai, 1) < 0)    // open annotation file
        std::exit(2);

    if ((tps = getiaorigfreq(0)) < sps) tps = sps;

    // Choose the number of decimal places (sprec, mprec, hprec; at least
    // 3, 5, and 7) of times in seconds, minutes, and hours (-x) so that one
    // tick is visible: n is 10 to the power of the precision.
    sprec = 3;
    n = 1000;
    while (n < tps) {
        sprec++;
        n *= 10;
    }

    tpm = 60.0 * tps;
    mprec = 5;
    n = 100000;
    while (n < tpm) {
        mprec++;
        n *= 10;
    }

    tph = 60.0 * tpm;
    hprec = 7;
    n = 10000000;
    while (n < tph) {
        hprec++;
        n *= 10;
    }

    if (from) {
        const char *fs = argv[static_cast<int>(from)];
        if (*fs == 'a') {
            if ((afrom = std::atol(fs + 1)) < 0) afrom = from = 0;
            while (anum < afrom && getann(0, &annot) == 0) {
                anum++;
                if (isqrs(annot.anntyp)) bnum++;
            }
            if (anum < afrom) std::exit(2);
        } else if (*fs == 'b' || *fs == '#') {
            if ((bfrom = std::atol(fs + 1)) < 0) bfrom = from = 0;
            while (bnum < bfrom && getann(0, &annot) == 0) {
                anum++;
                if (isqrs(annot.anntyp)) bnum++;
            }
            if (bnum < bfrom) std::exit(2);
        } else if (iannsettime(strtim(fs)) < 0)
            std::exit(2);
    }
    if (to) {
        const char *ts = argv[static_cast<int>(to)];
        if (*ts == 'a') {
            if ((ato = std::atol(ts + 1)) < 0) ato = 0;
            bto = 0;
            to = 0;
        } else if (*ts == 'b') {
            if ((bto = std::atol(ts + 1)) < 0) bto = 0;
            ato = 0;
            to = 0;
        } else if (*ts == '#') {
            if ((bto = std::atol(ts + 1)) < 1) bto = 1;
            bto += bnum;
            ato = 0;
            to = 0;
        } else {
            ato = bto = 0;
            to = strtim(ts);
            if (to < 0) to = -to;
        }
    }

    if (vflag) {    // print column headings
        if (eflag)
            std::printf("Elapsed time  Sample #  ");
        else if (xflag)
            std::printf("  Seconds   Minutes     Hours  ");
        else if (std::strchr(mstimstr(-1).c_str(), '/'))
            std::printf("      Time       Date     Sample #  ");
        else if (mstimstr(-1)[0] == '[')
            std::printf("      Time     Sample #  ");
        else
            std::printf("      Time   Sample #  ");
        std::printf("Type  Sub Chan  Num\tAux\n");
    }

    setifreq(tps);
    setiafreq(0, tps);
    while (getann(0, &annot) == 0) {
        if (tps == sps) {
            sample_num = annot.time;
        } else {
            sample_num = static_cast<WFDB_Time>(
                static_cast<double>(annot.time) * sps / tps + 0.5);
            if (static_cast<double>(sample_num) >
                static_cast<double>(annot.time) * sps / tps + 0.5)
                sample_num--;
        }
        if (to != 0 && sample_num > to) break;
        if ((flag[0] || (isann(annot.anntyp) && flag[(int)annot.anntyp])) &&
            (cflag == 0 || annot.chan == chanmatch) &&
            (nflag == 0 || annot.num == nummatch) &&
            (sflag == 0 || annot.subtyp == submatch)) {
            if (eflag)
                std::printf("%s  %7lld", mstimstr(annot.time).c_str(),
                            sample_num);
            else if (xflag)
                std::printf("%*.*f %*.*f %*.*f",
                            sprec + 6, sprec,
                            static_cast<double>(annot.time) / tps,
                            mprec + 4, mprec,
                            static_cast<double>(annot.time) / tpm,
                            hprec + 2, hprec,
                            static_cast<double>(annot.time) / tph);
            else
                std::printf("%s  %7lld", mstimstr(-annot.time).c_str(),
                            sample_num);
            std::printf("%6s%5d%5d%5d",
                        annstr(annot.anntyp).value_or("").c_str(),
                        annot.subtyp, annot.chan, annot.num);
            if (annot.aux)
                std::printf("\t%s", annot.aux->empty()
                                        ? "" : annot.aux->c_str() + 1);
            std::printf("\n");
        }
        if (ato && ++anum >= ato) break;
        if (bto && isqrs(annot.anntyp) && ++bnum >= bto) break;
    }
    std::exit(0);
}
