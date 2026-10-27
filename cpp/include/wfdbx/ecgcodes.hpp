// wfdbx/ecgcodes.hpp: annotation codes (C++ version of <wfdb/ecgcodes.h>).
//
// This file is part of wfdb-x, an independent reimplementation of the WFDB
// Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
//
// It is a C++ translation of lib/ecgcodes.h from the WFDB Software Package
// 10.7.0, by T. Baker and George B. Moody. The translation follows the logic
// and behavior of the original code, but it is new code, not the original C
// code.
//
// Changes from the original: none, apart from the language.
//
// Original C code: lib/ecgcodes.h, WFDB Software Package 10.7.0.
//   Copyright (C) 1999 George B. Moody.
// C++ translation and changes: Copyright (C) 2026 Reza Sameni.
//
// This library is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See LICENSE.

#ifndef WFDBX_ECGCODES_HPP
#define WFDBX_ECGCODES_HPP

namespace wfdbx {

constexpr int NOTQRS = 0;     ///< not-QRS (not a getann/putann code)
constexpr int NORMAL = 1;     ///< normal beat
constexpr int LBBB = 2;       ///< left bundle branch block beat
constexpr int RBBB = 3;       ///< right bundle branch block beat
constexpr int ABERR = 4;      ///< aberrated atrial premature beat
constexpr int PVC = 5;        ///< premature ventricular contraction
constexpr int FUSION = 6;     ///< fusion of ventricular and normal beat
constexpr int NPC = 7;        ///< nodal (junctional) premature beat
constexpr int APC = 8;        ///< atrial premature contraction
constexpr int SVPB = 9;       ///< premature or ectopic supraventricular beat
constexpr int VESC = 10;      ///< ventricular escape beat
constexpr int NESC = 11;      ///< nodal (junctional) escape beat
constexpr int PACE = 12;      ///< paced beat
constexpr int UNKNOWN = 13;   ///< unclassifiable beat
constexpr int NOISE = 14;     ///< signal quality change
constexpr int ARFCT = 16;     ///< isolated QRS-like artifact
constexpr int STCH = 18;      ///< ST change
constexpr int TCH = 19;       ///< T-wave change
constexpr int SYSTOLE = 20;   ///< systole
constexpr int DIASTOLE = 21;  ///< diastole
constexpr int NOTE = 22;      ///< comment annotation
constexpr int MEASURE = 23;   ///< measurement annotation
constexpr int PWAVE = 24;     ///< P-wave peak
constexpr int BBB = 25;       ///< left or right bundle branch block
constexpr int PACESP = 26;    ///< non-conducted pacer spike
constexpr int TWAVE = 27;     ///< T-wave peak
constexpr int RHYTHM = 28;    ///< rhythm change
constexpr int UWAVE = 29;     ///< U-wave peak
constexpr int LEARN = 30;     ///< learning
constexpr int FLWAV = 31;     ///< ventricular flutter wave
constexpr int VFON = 32;      ///< start of ventricular flutter/fibrillation
constexpr int VFOFF = 33;     ///< end of ventricular flutter/fibrillation
constexpr int AESC = 34;      ///< atrial escape beat
constexpr int SVESC = 35;     ///< supraventricular escape beat
constexpr int LINK = 36;      ///< link to external data (aux contains URL)
constexpr int NAPC = 37;      ///< non-conducted P-wave (blocked APB)
constexpr int PFUS = 38;      ///< fusion of paced and normal beat
constexpr int WFON = 39;      ///< waveform onset
constexpr int PQ = WFON;      ///< PQ junction (beginning of QRS)
constexpr int WFOFF = 40;     ///< waveform end
constexpr int JPT = WFOFF;    ///< J point (end of QRS)
constexpr int RONT = 41;      ///< R-on-T premature ventricular contraction
constexpr int ACMAX = 49;     ///< largest valid annotation code (< 50)

} // namespace wfdbx

#endif // WFDBX_ECGCODES_HPP
