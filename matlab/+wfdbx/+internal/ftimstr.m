function p = ftimstr(t, f)
%FTIMSTR Time string at frequency F (ftimstr in signal.c).
%   S = wfdbx.internal.ftimstr(T, F) is wfdbx.internal.fmstimstr(T, F)
%   without the milliseconds.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody, who contributed this
% function in 2011).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
p = wfdbx.internal.fmstimstr(t, f);
k = find(p == '.', 1);
if ~isempty(k)
    p = p(1:k - 1);
end
if t <= 0 && (S.btime ~= 0 || S.bdate ~= 0)
    p = [p S.date_string ']'];
end
end
