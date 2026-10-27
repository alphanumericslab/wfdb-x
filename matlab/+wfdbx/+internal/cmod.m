function r = cmod(a, b)
%CMOD C integer remainder (sign of the dividend).
%   R = wfdbx.internal.cmod(A, B) returns the C remainder A % B of
%   integer-valued doubles: A - B*cdiv(A, B), with the sign of A.
%
%   See also wfdbx.internal.cdiv.
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

r = rem(a, b);
end
