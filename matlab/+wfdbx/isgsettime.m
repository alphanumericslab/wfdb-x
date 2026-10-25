function stat = isgsettime(g, t)
%ISGSETTIME Skip to a given time in an input signal group.
%   STAT = wfdbx.isgsettime(G, T) is as wfdbx.isigsettime(T), for the
%   signals of group G (signals in the same file) only.
%
%   See also wfdbx.isigsettime.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
