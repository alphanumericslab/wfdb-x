function tf = cstreq(a, b)
%CSTREQ Equality of two C strings that may be NULL ([]).
%   TF = wfdbx.internal.cstreq(A, B) is true if A and B are both char
%   vectors with the same contents, or both NULL (non-char).
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

if ischar(a) && ischar(b)
    tf = strcmp(a, b);
else
    tf = ~ischar(a) && ~ischar(b);
end
end
