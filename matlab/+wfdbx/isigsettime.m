function stat = isigsettime(t)
%ISIGSETTIME Skip to a given time in the input signals.
%   STAT = wfdbx.isigsettime(T) positions all input signals so that the
%   next sample read by getvec is sample number T (in the units of
%   getvec: frames in WFDB_LOWRES mode, samples at the highest frequency
%   in WFDB_HIGHRES mode, or at the frequency set by setifreq).  T is
%   usually obtained from wfdbx.strtim.  Returns 0, or a negative value
%   on error.
%
%   See also wfdbx.isgsettime, wfdbx.strtim, wfdbx.getvec.
%
%   Translation of the C function isigsettime() (lib/signal.c, WFDB 10.7.0):
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
stat = 0;
if S.nisig == 0
    return;
end
if S.ifreq <= 0
    if ~bitand(S.gvmode, 1) || S.ispfmax < 2     % WFDB_HIGHRES
        curtime = S.istime;
    else
        curtime = (S.istime - 1) * S.ispfmax + S.gvc;
    end
    if t == curtime
        return;
    end
end
for g = 1:S.nigroup - 1
    stat = wfdbx.isgsettime(g, t);
    if stat < 0
        break;
    end
end
if stat == 0
    stat = wfdbx.isgsettime(0, t);
end
end
