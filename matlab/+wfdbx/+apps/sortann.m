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
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository; the example writes the annotation file 100s.srt in the
%   current folder):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.sortann({'-r', '100s', '-a', 'atr', '-o', 'srt'})
%
%   See also wfdbx.apps.rdann, wfdbx.putann.
%
%   Translation of the C program sortann (app/sortann.c, WFDB 10.7.0): same
%   options and output. Differences: -F gives the sampling frequency when
%   the record header gives none; see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/sortann.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in sampling frequency: the new option -F
% FREQ gives it when the record has no header or its header gives none, and is
% then required for the -f and -t times (the original assumed 250 Hz); an
% out-of-order annotation at time 0 (num 0, chan 0) is no longer lost, nor are
% those inserted after it; --legacy, as the first argument, restores the
% original behavior. Each change is marked "wfdb-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
%
% Original C program: app/sortann.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1997-2010 George B. Moody; revised 2017-2018 by
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
Ffreq = 0;      % -F (WFDB-x)
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
% wfdb-x: the original insertion (which loses an out-of-order annotation
% at time 0) in legacy mode only
[order, in_order] = wfdbx.internal.ann_sortlist(A.time, A.num, A.chan, ...
    legacy);
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
