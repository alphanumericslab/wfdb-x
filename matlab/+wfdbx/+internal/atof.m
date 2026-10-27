function v = atof(s)
%ATOF Emulate the C function atof().
%   V = wfdbx.internal.atof(S) returns the floating-point number at the start
%   of the char vector S, or 0 (see wfdbx.internal.strtod).
%
%   See also wfdbx.internal.strtod, wfdbx.internal.atoi.
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

v = wfdbx.internal.strtod(s);
end
