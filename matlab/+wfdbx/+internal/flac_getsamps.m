function [v, st] = flac_getsamps(ig, n)
%FLAC_GETSAMPS Many samples of a FLAC input group at once.
%   [V, ST] = wfdbx.internal.flac_getsamps(IG, N) has exactly the effect of
%   N calls of wfdbx.internal.flac_getsamp(IG): V(k) is the k-th sample
%   returned and ST(k) the value of IG.stat after it (as the outputs of
%   wfdbx.internal.ig_read).  N may be Inf: then all the remaining samples
%   are returned (without the reads past the end).
%
%   This is the bulk accessor for the vectorized frame readers of the
%   signal module: the samples come in WFDB frame order (for each frame,
%   spf samples of each signal of the group in turn).
%
%   Part of the translation of the FLAC support of lib/signal.c (WFDB
%   10.7.0).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
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

fi = ig.flac;
if ~fi.decoded
    fi = wfdbx.internal.flac_ensure(ig);
end
if ~isempty(fi.error)
    if isinf(n)
        n = 0;
    end
    v = zeros(1, n);
    st = -2 * ones(1, n);
    if n > 0
        ig.stat = -2;
    end
    return;
end
if fi.aborted || fi.discarded || ig.stat < 0
    % (after a failed seek: one sample at a time)
    if isinf(n)
        n = max(numel(fi.samples) - fi.pos, 0);
    end
    v = zeros(1, n);
    st = zeros(1, n);
    for k = 1:n
        v(k) = wfdbx.internal.flac_getsamp(ig);
        st(k) = ig.stat;
    end
    return;
end
p = fi.pos;
avail = numel(fi.samples) - p;
if isinf(n)
    n = avail;
end
k = min(n, avail);
v = zeros(1, n);
st = zeros(1, n);
v(1:k) = fi.samples(p+1:p+k);
st(1:k) = ig.stat;
fi.pos = p + k;
if k > 0
    % the blocks decoded for the frame of the last sample read
    need = fi.base + (floor((p + k - 1) / (fi.nsig * fi.spf)) + 1) * fi.spf;
    if need > fi.dec_end
        fi.dec_end = wfdbx.internal.flac_block_end(fi, need);
    end
end
if k < n
    fi.dec_end = fi.total;
    if fi.leftover
        wfdbx.internal.wfdb_error( ...
            'getvec: warning: %d samples left over at end of file\n', fi.leftover);
        fi.leftover = 0;
    end
    ig.stat = 0;
end
ig.flac = fi;
end
