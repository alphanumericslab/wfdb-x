function status = sortann(args)
%SORTANN Rearrange annotations in canonical order.
%   STATUS = wfdbx.apps.sortann(ARGS) runs the sortann tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       sortann -r RECORD -a ANNOTATOR [OPTIONS ...]
%   where OPTIONS may include:
%       -f TIME    start at specified TIME
%       -F FREQ    sampling frequency, if the record header does not specify
%                  one
%       -h         print a usage summary
%       -o OUTANN  write output as annotator OUTANN (required with -f or -t)
%       -t TIME    stop at specified TIME
%   The sorted output replaces the input if -o is omitted, the input is in
%   the current directory, and the input is not already sorted.
%
%   wfdb-x: no sampling frequency is assumed (the C program assumed 250 Hz
%   if the record had no header); without a header giving one, -F is
%   required to convert the -f and -t times.  See docs/DIVERGENCES.md.
%
%   Example:
%       wfdbx.apps.sortann({'-r', '100s', '-a', 'atr', '-o', 'srt'})
%
%   See also wfdbx.apps.rdann, wfdbx.putann.

% Copyright (C) 1997-2010 George B. Moody (original C program, app/sortann.c;
% revised 2017-2018 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU General Public License, version 2 or later (see LICENSE).

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'sortann'}, args]);
end

function help(pname)
h = {'where RECORD and ANNOTATOR specify the input, and OPTIONS may include:', ...
    ' -f TIME    start at specified TIME', ...
    ' -F FREQ    sampling frequency, if the record header does not specify one', ...
    ' -h         print this usage summary', ...
    ' -o OUTANN  write output as annotator OUTANN (required with -f or -t)', ...
    ' -t TIME    stop at specified TIME', ...
    'The sorted output replaces the input if -o is omitted, the input is in', ...
    'the current directory, and the input is not already sorted.'};
if wfdbx.wfdbx_get_legacy()  % wfdb-x: legacy mode: the original help text
    h(3) = [];                  % (without -F)
