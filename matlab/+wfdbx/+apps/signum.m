function status = signum(args)
%SIGNUM Print the numbers of the signals of a record that have given names.
%   STATUS = wfdbx.apps.signum(ARGS) runs the signum tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       signum -r RECORD -s SIGNAL [SIGNAL ...]
%       signum -h            (print a usage summary)
%   For each SIGNAL (a signal description), one line is printed: the
%   numbers of all signals with that description, separated by tabs, or X
%   if there is none.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with wfdb-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.signum({'-r', '100s', '-s', 'MLII'})
%
%   See also wfdbx.apps.signame, wfdbx.findsig.
%
%   Translation of the C program signum (app/signum.c, WFDB 10.7.0): same
%   options and output.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/signum.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language and the --legacy
% option (as the first argument, it restores the original behavior).
%
% Original C program: app/signum.c, WFDB Software Package 10.7.0.
%   Copyright (C) 2008 George B. Moody; revised 2021 by Benjamin Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'signum'}, args]);
end

function status = main(argv)
helplines = {'usage: %s -r RECORD [OPTIONS ...]\n', ...
    'where RECORD is the name of the input record, and OPTIONS may include:', ...
    ' -h          print this usage summary', ...
    ' -s SIGNAL [SIGNAL ...]  print signal number(s) for the specified signal(s)'};
[status, si, nsig, isiglist, nosig] = parse_args(argv, true, helplines);
if status >= 0
    return;
end
for i = 1:nosig
    found = 0;
    name = argv{isiglist + i};
    for j = 1:nsig
        if ischar(si(j).desc) && strcmp(name, si(j).desc)
            if found
                wfdbx.internal.cout(char(9));
            end
            wfdbx.internal.cout(sprintf('%d', j - 1));
            found = 1;
        end
    end
    if ~found
        wfdbx.internal.cout('X');
    end
    wfdbx.internal.cout(char(10));
end
wfdbx.wfdbquit();
status = 0;
end

function help(pname, lines)
wfdbx.internal.ceprintf(lines{1}, pname);
for k = 2:numel(lines)
    wfdbx.internal.ceprintf('%s\n', lines{k});
end
end

function [status, si, nsig, isiglist, nosig] = parse_args(argv, needlist, helplines)
% Option parsing shared by signame and signum (status -1: continue).
pname = argv{1};
argc = numel(argv);
status = -1;
si = [];
nsig = 0;
record = [];
isiglist = 0;
nosig = 0;
i = 1;
while i < argc
    a = argv{i + 1};
    if strncmp(a, '-', 1)
        if numel(a) >= 2
            c = a(2);
        else
            c = char(0);
        end
        switch c
            case 'h'
                help(pname, helplines);
                status = 0;
                return;
            case 'r'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i + 1};
            case 's'
                isiglist = i + 1;
                while i + 1 < argc && ~strncmp(argv{i + 2}, '-', 1)
                    i = i + 1;
                    nosig = nosig + 1;
                end
                if nosig == 0
                    wfdbx.internal.ceprintf('%s: signal list must follow -s\n', pname);
                    status = 1;
                    return;
                end
            otherwise
                wfdbx.internal.ceprintf('%s: unrecognized option %s\n', pname, a);
                status = 1;
                return;
        end
    else
        wfdbx.internal.ceprintf('%s: unrecognized argument %s\n', pname, a);
        status = 1;
        return;
    end
    i = i + 1;
end
if ~ischar(record) || (needlist && isiglist == 0)
    help(pname, helplines);
    status = 1;
    return;
end
nsig = wfdbx.isigopen(record, 0);
if nsig <= 0
    status = 2;
    return;
end
[nsig, si] = wfdbx.isigopen(record, -nsig);
if nsig <= 0
    status = 2;
    return;
end
end
