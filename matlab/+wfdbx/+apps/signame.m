function status = signame(args)
%SIGNAME Print the names of the signals of a WFDB record.
%   STATUS = wfdbx.apps.signame(ARGS) runs the signame tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       signame -r RECORD [OPTIONS ...]
%   where OPTIONS may include:
%       -h          print a usage summary
%       -s SIGNAL [SIGNAL ...]  print the names of the specified signals
%   Without -s, the names of all signals of the record are printed.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.signame({'-r', '100s'})
%
%   See also wfdbx.apps.signum, wfdbx.read_header.
%
%   Translation of the C program signame (app/signame.c, WFDB 10.7.0): same
%   options and output.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/signame.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language and the --legacy
% option (as the first argument, it restores the original behavior).
%
% Original C program: app/signame.c, WFDB Software Package 10.7.0.
%   Copyright (C) 2008 George B. Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'signame'}, args]);
end

function status = main(argv)
helplines = {'usage: %s -r RECORD [OPTIONS ...]\n', ...
    'where RECORD is the name of the input record, and OPTIONS may include:', ...
    ' -h          print this usage summary', ...
    ' -s SIGNAL [SIGNAL ...]  print signal name(s) for the specified signal(s)', ...
    'If no -s option is given, the names of all signals in the record are output.'};
[status, si, nsig, isiglist, nosig] = parse_args(argv, false, helplines);
if status >= 0
    return;
end
if isiglist
    for i = 1:nosig
        j = wfdbx.internal.atoi(argv{isiglist + i});
        % (The C version also accepts j == nsig, reading past the end of
        % its array; see docs/KNOWN_C_BEHAVIORS.md.)
        if j >= 0 && j < nsig
            p = si(j + 1).desc;
        else
            p = '[INVALID]';
        end
        wfdbx.internal.cprintf('%s\n', p);
    end
else
    for i = 1:nsig
        wfdbx.internal.cprintf('%s\n', si(i).desc);
    end
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
