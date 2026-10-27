function status = ann2rr(args)
%ANN2RR Extract a list of intervals from an annotation file.
%   STATUS = wfdbx.apps.ann2rr(ARGS) runs the ann2rr tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       ann2rr -r RECORD -a ANNOTATOR [OPTIONS ...]
%   where OPTIONS may include:
%       -A      print all intervals between annotations (default: print
%               only RR intervals; overrides -c, -p)
%       -c      print intervals between consecutive valid annotations only
%       -f TIME start at specified TIME
%       -F FREQ sampling frequency, if the record header does not specify
%               one
%       -h      print a usage summary
%       -i FMT  print intervals using format FMT (h, m, s, t; h, m and s
%               may be followed by a number of decimal places)
%       -p TYPE [TYPE ...]  print intervals ending with annotations of
%               specified TYPEs only
%       -P TYPE [TYPE ...]  print intervals beginning with specified
%               types only
%       -t TIME stop at specified TIME
%       -v FMT  print times of ends of intervals using format FMT
%       -V FMT  print times of beginnings of intervals using format FMT
%       -w      print annotations that end intervals
%       -W      print annotations that begin intervals
%
%   wfdb-x: no sampling frequency is assumed (the C program assumed 250 Hz
%   if the record had no header); without a header giving one, -F is
%   required for time arguments and for intervals and times in units of
%   time (formats h, m, s, t, T).  See docs/DIVERGENCES.md.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.ann2rr({'-r', '100s', '-a', 'atr', '-i', 's'})
%
%   See also wfdbx.apps.rr2ann, wfdbx.apps.rdann, wfdbx.read_annotations.
%
%   Translation of the C program ann2rr (app/ann2rr.c, WFDB 10.7.0): same
%   options and output. Differences: -F gives the sampling frequency when
%   the record header gives none; see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/ann2rr.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in sampling frequency: the new option -F
% FREQ gives it when the record has no header or its header gives none, and is
% then required for time arguments and for intervals and times in units of time
% (the original assumed 250 Hz); --legacy, as the first argument, restores the
% original behavior. Each change is marked "wfdb-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
%
% Original C program: app/ann2rr.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1995-2009 George B. Moody; revised 2018-2020 by
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
status = wfdbx.internal.app_run(@main, [{'ann2rr'}, args]);
end

function r = time_format_needs_freq(c)
% wfdb-x: true if output format C (for -i, -v, or -V) is a unit of time,
% which needs the sampling frequency.
r = ~isempty(c) && any(c(1) == 'hmstT');
end

