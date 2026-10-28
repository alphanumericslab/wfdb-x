function [v, st] = flac_getsamps(ig, n)
%FLAC_GETSAMPS Many samples of a FLAC input group at once.
%   [V, ST] = wfdbx.internal.flac_getsamps(IG, N) has exactly the effect of
%   N calls of wfdbx.internal.flac_getsamp(IG): V(k) is the k-th sample
%   returned and ST(k) the value of IG.stat after it (as the outputs of
%   wfdbx.internal.ig_read).  N may be Inf: then the samples are returned
%   up to the end of the data or an error (the call of flac_getsamp that
%   finds it is made, but its result is not returned).
%
%   This is the bulk accessor for the vectorized frame readers of the
%   signal module: the samples come in WFDB frame order (for each frame,
%   spf samples of each signal of the group in turn).
%
%   Part of the translation of the FLAC support of lib/signal.c (WFDB
%   10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of the FLAC support of lib/signal.c (the
% code that connects FLAC to the signal functions) from the WFDB Software
% Package 10.7.0, by Benjamin Moody (2020). The translation follows the logic
% and behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c (FLAC support), WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by
%   Benjamin Moody, including FLAC support (2020).
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

inf_n = isinf(n);
if inf_n
    v = zeros(1, 0);
    st = zeros(1, 0);
else
    v = zeros(1, n);
    st = zeros(1, n);
end
k = 0;
while k < n
    fi = ig.flac;
    p = fi.pos;
    m = min(fi.len - p, n - k);
    if m > 0
        % (the decoded samples: ig.stat unchanged)
        v(k+1:k+m) = fi.samples(p+1:p+m);
        st(k+1:k+m) = ig.stat;
        fi.pos = p + m;
        ig.flac = fi;
        k = k + m;
        continue;
    end
    fi = [];    %#ok<NASGU> (the samples are then appended in place)
    x = wfdbx.internal.flac_getsamp(ig);
    if inf_n && ig.stat <= 0
        break;
    end
    k = k + 1;
    v(k) = x;
    st(k) = ig.stat;
end
end
