function [stat, vector] = getframe_s(S, vector)
%GETFRAME_S Read a frame of samples (getframe in signal.c).
%   [STAT, V] = wfdbx.internal.getframe_s(S, V) is wfdbx.getframe(V), with
%   the signal state S (wfdbx.internal.sig_state()) given by the caller.
%
%   Part of the translation of lib/signal.c (WFDB 10.7.0).

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
