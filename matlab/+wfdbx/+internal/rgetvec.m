function [stat, vector] = rgetvec(S, vector)
%RGETVEC Read a sample of each signal at the record's frequency (rgetvec).
%   [STAT, V] = wfdbx.internal.rgetvec(S, V) is getvec without resampling
%   (setifreq): in WFDB_LOWRES mode, the samples of multi-frequency
%   signals are averaged over each frame; in WFDB_HIGHRES mode, each
%   frame gives ispfmax vectors.
%
%   Translation of the C function rgetvec() (lib/signal.c, WFDB 10.7.0).

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

if S.ispfmax < 2
    [stat, vector] = wfdbx.internal.getframe_s(S, vector);
    return;
end
nvsig = S.nvsig;
if bitand(S.gvmode, 1) ~= 1     % WFDB_HIGHRES
    [stat, tv] = wfdbx.internal.getframe_s(S, S.tvector);
    S.tvector = tv;
    S.rgetvec_stat = stat;
    vsd = S.vsd;
    tp = 0;
    for s = 1:nvsig
        sf = vsd(s).info.spf;
        vector(s) = meansamp(tv(tp + 1:tp + sf), sf);
        tp = tp + sf;
    end
else
    if S.gvc >= S.ispfmax
        [st, tv] = wfdbx.internal.getframe_s(S, S.tvector);
        S.tvector = tv;
        S.rgetvec_stat = st;
        S.gvc = 0;
    end
    stat = S.rgetvec_stat;
    tv = S.tvector;
    gvc = S.gvc;
    ispfmax = S.ispfmax;
    vsd = S.vsd;
    tp = 0;
    for s = 1:nvsig
        sf = vsd(s).info.spf;
        if gvc == 0
            vsd(s).gvindex = 0;
            vsd(s).gvcount = -ispfmax;
        else
            vsd(s).gvcount = vsd(s).gvcount + sf;
            if vsd(s).gvcount >= 0
                vsd(s).gvindex = vsd(s).gvindex + 1;
                vsd(s).gvcount = vsd(s).gvcount - ispfmax;
            end
        end
        vector(s) = tv(tp + vsd(s).gvindex + 1);
        tp = tp + sf;
    end
    S.vsd = vsd;
    S.gvc = gvc + 1;
end
end

function total = meansamp(sv, n)
% Mean of N samples with the rounding of meansamp() in signal.c.
total = fix(n / 2);
for k = 1:n
    if sv(k) == -32768
        total = -32768;
        return;
    end
    total = total + sv(k);
end
neg = double(total < 0);
if bitand(n, n - 1)
    total = fix((total + neg) / n) - neg;
    return;
end
while true
    n = fix(n / 2);
    if n == 0
        break;
    end
    total = fix((total - double(total < 0)) / 2);
end
end
