function ymd = datymd(date)
%DATYMD Convert a Julian date to [year month day].
%   YMD = wfdbx.internal.datymd(DATE) returns the date as a 1-by-3 double
%   [y m d], with the calendar code of wfdbx.datstr (which uses it).
%
%   Part of the translation of lib/signal.c (WFDB 10.7.0).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
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

% The algorithm is caldat() of "Numerical Recipes" (Press, Flannery,
% Teukolsky and Vetterling, 1986), as in C.
IGREG = 2299161;        % Julian day of 15/10/1582: Gregorian calendar
if date >= IGREG        % Gregorian calendar correction
    gcorr = fix(((date - 1867216) - 0.25) / 36524.25);
    date = date + 1 + gcorr - fix(0.25 * gcorr);
end
date = date + 1524;
jy = fix(6680 + ((date - 2439870) - 122.1) / 365.25);
jd = fix(365 * jy + (0.25 * jy));
jm = fix((date - jd) / 30.6001);
d = date - jd - fix(30.6001 * jm);
m = jm - 1;
if m > 12
    m = m - 12;
end
y = jy - 4715;
if m > 2
    y = y - 1;
end
if y <= 0
    y = y - 1;
end
ymd = [y m d];
end
