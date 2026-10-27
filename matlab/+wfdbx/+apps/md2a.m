function status = md2a(args)
%MD2A Convert an MIT-format signal file to AHA format.
%   STATUS = wfdbx.apps.md2a(ARGS) runs the md2a tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       md2a -o AHAFILE -r RECORD [OPTIONS ...]
%   where AHAFILE is the name of the AHA-format output signal file, RECORD
%   is the record name, and OPTIONS may include:
%       -h         print a usage summary
%       -n NEWREC  create a header file for the output signal file, so it
%                  may be read as record NEWREC
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository; the example writes out.aha and the record outaha in the
%   current folder):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.md2a({'-r', '100s', '-o', 'out.aha', '-n', 'outaha'})
%
%   See also wfdbx.apps.ad2m, wfdbx.apps.m2a.
%
%   Translation of the C program md2a (convert/md2a.c, WFDB 10.7.0): same
%   options and output.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of convert/md2a.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language and the --legacy
% option (as the first argument, it restores the original behavior).
%
% Original C program: convert/md2a.c, WFDB Software Package 10.7.0.
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
status = wfdbx.internal.app_run(@main, [{'md2a'}, args]);
end

function help(pname)
h = {'where AHAFILE is the name of the AHA-format output signal file,', ...
    'RECORD is the record name, and OPTIONS may include:', ...
    ' -h         print this usage summary', ...
    ' -n NEWREC  create a header file for the output signal file, so it', ...
    '             may be read as record NEWREC'};
wfdbx.internal.ceprintf('usage: %s -o AHAFILE -r RECORD [ OPTIONS ... ]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function status = main(argv)
EODF = 32768;           % 0100000
WFDB_MAXSIG = 32;
CHUNK = 65536;
pname = argv{1};
argc = numel(argv);
ep = @wfdbx.internal.ceprintf;
nrec = [];
ofname = [];
record = [];
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
            case 'h'
                help(pname);
                status = 1;
                return;
            case 'n'
                i = i + 1;
                if i >= argc
                    ep('%s: new record name must follow -n\n', pname);
                    status = 1;
                    return;
                end
                nrec = argv{i+1};
            case 'o'
                i = i + 1;
                if i >= argc
                    ep('%s: name of AHA-format output file must follow -o\n', pname);
                    status = 1;
                    return;
                end
                ofname = argv{i+1};
            case 'r'
                i = i + 1;
                if i >= argc
                    ep('%s: record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i+1};
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
if ~ischar(ofname) || ~ischar(record)
    help(pname);
    status = 1;
    return;
end
[nsig, s] = wfdbx.isigopen(record, WFDB_MAXSIG);
if nsig < 1
    status = 2;
    return;
end
if ischar(nrec) && wfdbx.newheader(nrec) < 0
    status = 3;
    return;
end
for k = 1:nsig
    s(k).fname = ofname;
    s(k).desc = '';
    s(k).group = 0;
    s(k).fmt = 16;
end
if wfdbx.osigfopen(s, nsig) < nsig
    status = 4;
    return;
end
% while (getvec(x) == nsig && putvec(x) == nsig) ;
% (x has one element per output sample of a frame, at least WFDB_MAXSIG,
% initially zero, of which getvec sets the first nsig; in C, x is an
% uninitialized array of WFDB_MAXSIG: see "Undefined behaviors" in
% docs/KNOWN_C_BEHAVIORS.md)
nout = sum(max([s(1:nsig).spf], 1));
while true
    [v, st] = wfdbx.getframes(CHUNK, nsig);
    if ~isempty(v)
        v = [v(:, 1:nsig), zeros(size(v, 1), nout - nsig)];
        if wfdbx.putframes(v) ~= nsig
            break;
        end
    end
    if st ~= nsig
        break;
    end
end
if ischar(nrec)
    wfdbx.newheader(nrec);
end
wfdbx.putvec([EODF * ones(1, nsig), zeros(1, nout - nsig)]);
wfdbx.wfdbquit();
status = 0;
end
