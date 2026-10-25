function s = findsig(p)
%FINDSIG Find an input signal by name or number.
%   S = wfdbx.findsig(P) returns the number (0-based) of the input signal
%   whose description is P, or P itself if P is a signal number (a
%   string of digits); -1 if there is no such signal.
%
%   See also wfdbx.isigopen, wfdbx.siginfo.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
if all(p >= '0' & p <= '9')
    s = wfdbx.internal.cint32(wfdbx.internal.strtol(p));
    if s < S.nisig || s < S.nvsig
        return;
    end
end
if S.need_sigmap
    d = S.vsd;
    n = S.nvsig;
else
    d = S.isd;
    n = S.nisig;
end
for s = 0:n - 1
    q = d(s + 1).info.desc;
    if ischar(q) && strcmp(q, p)
        return;
    end
end
s = -1;
end
