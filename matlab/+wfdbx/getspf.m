function n = getspf()
%GETSPF Number of samples per signal returned by getvec per frame.
%   N = wfdbx.getspf() returns 1 in WFDB_LOWRES mode, or the maximum
%   number of samples per frame in WFDB_HIGHRES mode.
%
%   See also wfdbx.setgvmode.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
if S.sfreq ~= S.ffreq
    n = fix(S.sfreq / S.ffreq + 0.5);
else
    n = 1;
end
end
