function setgvmode(mode)
%SETGVMODE Set the getvec operating mode.
%   wfdbx.setgvmode(MODE) selects how multi-frequency records are read:
%   wfdbx.WFDB_LOWRES() (0: one sample per signal per frame, averaged) or
%   wfdbx.WFDB_HIGHRES() (1: samples at the highest frequency), possibly
%   combined (bitor) with wfdbx.WFDB_GVPAD() (2: replace invalid samples
%   with the previous valid sample).  A negative MODE uses the value of
%   the WFDBGVMODE environment variable (default WFDB_LOWRES).
%
%   See also wfdbx.getgvmode, wfdbx.getspf.
%
%   Translation of the C function setgvmode() (lib/signal.c, WFDB 10.7.0):
%   same arguments and results.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

WFDB_HIGHRES = 1;       % lib/wfdb.h
WFDB_GVPAD = 2;
DEFWFDBGVMODE = 0;      % WFDB_LOWRES (lib/wfdblib.h)

S = wfdbx.internal.sig_state();
if mode < 0
    p = wfdbx.internal.cgetenv('WFDBGVMODE');
    if ischar(p)
        mode = wfdbx.internal.cint32(wfdbx.internal.strtol(p));
    else
        mode = DEFWFDBGVMODE;
    end
end
mode = mod(mode, 4294967296);           % unsigned, for bitand
S.gvmode = bitand(mode, WFDB_HIGHRES + WFDB_GVPAD);
if bitand(mode, WFDB_HIGHRES) == WFDB_HIGHRES
    if S.spfmax == 0
        S.spfmax = 1;
    end
    S.sfreq = S.ffreq * S.spfmax;
else
    S.sfreq = S.ffreq;
end
end