function help(pname)
h = {'where RECORD and ANNOTATOR specify the input, and OPTIONS may include:', ...
    ' -A      print all intervals between annotations (default: print only RR', ...
    '          intervals; overrides -c, -p)', ...
    ' -c      print intervals between consecutive valid annotations only', ...
    ' -f TIME start at specified TIME', ...
    ' -F FREQ sampling frequency, if the record header does not specify one', ...
    ' -h      print this usage summary', ...
    ' -i FMT  print intervals using format FMT (see below for values of FMT)', ...
    ' -p TYPE [TYPE ...]  print intervals ending with annotations of specified', ...
    '                      TYPEs only (use mnemonics such as N or V for TYPE)', ...
    ' -P TYPE [TYPE ...]  print intervals beginning with specified types only', ...
    ' -t TIME stop at specified TIME', ...
    ' -v FMT  print times of ends of intervals using format FMT (see below)', ...
    ' -V FMT  print times of beginnings of intervals using format FMT (see below)', ...
    ' -w      print annotations that end intervals', ...
    ' -W      print annotations that begin intervals', ...
    'By default, the output contains the RR intervals only, unless one or more', ...
    'of -v, -V, -w, or -W are used.  Intervals and times are printed in units of', ...
    'sample intervals, unless a format is specified using -i, -v, or -V.', ...
    'Formats can be ''h'' (hours), ''m'' (minutes), ''s'' (seconds), ''t'' (hh:mm:ss);', ...
    'when used with -v or -V, format ''T'' yields dates and times if available,', ...
    'or the format can be omitted to obtain times in sample intervals.  Formats', ...
    '''h'', ''m'', and ''s'' may be followed by a number between 0 and 15, specifying', ...
    'the number of decimal places (default: 3).  For example, to obtain intervals', ...
    'in seconds with 8 decimal places, use ''-i s8''.'};
if wfdbx.wfdbx_get_legacy()  % wfdb-x: legacy mode: the original help text
    h(6) = [];                  % (without -F)
end
wfdbx.internal.ceprintf('usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...]\n', pname);
for i = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{i});
    if mod(i, 23) == 0   % pause every 23 lines, as in C
        wfdbx.internal.cerr('--More--');
        wfdbx.internal.stdin_bytes();
        wfdbx.internal.cerr([char(27) '[A' char(27) '[2K']);   % VT100: cursor up, erase line
    end
end
end

function d = digits(arg, default)
[n, v] = wfdbx.internal.csscanf(arg(2:end), '%d');
if n == 1
    d = wfdbx.internal.cint32(v{1});
else
    d = default;
end
end

function status = main(argv)
ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
pname = argv{1};
Ffreq = 0;      % -F (WFDB-x)
legacy = wfdbx.wfdbx_get_legacy();
argc = numel(argv);
ep = @wfdbx.internal.ceprintf;
record = [];
ainame = [];
Aflag = 0; a0flag = 0; a1flag = 0; cflag = 0;
previous_annot_valid = 0;
rrdigits = 3; t0digits = 3; t1digits = 3;
rrformat = ''; t0format = ''; t1format = '';
t0flag = 0; t1flag = 0;
a0f = zeros(1, ACMAX + 1);
a1f = zeros(1, ACMAX + 1);
a0f(1) = 1;
a1f(1) = 1;
from = 0;
to = 0;
i = 1;
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
            case 'A'
                Aflag = 1;
            case 'c'
                cflag = 1;
            case 'f'
                i = i + 1;
                if i >= argc
                    ep('%s: starting time must follow -f\n', pname);
                    status = 1;
                    return;
                end
                from = i;
            case 'F'    % sampling frequency follows (WFDB-x)
                [Ffreq, i, ok] = wfdbx.internal.opt_ffreq(argv, i, Ffreq);
                if ~ok
                    status = 1;
                    return;
                end
            case 'h'
                help(pname);
                status = 0;
                return;
            case 'i'
                i = i + 1;
                if i >= argc || isdash(argv{i+1})
                    ep('%s: interval output format must follow -i\n', pname);
                    status = 1;
                    return;
                end
                rrformat = argv{i+1}(1:min(1, end));
                rrdigits = digits(argv{i+1}, rrdigits);
            case {'p', 'P'}
                i = i + 1;
                if i < argc
                    j = wfdbx.strann(argv{i+1});
                else
                    j = 0;
                end
                if i >= argc || ~(j > 0 && j <= ACMAX)
                    if c == 'p'
                        o = 'P';
                    else
                        o = 'p';
                    end
                    ep('%s: annotation mnemonic(s) must follow -%s\n', pname, o);
                    status = 1;
                    return;
                end
                tbl = zeros(1, ACMAX + 1);
                if c == 'p'
                    tbl = a1f;
                else
                    tbl = a0f;
                end
                tbl(j+1) = 1;
                i = i + 1;
                while i < argc && ~isdash(argv{i+1})
                    j = wfdbx.strann(argv{i+1});
                    if j > 0 && j <= ACMAX
                        tbl(j+1) = 1;
                    end
                    i = i + 1;
                end
                if i == argc || isdash(argv{i+1})
                    i = i - 1;
                end
                tbl(1) = 0;
                if c == 'p'
                    a1f = tbl;
                else
                    a0f = tbl;
                end
            case 'r'
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
            case {'v', 'V'}
                if c == 'v'
                    t1flag = 1;
                else
                    t0flag = 1;
                end
                i = i + 1;
                if i >= argc || isdash(argv{i+1})
                    i = i - 1;
                elseif c == 'v'
                    t1format = argv{i+1}(1:min(1, end));
                    t1digits = digits(argv{i+1}, t1digits);
                else
                    t0format = argv{i+1}(1:min(1, end));
                    t0digits = digits(argv{i+1}, t0digits);
                end
            case 'w'
                a1flag = 1;
            case 'W'
                a0flag = 1;
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
% the record had no header); -F specifies one.  It is needed for times and
% intervals in units of time.  Legacy mode: as in the C program.
sps = wfdbx.sampfreq(record);
if legacy
    if sps < 0
        sps = wfdbx.WFDB_DEFFREQ();
        wfdbx.setsampfreq(sps);
    end
elseif sps <= 0 && Ffreq > 0
    sps = Ffreq;
    wfdbx.setsampfreq(sps);
end
if ~legacy && sps <= 0 && ...
        ((from && wfdbx.wfdbx_time_needs_freq(argv{from+1})) || ...
        (to && wfdbx.wfdbx_time_needs_freq(argv{to+1})) || ...
        time_format_needs_freq(rrformat) || ...
        (t0flag && time_format_needs_freq(t0format)) || ...
        (t1flag && time_format_needs_freq(t1format)))
    ep('%s: sampling frequency of record %s is not specified (use -F)\n', ...
        pname, record);
    status = 1;
    return;
end
spm = 60 * sps;
sph = 60 * spm;
if wfdbx.annopen(record, wfdbx.anninfo(ainame, 0), 1) < 0
    status = 2;
    return;
end
if rrdigits < 0 || rrdigits > 15
    rrdigits = 3;
end
rrfstr = sprintf('%%.%df', rrdigits);
if t0digits < 0 || t0digits > 15
    t0digits = 3;
end
t0fstr = sprintf('%%.%df', t0digits);
if t1digits < 0 || t1digits > 15
    t1digits = 3;
end
t1fstr = sprintf('%%.%df', t1digits);
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
if to > 0 && to < from
    tmp = from;
    from = to;
    to = tmp;
end
if from > 0 && wfdbx.iannsettime(from) < 0
    status = 2;
    return;
end
a0 = 0;
t0 = from;
emap = wfdbx.internal.ecg_map();
qrs = emap.qrs;
st = wfdbx.internal.ann_state();
astr = st.astring;
out = @wfdbx.internal.cout;
switch rrformat
    case 'h'
        unit = sph;
    case 'm'
        unit = spm;
    case 's'
        unit = sps;
    otherwise
        unit = 0;
end
% Without the formats that need the time strings of the library or
% adjust the times (see fastchunk), the output is built with vector
% operations.
fast = unit == 0 && ~strcmp(rrformat, 't') && ~any(strcmp(t0format, {'t', 'T'})) ...
    && ~any(strcmp(t1format, {'t', 'T'}));
% (annotations are read 4096 at a time; one at a time from AHA files,
% where reading an annotation may print a message, so that no annotation
% is read beyond the last one C reads)
chunk = 4096;
if st.iad{1}.P.aha
    chunk = 1;
end
while true
    [stat, A] = wfdbx.internal.getann_bulk(0, chunk, true, true);
    m = numel(A.time);
    stop = false;
    if to ~= 0
        k = find(A.time > to, 1);
        if ~isempty(k)
            m = k - 1;
            stop = true;
        end
    end
    if fast
        [txt, a0, t0, previous_annot_valid] = fastchunk(A, m, a0, t0, ...
            previous_annot_valid, Aflag, cflag, a0flag, a1flag, t0flag, ...
            t1flag, a0f, a1f, qrs, astr, t0format, t1format, t0fstr, ...
            t1fstr, sps, spm, sph);
        if ischar(txt)
            out(txt);
            m = 0;                      % (done)
        end
    end
    for q = 1:m
        a1 = A.anntyp(q);
        t1 = A.time(q);
        if a1 > 0 && a1 <= ACMAX
            isq = qrs(a1+1) ~= 0;
            f1 = a1f(a1+1);
            f0 = a0f(a1+1);
        else
            isq = false;
            f1 = (a1 == 0) * a1f(1);
            f0 = (a1 == 0) * a0f(1);
        end
        if Aflag || (a1f(1) && isq) || f1
            if cflag == 0 || previous_annot_valid == 1
                s = '';
                if t0flag
                    s = [timefmt(t0format, t0fstr, t0, sps, spm, sph, true), char(9)];
                end
                if a0flag
                    if a0 == 0
                        s = [s, '[0]', char(9)]; %#ok<AGROW>
                    else
                        s = [s, mnem(astr, a0), char(9)]; %#ok<AGROW>
                    end
                end
                rr = t1 - t0;
                if unit
                    rrstr = sprintf(rrfstr, rr / unit);
                    rrstr = rrstr(1:min(end, 19));   % char rrstr[20] in C
                    s = [s, rrstr]; %#ok<AGROW>
                    [n, v] = wfdbx.internal.csscanf(rrstr, '%lf');
                    if n == 1
                        frr = v{1};
                    else
                        frr = 0;
                    end
                    t1 = fix(t0 + frr * unit + 0.5);
                elseif strcmp(rrformat, 't')
                    s = [s, wfdbx.mstimstr(t1)]; %#ok<AGROW>
                else
                    s = [s, sprintf('%d', rr)]; %#ok<AGROW>
                end
                if a1flag
                    s = [s, char(9), mnem(astr, a1)]; %#ok<AGROW>
                end
                if t1flag
                    s = [s, char(9), timefmt(t1format, t1fstr, t1, sps, spm, sph, false)]; %#ok<AGROW>
                end
                out([s, char(10)]);
            end
        end
        if Aflag || (a0f(1) && isq) || f0
            a0 = a1;
            t0 = t1;
            previous_annot_valid = 1;
        elseif cflag
            previous_annot_valid = 0;
        end
    end
    if stop
        break;
    end
    if stat ~= 0
        if stat == 1
            wfdbx.getann(0);        % the call that fails (prints any error)
        end
        break;
    end
end
status = 0;
end

function [txt, a0, t0, pv] = fastchunk(A, m, a0, t0, pv, Aflag, cflag, ...
    a0flag, a1flag, t0flag, t1flag, a0f, a1f, qrs, astr, t0format, ...
    t1format, t0fstr, t1fstr, sps, spm, sph)
% The output for the first m annotations of A, and the state after them,
% computed with vector operations (txt = [] if this is not possible).
ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
txt = [];
if m == 0
    txt = '';
    return;
end
a1 = A.anntyp(1:m);
t1 = A.time(1:m);
v = a1 > 0 & a1 <= ACMAX;
isq = false(1, m);
isq(v) = qrs(a1(v) + 1) ~= 0;
f1 = zeros(1, m);
f0 = zeros(1, m);
f1(v) = a1f(a1(v) + 1);
f0(v) = a0f(a1(v) + 1);
f1(a1 == 0) = a1f(1);
f0(a1 == 0) = a0f(1);
c1 = Aflag | (a1f(1) & isq) | f1 ~= 0;     % prints an interval
c0 = Aflag | (a0f(1) & isq) | f0 ~= 0;     % begins the next interval
% state before each annotation
k = find(c0);
last = zeros(1, m);                         % last annotation with c0, before q
if ~isempty(k)
    mark = zeros(1, m);
    mark(k) = k;
    last = [0, cummax(mark(1:end-1))];
end
T0 = repmat(t0, 1, m);
A0 = repmat(a0, 1, m);
h = last > 0;
T0(h) = t1(last(h));
A0(h) = a1(last(h));
if cflag
    PV = [pv, double(c0(1:end-1))];
    pr = c1 & PV == 1;
else
    pr = c1;
end
q = find(pr);
if ~isempty(k)
    a0 = a1(k(end));
    t0 = t1(k(end));
    pv = 1;
elseif cflag
    pv = 0;
end
if cflag && ~c0(m)
    pv = 0;
end
if isempty(q)
    txt = '';
    return;
end
n = numel(q);
fmt = '';
C = cell(0, n);
if t0flag
    [f, x] = numfmt(t0format, t0fstr, T0(q), sps, spm, sph);
    fmt = [fmt, f, '\t'];
    C(end+1, :) = num2cell(x);
end
if a0flag
    s = mnems(astr, A0(q), true);
    if isempty(s)
        return;
    end
    fmt = [fmt, '%s\t'];
    C(end+1, :) = s;
end
fmt = [fmt, '%d'];
C(end+1, :) = num2cell(t1(q) - T0(q));
if a1flag
    s = mnems(astr, a1(q), false);
    if isempty(s)
        return;
    end
    fmt = [fmt, '\t%s'];
    C(end+1, :) = s;
end
if t1flag
    [f, x] = numfmt(t1format, t1fstr, t1(q), sps, spm, sph);
    fmt = [fmt, '\t', f];
    C(end+1, :) = num2cell(x);
end
txt = sprintf([fmt, '\n'], C{:});
end

function [f, x] = numfmt(fmt, fstr, t, sps, spm, sph)
switch fmt
    case 'h'
        f = fstr;
        x = t / sph;
    case 'm'
        f = fstr;
        x = t / spm;
    case 's'
        f = fstr;
        x = t / sps;
    otherwise
        f = '%d';
        x = t;
end
end

function s = mnems(astr, a, zero)
% the mnemonics of codes a ([0] for 0 if zero); {} if one of them is empty
s = cell(1, numel(a));
for c = reshape(unique(a), 1, [])
    if zero && c == 0
        m = '[0]';
    else
        m = mnem(astr, c);
    end
    if isempty(m)
        s = {};
        return;
    end
    s(a == c) = {m};
end
end

function s = mnem(astr, a)
ACMAX = 49;     % largest annotation code (lib/ecgcodes.h)
if a >= 0 && a <= ACMAX
    s = astr{a+1};
else
    s = sprintf('[%d]', a);
end
end

function s = timefmt(fmt, fstr, t, sps, spm, sph, begin)
switch fmt
    case 'h'
        s = sprintf(fstr, t / sph);
    case 'm'
        s = sprintf(fstr, t / spm);
    case 's'
        s = sprintf(fstr, t / sps);
    case 't'
        if begin && t == 0
            s = '    0:00.000';
        else
            s = wfdbx.mstimstr(t);
        end
    case 'T'
        s = wfdbx.mstimstr(-t);
    otherwise
        s = sprintf('%d', t);
end
end

function tf = isdash(s)
tf = ~isempty(s) && s(1) == '-';
end
