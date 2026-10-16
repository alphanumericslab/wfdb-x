function [stat, vector] = rgetvec(S, vector)
%RGETVEC Read a sample of each signal at the record's frequency (rgetvec).
%   [STAT, V] = wfdbx.internal.rgetvec(S, V) is getvec without resampling
%   (setifreq): in WFDB_LOWRES mode, the samples of multi-frequency
%   signals are averaged over each frame; in WFDB_HIGHRES mode, each
%   frame gives ispfmax vectors.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
