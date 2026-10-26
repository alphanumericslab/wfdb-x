function s = datstr(date)
%DATSTR Convert a Julian date to a string.
%   S = wfdbx.datstr(DATE) returns " dd/mm/yyyy" (with a leading space).
%
%   See also wfdbx.strdat.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ymd = wfdbx.internal.datymd(date);
s = sprintf(' %02d/%02d/%d', ymd(3), ymd(2), ymd(1));
S = wfdbx.internal.sig_state();
S.date_string = s;
S.pdays = -1;
end
