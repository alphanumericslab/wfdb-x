// wfdbinit.cpp: WFDB library functions wfdbinit, wfdbquit, and wfdbflush
// (C++ port of lib/wfdbinit.c)
//
// Copyright (C) 1983-2012 George B. Moody (original C implementation,
// lib/wfdbinit.c; revised 2012-2019 by Benjamin Moody).
// C++ implementation part of wfdb-x, Reza Sameni, Oct 2026.
// GNU Library General Public License, version 2 or later (see LICENSE.LIB).

#include "wfdblib.hpp"

namespace wfdbx {

using namespace detail;

// wfdbinit: open annotation files and input signals
int wfdbinit(const char *record, const WFDB_Anninfo *aiarray, unsigned nann,
             WFDB_Siginfo *siarray, unsigned nsig)
{
    int stat;

    if ((stat = annopen(record, aiarray, nann)) == 0)
        stat = isigopen(record, siarray, static_cast<int>(nsig));
    return stat;
}

// wfdbquit: close all annotation and signal files
void wfdbquit()
{
    wfdb_anclose();     // close annotation files, reset variables
    wfdb_oinfoclose();  // close info file
    wfdb_sigclose();    // close signals, reset variables
    resetwfdb();        // restore the WFDB path
    wfdb_sampquit();    // release sample data buffer
    wfdb_freeinfo();    // release info strings
}

// wfdbflush: write all buffered output to files
void wfdbflush()
{
    wfdb_oaflush();     // flush buffered output annotations
    wfdb_osflush();     // flush buffered output samples
}

} // namespace wfdbx
