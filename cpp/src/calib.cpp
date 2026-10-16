// calib.cpp: WFDB library functions for signal calibration
// (C++ port of lib/calib.c)
//
// This file contains calopen (reads a calibration file into the calibration
// list), getcal (finds an entry of the list), putcal (appends an entry),
// newcal (writes the list to a calibration file), and flushcal (empties the
// list).  Calibration files are written with \r\n line separators.
//
// Copyright (C) 1991-2013 George B. Moody (original C implementation,
// lib/calib.c; revised 2019-2022 by Benjamin Moody).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

#include "wfdblib.hpp"

#include <cstdlib>
#include <cstring>

namespace wfdbx {
namespace detail {

namespace {

// A calibration list entry
struct CalEntry {
    double low = 0;     // low level of calibration pulse in physical units
    double high = 0;    // high level of calibration pulse in physical units
    double scale = 0;   // customary plotting scale (physical units per cm)
    std::optional<std::string> sigtype;     // signal type
    std::optional<std::string> units;       // physical units
    int caltype = 0;    // calibration pulse type
};

std::vector<CalEntry> &cal_list()
{
    static std::vector<CalEntry> list;
    return list;
}

// strtok(), with its state kept by the caller
char *next_token(char *s, const char *delim, char *&save)
{
    if (s == nullptr) s = save;
    if (s == nullptr) return nullptr;
    s += std::strspn(s, delim);
    if (*s == '\0') {
        save = s;
        return nullptr;
    }
    char *end = s + std::strcspn(s, delim);
    if (*end == '\0')
        save = end;
    else {
        *end = '\0';
        save = end + 1;
    }
    return s;
}

} // namespace

} // namespace detail

using namespace detail;

// calopen reads the specified calibration file;  if called with a NULL
// argument, it takes the value of the environment variable WFDBCAL to be the
// name of the calibration file.  If the calibration file name does not begin
// with "+", calopen empties the calibration list first;  otherwise, the "+"
// is discarded before attempting to open the file, which may be in any
// directory in the WFDB path.  If the file can be read, its contents are
// appended to the calibration list.
int calopen(const char *cfname)
{
    // If no calibration file is specified, return immediately.
    if (cfname == nullptr && (cfname = std::getenv("WFDBCAL")) == nullptr &&
        (cfname = DEFWFDBCAL) == nullptr)
        return 0;

    if (*cfname == '+')         // don't empty the calibration list
        cfname++;               // discard the '+' prefix
    else
        flushcal();             // empty the calibration list

    // Quit if file can't be found or opened.
    FilePtr cfile = wfdb_open(cfname, nullptr, WFDB_READ);
    if (!cfile) {
        wfdb_error("calopen: can't read calibration file %s\n", cfname);
        return -2;
    }

    // Read a line of the calibration file on each iteration.  See
    // wfdbcal(5) for a description of the format.
    std::string line;
    while (cfile->getline(line)) {
        std::vector<char> buf(line.begin(), line.end());
        buf.push_back('\0');
        char *p1, *p2, *p3, *p4, *p5, *p6, *save = nullptr;
        // ignore leading whitespace
        for (p1 = buf.data(); *p1 == ' ' || *p1 == '\t' || *p1 == '\r'; p1++)
            ;
        // skip comments, empty lines, and improperly formatted lines
        if (*p1 == '#' ||
            (p1 = next_token(p1, "\t", save)) == nullptr ||        // type
            (p2 = next_token(nullptr, " \t", save)) == nullptr ||  // low
            (p3 = next_token(nullptr, " \t", save)) == nullptr ||  // high
            (p4 = next_token(nullptr, " \t", save)) == nullptr ||  // pulse
            (p5 = next_token(nullptr, " \t", save)) == nullptr ||  // scale
            (p6 = next_token(nullptr, " \t\r\n", save)) == nullptr) // units
            continue;

        CalEntry c;
        // "*" is a wildcard that matches any signal type.
        if (std::strcmp(p1, "*") == 0) p1++;

        c.sigtype = std::string(p1);
        if (std::strcmp(p2, "-") == 0) {
            c.caltype = WFDB_AC_COUPLED;
            c.low = 0.0;
        } else {
            c.caltype = WFDB_DC_COUPLED;
            c.low = std::strtod(p2, nullptr);
        }
        if (std::strcmp(p3, "-") == 0)
            c.high = c.low = 0.0;
        else
            c.high = std::strtod(p3, nullptr);
        if (std::strcmp(p4, "square") == 0)
            c.caltype |= WFDB_CAL_SQUARE;
        else if (std::strcmp(p4, "sine") == 0)
            c.caltype |= WFDB_CAL_SINE;
        else if (std::strcmp(p4, "sawtooth") == 0)
            c.caltype |= WFDB_CAL_SAWTOOTH;
        // otherwise pulse shape is undefined
        c.scale = std::strtod(p5, nullptr);
        c.units = std::string(p6);
        cal_list().push_back(std::move(c));
    }
    (void)cfile->close();
    return 0;
}

// getcal attempts to find a calibration record which matches the supplied
// desc and units strings.  If the sigtype field of the record is a prefix
// of or an exact match for the desc string, and if the units field of the
// record is an exact match for the units string, the record matches.  If
// either desc or units is NULL, it is ignored for the purpose of finding a
// match.  If a match is found, it is copied into the caller's WFDB_Calinfo
// structure.
int getcal(const char *desc, const char *units, WFDB_Calinfo *cal)
{
    for (const CalEntry &c : cal_list()) {
        const std::string sigtype = c.sigtype.value_or("");
        if ((desc == nullptr ||
             std::strncmp(desc, sigtype.c_str(), sigtype.size()) == 0) &&
            (units == nullptr ||
             (c.units && std::strcmp(units, c.units->c_str()) == 0))) {
            cal->low = c.low;
            cal->high = c.high;
            cal->scale = c.scale;
            cal->sigtype = c.sigtype;
            cal->units = c.units;
            cal->caltype = c.caltype;
            return 0;
        }
    }
    return -1;
}

// putcal appends the caller's WFDB_Calinfo structure to the end of the
// calibration list.
int putcal(const WFDB_Calinfo *cal)
{
    CalEntry c;
    c.sigtype = cal->sigtype;
    c.caltype = cal->caltype;
    c.low = cal->low;
    c.high = cal->high;
    c.scale = cal->scale;
    c.units = cal->units;
    cal_list().push_back(std::move(c));
    return 0;
}

// newcal generates a calibration file based on the contents of the
// calibration list.
int newcal(const char *cfname)
{
    if (wfdb_checkname(cfname, "calibration file") < 0) return -1;

    FilePtr cfile = wfdb_open(cfname, nullptr, WFDB_WRITE);
    if (!cfile) {
        wfdb_error("newcal: can't create calibration file %s\n", cfname);
        return -1;
    }

    for (const CalEntry &c : cal_list()) {
        const char *pulsetype;

        // If sigtype is an empty string (matches anything), write it as "*".
        const std::string sigtype = c.sigtype.value_or("");
        cfile->printf("%s\t", sigtype.empty() ? "*" : sigtype.c_str());
        if (c.caltype & WFDB_DC_COUPLED)
            (void)cfile->printf("%g ", c.low);
        else
            (void)cfile->printf("- ");
        if (c.high != c.low)
            (void)cfile->printf("%g ", c.high);
        else
            (void)cfile->printf("- ");
        switch (c.caltype & (~WFDB_DC_COUPLED)) {
        case WFDB_CAL_SQUARE: pulsetype = "square"; break;
        case WFDB_CAL_SINE: pulsetype = "sine"; break;
        case WFDB_CAL_SAWTOOTH: pulsetype = "sawtooth"; break;
        default: pulsetype = "undefined"; break;
        }
        (void)cfile->printf("%s %g %s\r\n", pulsetype, c.scale,
                            c.units ? c.units->c_str() : "(null)");
    }

    int errflag = cfile->error();
    if (cfile->close()) errflag = 1;
    if (errflag) {
        wfdb_error("newcal: write error in calibration file\n");
        return -1;
    }
    return 0;
}

// flushcal empties the calibration list.
void flushcal()
{
    cal_list().clear();
}

} // namespace wfdbx
