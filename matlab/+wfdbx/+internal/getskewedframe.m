function [stat, vector] = getskewedframe(S, vector)
%GETSKEWEDFRAME Read one frame without deskewing (getskewedframe in signal.c).
%   [STAT, V] = wfdbx.internal.getskewedframe(S, V) reads the next frame of
%   the open input signals into V(1:tspf) (V is returned unchanged if no
%   signals are open) and returns the getvec status: the number of
%   signals, -1 at the end of the record, -3 for a read error, -4 for a
%   checksum error.  Segments of multi-segment records are switched as
%   needed, and variable-layout segments are mapped with sigmap.  S is
%   the signal state (wfdbx.internal.sig_state()).
%
%   Translation of the C function getskewedframe() (lib/signal.c, WFDB
%   10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: a checksum error is not printed during a
% high-level read (which warns instead), but recorded for wfdberror. Each
% change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the
% reasons.
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

nisig = S.nisig;
stat = nisig;
if nisig == 0
    if S.nvsig > 0
        stat = -1;
    else
        stat = 0;
    end
    return;
end
if S.istime == 0
    isd = S.isd;
    for s = 1:nisig
        isd(s).samp = isd(s).info.initval;
    end
    S.isd = isd;
end
igd = S.igd;
in_msrec = S.in_msrec;
if S.skip_pending
    for g = S.nigroup:-1:1
        if igd{g}.initial_skip
            if in_msrec
                wfdbx.internal.isgsetframe(g - 1, S.segarray(S.segp + 1).samp0);
            else
                wfdbx.internal.isgsetframe(g - 1, 0);
            end
        end
    end
    pending = false;
    for g = 1:S.nigroup
        pending = pending || igd{g}.initial_skip;
    end
    S.skip_pending = pending;
end
plan = S.plan;
if isempty(plan)
    plan = make_plan(S.isd);
    S.plan = plan;
end
need_sigmap = S.need_sigmap;
if need_sigmap
    vec = S.ovec;
else
    vec = vector;
end
pad = bitand(S.gvmode, 2) ~= 0;      % WFDB_GVPAD
isedf = S.isedf;
isd = S.isd;
vi = 0;
for s = 1:nisig
    info = isd(s).info;
    g = plan.group(s);
    ig = igd{g + 1};
    fmt = plan.fmt(s);
    spf = info.spf;
    cks = info.cksum;
    samp = isd(s).samp;
    if plan.first(s) && fmt ~= 0
        % Read the samples of this signal's group for the frame.
        [gv, gst] = wfdbx.internal.ig_read(ig, fmt, plan.nn(s), true);
        gk = 0;
    end
    inval = plan.inval(s);      % NaN: format 8 (first differences)
    for c = 1:spf
        if fmt == 0
            if pad
                v = samp;
            else
                v = -32768;
            end
            vec(vi + 1) = v;
            if info.nsamp == 0
                ig.stat = -1;
            end
            igstat = ig.stat;
        else
            gk = gk + 1;
            v = gv(gk);
            igstat = gst(gk);
            if isnan(inval)         % format 8 (first differences)
                v = samp + v;
                v = v - 4294967296 * ((v >= 2147483648) - (v < -2147483648));  % (int)
                samp = v;
                vec(vi + 1) = v;
            elseif v == inval
                if pad
                    vec(vi + 1) = samp;
                else
                    vec(vi + 1) = -32768;
                end
            else
                samp = v;
                vec(vi + 1) = v;
            end
        end
        vi = vi + 1;
        if igstat <= 0
            if igstat == -2
                stat = -3;
            elseif info.nsamp > 0
                wfdbx.internal.wfdb_error('getvec: unexpected EOF in signal %d\n', s - 1);
                stat = -3;
            elseif in_msrec && ~isempty(S.segarray) && S.segp < S.segend
                if need_sigmap
                    S.ovec = vec;
                else
                    vector = vec;
                end
                S.segp = S.segp + 1;
                if wfdbx.isigopen(S.segarray(S.segp + 1).recname, S.nvsig) <= 0
                    wfdbx.internal.wfdb_error('getvec: error opening segment %s\n', ...
                        S.segarray(S.segp + 1).recname);
                    stat = -3;
                    return;
                else
                    S.istime = S.segarray(S.segp + 1).samp0;
                    [stat, vector] = wfdbx.internal.getskewedframe(S, vector);
                    return;
                end
            else
                stat = -1;
            end
        end
        cks = cks - v;
    end
    cks = cks - 4294967296 * floor((cks + 2147483648) / 4294967296);   % (int)
    info.cksum = cks;
    if info.nsamp >= 0
        info.nsamp = info.nsamp - 1;
        if info.nsamp == 0 && mod(cks, 65536) ~= 0 && ~in_msrec && ...
                ~isedf && fmt ~= 0
            % WFDB-x: not printed during a high-level read (which warns
            % instead), but recorded for wfdberror
            io = wfdbx.internal.io_state();
            pr = io.error_print;
            if S.cksum_quiet
                io.error_print = false;
            end
            wfdbx.internal.wfdb_error('getvec: checksum error in signal %d\n', s - 1);
            io.error_print = pr;
            stat = -4;
        end
    end
    isd(s).info = info;
    isd(s).samp = samp;
end
S.isd = isd;
if need_sigmap
    S.ovec = vec;
    vector(1:S.tspf) = wfdbx.internal.sigmap(vec);
else
    vector = vec;
    framelen = S.framelen;
    tspf = S.tspf;
    if framelen ~= tspf
        vector(framelen + 1:tspf) = -32768;
    end
end
end

function plan = make_plan(isd)
% Per-signal constants: group, format, first signal of its group, number
% of samples per frame of the group, invalid-sample value of the format.
n = numel(isd);
plan.group = zeros(1, n);
plan.fmt = zeros(1, n);
plan.first = false(1, n);
plan.nn = zeros(1, n);
plan.inval = zeros(1, n);
for s = 1:n
    info = isd(s).info;
    plan.group(s) = info.group;
    plan.fmt(s) = info.fmt;
    plan.first(s) = s == 1 || info.group ~= isd(s - 1).info.group;
    bits = wfdbx.internal.fmt_bits(info.fmt);
    if bits > 0
        plan.inval(s) = -2^(bits - 1);  % the invalid value of the format
    else
        plan.inval(s) = NaN;            % none (formats 0 and 8)
    end
end
for s = 1:n
    if plan.first(s)
        k = s;
        nn = 0;
        while k <= n && plan.group(k) == plan.group(s)
            nn = nn + isd(k).info.spf;
            k = k + 1;
        end
        plan.nn(s) = nn;
    end
end
end
