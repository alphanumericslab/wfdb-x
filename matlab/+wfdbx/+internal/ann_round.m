function t = ann_round(x)
%ANN_ROUND Round times as the WFDB library does (round_to_time).
%   T = wfdbx.internal.ann_round(X) rounds the elements of X to the
%   nearest integer, halfway cases away from zero for positive values and
%   toward zero for negative ones (as the C code does), clamped to the
%   range of WFDB_Time; NaN gives the minimum time.
%
%   Part of the translation of lib/annot.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/annot.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/annot.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

LONG_MIN = -9223372036854775808;   % range of WFDB_Time (long)
LONG_MAX = 9223372036854775807;
t = fix(x);
f = x - t;
t = t + (x >= 0 & f >= 0.5) - (x < 0 & f < -0.5);
t(x >= LONG_MAX) = LONG_MAX;
t(x <= LONG_MIN | isnan(x)) = LONG_MIN;
end
