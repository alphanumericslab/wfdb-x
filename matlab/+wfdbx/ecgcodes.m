function c = ecgcodes()
%ECGCODES Annotation codes and position codes, as a structure.
%   C = wfdbx.ecgcodes() returns a structure whose fields are the annotation
%   codes of lib/ecgcodes.h (C.NOTQRS = 0, C.NORMAL = 1, ..., C.ACMAX = 49)
%   and the annotation position codes (C.APUNDEF ... C.APALOW).  The same
%   values are returned by the functions wfdbx.NORMAL(), wfdbx.PVC(), ...;
%   in loops, fetch the structure once and use its fields, which is faster:
%
%       C = wfdbx.ecgcodes();
%       if annot.anntyp == C.NORMAL, ... end
%
%   See also wfdbx.isqrs, wfdbx.map1, wfdbx.annpos.
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/ecgcodes.h from the WFDB Software
% Package 10.7.0, by T. Baker and George B. Moody. The translation follows the
% logic and behavior of the original code, but it is new code, not the original
% C code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/ecgcodes.h, WFDB Software Package 10.7.0.
%   Copyright (C) 1999 George B. Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

persistent s
if isempty(s)
    c.NOTQRS = 0;   % not-QRS (not a getann/putann code)
    c.NORMAL = 1;   % normal beat
    c.LBBB = 2;   % left bundle branch block beat
    c.RBBB = 3;   % right bundle branch block beat
    c.ABERR = 4;   % aberrated atrial premature beat
    c.PVC = 5;   % premature ventricular contraction
    c.FUSION = 6;   % fusion of ventricular and normal beat
    c.NPC = 7;   % nodal (junctional) premature beat
    c.APC = 8;   % atrial premature contraction
    c.SVPB = 9;   % premature or ectopic supraventricular beat
    c.VESC = 10;   % ventricular escape beat
    c.NESC = 11;   % nodal (junctional) escape beat
    c.PACE = 12;   % paced beat
    c.UNKNOWN = 13;   % unclassifiable beat
    c.NOISE = 14;   % signal quality change
    c.ARFCT = 16;   % isolated QRS-like artifact
    c.STCH = 18;   % ST change
    c.TCH = 19;   % T-wave change
    c.SYSTOLE = 20;   % systole
    c.DIASTOLE = 21;   % diastole
    c.NOTE = 22;   % comment annotation
    c.MEASURE = 23;   % measurement annotation
    c.PWAVE = 24;   % P-wave peak
    c.BBB = 25;   % left or right bundle branch block
    c.PACESP = 26;   % non-conducted pacer spike
    c.TWAVE = 27;   % T-wave peak
    c.RHYTHM = 28;   % rhythm change
    c.UWAVE = 29;   % U-wave peak
    c.LEARN = 30;   % learning
    c.FLWAV = 31;   % ventricular flutter wave
    c.VFON = 32;   % start of ventricular flutter/fibrillation
    c.VFOFF = 33;   % end of ventricular flutter/fibrillation
    c.AESC = 34;   % atrial escape beat
    c.SVESC = 35;   % supraventricular escape beat
    c.LINK = 36;   % link to external data (aux contains URL)
    c.NAPC = 37;   % non-conducted P-wave (blocked APB)
    c.PFUS = 38;   % fusion of paced and normal beat
    c.WFON = 39;   % waveform onset
    c.PQ = 39;   % PQ junction (beginning of QRS)
    c.WFOFF = 40;   % waveform end
    c.JPT = 40;   % J point (end of QRS)
    c.RONT = 41;   % R-on-T premature ventricular contraction
    c.ACMAX = 49;   % value of largest valid annot code (must be < 50)
    c.APUNDEF = 0;
    c.APSTD = 1;
    c.APHIGH = 2;
    c.APLOW = 3;
    c.APATT = 4;
    c.APAHIGH = 5;
    c.APALOW = 6;
    s = c;
end
c = s;
end
