function status = readid(args)
%READID Read an AHA-format ID block from the standard input.
%   STATUS = wfdbx.apps.readid(ARGS) runs the readid tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       readid DATA-BLOCK-SIZE ANNOT-BLOCK-SIZE <IDBLOCK
%   prints the record name, and the numbers of data and annotation blocks
%   of the given sizes.
%
%   Example:
%       wfdbx.apps.readid({'512', '512'})
%
%   See also wfdbx.apps.makeid.
%
%   Translation of the C program readid (convert/readid.c, WFDB 10.7.0):
%   same options and output.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of convert/readid.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language and the --legacy
% option (as the first argument, it restores the original behavior).
%
% Original C program: convert/readid.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1983-2005 George B. Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'readid'}, args]);
end

function status = main(argv)
if numel(argv) < 3
    wfdbx.internal.ceprintf('usage: %s data-block-size annot-block-size\n', argv{1});
    status = 1;
    return;
end
dasize = wfdbx.internal.atoi(argv{2});
ansize = wfdbx.internal.atoi(argv{3});
if dasize < 1
    dasize = 1;
end
if ansize < 1
    ansize = 1;
end
data = double(wfdbx.internal.stdin_bytes());
% bytes beyond the end of the input read as EOF (255 as an unsigned char)
d = 255 * ones(1, 42);   % the first 42 bytes of the ID block
n = min(42, numel(data));
d(1:n) = data(1:n);
buf = zeros(1, 25);   % the record ID: up to 24 bytes, null-terminated
k = min(24, numel(data));
buf(1:k) = data(1:k);
z = find(buf == 0, 1);
[n, v] = wfdbx.internal.csscanf(char(buf(1:z - 1)), '%s');
% (name[9] overflows in the C version for longer IDs; the whole ID is
% printed there, as here.)
if n == 1
    name = v{1};
else
    name = '';
end
dcount = wfdbx.internal.cdiv((d(25) + 256 * d(26)) * 512 + dasize - 1, dasize);   % lengths in 512-byte blocks
acount = wfdbx.internal.cdiv((d(41) + 256 * d(42)) * 512 + ansize - 1, ansize);
wfdbx.internal.cout(sprintf('%s %d %d\n', name, dcount, acount));
status = 0;
end
