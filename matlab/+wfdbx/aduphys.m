function x = aduphys(s, a)
%ADUPHYS Convert ADC units to physical units.
%   X = wfdbx.aduphys(S, A) converts A (ADC units of input signal S) to
%   physical units: (A - baseline) / gain.  If S is not a valid signal
%   number or the signal is uncalibrated (gain 0), an error is reported and
%   NaN is returned (WFDB-x: C assumed a gain of 200; see
%   docs/DIVERGENCES.md; in legacy mode, see wfdbx.wfdbx_set_legacy, a
%   gain of 200 and a baseline of 0 for invalid signal numbers are used,
%   as in C).
%
%   See also wfdbx.physadu, wfdbx.adumuv.
%
%   Translation of the C function aduphys() (lib/signal.c, WFDB 10.7.0): same
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
% number is an error, and NaN is returned (the C library assumed a gain of
% 200). Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md
% gives the reasons.
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

S = wfdbx.internal.sig_state();
g = wfdbx.internal.conversion_gain(S, 'aduphys', s);
if g == 0
    x = NaN;
    return;
end
s = mod(s, 4294967296);     % WFDB_Signal is unsigned
if s < S.nvsig
    b = S.vsd(s + 1).info.baseline;
else
    b = 0;      % WFDB-x: legacy mode (original behavior)
end
x = (a - b) / g;
end

