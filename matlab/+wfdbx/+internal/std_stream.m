function fid = std_stream(k)
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

persistent fids
if isempty(fids)
    fids = [0 0];
end
if fids(k) == 0
    fids(k) = k;
    names = {'WFDBX_STDOUT', 'WFDBX_STDERR'};
    name = getenv(names{k});
    if ~isempty(name)
        f = fopen(name, 'w', 'ieee-le');
        if f >= 0
            fids(k) = f;
        end
    end
end
fid = fids(k);
end