end
wfdbx.internal.ceprintf('usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function status = main(argv)
pname = argv{1};
Ffreq = 0;      % -F (wfdb-x)
legacy = wfdbx.wfdbx_get_legacy();
argc = numel(argv);
ep = @wfdbx.internal.ceprintf;
record = [];
in_name = [];
out_name = [];
from = 0;
to = 0;
i = 1;
while i < argc
    a = argv{i+1};
    if ~isempty(a) && a(1) == '-'
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
                in_name = argv{i+1};
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
            case 'o'
                i = i + 1;
                if i >= argc
                    ep('%s: annotator must follow -o\n', pname);
                    status = 1;
                    return;
                end
                out_name = argv{i+1};
            case 'r'
                if numel(a) > 2
                    wfdbx.setwfdb(a(3:end));
                end
                i = i + 1;
                if i >= argc
                    ep('%s: input record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i+1};
            case 't'
                i = i + 1;
                if i >= argc
                    ep('%s: end time must follow -t\n', pname);
                    status = 1;
                    return;
                end
                to = i;
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
if ~ischar(record) || ~ischar(in_name)
    help(pname);
    status = 1;
    return;
end
if (from || to) && ~ischar(out_name)
    ep('%s: -o required when using -f or -t options\n', pname);
    status = 1;
    return;
end
if ischar(out_name) && strcmp(in_name, out_name)
    ep('%s: must specify different annotator names after -a and -o\n', pname);
    status = 1;
    return;
end
setenv('WFDBANNSORT', '0');
% wfdb-x: no default sampling frequency (the C program assumed 250 Hz if
% the record had no header); -F specifies one.  It is needed only to
% convert the -f and -t times.
sps = wfdbx.sampfreq(record);
if legacy           % wfdb-x: legacy mode (original behavior)
    if sps < 0
        sps = wfdbx.WFDB_DEFFREQ();
        wfdbx.setsampfreq(sps);
    end
elseif sps <= 0 && Ffreq > 0
    sps = Ffreq;
    wfdbx.setsampfreq(sps);
end
if ~legacy && sps <= 0 && ((from && wfdbx.wfdbx_time_needs_freq(argv{from+1})) || ...
        (to && wfdbx.wfdbx_time_needs_freq(argv{to+1})))
    ep('%s: sampling frequency of record %s is not specified (use -F)\n', ...
        pname, record);
    status = 1;
    return;
end
if wfdbx.annopen(record, wfdbx.anninfo(in_name, 0), 1) < 0
    status = 2;
    return;
end
if from
    from = wfdbx.strtim(argv{from+1});
    if from < 0
        from = -from;
    end
end
if to
    to = wfdbx.strtim(argv{to+1});
    if to < 0
        to = -to;
    end
end
tps = wfdbx.getiaorigfreq(0);
if tps > 0
    wfdbx.setafreq(tps);
    wfdbx.setiafreq(0, tps);
    if legacy || sps > 0
        from = fix(from * tps / sps + 0.5);
        to = fix(to * tps / sps + 0.5);
    elseif from || to   % wfdb-x: no default sampling frequency
        ep('%s: sampling frequency of record %s is not specified (use -F)\n', ...
            pname, record);
        status = 1;
        return;
    end
end
[~, A] = wfdbx.internal.getann_bulk(0, inf);
keep = ~(A.time < from | (to > 0 & A.time >= to));
A = sel(A, keep);
[order, in_order] = annlist(A.time, A.num, A.chan);
wfdbx.iannclose(0);
if in_order && ~ischar(out_name)
    ep('%s: input is already ordered -- no output written\n', pname);
    status = 0;
    return;
end
if from == 0 && to == 0 && ~ischar(out_name)
    out_name = in_name;
end
if wfdbx.annopen(record, wfdbx.anninfo(out_name, 1), 1) < 0
    status = 2;
    return;
end
A = sel(A, order);
A = sel(A, A.anntyp ~= 0);
wfdbx.internal.putann_bulk(0, A);
wfdbx.wfdbquit();
status = 0;
end

function A = sel(A, k)
A.time = A.time(k);
A.anntyp = A.anntyp(k);
A.subtyp = A.subtyp(k);
A.chan = A.chan(k);
A.num = A.num(k);
A.aux = A.aux(k);
end

function [order, in_order] = annlist(t, num, chan)
% The doubly-linked annotation list of sortann.c (same algorithm): returns
% the indices of the annotations in list order.  Node 1 is the static
% list head (an all-zero annotation, which takes part in comparisons).
n = numel(t);
in_order = 1;
if n <= 1
    order = 1:n;
    return;
end
gt = t(2:end) > t(1:end-1) | (t(2:end) == t(1:end-1) & ...
    (num(2:end) > num(1:end-1) | (num(2:end) == num(1:end-1) & ...
    chan(2:end) > chan(1:end-1))));
if all(gt)
    order = 1:n;
    return;
end
in_order = 0;
T = [0, t];
M = [0, num];
C = [0, chan];
nxt = zeros(1, n + 1);
prv = zeros(1, n + 1);
% the appended prefix
f = find(~gt, 1);           % annotation f+1 is the first not appended
nxt(1:f) = 2:f+1;
prv(2:f+1) = 1:f;
lastp = f + 1;
for x = f+2:n+1
    la = lastp;
    tx = T(x); mx = M(x); cx = C(x);
    if la == 1 || tx > T(la) || (tx == T(la) && (mx > M(la) || ...
            (mx == M(la) && cx > C(la))))
        prv(x) = la;
        nxt(la) = x;
        lastp = x;
        nxt(x) = 0;
        continue;
    end
    ap = la;
    while ap ~= 0
        ta = T(ap);
        if tx > ta || (tx == ta && (mx > M(ap) || (mx == M(ap) && cx >= C(ap))))
            break;
        end
        ap = prv(ap);
    end
    if ap == 0
        prv(x) = 0;
        nxt(x) = nxt(1);
        nxt(1) = x;
        prv(nxt(x)) = x;
    elseif tx == T(ap) && mx == M(ap) && cx == C(ap)
        prv(x) = prv(ap);
        if prv(x) ~= 0
            nxt(prv(x)) = x;
        end
        nxt(x) = nxt(ap);
        if nxt(x) ~= 0
            prv(nxt(x)) = x;
        else
            lastp = x;
        end
        % If ap was the first entry of the list but its 'prev' link does not
        % lead back to the list head (an entry inserted at the beginning
        % gets a null link, and one whose predecessor replaced the head is
        % detached), C leaves the head pointing to the freed entry
        % (undefined behavior): here the head is updated, so that the
        % duplicate is replaced (see docs/KNOWN_C_BEHAVIORS.md).
        if ap ~= 1 && nxt(1) == ap
            nxt(1) = x;
        end
    else
        prv(x) = ap;
        nxt(x) = nxt(ap);
        nxt(ap) = x;
        prv(nxt(x)) = x;
    end
end
order = zeros(1, n);
k = 0;
p = nxt(1);
while p ~= 0
    k = k + 1;
    order(k) = p - 1;
    p = nxt(p);
end
order = order(1:k);
end
