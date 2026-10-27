function status = rdann(args)
%RDANN Print an annotation file in ASCII form.
%   STATUS = wfdbx.apps.rdann(ARGS) runs the rdann tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       rdann -r RECORD -a ANNOTATOR [OPTIONS ...]
%   where OPTIONS may include:
%       -c CHAN             print annotations with specified CHAN only
%       -e                  show annotation times as elapsed times
%       -f TIME             start at specified TIME
%       -F FREQ             sampling frequency, if the record header does
%                           not specify one
%       -h                  print a usage summary
%       -n NUM              print annotations with specified NUM only
%       -p TYPE [TYPE ...]  print annotations of specified TYPEs only
%       -s SUBTYPE          print annotations with specified SUBTYPE only
%       -t TIME             stop at specified TIME
%       -v                  print column headings
%       -x                  use alternate time format (seconds, minutes,
%                           hours)
%
%   wfdb-x: no sampling frequency is assumed (the C program assumed 250 Hz
%   if the record had no header); without a header giving one, -F is
%   required.  See docs/DIVERGENCES.md.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with wfdb-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.rdann({'-r', '100s', '-a', 'atr'})
%
%   See also wfdbx.apps.wrann, wfdbx.apps.sortann, wfdbx.read_annotations.
%
%   Translation of the C program rdann (app/rdann.c, WFDB 10.7.0): same
%   options and output. Differences: -F gives the sampling frequency when
%   the record header gives none; see docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/rdann.c from the WFDB Software
% Package 10.7.0, by T. Baker and George B. Moody. The translation follows the
% logic and behavior of the original program, but it is new code, not the
% original C code.
%
% Changes from the original: no built-in sampling frequency: the new option -F
% FREQ gives it when the record has no header or its header gives none, and is
% then required (the original assumed 250 Hz); --legacy, as the first argument,
% restores the original behavior. Each change is marked "wfdb-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
%
% Original C program: app/rdann.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1981-2010 George B. Moody; revised 2017-2018 by
%   Benjamin Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'rdann'}, args]);
end

function help(pname)
h = {'where RECORD and ANNOTATOR specify the input, and OPTIONS may include:', ...
    ' -c CHAN             print annotations with specified CHAN only', ...
    ' -e                  * show annotation times as elapsed times', ...
    ' -f TIME             start at specified TIME', ...
    ' -F FREQ             sampling frequency, if the record header does not', ...
    '                      specify one', ...
    ' -h                  print this usage summary', ...
    ' -n NUM              print annotations with specified NUM only', ...
    ' -p TYPE [TYPE ...]  print annotations of specified TYPEs only', ...
    ' -s SUBTYPE          print annotations with specified SUBTYPE only', ...
    ' -t TIME             stop at specified TIME', ...
    ' -v                  print column headings', ...
    ' -x                  * use alternate time format (seconds, minutes, hours)', ...
    '* Only one of -e and -x can be used.'};
if wfdbx.wfdbx_get_legacy()  % wfdb-x: legacy mode: the original help text
    h(5:6) = [];                % (without -F)
