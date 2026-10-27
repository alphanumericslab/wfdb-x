function s = findsig(p)
%FINDSIG Find an input signal by name or number.
%   S = wfdbx.findsig(P) returns the number (0-based) of the input signal
%   whose description is P, or P itself if P is a signal number (a
%   string of digits); -1 if there is no such signal.
%
%   See also wfdbx.isigopen, wfdbx.siginfo.
%
%   Translation of the C function findsig() (lib/signal.c, WFDB 10.7.0):
%   same arguments and results.

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
