function status = makeid(args)
%MAKEID Make an AHA-format ID block for a record.
%   STATUS = wfdbx.apps.makeid(ARGS) runs the makeid tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       makeid ANNOTATOR RECORD
%   The 512-byte ID block is written to the standard output, and a
%   description of it to the standard error output.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.makeid({'atr', '100s'})
%
%   See also wfdbx.apps.readid, wfdbx.apps.md2a.
%
%   Translation of the C program makeid (convert/makeid.c, WFDB 10.7.0):
%   same options and output.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of convert/makeid.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language and the --legacy
% option (as the first argument, it restores the original behavior).
%
% Original C program: convert/makeid.c, WFDB Software Package 10.7.0.
%   Copyright (C) 2003 George B. Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'makeid'}, args]);
end

function b = p16(x)
x = mod(x, 65536);
b = [mod(x, 256), floor(x / 256)];
end

function b = p32(x)
% PDP-11 byte order: the high 16-bit word first, each word little-endian.
b = [p16(floor(x / 65536)), p16(x)];
end

function status = main(argv)
if numel(argv) < 3
    wfdbx.internal.ceprintf('usage: %s annotator record\n', argv{1});
    status = 1;
    return;
end
rec = argv{3};
ln = numel(rec);
if ln > 8
    wfdbx.internal.ceprintf('record name must be 8 characters or less\n');
    status = 1;
    return;
end
[stat, si] = wfdbx.wfdbinit(rec, wfdbx.anninfo(argv{2}, 0), 1, 2);   % WFDB_READ
if stat < 1
    status = 2;
    return;
end
nsamp = si(1).nsamp;
[~, A] = wfdbx.internal.getann_bulk(0, Inf, true);
n = numel(A.time);
if n == 0
    wfdbx.getann(0);    % the second call of the C loop (which fails too)
    first = 0;
else
    first = A.time(1);
end
if n >= 2
    last = A.time(end);
else
    last = 0;
end
nann = max(n, 1);
wfdbx.wfdbquit();
out = [double(rec), zeros(1, 8 - ln)];
wfdbx.internal.ceprintf('%s\n', rec);
out = [out, p16(nann)];
wfdbx.internal.ceprintf('%d annotations\n', nann);
out = [out, zeros(1, 6), p32(0)];
wfdbx.internal.ceprintf('Annotated segment begins at sample 0\n');
out = [out, p32(nsamp)];
wfdbx.internal.ceprintf('Annotated segment ends at sample %d\n', nsamp);
blocks = floor((nsamp + 127) / 128);
out = [out, p16(blocks)];
wfdbx.internal.ceprintf('%d blocks of sample data\n', blocks);
out = [out, zeros(1, 6), p32(first)];
wfdbx.internal.ceprintf('First annotation is at sample %d\n', first);
out = [out, p32(last)];
wfdbx.internal.ceprintf('Last annotation is at sample %d\n', last);
blocks = floor((nann + 31) / 32);   % 32 annotations per 512-byte block
out = [out, p16(blocks)];
wfdbx.internal.ceprintf('%d blocks of annotations\n', blocks);
out = [out, zeros(1, 6), zeros(1, 464)];   % pad the ID block to 512 bytes
wfdbx.internal.cout(char(out));
status = 0;
end