end
wfdbx.internal.ceprintf('usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function status = main(argv)
ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
pname = argv{1};
Ffreq = 0;      % -F (wfdb-x)
legacy = wfdbx.wfdbx_get_legacy();
argc = numel(argv);
ep = @wfdbx.internal.ceprintf;
record = [];
cflag = 0; nflag = 0; sflag = 0;
chanmatch = 0; nummatch = 0; submatch = 0;
eflag = 0; vflag = 0; xflag = 0;
afrom = 0; anum = 0; ato = 0; bfrom = 0; bnum = 0; bto = 0;
from = 0; to = 0;
flag = zeros(1, ACMAX + 1);     % flag(code+1)
ainame = [];
% argv{i+1} is C argv[i]
if argc >= 3 && ~isdash(argv{2})
    ainame = argv{2};
    record = argv{3};
    i = 3;
    if argc > 3
        from = 3;
        i = 4;
    end
    if argc > 4
        to = 4;
        i = 5;
    end
    if argc <= 5
        flag(1) = 1;
    else
        while i < argc && ~isdash(argv{i+1})
            j = wfdbx.strann(argv{i+1});
            if j > 0 && j <= ACMAX
                flag(j+1) = 1;
            end
            i = i + 1;
        end
    end
else
    i = 1;
    flag(1) = 1;
end
while i < argc
    a = argv{i+1};
    if isdash(a)
        if numel(a) >= 2
            c = a(2);
        else
            c = '';
        end
        if legacy && strcmp(c, 'F')   % wfdb-x: legacy mode: not an option of
            c = '';                     % the original (unrecognized)
        end
        switch c
            case 'a'
                i = i + 1;
                if i >= argc
                    ep('%s: annotator must follow -a\n', pname);
                    status = 1;
                    return;
                end
                ainame = argv{i+1};
            case 'c'
                i = i + 1;
                if i >= argc
                    ep('%s: chan value (between -128 and 127) must follow -c\n', pname);
                    status = 1;
                    return;
                end
                chanmatch = wfdbx.internal.cint8(wfdbx.internal.atoi(argv{i+1}));
                cflag = 1;
            case 'e'
                eflag = 1;
                xflag = 0;
            case 'f'
                i = i + 1;
                if i >= argc
                    ep('%s: starting time must follow -f\n', pname);
                    status = 1;
                    return;
                end
                from = i;
            case 'F'    % sampling frequency follows (wfdb-x)
                [Ffreq, i, ok] = wfdbx.internal.opt_ffreq(argv, i, Ffreq);
                if ~ok
                    status = 1;
                    return;
                end
            case 'h'
                help(pname);
                status = 0;
                return;
            case 'n'
                i = i + 1;
                if i >= argc
                    ep('%s: num value (between -128 and 127) must follow -n\n', pname);
                    status = 1;
                    return;
                end
                nummatch = wfdbx.internal.cint8(wfdbx.internal.atoi(argv{i+1}));
                nflag = 1;
            case 'p'
                i = i + 1;
                if i < argc
                    j = wfdbx.strann(argv{i+1});
                else
                    j = 0;
                end
                if i >= argc || ~(j > 0 && j <= ACMAX)
                    ep('%s: annotation mnemonic(s) must follow -p\n', pname);
                    status = 1;
                    return;
                end
                flag(j+1) = 1;
                i = i + 1;
                while i < argc && ~isdash(argv{i+1})
                    j = wfdbx.strann(argv{i+1});
                    if j > 0 && j <= ACMAX
                        flag(j+1) = 1;
                    end
                    i = i + 1;
                end
                if i == argc || isdash(argv{i+1})
                    i = i - 1;
                end
                flag(1) = 0;
            case 'r'
                i = i + 1;
                if i >= argc
                    ep('%s: input record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i+1};
            case 's'
                i = i + 1;
                if i >= argc
                    ep('%s: subtyp value (between -128 and 127) must follow -s\n', pname);
                    status = 1;
                    return;
                end
                submatch = wfdbx.internal.cint8(wfdbx.internal.atoi(argv{i+1}));
                sflag = 1;
            case 't'
                i = i + 1;
                if i >= argc
                    ep('%s: end time must follow -t\n', pname);
                    status = 1;
                    return;
                end
                to = i;
            case 'v'
                vflag = 1;
            case 'x'
                xflag = 1;
                eflag = 0;
            otherwise
                ep('%s: unrecognized option %s\n', pname, a);
                status = 1;
                return;
        end
    else
        ep('%s: unrecognized argument %s\n', pname, a);
        status = 1;
        return;
    end
    i = i + 1;
end
if ~ischar(record) || ~ischar(ainame)
    help(pname);
    status = 1;
    return;
end
% wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
% the record had no header); -F specifies one.
sps = wfdbx.sampfreq(record);
if legacy
    if sps < 0      % wfdb-x: legacy mode (original behavior)
        sps = wfdbx.WFDB_DEFFREQ();
        wfdbx.setsampfreq(sps);
    end
elseif sps <= 0 && Ffreq > 0
    sps = Ffreq;
    wfdbx.setsampfreq(sps);
end
if ~legacy && sps <= 0
    ep('%s: sampling frequency of record %s is not specified (use -F)\n', ...
        pname, record);
    status = 1;
    return;
end
if wfdbx.annopen(record, wfdbx.anninfo(ainame, 0), 1) < 0
    status = 2;
    return;
end
tps = wfdbx.getiaorigfreq(0);
if tps < sps
    tps = sps;
end
sprec = 3;   % decimal places for times in seconds, minutes and hours (as in C)
n = 1000;
while n < tps
    sprec = sprec + 1;
    n = n * 10;
end
tpm = 60 * tps;
mprec = 5;
n = 100000;
while n < tpm
    mprec = mprec + 1;
    n = n * 10;
end
tph = 60 * tpm;
hprec = 7;
n = 10000000;
while n < tph
    hprec = hprec + 1;
    n = n * 10;
end
emap = wfdbx.internal.ecg_map();
qrs = emap.qrs;
if from
    fa = argv{from+1};
    if ~isempty(fa) && fa(1) == 'a'
        afrom = wfdbx.internal.strtol(fa, 10, 2);
        if afrom < 0
            afrom = 0;
        end
        [anum, bnum, ok] = skipn(afrom - anum, anum, bnum, qrs, 1, afrom);
        if ~ok
            status = 2;
            return;
        end
    elseif ~isempty(fa) && (fa(1) == 'b' || fa(1) == '#')
        bfrom = wfdbx.internal.strtol(fa, 10, 2);
        if bfrom < 0
            bfrom = 0;
        end
        [anum, bnum, ok] = skipn(0, anum, bnum, qrs, 2, bfrom);
        if ~ok
            status = 2;
            return;
        end
    elseif wfdbx.iannsettime(wfdbx.strtim(fa)) < 0
        status = 2;
        return;
    end
end
if to
    ta = argv{to+1};
    if ~isempty(ta) && ta(1) == 'a'
        ato = wfdbx.internal.strtol(ta, 10, 2);
        if ato < 0
            ato = 0;
        end
        bto = 0;
        to = 0;
    elseif ~isempty(ta) && ta(1) == 'b'
        bto = wfdbx.internal.strtol(ta, 10, 2);
        if bto < 0
            bto = 0;
        end
        ato = 0;
        to = 0;
    elseif ~isempty(ta) && ta(1) == '#'
        bto = wfdbx.internal.strtol(ta, 10, 2);
        if bto < 1
            bto = 1;
        end
        bto = bto + bnum;
        ato = 0;
        to = 0;
    else
        ato = 0;
        bto = 0;
        to = wfdbx.strtim(ta);
        if to < 0
            to = -to;
        end
    end
end
out = @wfdbx.internal.cout;
if vflag
    if eflag
        out('Elapsed time  Sample #  ');
    elseif xflag
        out('  Seconds   Minutes     Hours  ');
    else
        s = wfdbx.mstimstr(-1);
        if any(s == '/')
            out('      Time       Date     Sample #  ');
        elseif ~isempty(s) && s(1) == '['
            out('      Time     Sample #  ');
        else
            out('      Time   Sample #  ');
        end
    end
    out(sprintf('Type  Sub Chan  Num\tAux\n'));
end
wfdbx.setifreq(tps);
wfdbx.setiafreq(0, tps);
xfmt = sprintf('%%%d.%df %%%d.%df %%%d.%df', sprec + 6, sprec, ...
    mprec + 4, mprec, hprec + 2, hprec);
st = wfdbx.internal.ann_state();
astr = st.astring;
% (annotations are read 4096 at a time; one at a time from AHA files,
% where reading an annotation may print a message, so that no annotation
% is read beyond the last one C reads)
chunk = 4096;
if st.iad{1}.P.aha
    chunk = 1;
end
done = false;
while ~done
    [stat, A] = wfdbx.internal.getann_bulk(0, chunk, false, true);
    m = numel(A.time);
    if m == 0
        if stat == 1
            wfdbx.getann(0);        % the failing call (prints any error)
        end
        break;
    end
    if tps == sps
        sn = A.time;
    else
        sn = floor(A.time * sps / tps + 0.5);
    end
    at = A.anntyp;
    % where the loop stops: before an annotation after 'to', or after the
    % annotation that reaches ato or bto
    last = m;
    if to ~= 0
        k = find(sn > to, 1);
        if ~isempty(k)
            last = k - 1;
            done = true;
        end
    end
    if ato
        k = ato - anum;
        if k <= last
            last = max(k, 1);
            done = true;
        end
    end
    isq = zeros(1, m);
    v = at > 0 & at <= ACMAX;
    isq(v) = qrs(at(v) + 1);
    isq = isq ~= 0;
    if bto
        k = find(bnum + cumsum(isq) >= bto & isq, 1);
        if ~isempty(k) && k <= last
            last = k;
            done = true;
        end
    end
    if ato
        anum = anum + last;
    end
    if bto
        bnum = bnum + sum(isq(1:last));
    end
    idx = 1:last;
    if ~flag(1)
        fl = zeros(1, last);
        v = at(idx) > 0 & at(idx) <= ACMAX;
        fl(v) = flag(at(idx(v)) + 1);
        sel = fl ~= 0;
    else
        sel = true(1, last);
    end
    if cflag
        sel = sel & A.chan(idx) == chanmatch;
    end
    if nflag
        sel = sel & A.num(idx) == nummatch;
    end
    if sflag
        sel = sel & A.subtyp(idx) == submatch;
    end
    q = find(sel);
    if ~isempty(q)
        txt = [];
        if ~xflag
            if eflag
                tq = A.time(q);
            else
                tq = -A.time(q);
            end
            txt = fastlines(tq, sn(q), at(q), A.subtyp(q), A.chan(q), ...
                A.num(q), A.aux(q), astr);
        end
        if isempty(txt)
            txt = slowlines(q, A, sn, at, astr, eflag, xflag, xfmt, tps, ...
                tpm, tph);
        end
        out(txt);
    end
    if stat ~= 0 && ~done
        if stat == 1
            wfdbx.getann(0);
        end
        break;
    end
end
status = 0;
end

function txt = slowlines(qs, A, sn, at, astr, eflag, xflag, xfmt, tps, tpm, tph)
% The output lines of annotations qs, one at a time.
c = cell(1, numel(qs));
for k = 1:numel(qs)
    q = qs(k);
    if eflag
        line = sprintf('%s  %7d', wfdbx.mstimstr(A.time(q)), sn(q));
    elseif xflag
        tq = A.time(q);
        line = sprintf(xfmt, tq / tps, tq / tpm, tq / tph);
    else
        line = sprintf('%s  %7d', wfdbx.mstimstr(-A.time(q)), sn(q));
    end
    line = [line, sprintf('%6s%5d%5d%5d', mnem(astr, at(q)), A.subtyp(q), ...
        A.chan(q), A.num(q)), auxstr(A.aux{q}), char(10)]; %#ok<AGROW>
    c{k} = line;
end
txt = [c{:}];
end

function s = auxstr(x)
% "\t%s" of annot.aux + 1 (up to the first null), or ''
if isempty(x)
    s = '';
    return;
end
x = x(2:end);
z = find(x == 0, 1);
if ~isempty(z)
    x = x(1:z-1);
end
s = [char(9), char(x)];
end

function s = mnem(astr, a)
ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if a >= 0 && a <= ACMAX
    s = astr{a+1};
else
    s = sprintf('[%d]', a);
end
end

function txt = fastlines(t, sn, at, sub, chan, num, aux, astr)
% The output lines (default and -e formats) built with vector operations
% when all fields have their usual widths and all times are elapsed times
% (mstimstr(t) for t > 0, or without a base time); [] otherwise.
ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
txt = [];
n = numel(t);
S = wfdbx.internal.sig_state();
if ~(all(t > 0) || (S.btime == 0 && S.bdate == 0))
    return;
end
if any(at < 0 | at > ACMAX)
    return;
end
if S.ifreq > 0
    f = S.ifreq;
elseif S.sfreq > 0
    f = S.sfreq;
else
    f = 1;
end
% fmstimstr (elapsed time form), vectorized
t = abs(t);
sec = fix(t / f);
msec = fix((t - sec * f) * 1000 / f + 0.5);
k = msec == 1000;
msec(k) = 0;
sec(k) = sec(k) + 1;
seconds = mod(sec, 60);
m = floor(sec / 60);
minutes = mod(m, 60);
hours = floor(m / 60);
h = hours > 0;
wh = 2;
if any(h)
    wh = unique(max(2, ndig(hours(h))));
    if numel(wh) > 1 || (wh > 2 && ~all(h))
        return;                         % (lines of different widths)
    end
end
T = repmat(' ', n, 10 + wh);
if any(h)
    T(h, :) = reshape(sprintf('%2d:%02d:%02d.%03d', ...
        [hours(h); minutes(h); seconds(h); msec(h)]), 10 + wh, [])';
end
if any(~h)
    T(~h, :) = reshape(sprintf('   %2d:%02d.%03d', ...
        [minutes(~h); seconds(~h); msec(~h)]), 12, [])';
end
% mnemonics, right-justified in 6 columns
M = repmat(' ', ACMAX + 1, 6);
for c = 1:ACMAX + 1
    s = astr{c};
    if numel(s) > 6 || any(s == 10)
        if any(at == c - 1)
            return;
        end
        continue;
    end
    M(c, 7-numel(s):6) = s;
end
ws = unique(max(7, ndig(sn)));
if numel(ws) > 1
    return;
end
SN = reshape(sprintf('%7d', sn), ws, [])';
F = reshape(sprintf('%5d%5d%5d', [sub; chan; num]), 15, [])';
L = [T, repmat(' ', n, 2), SN, M(at + 1, :), F];
ha = find(~cellfun('isempty', aux));
if isempty(ha)
    L(:, end+1) = char(10);
    txt = reshape(L', 1, []);
    return;
end
% lines with aux strings
w = size(L, 2);
L(:, end+1) = char(10);
body = reshape(L', 1, []);
pieces = cell(1, 2 * numel(ha) + 1);
p0 = 1;
for k = 1:numel(ha)
    e = ha(k) * (w + 1) - 1;            % end of the line, before its newline
    pieces{2*k-1} = body(p0:e);
    pieces{2*k} = auxstr(aux{ha(k)});
    p0 = e + 1;
end
pieces{end} = body(p0:end);
txt = [pieces{:}];
end

function d = ndig(v)
% number of characters of %d of the integers v
a = abs(v);
d = ones(size(v));
k = a >= 10;
d(k) = floor(log10(a(k))) + 1;
p = 10 .^ d;
d = d + (a >= p) - (a < p / 10 & a >= 10);     % (guard log10 rounding)
d = d + (v < 0);
end

function [anum, bnum, ok] = skipn(~, anum, bnum, qrs, mode, target)
% while (anum < afrom (mode 1) or bnum < bfrom (mode 2)) && getann == 0:
%   anum++, bnum += isqrs
ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
ok = true;
while true
    if mode == 1
        need = target - anum;
    else
        need = target - bnum;
    end
    if need <= 0
        return;
    end
    if mode == 1
        [stat, A] = wfdbx.internal.getann_bulk(0, need, true);
        n = numel(A.time);
    else
        [stat, A] = wfdbx.internal.getann_bulk(0, need, true);
        n = numel(A.time);
    end
    at = A.anntyp;
    isq = zeros(1, n);
    v = at > 0 & at <= ACMAX;
    isq(v) = qrs(at(v) + 1);
    anum = anum + n;
    bnum = bnum + sum(isq ~= 0);
    if stat ~= 0
        if mode == 1
            ok = anum >= target;
        else
            ok = bnum >= target;
        end
        return;
    end
end
end

function tf = isdash(s)
tf = ~isempty(s) && s(1) == '-';
end
