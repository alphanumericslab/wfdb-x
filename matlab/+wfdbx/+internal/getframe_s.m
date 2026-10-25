function [stat, vector] = getframe_s(S, vector)
%GETFRAME_S Read a frame of samples (getframe in signal.c).
%   [STAT, V] = wfdbx.internal.getframe_s(S, V) is wfdbx.getframe(V), with
%   the signal state S (wfdbx.internal.sig_state()) given by the caller.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if S.has_dsbuf
    dsbuf = S.dsbuf;
    tspf = S.tspf;
    dsblen = S.dsblen;
    if S.dsbi < 0
        i = 0;
        stat = -1;
        while i < dsblen
            [stat, fr] = wfdbx.internal.getskewedframe(S, dsbuf(i + 1:i + tspf));
            dsbuf(i + 1:i + tspf) = fr(1:tspf);
            if stat < 0
                break;
            end
            i = i + tspf;
        end
        dsbi = 0;
    else
        dsbi = S.dsbi;
        [stat, fr] = wfdbx.internal.getskewedframe(S, dsbuf(dsbi + 1:dsbi + tspf));
        dsbuf(dsbi + 1:dsbi + tspf) = fr(1:tspf);
        dsbi = dsbi + tspf;
        if dsbi >= dsblen
            dsbi = 0;
        end
    end
    S.dsbuf = dsbuf;
    S.dsbi = dsbi;
    j = 0;
    vsd = S.vsd;
    for s = 1:S.nvsig
        i = j + dsbi + vsd(s).skew * tspf;
        if i >= dsblen
            i = mod(i, dsblen);
        end
        spf = vsd(s).info.spf;
        vector(j + 1:j + spf) = dsbuf(i + 1:i + spf);
        j = j + spf;
    end
else
    [stat, vector] = wfdbx.internal.getskewedframe(S, vector);
end
S.istime = S.istime + 1;
end
