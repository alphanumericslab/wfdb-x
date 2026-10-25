function s = datstr(date)
%DATSTR Convert a Julian date to a string.
%   S = wfdbx.datstr(DATE) returns " dd/mm/yyyy" (with a leading space).
%
%   See also wfdbx.strdat.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
s = sprintf(' %02d/%02d/%d', d, m, y);
S = wfdbx.internal.sig_state();
S.date_string = s;
S.pdays = -1;
end
