// wfdb2mat.cpp: convert (all or part of) a WFDB signal file to Matlab .mat
// format.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of convert/wfdb2mat.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency, gain or units:
// the record must give the sampling frequency (the original assumed 250 Hz),
// uncalibrated signals stay uncalibrated in the output header (the original
// wrote 200 adu/mV), and unspecified units are written as "nd" (the original
// wrote "mV"); --legacy, as the first argument, restores the original
// behavior. Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md
// gives the reasons.
//
// Original C program: convert/wfdb2mat.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2009-2013 George B. Moody; revised 2014-2021 by
//   Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// If the input record name is REC, the output files are RECm.mat (a version
// 5 MAT-file containing a single matrix named 'val' of raw samples, one
// column per sample) and RECm.hea.  See the C source for details.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <optional>
#include <string>
#include <vector>

#include <wfdbx/wfdb.hpp>

using namespace wfdbx;

// Output .mat data storage types (values of mattype), defined by the .mat
// format specification.  These variables are for the sub4 tag data STORAGE
// type.
#define MAT8 2      // 8 bits per sample unsigned
#define MAT16 3     // 16 bits per sample signed
#define MAT32 5     // 32 bits per sample signed

static const char *pname;

static const char *prog_name(const char *s);
static void help();

int main(int argc, char **argv)
{
    // WFDB-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    std::string matname, orec, p;
    const char *record = nullptr, *search = nullptr;
    // The entire file is composed of:
    //  - 128 byte descriptive text
    //  - 8 byte master tag. 4 bytes indicate data type = matrix, 4 bytes
    //    indicate data size.
    //  - 4 subelements. Each subelement has a 4 byte tag giving the data
    //    type of the elements, a 4 byte tag giving the subelement size, and
    //    the subelement's actual content.
    //    - Subelement 1: array flags (8 + 8 bytes)
    //    - Subelement 2: array dimension (8 + 8 bytes)
    //    - Subelement 3: array name (8 + 8 bytes)
    //    - Subelement 4: array content (8 + ?? bytes)
    static char prolog[192];  // 128 byte descriptive text
                              // + 64 bytes of fixed length content

    // mastertype=matrix, sub1type=UINT32, sub2type=INT32, sub3type=INT8
    // fieldversion=0x0100 indicating mat file
    int highres = 0, i, isiglist = 0, nisig, nosig = 0,
        mastertype = 14, sub1type = 6, sub2type = 5, sub3type = 1, sub4type,
        fieldversion = 256, s, sfname = 0, stat = 0,
        sub1class = 6, nbytesperelement, wfdbtype, offset;
    // nbytesmaster is the value specified in the master tag representing
    // the size of all following content.  nbytesofdata gives the number of
    // bytes of signal data.  lremain stores the number of bytes to pad to
    // make the file size a multiple of 8.  max_length is the maximum
    // permissible signal length.
    unsigned long nbytesmaster, nbytesofdata, lremain, max_length;
    WFDB_Frequency freq;
    std::vector<WFDB_Sample> vi, vo;
    std::vector<WFDB_Siginfo> si, so;
    std::vector<int> sig;
    WFDB_Time from = 0L, maxl = 0L, t, to = 0L, lower, upper;

    pname = prog_name(argv[0]);
    for (i = 1 ; i < argc; i++) {
        if (*argv[i] == '-') switch (*(argv[i]+1)) {
          case 'f':     // starting time
            if (++i >= argc) {
                std::fprintf(stderr, "%s: time must follow -f\n", pname);
                std::exit(1);
            }
            from = i;
            break;
          case 'h':     // help requested
            help();
            std::exit(0);
            break;
          case 'H':     // select high-resolution mode
            highres = 1;
            break;
          case 'l':     // maximum length of output follows
            if (++i >= argc) {
                std::fprintf(stderr, "%s: max output length must follow -l\n",
                             pname);
                std::exit(1);
            }
            maxl = i;
            break;
          case 'r':     // record name
            if (++i >= argc) {
                std::fprintf(stderr, "%s: record name must follow -r\n",
                             pname);
                std::exit(1);
            }
            record = argv[i];
            break;
          case 's':     // signal list follows
            isiglist = i+1; // index of first argument containing a signal #
            while (i+1 < argc && *argv[i+1] != '-') {
                i++;
                nosig++;        // number of elements in signal list
            }
            if (nosig == 0) {
                std::fprintf(stderr, "%s: signal list must follow -s\n",
                             pname);
                std::exit(1);
            }
            break;
          case 'S':     // search for valid sample of specified signal
            if (++i >= argc) {
                std::fprintf(stderr,
                             "%s: signal name or number must follow -S\n",
                             pname);
                std::exit(1);
            }
            search = argv[i];
            break;

          case 't':     // end time
            if (++i >= argc) {
                std::fprintf(stderr, "%s: time must follow -t\n", pname);
                std::exit(1);
            }
            to = i;
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
    if (record == nullptr) {
        help();
        std::exit(1);
    }
    if ((nisig = isigopen(record, nullptr, 0)) <= 0) std::exit(2);
    si.resize(nisig);
    vi.resize(nisig);
    if ((nisig = isigopen(record, si.data(), nisig)) <= 0)
        std::exit(2);
    // WFDB-x: uncalibrated signals remain uncalibrated in the output (the C
    // program assumed 200 adu/mV), and the output header needs the sampling
    // frequency (the C program assumed 250 Hz).  Legacy mode: as in the C
    // program.
    if (wfdbx_get_legacy())
        for (i = 0; i < nisig; i++)
            if (si[i].gain == 0.0) si[i].gain = WFDB_DEFGAIN;
    if (highres)
        setgvmode(WFDB_HIGHRES);
    freq = sampfreq(nullptr);
    if (freq <= 0. && !wfdbx_get_legacy()) {
        std::fprintf(stderr,
                     "%s: sampling frequency of record %s is not specified\n",
                     pname, record);
        std::exit(2);
    }
    if (from > 0L && (from = strtim(argv[from])) < 0L)
        from = -from;
    if (isigsettime(from) < 0)
        std::exit(2);
    if (to > 0L && (to = strtim(argv[to])) < 0L)
        to = -to;
    if (nosig) {        // convert samples only from specified signals
        so.resize(nosig);
        vo.resize(nosig);
        sig.resize(nosig);
        for (i = 0; i < nosig; i++) {
            if ((s = findsig(argv[isiglist+i])) < 0) {
                std::fprintf(stderr, "%s: can't read signal '%s'\n", pname,
                             argv[isiglist+i]);
                std::exit(2);
            }
            sig[i] = s;
        }
    }
    else {              // convert samples from all signals
        nosig = nisig;
        so.resize(nosig);
        vo.resize(nosig);
        sig.resize(nosig);
        for (i = 0; i < nosig; i++)
            sig[i] = i;
    }

    // Reset 'from' if a search was requested.
    if (search &&
        ((s = findsig(search)) < 0 ||
         (from = tnextvec(static_cast<WFDB_Signal>(s), from)) < 0)) {
        std::fprintf(stderr, "%s: can't read signal '%s'\n", pname, search);
        std::exit(2);
    }

    // Reset 'to' if a duration limit was specified.
    if (maxl > 0L && (maxl = strtim(argv[maxl])) < 0L)
        maxl = -maxl;
    if (maxl && (to == 0L || to > from + maxl))
        to = from + maxl;

    t = strtim("e");    // the end of the record
    if (t == 0) {
        // record length unspecified; determine length by a binary search
        wfdbquiet();
        lower = 0;
        upper = WFDB_TIME_MAX;
        t = 16 * 1024;
        while (lower < upper) {
            if (isigsettime(t) >= 0 && getvec(vi.data()) > 0)
                lower = t + 1;
            else
                upper = t;
            if (upper == WFDB_TIME_MAX && t < WFDB_TIME_MAX / 2)
                t *= 2;
            else
                t = lower + (upper - lower) / 2;
        }
        wfdbverbose();
        if (isigsettime(from) < 0)
            std::exit(2);
    }
    if (to == 0L || to > t)
        to = t;

    // Quit if there will be no output.
    if (to <= from) {
        wfdbquit();
        std::fprintf(stderr, "%s: no output\n", pname);
        std::fprintf(stderr,
                     " Use the -f and -t options to specify time limits\n"
                     "(or type '%s -h' for help)\n", pname);
        std::exit(1);
    }

    // Generate the names for the output .mat file and the output record.
    {
        const char *q = record + std::strlen(record) - 1;
                                    // *q = final char of record name
        if (*q == '/')  // short form name ('rec/' rather than 'rec/rec')
            sfname = 1;
        while (--q > record)
            if (*q == '/') { q++; break; } // omit path components from orec
        if (q < record) q = record;
        orec.assign(q, std::strlen(q) - sfname);
    }
    // If the input record is an EDF file, it will have a '.' in its name.
    // The output record will not be an EDF file, so it may not have a '.'
    // in its name.  Replace any '.' with '_' here.
    for (char &c : orec)
        if (c == '.') c = '_';
    orec += 'm';        // append 'm' to the output record name
    matname = orec + ".mat";

    // Determine if we can write 8-bit unsigned samples, or if 16 or 32 bits
    // are needed per sample.
    nbytesperelement = 1;
    for (i = 0; i < nosig; i++) {
        if (si[sig[i]].adcres > 0) {
            if (si[sig[i]].adcres > 16)
                nbytesperelement = 4;
            else if (si[sig[i]].adcres > 8 && nbytesperelement < 2)
                nbytesperelement = 2;
        }
        else {
            // adcres not specified; try to guess from format
            if (si[sig[i]].fmt == 24 || si[sig[i]].fmt == 32)
                nbytesperelement = 4;
            else if (si[sig[i]].fmt != 80 && nbytesperelement < 2)
                nbytesperelement = 2;
        }
    }
    if (nbytesperelement == 1) {
        sub4type = MAT8;
        wfdbtype = 80;
    }
    else if (nbytesperelement == 2) {
        sub4type = MAT16;
        wfdbtype = 16;
    }
    else {
        sub4type = MAT32;
        wfdbtype = 32;
    }

    for (i = 0; i < nosig; i++) {
        so[i] = si[sig[i]];
        so[i].fname = matname;
        so[i].group = 0;
        so[i].spf = 1;
        so[i].fmt = wfdbtype;
        so[i].adczero = 0;
        so[i].baseline -= si[sig[i]].adczero;
        // handle possibly missing units strings
        if (!so[i].units) {
            // WFDB-x: missing units are not assumed to be millivolts (except
            // in legacy mode: "in a .hea file, missing units can be assumed
            // to be millivolts")
            so[i].units = std::string(wfdbx_get_legacy() ? "mV" : "nd");
        }
        else if (so[i].units->empty()) {
            // this can happen only in an EDF file; in this case, the signal
            // is dimensionless (nd => "no dimension")
            so[i].units = std::string("nd");
        }
    }

    // Ensure the signal size does not exceed 2^31 byte limit
    max_length = 2147483648UL / nbytesperelement / nosig;
    if (static_cast<unsigned long>(to - from) > max_length) {
        std::fprintf(stderr, "%s: cannot write mat file -"
                     " data size exceeds 2GB limit\n", pname);
        std::exit(1);
    }

    nbytesofdata = static_cast<unsigned long>(nbytesperelement * nosig *
                                              (to - from));
                                // Bytes of actual data
    lremain = nbytesofdata % 8; // This is the remaining no. bytes that don't
                                // fit into integer multiple of 8. ie if 18
                                // bytes, lremain=2, from 17 to 18.

    // nbytesmaster = (8 + 8) + (8 + 8) + (8 + 8) + (8 + nbytesofdata)
    //  + padding.  Must be integer multiple 8.
    if (lremain == 0) {
        nbytesmaster = nbytesofdata + 56;
    }
    else {
        nbytesmaster = nbytesofdata + 64 - (lremain);
        for (i = 0; i < nosig; i++)
            so[i].bsize = 8;
    }

    // Create an empty .mat file.
    if (osigfopen(so.data(), static_cast<unsigned>(nosig)) != nosig) {
        wfdbquit();             // failed to open output, quit
        std::exit(1);
    }

    // Fill in the .mat file's prolog and write it.  (Elements of prolog[]
    // not set explicitly below are always zero.)

    // Start with 128 byte header
    std::memcpy(prolog, "MATLAB 5.0", 10); // first 116 bytes: descriptive text
    prolog[124] = fieldversion & 0xff; // Bytes 125-126 indicate version,
                                       // set to 0x0100 hex = 256.
    prolog[125] = (fieldversion >> 8) & 0xff;
    prolog[126] = 'I';  // Characters IM to indicate little endian
    prolog[127] = 'M';

    // 8 byte MASTER TAG, followed by the actual data.  First 4 is data type,
    // next 4 is number of bytes of entire field.
    prolog[128] = mastertype & 0xff; // Data type is always 14 for matrix.
    // Number of bytes of data element
    //  = (8 + 8) + (8 + 8) + (8 + 8) + (8 + Nvalues*bytespervalue)
    //  = 56 + Nvalues*bytespervalue
    prolog[132] = static_cast<char>(nbytesmaster & 0xff);
    prolog[133] = static_cast<char>((nbytesmaster >> 8) & 0xff);
    prolog[134] = static_cast<char>((nbytesmaster >> 16) & 0xff);
    prolog[135] = static_cast<char>((nbytesmaster >> 24) & 0xff);

    // Matrix data has 4 subelements (5 if imag): Array flags, dimensions
    // array, array name, real part.  Each subelement has its own subtag, and
    // subdata.

    // Subelement 1: Array flags.
    prolog[136] = (sub1type & 0xff);    // Sub tag 1: type
    prolog[140] = 8 & 0xff;             // Sub tag 1: size
    prolog[144] = sub1class & 0xff;     // Value class, indicating the MATLAB
                                        // data type. NOT the same as sub4type.

    // Subelement 2: Rows and Cols
    prolog[152] = sub2type & 0xff;      // Sub tag 2: type
    prolog[156] = 8 & 0xff;             // sub tag 2: size
    prolog[160] = static_cast<char>(nosig & 0xff);  // Number of signals.
    prolog[161] = static_cast<char>((nosig >> 8) & 0xff);
    prolog[162] = static_cast<char>((nosig >> 16) & 0xff);
    prolog[163] = static_cast<char>((nosig >> 24) & 0xff);
    prolog[164] = static_cast<char>((to - from) & 0xff);    // Value nrows.
    prolog[165] = static_cast<char>(((to - from) >> 8) & 0xff);
    prolog[166] = static_cast<char>(((to - from) >> 16) & 0xff);
    prolog[167] = static_cast<char>(((to - from) >> 24) & 0xff);

    // Subelement 3: Array Name
    prolog[168] = sub3type & 0xff;
    prolog[172] = 3 & 0xff;
    std::memcpy(prolog + 176, "val", 3);

    // Subelement 4: Data itself
    prolog[184] = static_cast<char>(sub4type & 0xff);
    prolog[188] = static_cast<char>(nbytesofdata & 0xff);
    prolog[189] = static_cast<char>((nbytesofdata >> 8) & 0xff);
    prolog[190] = static_cast<char>((nbytesofdata >> 16) & 0xff);
    prolog[191] = static_cast<char>((nbytesofdata >> 24) & 0xff);

    // Total size of everything before actual data:
    //   128 byte header
    // + 8 byte master tag
    // + 56 byte Subelements (48 byte default + 8 byte name)
    // = 192.
    wfdbputprolog(prolog, 192, 0);

    // Copy the selected data into the .mat file.
    for (t = from; t < to && stat >= 0; t++) {
        stat = getvec(vi.data());
        for (i = 0; i < nosig; i++)
            vo[i] = vi[sig[i]] - si[sig[i]].adczero;
        if (putvec(vo.data()) != nosig)
            break;
    }

    // If the input ended prematurely, pad the matrix with invalid samples.
    if (t != to) {
        std::fprintf(stderr, "%s (warning): final %lld columns are invalid\n",
                     pname, to - t);
        for (i = 0; i < nosig; i++)
            vo[i] = WFDB_INVALID_SAMPLE;
        while (t++ < to)
            putvec(vo.data());
    }

    // Create the new header file.
    setsampfreq(freq);
    p = mstimstr(-from);
    if (!p.empty() && p[0] == '[')
        setbasetime(p.c_str() + 1);
    newheader(orec.c_str());

    // Copy info from the old record, if any
    if (std::optional<std::string> info = getinfo(nullptr))
        do {
            (void)putinfo(info->c_str());
        } while ((info = getinfo(nullptr)));

    // Append additional info summarizing what wfdb2mat has done.
    p = std::string("Creator: ") + pname;
    (void)putinfo(p.c_str());
    p = std::string("Source: record ") + record;
    std::string qs = mstimstr(0);
    const char *q = qs.c_str();
    while (*q == ' ') q++;
    if (from != 0 || *q == '[') {
        p += "  Start: ";
        p += q;
    }
    (void)putinfo(p.c_str());

    // Determine offset between sample values and the raw byte/word values
    // as interpreted by Matlab/Octave.
    if (wfdbtype == 80)
        offset = 128;   // format 80 stores samples offset by 2^7
    else
        offset = 0;

    // Summarize the contents of the .mat file.
    std::printf("%s\n", p.c_str());
    std::printf("val has %d row%s (signal%s) and "
                "%lld column%s (sample%s/signal)\n",
                nosig, nosig == 1 ? "" : "s", nosig == 1 ? "" : "s",
                to-from, to == from+1 ? "" : "s", to == from+1 ? "" : "s");
    std::printf("Duration: %s\n", timstr(to-from).c_str());
    std::printf("Sampling frequency: %.12g Hz  Sampling interval: %.10g sec\n",
                freq, 1/freq);
    std::printf("Row\tSignal\tGain\tBase\tUnits\n");
    for (i = 0; i < nosig; i++)
        std::printf("%d\t%s\t%.12g\t%d\t%s\n", i+1,
                    so[i].desc ? so[i].desc->c_str() : "(null)", so[i].gain,
                    so[i].baseline + offset, so[i].units->c_str());
    std::printf("\nTo convert from raw units to the physical units shown\n"
                "above, call the 'rdmat.m' function from the wfdb-matlab\n"
                "toolbox: https://physionet.org/physiotools/matlab/"
                "wfdb-app-matlab/\n");
    wfdbquit();
    std::exit(0);
}

static const char *prog_name(const char *s)
{
    const char *p = s + std::strlen(s);

    while (p >= s && *p != '/')
        p--;
    return (p+1);
}

static const char *help_strings[] = {
 "usage: %s -r RECORD [OPTIONS ...]\n",
 "where RECORD is the name of the input record, and OPTIONS may include:",
 " -f TIME     begin at specified time",
 " -h          print this usage summary",
 " -H          read multifrequency signals in high resolution mode",
 " -l INTERVAL truncate output after the specified time interval (hh:mm:ss)",
 " -s SIGNAL   [SIGNAL ...]  convert only the specified signal(s)",
 " -S SIGNAL   search for a valid sample of the specified SIGNAL at or after",
 "\t\tthe time specified with -f, and begin converting then",
 " -t TIME     stop at specified time",
"Outputs are written to the current directory as RECORD.mat and RECORDm.hea.",
nullptr
};

static void help()
{
    int i;

    std::fprintf(stderr, help_strings[0], pname);
    for (i = 1; help_strings[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", help_strings[i]);
}
