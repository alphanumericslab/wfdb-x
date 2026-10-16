function f = sample_valid()
%SAMPLE_VALID Status of the last call of wfdbx.sample.
%   F = wfdbx.sample_valid() returns 1 if the last sample returned by
%   wfdbx.sample was valid, -1 if it was invalid (or the signal number was
%   out of range), 0 if it was beyond the end of the record.
%
%   See also wfdbx.sample.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
f = S.sample_vflag;
end
