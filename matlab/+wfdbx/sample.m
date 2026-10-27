function v = sample(s, t)
%SAMPLE Random access to a sample of an input signal.
%   V = wfdbx.sample(S, T) returns sample number T of input signal S (both
%   0-based), reading the signals as needed (recent samples are kept in a
%   buffer).  Returns wfdbx.WFDB_INVALID_SAMPLE() if the sample cannot be
%   read; wfdbx.sample_valid() then tells why.
%
%   See also wfdbx.sample_valid, wfdbx.getvec.
%
%   Translation of the C function sample() (lib/signal.c, WFDB 10.7.0): same
%   arguments and results.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

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
