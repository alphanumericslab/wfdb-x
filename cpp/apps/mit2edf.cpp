// mit2edf.cpp: convert MIT format header and signal files to EDF (European
// Data Format) file.
//
// This file is part of WFDB-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of convert/mit2edf.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original program, but it is new code, not the original C code.
//
// Changes from the original: no built-in sampling frequency, gain or ADC
// resolution: the record must give the sampling frequency, and the gain and
// ADC resolution of every signal (the original assumed 250 Hz and 200 adu/mV,
// and guessed the resolution from the storage format); unspecified units are
// written as "nd" (the original wrote "mV"); --legacy, as the first argument,
// restores the original behavior. Each change is marked "wfdb-x:" in the code;
// docs/DIVERGENCES.md gives the reasons.
//
// Original C program: convert/mit2edf.c, WFDB Software Package 10.7.0.
//   Copyright (C) 2002-2014 George B. Moody; revised 2020 by Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.
//
// As in the C program, the current date and time are used as the start of a
// record that has none.  Where the C program has undefined behavior, this
// port uses: 0 for time and date fields that cannot be parsed; the first 50
// characters of a long record name for the default output file name; and
// it does not write header fields past the end of the header (if they are
// longer than their space), divide by zero (when no frame fits in a block,
// or in verbose mode when a block is longer than a minute), or name a month
// outside 1-12 (DEC is used, as for the Python port).

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <wfdbx/wfdb.hpp>

#include "cemul.hpp"
using namespace wfdbx;

#define EDFMAXBLOCK 61440   // maximum data block length, in bytes
#define EDFHDRLEN 256L      // EDF header length, in bytes, per signal and for
                            // the fixed-size part

static const char *pname;

static void help();

// wfdb-x: legacy mode (original behavior).  The C program's guess of the
// ADC resolution of a signal, based on its format.
static int legacy_adcres(int fmt)
{
    switch (fmt) {
      case 524:
      case 24: return 24;
      case 32: return 32;
      case 508:
      case 80: return 8;
      case 212: return 12;
      case 310:
      case 311: return 10;
      case 516:
      case 16:
      case 61:
      case 160: return 16;
      default:
        // resolution for unknown future formats
        if (fmt >= 100 && fmt % 100 > 0 && fmt % 100 <= 32)
            return fmt % 100;
        return 16;
    }
}

