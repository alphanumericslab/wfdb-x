function date = strdat(string)
%STRDAT Convert a date string to a Julian date.
%   D = wfdbx.strdat(STRING) converts "dd/mm/yyyy" to a Julian date
%   number; it returns 0 if STRING is not a valid date.
%
%   See also wfdbx.datstr.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
