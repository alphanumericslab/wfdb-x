function v = sample(s, t)
%SAMPLE Random access to a sample of an input signal.
%   V = wfdbx.sample(S, T) returns sample number T of input signal S (both
%   0-based), reading the signals as needed (recent samples are kept in a
%   buffer).  Returns wfdbx.WFDB_INVALID_SAMPLE() if the sample cannot be
%   read; wfdbx.sample_valid() then tells why.
%
%   See also wfdbx.sample_valid, wfdbx.getvec.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

BUFLN = 4096;
S = wfdbx.internal.sig_state();
nsig = max(S.nvsig, S.nisig);
if isempty(S.sbuf)
    S.sbuf = zeros(BUFLN, max(nsig, 1));
    S.sample_tt = -1;
end
if s < 0 || s >= nsig
    S.sample_vflag = -1;
    v = -32768;
    return;
end
if t < 0
    t = 0;
end
tt = S.sample_tt;
if t <= tt - BUFLN || t > tt + BUFLN
    tt = t - BUFLN;
    if tt < 0
        tt = -1;
    end
    S.sample_tt = tt;
    if wfdbx.isigsettime(tt + 1) < 0
        S.sample_vflag = 0;
        v = -32768;
        return;
    end
end
sbuf = S.sbuf;
while t > tt
    tt = tt + 1;
    r = mod(tt, BUFLN) + 1;
    [st, row] = wfdbx.getvec(sbuf(r, :));
    sbuf(r, :) = row(1:size(sbuf, 2));
    if st < 0
        tt = tt - 1;
        S.sample_tt = tt;
        S.sbuf = sbuf;
        S.sample_vflag = 0;
        v = sbuf(mod(tt, BUFLN) + 1, s + 1);  % (tt may be -1)
        return;
    end
end
S.sample_tt = tt;
S.sbuf = sbuf;
v = sbuf(mod(t, BUFLN) + 1, s + 1);
if v == -32768
    S.sample_vflag = -1;
else
    S.sample_vflag = 1;
end
end
