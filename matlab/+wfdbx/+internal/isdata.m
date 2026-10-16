function d = isdata()
%ISDATA An input signal structure (isdata in signal.c).
%   D = wfdbx.internal.isdata() returns a structure with fields info (a
%   wfdbx.siginfo structure), samp (the last sample read), skew, gvindex
%   and gvcount (used by getvec in WFDB_HIGHRES mode).

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

persistent d0
if isempty(d0)
    d0 = struct('info', wfdbx.siginfo(), 'samp', 0, 'skew', 0, ...
        'gvindex', 0, 'gvcount', 0);
end
d = d0;
end
