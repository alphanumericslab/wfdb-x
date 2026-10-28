function s = cstr(s)
%CSTR A string as a C string: up to its first NUL character.
%   S = wfdbx.internal.cstr(S) returns S up to (not including) its first
%   NUL character (char(0)), or S itself if it has none: the string that C
%   code sees in a buffer read from a file (e.g. a header line).
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

k = find(s == 0, 1);
if ~isempty(k)
    s = s(1:k - 1);
end
end
