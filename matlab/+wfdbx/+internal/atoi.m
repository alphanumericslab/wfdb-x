function v = atoi(s)
%ATOI Emulate the C function atoi().
%   V = wfdbx.internal.atoi(S) returns the decimal integer at the start of
%   the char vector S (after optional white space and sign), or 0, wrapped
%   to a 32-bit int as with glibc (strtol truncated to int).
%
%   See also wfdbx.internal.strtol, wfdbx.internal.atof.
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

v = wfdbx.internal.cint32(wfdbx.internal.strtol(s));
end
