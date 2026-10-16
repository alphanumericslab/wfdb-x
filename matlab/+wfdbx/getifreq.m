function f = getifreq()
%GETIFREQ Frequency at which getvec returns samples.
%   F = wfdbx.getifreq() returns the frequency set by wfdbx.setifreq, or
%   the sampling frequency of the open record.
%
%   See also wfdbx.setifreq, wfdbx.sampfreq.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
if S.ifreq > 0
    f = S.ifreq;
else
    f = S.sfreq;
end
end
