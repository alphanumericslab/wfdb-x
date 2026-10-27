function d = isdata()
%ISDATA An input signal structure (isdata in signal.c).
%   D = wfdbx.internal.isdata() returns a structure with fields info (a
%   wfdbx.siginfo structure), samp (the last sample read), skew, gvindex
%   and gvcount (used by getvec in WFDB_HIGHRES mode).
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

persistent d0
if isempty(d0)
    d0 = struct('info', wfdbx.siginfo(), 'samp', 0, 'skew', 0, ...
        'gvindex', 0, 'gvcount', 0);
end
d = d0;
end
