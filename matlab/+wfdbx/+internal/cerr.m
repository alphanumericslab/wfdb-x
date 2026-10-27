function cerr(s)
%CERR Write bytes to the standard error output.
%   wfdbx.internal.cerr(S) flushes the buffered standard output (see
%   wfdbx.internal.cout), then writes the char (codes 0-255) or uint8 vector
%   S to the standard error output, byte for byte, unbuffered.
%
%   See also wfdbx.internal.ceprintf, wfdbx.internal.cout.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

wfdbx.internal.cout();
if isempty(s)
    return;
end
fid = wfdbx.internal.std_stream(2);
fwrite(fid, s, 'uint8');
if wfdbx.internal.is_octave()
    fflush(fid);
end
end
