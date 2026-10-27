function status = rr2ann(args)
%RR2ANN Convert a series of RR intervals to an annotation file.
%   STATUS = wfdbx.apps.rr2ann(ARGS) runs the rr2ann tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       rr2ann -r RECORD -a ANNOTATOR [OPTIONS ...] <TEXT-FILE
%   where OPTIONS may include:
%       -F FREQ   use FREQ as the sampling frequency (effective only if the
%                 header file does not exist or does not specify it)
%       -h        print a usage summary
%       -T        TEXT-FILE contains times of occurrence, not RR intervals
%       -x N      multiply input by N to obtain RR in sample intervals
%       -w        copy annotation types from second column of input
%
%   wfdb-x: -F is required if the record has no header or its header does
%   not specify the sampling frequency (the C program assumed 250 Hz); see
%   docs/DIVERGENCES.md.
%
%   Example (from the shell; 100s, the first minute of record 100 of the
%   MIT-BIH Arrhythmia Database, is included with wfdb-x in the folder
%   tests/data of a copy of the repository; the example writes the
%   annotation file 100s.rr in the current folder):
%       export WFDBX_INPUT_DIR=/path/to/wfdb-x/tests/data
%       ann2rr -r 100s -a atr | rr2ann -r 100s -a rr
%
%   See also wfdbx.apps.ann2rr, wfdbx.apps.wrann.
%
%   Translation of the C program rr2ann (app/rr2ann.c, WFDB 10.7.0): same
%   options and output. Differences: -F is required when the record header
%   gives no sampling frequency; see docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/rr2ann.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in sampling frequency: -F FREQ is
% required when the record has no header or its header gives none (the original
% assumed 250 Hz); --legacy, as the first argument, restores the original
% behavior. Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md
% gives the reasons.
%
% Original C program: app/rr2ann.c, WFDB Software Package 10.7.0.
%   Copyright (C) 2000 George B. Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'rr2ann'}, args]);
end

function help(pname)
h = {'where RECORD and ANNOTATOR specify the output, and OPTIONS may include:', ...
    [' -F FREQ     use FREQ as the sampling frequency (effective only if the' ...
    '               header file does not exist or does not specify it)'], ...
    ' -h          print this usage summary', ...
    ' -T          TEXT-FILE contains times of occurrence, not RR intervals', ...
    ' -x N        multiply input by N to obtain RR in sample intervals', ...
    '               (default: N = 1)', ...
    ' -w          copy annotation types from second column of input', ...
    'TEXT-FILE should contain a column of RR intervals (or times of occurrence,', ...
    'if the -T option is specified), in units of sample intervals (unless the', ...
    '-x option is used to specify a conversion factor).   The first token on', ...
    'each line is taken as an RR interval, and (if the -w option is specified)', ...
    'the second token is taken as an annotation mnemonic (N, V, etc.);  anything', ...
    'else on the same line is ignored, as are empty lines, spaces and tabs at', ...
    'the beginning of a line non-numeric tokens and anything following them on', ...
    'the same line, negative intervals, and zero intervals.  The output consists', ...
    'of a binary annotation file (RECORD.ANNOTATOR), and (if it does not exist', ...
    'already) a text header file (RECORD.hea).'};
if wfdbx.wfdbx_get_legacy()  % wfdb-x: legacy mode: the original help text
    h{2} = [' -F FREQ     use FREQ as the sampling frequency (effective only if no' ...
        '               header file exists;  default: 250)'];
end
wfdbx.internal.ceprintf( ...
    'usage: %s -r RECORD -a ANNOTATOR [OPTIONS ...] <TEXT-FILE\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function status = main(argv)
pname = argv{1};
argc = numel(argv);
ep = @wfdbx.internal.ceprintf;
record = [];
ainame = [];
sps = 0;
t = 0;
xfactor = 1;
Tflag = 0;
wflag = 0;
i = 1;
while i < argc
    a = argv{i+1};
    if ~isempty(a) && a(1) == '-'
        if numel(a) >= 2
            c = a(2);
        else
            c = '';
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
            case 'F'
                i = i + 1;
                if i < argc
                    sps = wfdbx.internal.atof(argv{i+1});
                end
                if i >= argc || sps <= 0
                    ep('%s: sampling frequency (> 0) must follow -F\n', pname);
                    status = 1;
                    return;
                end
            case 'h'
                help(pname);
                status = 0;
                return;
            case 'r'
                i = i + 1;
                if i >= argc
                    ep('%s: record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i+1};
            case 'T'
                Tflag = 1;
            case 'x'
                i = i + 1;
                if i < argc
                    xfactor = wfdbx.internal.atof(argv{i+1});
                end
                if i >= argc || xfactor <= 0
                    ep('%s: an input multiplier (> 0) must follow -x\n', pname);
                    status = 1;
                    return;
                end
            case 'w'
                wflag = 1;
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
wfdbx.wfdbquiet();
% wfdb-x: no default sampling frequency (the C program assumed 250 Hz); -F
% specifies one if the record header does not.
f = wfdbx.sampfreq(record);
if f <= 0
    wfdbx.wfdbverbose();
    if sps == 0 && wfdbx.wfdbx_get_legacy()
        sps = wfdbx.WFDB_DEFFREQ();     % wfdb-x: legacy mode
    elseif sps == 0
        ep(['%s: sampling frequency of record %s is not specified ' ...
            '(use -F)\n'], pname, record);
        status = 1;
        return;
    end
    wfdbx.setsampfreq(sps);
    % no header: create one (the C program, and legacy mode: in any case)
    if (f < 0 || wfdbx.wfdbx_get_legacy()) && wfdbx.newheader(record) < 0
        status = 2;
        return;
    end
else
    wfdbx.wfdbverbose();
    if sps ~= 0
        ep('%s (warning): -F option ignored (using %g for sampling frequency)\n', ...
            pname, wfdbx.sampfreq([]));
    end
end
if wfdbx.annopen(record, wfdbx.anninfo(ainame, 1), 1) < 0
    status = 3;
    return;
end
lines = wfdbx.internal.fgets_lines(wfdbx.internal.stdin_bytes(), 1024);
nl = numel(lines);
T = zeros(1, nl);
typ = ones(1, nl);
keep = false(1, nl);
anntyp = 1;                             % NORMAL
rr = 0;
for li = 1:nl
    line = lines{li};
    if ~wflag
        [n, v] = wfdbx.internal.csscanf(line, '%lf');
        if n == 0
            continue;
        end
        if n > 0
            rr = v{1};
        end
    else
        [n, v] = wfdbx.internal.csscanf(line, '%lf%s');
        if n >= 1
            rr = v{1};
        end
        if n < 2
            continue;
        end
        anntyp = wfdbx.strann(v{2});
        if anntyp == 0
            continue;
        end
    end
    if rr <= 0
        continue;
    elseif Tflag
        t = rr * xfactor;
    else
        t = t + rr * xfactor;
    end
    T(li) = fix(t + 0.5);
    typ(li) = anntyp;
    keep(li) = true;
end
m = sum(keep);
A.time = T(keep);
A.anntyp = typ(keep);
A.subtyp = zeros(1, m);
A.chan = zeros(1, m);
A.num = zeros(1, m);
A.aux = cell(1, m);
wfdbx.internal.putann_bulk(0, A);
wfdbx.wfdbquit();
status = 0;
end
