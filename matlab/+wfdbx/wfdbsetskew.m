function wfdbsetskew(s, skew)
%WFDBSETSKEW Set the skew of an output signal.
%   wfdbx.wfdbsetskew(S, K) sets the skew (in frames) written in the header
%   by setheader/newheader for output signal S.
%
%   See also wfdbx.wfdbgetskew, wfdbx.newheader.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
if s < S.nosig
    S.osd(s + 1).skew = skew;
end
end
