function date = strdat(string)
%STRDAT Convert a date string to a Julian date.
%   D = wfdbx.strdat(STRING) converts "dd/mm/yyyy" to a Julian date
%   number; it returns 0 if STRING is not a valid date.
%
%   See also wfdbx.datstr.
%
%   Translation of the C function strdat() (lib/signal.c, WFDB 10.7.0): same
%   arguments and results.

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

% The algorithm is julday() of "Numerical Recipes" (Press, Flannery,
% Teukolsky and Vetterling, 1986), as in C.
IGREG = 15 + 31 * (10 + 12 * 1582);     % 15/10/1582: Gregorian calendar

date = 0;
mp = find(string == '/', 1);
if isempty(mp)
    return;
end
yp = find(string(mp + 1:end) == '/', 1);
if isempty(yp)
    return;
end
yp = mp + yp;
d = wfdbx.internal.cint32(wfdbx.internal.strtol(string));
if d < 1 || d > 31
    return;
end
m = wfdbx.internal.cint32(wfdbx.internal.strtol(string, 10, mp + 1));
if m < 1 || m > 12
    return;
end
y = wfdbx.internal.cint32(wfdbx.internal.strtol(string, 10, yp + 1));
if y == 0
    return;
end
if m > 2
    jy = y;
    jm = m + 1;
else
    jy = y - 1;
    jm = m + 13;
end
if jy > 0
    date = fix(365.25 * jy);
else
    date = -fix(-365.25 * (jy + 0.25));
end
date = date + fix(30.6001 * jm) + d + 1720995;
if d + 31 * (m + 12 * y) >= IGREG
    gcorr = fix(0.01 * jy);         % Gregorian calendar correction
    date = date + 2 - gcorr + fix(0.25 * gcorr);
end
end
