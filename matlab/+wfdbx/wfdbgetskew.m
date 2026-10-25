function skew = wfdbgetskew(s)
%WFDBGETSKEW Skew of an input signal.
%   K = wfdbx.wfdbgetskew(S) returns the skew (in frames) of input signal
%   S (0-based), as given in the header; 0 if S is not open.
%
%   See also wfdbx.wfdbsetiskew, wfdbx.wfdbsetskew.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
if s < S.nvsig
    skew = S.vsd(s + 1).skew;
else
    skew = 0;
end
end
