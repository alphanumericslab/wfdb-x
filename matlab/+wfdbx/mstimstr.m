function s = mstimstr(t)
%MSTIMSTR Convert a time in sample intervals to a string with milliseconds.
%   S = wfdbx.mstimstr(T) is as wfdbx.timstr(T), with milliseconds
%   ("hh:mm:ss.mmm" or "[hh:mm:ss.mmm dd/mm/yyyy]").  If no sampling
%   frequency is specified, an error is reported and T is returned as a
%   sample number, 'sN' with N = |T| (WFDB-x; in legacy mode, 1 sample per
%   second is used, as in C; see docs/DIVERGENCES.md).
%
%   See also wfdbx.timstr, wfdbx.strtim.
%
%   Translation of the C function mstimstr() (lib/signal.c, WFDB 10.7.0): same
%   arguments and results. Differences: if the sampling frequency is not
%   specified, it reports an error and returns the time as a sample number (the
%   original assumed 1 sample per second); see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: no sampling frequency is assumed (the C library
% used 1 sample per second): without one, an error is reported and the time
% is returned as a sample number. Each change is marked "WFDB-x:" in the
% code; docs/DIVERGENCES.md gives the reasons.
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
if S.ifreq > 0
    f = S.ifreq;
elseif S.sfreq > 0
    f = S.sfreq;
elseif S.legacy_mode
    f = 1;      % WFDB-x: legacy mode (original behavior)
else
    % WFDB-x: no default sampling frequency (C used 1 sample per second)
    wfdbx.internal.wfdb_error('mstimstr: sampling frequency is not specified\n');
    s = sprintf('s%d', abs(t));
    return;
end
s = wfdbx.internal.fmstimstr(t, f);
end
