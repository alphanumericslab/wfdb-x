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
%   Example:
%       wfdbx.apps.signum({'-r', '100s', '-s', 'MLII'})
%
%   See also wfdbx.apps.signame, wfdbx.findsig.

% Copyright (C) 2008 George B. Moody (original C program, app/signum.c; revised
% 2021 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU General Public License, version 2 or later (see LICENSE).

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
