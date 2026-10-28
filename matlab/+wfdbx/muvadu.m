function a = muvadu(s, v)
%MUVADU Convert microvolts to ADC units.
%   A = wfdbx.muvadu(S, V) converts V microvolts to ADC units of input
%   signal S, rounded to an integer.  If S is not a valid signal number or
%   the signal is uncalibrated (gain 0), an error is reported and
%   WFDB_INVALID_SAMPLE is returned (WFDB-x: C assumed a gain of 200; see
%   docs/DIVERGENCES.md; in legacy mode, see wfdbx.wfdbx_set_legacy, a
%   gain of 200 is used, as in C).
%
%   See also wfdbx.adumuv, wfdbx.physadu.
%
%   Translation of the C function muvadu() (lib/signal.c, WFDB 10.7.0): same
%   arguments and results. Differences: an uncalibrated signal or an invalid
%   signal number is an error (the original assumed a gain of 200); see
%   docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: an uncalibrated signal or an invalid signal
% number is an error, and WFDB_INVALID_SAMPLE is returned (the C library
% assumed a gain of 200). Each change is marked "WFDB-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
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

WFDB_INVALID_SAMPLE = -32768;   % lib/wfdb.h

S = wfdbx.internal.sig_state();
g = wfdbx.internal.conversion_gain(S, 'muvadu', s);
if g == 0
    a = WFDB_INVALID_SAMPLE;
    return;
end
x = g * v * 0.001;
if x >= 0
    a = fix(x + 0.5);
else
    a = fix(x - 0.5);
end
end
