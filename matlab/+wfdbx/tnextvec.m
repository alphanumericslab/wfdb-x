function t = tnextvec(s, t)
%TNEXTVEC Time of the next valid sample of a signal.
%   T = wfdbx.tnextvec(S, T0) returns the time of the first valid sample
%   of input signal S at or after time T0, and positions the input
%   signals there; a negative value if there is none (or on error).
%
%   See also wfdbx.isigsettime, wfdbx.getvec.
%
%   Translation of the C function tnextvec() (lib/signal.c, WFDB 10.7.0):
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
