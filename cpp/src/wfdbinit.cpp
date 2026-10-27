// wfdbinit.cpp: WFDB library functions wfdbinit, wfdbquit, and wfdbflush.
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of lib/wfdbinit.c from the WFDB Software Package
// 10.7.0, by George B. Moody. The translation follows the logic and behavior
// of the original code, but it is new code, not the original C code.
//
// Changes from the original: wfdbquit leaves the input and output directories
// as they are (the original restored the WFDB path); legacy mode
// (wfdbx_set_legacy) restores the original behavior. Each change is marked
// "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
//
// Original C code: lib/wfdbinit.c, WFDB Software Package 10.7.0.
//   Copyright (C) 1983-2012 George B. Moody; revised 2012-2019 by
//   Benjamin Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

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
    // wfdb-x: in normal mode, the input directory is left as it is (in the C
    // library, resetwfdb restored the string returned by getwfdb, but not the
    // list of directories searched)
    if (wfdbx_get_legacy()) resetwfdb();    // restore the WFDB path
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
