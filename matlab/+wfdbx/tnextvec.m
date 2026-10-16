function t = tnextvec(s, t)
%TNEXTVEC Time of the next valid sample of a signal.
%   T = wfdbx.tnextvec(S, T0) returns the time of the first valid sample
%   of input signal S at or after time T0, and positions the input
%   signals there; a negative value if there is none (or on error).
%
%   See also wfdbx.isigsettime, wfdbx.getvec.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
stat = 0;
if S.in_msrec && S.need_sigmap
    if s >= S.nvsig
        wfdbx.internal.wfdb_error('nextvect: illegal signal number %d\n', s);
        t = -1;
        return;
    end
    if t ~= S.istime && wfdbx.isigsettime(t) < 0
        t = -1;
        return;
    end
    while stat >= 0
        p = S.vsd(s + 1).info.desc;
        seg = S.segarray(S.segp + 1);
        tf = seg.samp0 + seg.nsamp;
        ss = 0;
        while ss < S.nisig
            q = S.isd(ss + 1).info.desc;
            if ischar(q) && ischar(p) && strcmp(p, q)
                break;
            end
            ss = ss + 1;
        end
        if ss < S.nisig
            while t <= tf
                [stat, vv] = wfdbx.getvec(S.vvector);
                S.vvector = vv;
                if stat <= 0
                    break;
                end
                if vv(s + 1) ~= -32768
                    wfdbx.isigsettime(t);
                    return;
                end
                t = t + 1;
            end
            if stat < 0
                t = -1;
                return;
            end
        end
        if t ~= tf
            t = tf;
            stat = wfdbx.isigsettime(t);
        end
    end
else
    if t ~= S.istime && wfdbx.isigsettime(t) < 0
        t = -1;
        return;
    end
    if s >= S.nisig
        wfdbx.internal.wfdb_error('nextvect: illegal signal number %d\n', s);
        t = -1;
        return;
    end
    while true
        [stat, vv] = wfdbx.getvec(S.vvector);
        S.vvector = vv;
        if stat <= 0
            break;
        end
        if vv(s + 1) ~= -32768
            wfdbx.isigsettime(t);
            return;
        end
        t = t + 1;
    end
end
t = stat;
end
