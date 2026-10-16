function wfdbsetiskew(s, skew)
%WFDBSETISKEW Change the skew of an input signal.
%   wfdbx.wfdbsetiskew(S, K) sets the skew of input signal S to K frames
%   (K must be less than the maximum skew of the record plus one).
%
%   See also wfdbx.wfdbgetskew.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
if s < S.nvsig && skew >= 0 && S.tspf && skew < fix(S.dsblen / S.tspf)
    S.vsd(s + 1).skew = skew;
end
end
