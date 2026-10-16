function setbasecount(counter)
%SETBASECOUNT Set the base counter value.
%   wfdbx.setbasecount(C) sets the counter value of sample 0.
%
%   See also wfdbx.getbasecount.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
S.bcount = counter;
end
