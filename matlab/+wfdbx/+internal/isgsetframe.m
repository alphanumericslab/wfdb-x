function stat = isgsetframe(g, t)
%ISGSETFRAME Position input signal group G at frame T (isgsetframe in signal.c).
%   STAT = wfdbx.internal.isgsetframe(G, T) moves the input pointer of
%   signal group G (0-based) to frame T, switching segments of a
%   multi-segment record if needed.  Returns 0, or a negative value on
%   error.
%
%   Translation of the C function isgsetframe() (lib/signal.c, WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: a seek drops the blocks read ahead by the bulk
% reader. Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md
% gives the reasons.
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
d = 1;
% (C reads igd[g] even if g is not a signal group number: undefined
% behavior, here the group number is then reported as incorrect)
if S.nigroup < 2 && S.istime == t && S.gvc == S.ispfmax && g >= 0 && ...
        g < numel(S.igd) && S.igd{g + 1}.start == 0
    stat = 0;
    return;
end
isd = S.isd;
nisig = S.nisig;
s = 0;
while s < nisig && g ~= isd(s + 1).info.group
    s = s + 1;
end
if s == nisig
    wfdbx.internal.wfdb_error('isgsettime: incorrect signal group number %d\n', g);
    stat = -2;
    return;
end
if S.in_msrec
    if t >= S.msnsamples
        wfdbx.internal.wfdb_error('isigsettime: improper seek on signal group %d\n', g);
        stat = -1;
        return;
    end
    tseg = S.segp;
    seg = S.segarray;
    while t < seg(tseg + 1).samp0
        tseg = tseg - 1;
    end
    while t >= seg(tseg + 1).samp0 + seg(tseg + 1).nsamp && tseg < S.segend
        tseg = tseg + 1;
    end
    if S.segp ~= tseg
        S.segp = tseg;
        if wfdbx.isigopen(seg(tseg + 1).recname, S.nvsig) <= 0
            wfdbx.internal.wfdb_error('isigsettime: can''t open segment %s\n', ...
                seg(tseg + 1).recname);
            stat = -1;
            return;
        end
        for h = 1:S.nigroup - 1
            i = wfdbx.internal.isgsetframe(h, t);
            if i
                stat = i;
                return;
            end
        end
        if g == 0
            stat = wfdbx.internal.isgsetframe(0, t);
            return;
        end
        stat = 0;
        return;
    end
    t = t - seg(S.segp + 1).samp0;
end
ig = S.igd{g + 1};
ig.initial_skip = 0;
n = 0;
nn = 0;
while s + n < nisig && isd(s + n + 1).info.group == g
    nn = nn + isd(s + n + 1).info.spf;
    n = n + 1;
end
fmt = isd(s + 1).info.fmt;
UINT_MAX = 4294967295;
LONG_MAX = 9223372036854775807;
switch fmt
    case 0
        if t < S.nsamples
            S.gvc = S.ispfmax;
            if s == 0
                if S.in_msrec
                    S.istime = t + S.segarray(S.segp + 1).samp0;
                else
                    S.istime = t;
                end
            end
            S.isd(s + 1).info.nsamp = S.nsamples - t;
            ig.stat = 1;
            stat = 0;
        else
            if s == 0
                if S.in_msrec
                    S.istime = S.msnsamples;
                else
                    S.istime = S.nsamples;
                end
            end
            S.isd(s + 1).info.nsamp = 0;
            stat = -1;
        end
        return;
    case {508, 516, 524}
        if wfdbx.internal.flac_isseek(ig, t) < 0
            wfdbx.internal.wfdb_error('isigsettime: improper seek on signal group %d\n', g);
            stat = -1;
            return;
        end
        S.gvc = S.ispfmax;
        if s == 0
            if S.in_msrec
                S.istime = t + S.segarray(S.segp + 1).samp0;
            else
                S.istime = t;
            end
        end
        for k = s + 1:s + n
            S.isd(k).info.nsamp = 0;
        end
        stat = 0;
        return;
    case {16, 61, 160}
        if nn > floor(UINT_MAX / 2)
            stat = overflow(g);
            return;
        end
        b = 2 * nn;
    case 212
        if nn > floor(UINT_MAX / 3)
            stat = overflow(g);
            return;
        end
        ig.count = 0;
        if mod(nn, 2) == 1 && mod(t, 2) ~= 0
            if S.in_msrec
                t = t + S.segarray(S.segp + 1).samp0;
            end
            i = wfdbx.internal.isgsetframe(g, t - 1);
            if i
                stat = i;
                return;
            end
            wfdbx.internal.ig_read(ig, 212, nn, false);
            S.istime = S.istime + 1;
            k = s + 1;
            while k <= S.nisig && S.isd(k).info.group == g
                S.isd(k).info.nsamp = 0;
                k = k + 1;
            end
            stat = 0;
            return;
        end
        b = 3 * nn;
        d = 2;
    case {310, 311}
        if nn > floor(UINT_MAX / 4)
            stat = overflow(g);
            return;
        end
        ig.count = 0;
        trem = rem(t, 3);
        if mod(nn, 3) && trem
            if S.in_msrec
                t = t + S.segarray(S.segp + 1).samp0;
            end
            i = wfdbx.internal.isgsetframe(g, t - trem);
            if i
                stat = i;
                return;
            end
            wfdbx.internal.ig_read(ig, fmt, nn * trem, false);
            S.istime = S.istime + trem;
            k = s + 1;
            while k <= S.nisig && S.isd(k).info.group == g
                S.isd(k).info.nsamp = 0;
                k = k + 1;
            end
            stat = 0;
            return;
        end
        b = 4 * nn;
        d = 3;
    case 24
        if nn > floor(UINT_MAX / 3)
            stat = overflow(g);
            return;
        end
        b = 3 * nn;
    case 32
        if nn > floor(UINT_MAX / 4)
            stat = overflow(g);
            return;
        end
        b = 4 * nn;
    otherwise   % 8, 80
        b = nn;
end
if b == 0 || t > fix(LONG_MAX / b) || fix(t * b / d) > (LONG_MAX - ig.start)
    wfdbx.internal.wfdb_error('isigsettime: improper seek on signal group %d\n', g);
    stat = -1;
    return;
end
if ig.seek
    nb = fix(t * b / d) + ig.start;
    i = ig.bsize;
    if i == 0
        i = S.ibsize;
    end
    tt = fix(nb / i);
    ig.ahead = zeros(1, 0, 'uint8');    % (WFDB-x: the bulk reader's blocks)
    if isempty(ig.fp) || ig.fp.seek(tt * i, 0)
        wfdbx.internal.wfdb_error('isigsettime: improper seek on signal group %d\n', g);
        stat = -1;
        return;
    end
    nb = rem(nb, i);
else
    t0 = S.istime - fix(ig.bp / b);
    t1 = t0 + fix(ig.be / b);
    if t < t0
        if ig.fp.seek(0, 0)
            wfdbx.internal.wfdb_error('isigsettime: improper seek on signal group %d\n', g);
            stat = -1;
            return;
        end
        nb = fix(t * b / d) + ig.start;
    elseif t < t1
        ig.bp = fix((t - t0) * b / d);
        stat = 0;
        return;
    else
        nb = fix((t - t1) * b / d);
    end
    while nb > ig.bsize && ~ig.fp.feof()
        nb = nb - numel(ig.fp.read(ig.bsize));
    end
end
ig.bp = 0;
ig.be = 0;
ig.stat = 1;
wfdbx.internal.ig_skip(ig, nb);
if ig.stat <= 0
    stat = -1;
    return;
end
S.gvc = S.ispfmax;
if s == 0
    if S.in_msrec
        S.istime = t + S.segarray(S.segp + 1).samp0;
    else
        S.istime = t;
    end
end
for k = s + 1:s + n
    S.isd(k).info.nsamp = 0;
end
stat = 0;
end

function stat = overflow(g)
wfdbx.internal.wfdb_error('isigsettime: overflow in signal group %d\n', g);
stat = -1;
end
