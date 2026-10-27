function status = m2a(args)
%M2A Convert an MIT-format annotation file to AHA format.
%   STATUS = wfdbx.apps.m2a(ARGS) runs the m2a tool with the command-line
%   arguments ARGS (a cell row of char vectors, without the program name)
%   and returns its exit status.
%
%   Usage (as for the C program):
%       m2a -r RECORD -a MIT-ANNOTATOR AHA-ANNOTATOR [OPTIONS ...]
%   where OPTIONS may include:
%       -F FREQ   sampling frequency, if the record header does not specify
%                 one
%       -h        print a usage summary
%       -s TIME   shift annotation times backwards by TIME, and convert
%                 them to milliseconds
%
%   wfdb-x: no sampling frequency is assumed (the C program assumed 250 Hz
%   if the record header did not specify one); with -s, a header giving it
%   or -F is required.  See docs/DIVERGENCES.md.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository; the example writes the AHA-format file aha in the
%   current folder):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.m2a({'-r', '100s', '-a', 'atr', 'aha'})
%
%   See also wfdbx.apps.a2m, wfdbx.apps.md2a.
%
%   Translation of the C program m2a (convert/m2a.c, WFDB 10.7.0): same
%   options and output. Differences: -F gives the sampling frequency when
%   the record header gives none; see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of convert/m2a.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in sampling frequency: the new option -F
% FREQ gives it when the record header gives none, and is then required for -s
% (the original assumed 250 Hz); --legacy, as the first argument, restores the
% original behavior. Each change is marked "wfdb-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
%
% Original C program: convert/m2a.c, WFDB Software Package 10.7.0.
%   Copyright (C) 2001 George B. Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'m2a'}, args]);
end

function help(pname)
h = {'where RECORD is the record name, MIT-ANNOTATOR is the annotator name', ...
    'for the input annotation file, AHA-ANNOTATOR is the annotator name', ...
    'for the output (AHA format) annotation file, and OPTIONS may include:', ...
    ' -F FREQ   sampling frequency, if the record header does not specify one', ...
    ' -h        print this usage summary', ...
    ' -s TIME   shift annotation times backwards by the specified TIME,', ...
    '            and convert them to milliseconds'};
if wfdbx.wfdbx_get_legacy()  % wfdb-x: legacy mode: the original help text
    h(4) = [];                  % (without -F)
end
wfdbx.internal.ceprintf( ...
    'usage: %s -r RECORD -a MIT-ANNOTATOR AHA-ANNOTATOR [ OPTIONS ... ]\n', pname);
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
ianame = [];
oaname = [];
record = [];
shift = [];
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
                if i >= argc - 1
                    ep('%s: input and output annotator names must follow -a\n', pname);
                    status = 1;
                    return;
                end
                ianame = argv{i+1};
                i = i + 1;
                oaname = argv{i+1};
            case 'F'    % sampling frequency follows (WFDB-x)
                [Ffreq, i, ok] = wfdbx.internal.opt_ffreq(argv, i, Ffreq);
                if ~ok
                    status = 1;
                    return;
                end
            case 'h'
                help(pname);
                status = 1;
                return;
            case 'r'
                i = i + 1;
                if i >= argc
                    ep('%s: record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i+1};
            case 's'
                i = i + 1;
                if i >= argc
                    ep('%s: time shift must follow -s\n', pname);
                    status = 1;
                    return;
                end
                shift = argv{i+1};
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
if ~ischar(ianame) || ~ischar(oaname) || ~ischar(record)
    help(pname);
    status = 1;
    return;
end
ai = [wfdbx.anninfo(ianame, 0), wfdbx.anninfo(oaname, 3)]; % READ, AHA_WRITE
if wfdbx.annopen(record, ai, 2) < 0
    status = 2;
    return;
end
annot = wfdbx.annotation();
if ~ischar(shift)
    while true
        [st, annot] = wfdbx.getann(0, annot);
        if st < 0
            break;
        end
        wfdbx.putann(0, annot);
    end
else
    % wfdb-x: no default sampling frequency (the C program assumed 250 Hz
    % if the record header did not specify one); -F specifies one.
    if wfdbx.sampfreq(record) <= 0
        if legacy   % (as in the C program)
            wfdbx.setsampfreq(wfdbx.WFDB_DEFFREQ());
        elseif Ffreq > 0
            wfdbx.setsampfreq(Ffreq);
        else
            ep(['%s: sampling frequency of record %s is not specified ' ...
                '(use -F)\n'], pname, record);
            status = 1;
            return;
        end
    end
    mssi = 1000.0 / wfdbx.strtim('1');   % milliseconds per sample interval
    dt = wfdbx.strtim(shift);
    while true
        [st, annot] = wfdbx.getann(0, annot);
        if st < 0
            break;
        end
        if annot.time >= dt
            annot.time = fix((annot.time - dt) * mssi);
            wfdbx.putann(0, annot);
        end
    end
end
wfdbx.wfdbquit();
status = 0;
end
