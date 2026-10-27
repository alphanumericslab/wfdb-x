function q = cdiv(a, b)
%CDIV C integer division (truncation toward zero).
%   Q = wfdbx.internal.cdiv(A, B) returns A/B truncated toward zero, as the
%   C operator / does for integers.  A and B are integer-valued doubles
%   (scalars or arrays of compatible sizes).
%
%   See also wfdbx.internal.cmod.
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

q = fix(a ./ b);
end
