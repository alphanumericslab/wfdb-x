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

% Original C implementation: the FLAC support of lib/signal.c, written by
% Benjamin Moody (2020); lib/signal.c is Copyright (C) 1989-2013 George
% B. Moody.
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
