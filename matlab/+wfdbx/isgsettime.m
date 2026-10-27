function stat = isgsettime(g, t)
%ISGSETTIME Skip to a given time in an input signal group.
%   STAT = wfdbx.isgsettime(G, T) is as wfdbx.isigsettime(T), for the
%   signals of group G (signals in the same file) only.
%
%   See also wfdbx.isigsettime.
%
%   Translation of the C function isgsettime() (lib/signal.c, WFDB 10.7.0):
%   same arguments and results.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
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

LONG_MAX = 9223372036854775807;    % largest WFDB_Time

S = wfdbx.internal.sig_state();
trem = 0;
if t < 0
    if t < -LONG_MAX
        wfdbx.internal.wfdb_error('isigsettime: improper seek on signal group %d\n', g);
        stat = -1;
        return;
    end
    t = -t;
end
if S.ifreq > 0
    tt = t * S.sfreq / S.ifreq;
    if tt > LONG_MAX
        wfdbx.internal.wfdb_error('isigsettime: improper seek on signal group %d\n', g);
        stat = -1;
        return;
    end
    t = fix(tt);
end
if bitand(S.gvmode, 1)     % WFDB_HIGHRES
    trem = rem(t, S.ispfmax);
    t = fix(t / S.ispfmax);
end
S.dsbi = -1;
stat = wfdbx.internal.isgsetframe(g, t);
if stat == 0 && g == 0
    while trem > 0
        trem = trem - 1;
        [st, uv] = wfdbx.internal.rgetvec(S, S.uvector);
        S.uvector = uv;
        if st < 0
            wfdbx.internal.wfdb_error('isigsettime: improper seek on signal group %d\n', g);
            stat = -1;
            return;
        end
    end
    if S.ifreq > 0 && S.ifreq ~= S.sfreq
        S.gvtime = 0;
        [S.rgvstat, S.gv0] = wfdbx.internal.rgetvec(S, S.gv0);
        [S.rgvstat, S.gv1] = wfdbx.internal.rgetvec(S, S.gv1);
        S.rgvtime = S.nticks;
    end
end
end
