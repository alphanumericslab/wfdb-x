function t = ann_round(x)
%ANN_ROUND Round times as the WFDB library does (round_to_time).
%   T = wfdbx.internal.ann_round(X) rounds the elements of X to the
%   nearest integer, halfway cases away from zero for positive values and
%   toward zero for negative ones (as the C code does), clamped to the
%   range of WFDB_Time; NaN gives the minimum time.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

LONG_MIN = -9223372036854775808;   % range of WFDB_Time (long)
LONG_MAX = 9223372036854775807;
t = fix(x);
f = x - t;
t = t + (x >= 0 & f >= 0.5) - (x < 0 & f < -0.5);
t(x >= LONG_MAX) = LONG_MAX;
t(x <= LONG_MIN | isnan(x)) = LONG_MIN;
end
