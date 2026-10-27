function g = conversion_gain(S, fn, s)
%CONVERSION_GAIN Gain of an input signal for the unit conversion functions.
%   G = wfdbx.internal.conversion_gain(S, FN, SIG) returns the gain of
%   input signal SIG (S is the signal state).  If SIG is not a valid signal
%   number, it reports "FN: invalid signal number SIG" and returns 0; if
%   the signal is uncalibrated (gain 0), it reports "FN: signal SIG is
%   uncalibrated" and returns 0.  wfdb-x: the C library assumed
%   WFDB_DEFGAIN (200 adu per physical unit) in both cases, as legacy mode
%   (wfdbx.wfdbx_set_legacy) does, without an error; see
%   docs/DIVERGENCES.md.
%
%   See also wfdbx.adumuv, wfdbx.muvadu, wfdbx.aduphys, wfdbx.physadu.
%
%   Part of the translation of lib/signal.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: an uncalibrated signal or an invalid signal
% number is an error, and 0 is returned (the C library assumed a gain of
% 200). Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md
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

WFDB_DEFGAIN = 200;     % lib/wfdb.h

s = mod(s, 4294967296);     % WFDB_Signal is unsigned
if S.legacy_mode    % wfdb-x: legacy mode (original behavior)
    if s < S.nvsig
        g = S.vsd(s + 1).info.gain;
    else
        g = WFDB_DEFGAIN;
    end
    if g == 0
        g = WFDB_DEFGAIN;
    end
    return;
end
if s >= S.nvsig
    wfdbx.internal.wfdb_error('%s: invalid signal number %u\n', fn, s);
    g = 0;
    return;
end
g = S.vsd(s + 1).info.gain;
if g == 0
    wfdbx.internal.wfdb_error('%s: signal %u is uncalibrated\n', fn, s);
end
end