int main(int argc, char **argv)
{
    // wfdb-x: --legacy as the first argument selects legacy mode (the
    // behavior of the original program; see src/signal.cpp)
    wfdbx_legacy_args(argc, argv);

    char buf[100];
    const char *ofname = nullptr, *p;
    std::string record, ofnamebuf;
    double frames_per_second, seconds_per_block;
    std::FILE *ofile = nullptr;
    int i, j, k, nsig, samples_per_frame, start_date_recorded,
        edfplusflag = 0, vflag = 0, day = 0, month = 0, year = 0, hour = 0,
        minute = 0, second = 0;
    bool have_record = false;
    long bytes_per_block, frames_per_block, n, nblocks,
        blocks_per_minute = 0, blocks_per_hour = 0;
    static const char *month_name[] = { "JAN", "FEB", "MAR", "APR", "MAY",
                                        "JUN", "JUL", "AUG", "SEP", "OCT",
                                        "NOV", "DEC" };

    // Interpret the command line.
    pname = argv[0];
    for (i = 1; i < argc; i++) {
        if (*argv[i] == '-') switch (argv[i][1]) {
          case 'h':     // show usage and quit
            help();
            std::exit(0);
          case 'o':     // output file name follows
            if (++i < argc)
                ofname = argv[i];
            else {
                std::fprintf(stderr, "%s: output file name must follow -o\n",
                             pname);
                std::exit(1);
            }
            break;
          case 'p':     // format output as EDF+
            edfplusflag = 1;
            break;
          case 'r':     // record name follows
            if (++i < argc) {
                record = argv[i];
                have_record = true;
            }
            else {
                std::fprintf(stderr, "%s: record name must follow -r\n",
                             pname);
                std::exit(1);
            }
            break;
          case 'v':     // select verbose mode
            vflag = 1;
            break;
        }
    }

    // Quit if no record was specified.
    if (!have_record) {
        help();
        std::exit(1);
    }

    // Construct or validate the name of the output file.
    if (ofname == nullptr) {
        size_t q = record.rfind('/');
        q = (q == std::string::npos) ? 0 : q + 1;
        ofnamebuf = record.substr(q, WFDB_MAXRNL) + ".edf";
        ofname = ofnamebuf.c_str();
    }
    else if (edfplusflag) {
        size_t len = std::strlen(ofname);
        p = ofname + (len >= 4 ? len - 4 : 0);
        if (std::strcmp(p, ".edf") && std::strcmp(p, ".EDF")) {
            std::fprintf(stderr, "%s: '%s' is not a valid EDF+ file name\n",
                         pname, ofname);
            std::fprintf(stderr,
                         " EDF+ file names must end with '.edf' or '.EDF')\n");

            std::exit(1);
        }
    }

    // Open the input record.
    if ((nsig = isigopen(record.c_str(), nullptr, 0)) <= 0) std::exit(2);
    std::vector<WFDB_Siginfo> si(nsig);
    if ((nsig = isigopen(record.c_str(), si.data(), nsig)) <= 0)
        std::exit(3);

    // wfdb-x: an EDF file needs the sampling frequency, and the gain and the
    // ADC resolution of each signal (the C program assumed 250 Hz and
    // 200 adu/mV, and guessed the resolution from the format, if the header
    // did not specify them, as legacy mode does).
    if (!wfdbx_get_legacy() && sampfreq(nullptr) <= 0.) {
        std::fprintf(stderr,
                     "%s: sampling frequency of record %s is not specified\n",
                     pname, record.c_str());
        std::exit(3);
    }
    for (i = 0; i < nsig && !wfdbx_get_legacy(); i++) {
        if (si[i].gain == 0.) {
            std::fprintf(stderr, "%s: signal %d of record %s is uncalibrated\n",
                         pname, i, record.c_str());
            std::exit(3);
        }
        if (si[i].adcres < 1) { // the EDF digital range needs it
            std::fprintf(stderr, "%s: ADC resolution of signal %d of record "
                         "%s is not specified\n", pname, i, record.c_str());
            std::exit(3);
        }
    }

    // Open the output (EDF) file.
    if ((ofile = std::fopen(ofname, "wb")) == nullptr) {
        std::fprintf(stderr, "%s: can't create %s\n", pname, ofname);
        std::exit(4);
    }

    // Get start date and time
    std::string ts = timstr(0L);
    start_date_recorded = 1;
    if (ts.empty() || ts[0] != '[') {
        // start date/time not recorded -- use current date
        setbasetime(nullptr);
        ts = timstr(0L);
        start_date_recorded = 0;
    }
    i = std::sscanf(ts.c_str(), "[%d:%d:%d %d/%d/%d",
                    &hour, &minute, &second, &day, &month, &year);
    if (i != 6) {       // start time, but not date, recorded
        start_date_recorded = 0;
        day = month = 1;
        year = 1985;    // beginning of EDF epoch
    }

    // Calculate block duration.  (In the EDF spec, blocks are called
    // "records" or "data records", but this would be confusing here since
    // "record" refers to the entire recording -- so here we say "blocks".)
    for (i = samples_per_frame = 0; i < nsig; i++)
        samples_per_frame += si[i].spf;
    frames_per_second = strtim("1:0")/60.0;   // i.e., the number of frames
                                              // per minute, divided by 60
    frames_per_block = static_cast<long>(10 * frames_per_second + 0.5);
                                              // ten seconds
    bytes_per_block = 2 * samples_per_frame * frames_per_block;
                                   // EDF specifies 2 bytes per sample
    while (bytes_per_block > EDFMAXBLOCK) {
        // blocks would be too long -- reduce their length by a factor of 10
        frames_per_block /= 10;
        bytes_per_block = samples_per_frame * 2 * frames_per_block;
    }

    seconds_per_block = frames_per_block / frames_per_second;

    if (frames_per_block < 1 && bytes_per_block < EDFMAXBLOCK/60) {
        frames_per_block = static_cast<long>(strtim("1:0"));
                                        // the number of frames/minute
        bytes_per_block = 2* samples_per_frame * frames_per_block;
        seconds_per_block = 60;
    }

    if (bytes_per_block > EDFMAXBLOCK) {
        std::fprintf(stderr, "%s: can't convert record %s to EDF\n", pname,
                     record.c_str());
        std::fprintf(stderr,
 " EDF blocks cannot be larger than %d bytes, but each input frame requires\n",
                     EDFMAXBLOCK);
        std::fprintf(stderr,
 " %d bytes.  Use 'snip' to select a subset of the input signals, or use\n"
                     " 'xform' to reduce the sampling frequency.\n",
                     samples_per_frame * 2);
        std::exit(5);
    }

    // Calculate the number of blocks to be written.  strtim("e") is the
    // frame number of the last frame in the record, and that of the first
    // frame is 0, so the number of frames is strtim("e") + 1.  The
    // calculation rounds up so that we don't lose any frames, even if the
    // number of frames is not an exact multiple of frames_per_block.
    nblocks = (frames_per_block ?
               static_cast<long>(strtim("e")) / frames_per_block : 0) + 1;

    // Allocate and initialize arrays and buffers.
    std::vector<int> dmax(nsig), dmin(nsig);
    std::vector<double> pmax(nsig), pmin(nsig);
    const size_t hlen = static_cast<size_t>((nsig + 1) * EDFHDRLEN);
    std::vector<char> header(hlen, ' ');
    std::vector<WFDB_Sample> v(samples_per_frame > 0 ? samples_per_frame : 0);
    std::vector<char> block(bytes_per_block > 0 ? bytes_per_block : 0);
    std::vector<long> blockp(nsig);     // offsets within block

    if (vflag)
        std::printf("Converting record %s to %s (%s mode)\n", record.c_str(),
                    ofname, edfplusflag == 1 ? "EDF+" : "EDF");

    // Calculate physical and digital extrema.
    for (i = 0; i < nsig; i++) {
        // (wfdb-x: the ADC resolution was checked above; the C program
        // guessed it from the storage format if the header did not give it,
        // as legacy mode does.)
        if (wfdbx_get_legacy() && si[i].adcres < 1) // invalid in .hea file
            si[i].adcres = legacy_adcres(si[i].fmt);
        unsigned half = 1u << ((si[i].adcres - 1) & 31);
        dmax[i] = static_cast<int>(static_cast<unsigned>(si[i].adczero) +
                                   half - 1u);
        dmin[i] = static_cast<int>(static_cast<unsigned>(si[i].adczero) -
                                   half);
        pmax[i] = aduphys(static_cast<WFDB_Signal>(i), dmax[i]);
        pmin[i] = aduphys(static_cast<WFDB_Signal>(i), dmin[i]);
    }

    // Start filling in the header.  The first line of comments above each
    // entry is as given in the EDF technical specification
    // (http://www.hsr.nl/edf/edf_spec.htm).
    size_t pos = 0;
    // strncpy(header + pos, s, len): copy at most len bytes of s, padding
    // with NULs (within the header).
    auto put = [&](const char *s, size_t len) {
        size_t sl = std::strlen(s);
        for (size_t m = 0; m < len && pos + m < hlen; m++)
            header[pos + m] = m < sl ? s[m] : '\0';
    };

    // Version of this data format (0).
    put("0", 1);
    pos += 8;

    // Local patient identification.
    if (record.size() > 80) record.resize(79);
    put(record.c_str(), record.size());
    pos += 80;

    // Local recording identification.
    //
    // Bob Kemp recommends using this field to encode the start date
    // including an abbreviated month name in English and a full (4-digit)
    // year, as is done here if this information is available in the input
    // record.  EDF+ requires this.
    if (start_date_recorded)
        std::snprintf(buf, sizeof(buf), "Startdate %02d-%s-%d", day,
                      month_name[(month >= 1 && month <= 12) ? month-1 : 11],
                      year);
    else {
        std::snprintf(buf, sizeof(buf), "Startdate not recorded");
        if (edfplusflag)
            std::fprintf(stderr,
                     "WARNING (%s): EDF+ requires start date (not specified)\n",
                         pname);
    }
    put(buf, std::strlen(buf));
    pos += 80;

    // Start date of recording (dd.mm.yy).
    std::snprintf(buf, sizeof(buf), "%02d.%02d.%02d", day, month, year % 100);
    put(buf, 8);
    pos += 8;

    // Start time of recording (hh.mm.ss).
    std::snprintf(buf, sizeof(buf), "%02d.%02d.%02d", hour, minute, second);
    put(buf, 8);
    pos += 8;

    // Number of bytes in header.
    std::snprintf(buf, sizeof(buf), "%ld", (nsig + 1)*EDFHDRLEN);
    put(buf, std::strlen(buf));
    pos += 8;

    // Reserved.
    if (edfplusflag)
        put("EDF+C", 5);
    pos += 44;

    // Number of blocks (-1 if unknown).
    std::snprintf(buf, sizeof(buf), "%ld", nblocks);
    put(buf, std::strlen(buf));
    pos += 8;

    // Duration of a block, in seconds.
    std::snprintf(buf, sizeof(buf), "%g", seconds_per_block);
    if (std::strlen(buf) > 8) buf[8] = '\0';
    put(buf, std::strlen(buf));
    pos += 8;

    // Number of signals.
    std::snprintf(buf, sizeof(buf), "%d", nsig);
    put(buf, std::strlen(buf));
    pos += 4;

    // Label (e.g., EEG FpzCz or Body temp).
    for (i = 0; i < nsig; i++, pos += 16) {
        std::string &d = *si[i].desc;
        if (d.size() > 16) d.resize(16);
        put(d.c_str(), d.size());
    }

    // Transducer type (e.g., AgAgCl electrode).
    for (i = 0; i < nsig; i++, pos += 80) {
        put("transducer type not recorded",
            std::strlen("transducer type not recorded"));
    }

    // Physical dimension (e.g., uV or degreeC).
    for (i = 0; i < nsig; i++, pos += 8) {
        // wfdb-x: unspecified units are shown as "nd" (C, legacy mode: mV)
        if (!si[i].units)
            si[i].units = std::string(wfdbx_get_legacy() ? "mV" : "nd");
        else if (si[i].units->size() > 8) si[i].units->resize(8);
        put(si[i].units->c_str(), si[i].units->size());
    }

    // Physical minimum (e.g., -500 or 34).
    for (i = 0; i < nsig; i++, pos += 8) {
        std::snprintf(buf, sizeof(buf), "%g", pmin[i]);
        put(buf, std::strlen(buf));
    }

    // Physical maximum (e.g., 500 or 40).
    for (i = 0; i < nsig; i++, pos += 8) {
        std::snprintf(buf, sizeof(buf), "%g", pmax[i]);
        put(buf, std::strlen(buf));
    }

    // Digital minimum (e.g., -2048).
    for (i = 0; i < nsig; i++, pos += 8) {
        std::snprintf(buf, sizeof(buf), "%d", dmin[i]);
        put(buf, std::strlen(buf));
    }

    // Digital maximum (e.g., 2047).
    for (i = 0; i < nsig; i++, pos += 8) {
        std::snprintf(buf, sizeof(buf), "%d", dmax[i]);
        put(buf, std::strlen(buf));
    }

    // Prefiltering (e.g., HP:0.1Hz LP:75Hz).
    for (i = 0; i < nsig; i++, pos += 80) {
        put("prefiltering not recorded",
            std::strlen("prefiltering not recorded"));
    }

    // Number of samples per block.
    for (i = 0; i < nsig; i++, pos += 8) {
        std::snprintf(buf, sizeof(buf), "%ld", frames_per_block * si[i].spf);
        put(buf, std::strlen(buf));
    }

    // (The last 32*nsig bytes in the header are unused.)

    // Write the header to the output file.
    std::fwrite(header.data(), 1, hlen, ofile);

    // Check that all characters in the header are valid (printable ASCII
    // between 32 and 126 inclusive).  Note that this test does not prevent
    // generation of files containing invalid characters;  it merely warns
    // the user if this has happened.
    for (i = 0; i < static_cast<int>(hlen); i++) {
        int c = static_cast<signed char>(header[i]);
        if (c < 32 || c > 126)
            std::fprintf(stderr,
                         "WARNING (%s): output contains an invalid character,"
                         " %d, at byte %d\n", pname, c, i);
    }

    // In verbose mode, summarize what we've done so far.
    if (vflag) {
        std::printf(" Header block size: %ld bytes\n", (nsig+1) * EDFHDRLEN);
        std::printf(" Data block size: %g second%s (%ld frame%s or %ld bytes)\n",
                    seconds_per_block, seconds_per_block == 1.0 ? "" : "s",
                    frames_per_block, frames_per_block == 1 ? "" : "s",
                    bytes_per_block);
        std::string es = timstr(strtim("e"));
        for (p = es.c_str(); *p == ' '; p++)
            ;
        std::printf(" Recording length: %s"
                    " (%ld data blocks, %ld frames, %ld bytes)\n",
                    p, nblocks, nblocks*frames_per_block,
                    nblocks*bytes_per_block);
        std::printf(" Total length of file to be written: %ld bytes\n",
                    (nsig+1)*EDFHDRLEN + nblocks*bytes_per_block);

        blocks_per_minute = static_cast<long>(60 / seconds_per_block);
        blocks_per_hour = 60L * blocks_per_minute;
    }

    // Write the data blocks.
    for (n = 1; n <= nblocks; n++) {
        if (nsig > 0) blockp[0] = 0;
        for (j = 1; j < nsig; j++)
            blockp[j] = blockp[j-1] + 2 * frames_per_block * si[j-1].spf;
        for (i = 0; i < frames_per_block; i++) {
            if (nsig != getframe(v.data())) {
                // end of input: pad last block with invalid samples
                for (j = 0; j < samples_per_frame; j++)
                    v[j] = WFDB_INVALID_SAMPLE;
            }
            const WFDB_Sample *vp = v.data();
            for (j = 0; j < nsig; j++) {
                for (k = 0; k < si[j].spf; k++) {
                    block[blockp[j]++] = static_cast<char>((*vp) & 0xff);
                    block[blockp[j]++] = static_cast<char>((*vp++ >> 8) & 0xff);
                }
            }
        }
        std::fwrite(block.data(), 1, block.size(), ofile);
        if (vflag) {
            if (blocks_per_minute && n % blocks_per_minute == 0) {
                std::printf(".");
                std::fflush(stdout);
            }
            if (blocks_per_hour && n % blocks_per_hour == 0)
                std::printf("\n");
        }
    }
    cemul::fclose_output(ofile, pname, ofname);    // WFDB-x
    std::printf("\n");

    if (edfplusflag) {
        std::fprintf(stderr,
"\nWARNING (%s): EDF+ requires the subject's gender, birthdate, and name, as\n"
" well as additional information about the recording that is not usually\n"
" available.  This information is not saved in the output file even if\n"
" available.  EDF+ also requires the use of standard names for signals and\n"
" for physical units;  these requirements are not enforced by this program.\n"
" To make the output file fully EDF+ compliant, its header must be edited\n"
" manually.\n",
                     pname);
        for (i = nsig-1; i >= 0; i--)
            if (*si[i].desc == "EDF-Annotations")
                break;
        if (i < 0)
            std::fprintf(stderr,
"\nWARNING:  The output file does not include EDF annotations, which are\n"
                         " required for EDF+.\n");
    }

    wfdbquit();
    std::exit(0);
}

static const char *help_strings[] = {
 "usage: %s -r RECORD [OPTIONS ...]\n",
 "where RECORD is the name of the input record, and OPTIONS may include:",
 " -h          print this usage summary",
 " -o EDFILE   write the specified European Data Format file (default:",
 "              RECORD.edf)",
 " -p          write the output as an EDF+ file",
 " -v          select verbose mode",
 "This program reads MIT-format signal and header files and writes an EDF",
 "file containing the same data.",
nullptr
};

static void help()
{
    int i;

    std::fprintf(stderr, help_strings[0], pname);
    for (i = 1; help_strings[i] != nullptr; i++)
        std::fprintf(stderr, "%s\n", help_strings[i]);
}
