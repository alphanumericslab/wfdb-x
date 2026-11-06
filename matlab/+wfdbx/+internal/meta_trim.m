function s = meta_trim(s)
%META_TRIM Remove spaces, tabs, VT, FF and CR at both ends of a string.
%   S = wfdbx.internal.meta_trim(S) is S (a char row of bytes) without the
%   characters 32, 9, 11, 12 and 13 at either end (as Python's
%   bytes.strip(b" \t\v\f\r")), for the header metadata functions.
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

ws = s == ' ' | s == char(9) | s == char(11) | s == char(12) | s == char(13);
first = find(~ws, 1);
if isempty(first)
    s = s([]);
    s = reshape(s, 1, 0);
    return;
end
s = s(first:find(~ws, 1, 'last'));
end
