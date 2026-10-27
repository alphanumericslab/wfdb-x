function status = wfdbtime(args)
%WFDBTIME Convert between times and sample numbers of a WFDB record.
%   STATUS = wfdbx.apps.wfdbtime(ARGS) runs the wfdbtime tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       wfdbtime [ -r RECORD [ TIME ... ] ]
%   For each TIME, the sample number, the elapsed time and the absolute
%   time (if known) are printed.  wfdb-x: the record must specify its
%   sampling frequency (the C program assumed 250 Hz); see
%   docs/DIVERGENCES.md.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.wfdbtime({'-r', '100s', '1:00', 's100'})
%
%   See also wfdbx.apps.time2sec, wfdbx.strtim, wfdbx.timstr.
%
%   Translation of the C program wfdbtime (app/wfdbtime.c, WFDB 10.7.0):
%   same options and output. Differences: no sampling frequency is assumed;
%   see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/wfdbtime.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in sampling frequency: the record must
% give it (the original assumed 250 Hz); --legacy, as the first argument,
% restores the original behavior. Each change is marked "wfdb-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
%
% Original C program: app/wfdbtime.c, WFDB Software Package 10.7.0.
%   Copyright (C) 2001 George B. Moody; revised 2017-2018 by Benjamin Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'wfdbtime'}, args]);
end

function status = main(argv)
record = [];
argc = numel(argv);
i = 1;
while i < argc
    if strcmp(argv{i + 1}, '-r')
        if ischar(record)
            wfdbx.wfdbquit();
        end
        i = i + 1;
        if i == argc
            break;
        end
        record = argv{i + 1};
        if wfdbx.isigopen(record, 0) < 0
            status = 2;
            return;
        end
        % wfdb-x: no default frequency (except in legacy mode)
        if ~wfdbx.wfdbx_get_legacy() && wfdbx.sampfreq([]) <= 0
            wfdbx.internal.ceprintf( ...
                '%s: sampling frequency of record %s is not specified\n', ...
                argv{1}, record);
            status = 2;
            return;
        end
    elseif ischar(record)
        t = wfdbx.strtim(argv{i + 1});
        if t < 0
            t = -t;
        end
        if t == 0
            e = '0:00.000';
        else
            e = wfdbx.mstimstr(t);
        end
        wfdbx.internal.cout([sprintf('%15s\t%15s', sprintf('s%d', t), e), ...
            sprintf('\t%15s\n', wfdbx.mstimstr(-t))]);
    end
    i = i + 1;
end
if ~ischar(record)
    wfdbx.internal.ceprintf('usage: %s [ -r RECORD [ TIME ] ]\n', argv{1});
    wfdbx.internal.ceprintf(' where RECORD is the name of the input record\n');
    wfdbx.internal.ceprintf(' Each TIME is a time to be converted\n');
    status = 1;
    return;
end
wfdbx.wfdbquit();
status = 0;
end
