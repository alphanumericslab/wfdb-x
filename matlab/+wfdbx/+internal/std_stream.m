function [fid, check] = std_stream(k)
%STD_STREAM File identifier for the standard output (K = 1) or error (K = 2).
%   FID = wfdbx.internal.std_stream(K) returns the file to which cout and
%   cerr write the bytes of the standard output or error.  It is the file
%   named by the environment variable WFDBX_STDOUT (K = 1) or WFDBX_STDERR
%   (K = 2) if that is set, opened once for binary writing, and otherwise
%   K itself.  The MATLAB driver (bin/wfdbx_matlab.sh) sets these variables:
%   MATLAB writes to file identifier 1 through its Command Window, as text
%   (a NUL byte becomes a space, and bytes above 127 are encoded as UTF-8),
%   so the bytes are written to these files and copied by the driver to the
%   real standard output and error once MATLAB has exited.  (The startup
%   messages MATLAB itself prints are then kept out of the output, too.)
%
%   [FID, CHECK] = wfdbx.internal.std_stream(K) also tells whether a failed
%   write to FID can be detected by fseek(FID, 0, 'cof'), which flushes it
%   (true for a seekable file opened here; see wfdbx.internal.cout).
%
%   wfdbx.internal.std_stream('cli') (called by the Octave driver,
%   bin/wfdbx_cli.m, before anything is written) makes K = 1 the file
%   /dev/fd/1 opened for appending, when the standard output is a regular
%   file or a device, so that the tools can report a standard output that
%   could not be written (Octave does not report a failed write to file
%   identifier 1).  Pipes keep file identifier 1.
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

persistent fids checks cli
if isempty(fids)
    fids = [0 0];
    checks = [false false];
    cli = false;
end
if ischar(k)
    cli = strcmp(k, 'cli');
    return;
end
if fids(k) == 0
    fids(k) = k;
    names = {'WFDBX_STDOUT', 'WFDBX_STDERR'};
    name = getenv(names{k});
    if ~isempty(name)
        f = fopen(name, 'w', 'ieee-le');
        if f >= 0
            fids(k) = f;
            checks(k) = true;
        end
    elseif k == 1 && cli && wfdbx.internal.is_octave()
        [f, checks(k)] = open_stdout();
        if f >= 0
            fids(k) = f;
        end
    end
end
fid = fids(k);
check = checks(k);
end

function [f, check] = open_stdout()
% (Octave only) /dev/fd/1 opened for appending, if the standard output is a
% regular file or a device; -1 otherwise
f = -1;
check = false;
[info, err] = stat('/dev/fd/1');
if err ~= 0 || ~(S_ISREG(info.mode) || S_ISCHR(info.mode))
    return;
end
f = fopen('/dev/fd/1', 'ab');
if f >= 0
    check = fseek(f, 0, 'cof') == 0;
end
end
