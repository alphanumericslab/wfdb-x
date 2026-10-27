function stat = setsampfreq(freq)
%SETSAMPFREQ Set the sampling frequency.
%   STAT = wfdbx.setsampfreq(F) sets the sampling frequency (Hz) used for
%   output headers and time conversions.  Returns 0, or -1 if F < 0.
%
%   See also wfdbx.sampfreq.
%
%   Translation of the C function setsampfreq() (lib/signal.c, WFDB 10.7.0):
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

S = wfdbx.internal.sig_state();
if freq >= 0
    S.sfreq = freq;
    S.ffreq = freq;
    if S.spfmax == 0
        S.spfmax = 1;
    end
    if bitand(S.gvmode, 1) == 1     % WFDB_HIGHRES
        S.sfreq = S.sfreq * S.spfmax;
    end
    stat = 0;
    return;
end
wfdbx.internal.wfdb_error('setsampfreq: sampling frequency must not be negative\n');
stat = -1;
end
