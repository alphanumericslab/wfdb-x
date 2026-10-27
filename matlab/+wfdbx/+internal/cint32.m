function y = cint32(x)
%CINT32 Wrap values to the range of a C 32-bit signed int.
%   Y = wfdbx.internal.cint32(X) returns the value that a C int (32 bits,
%   two's complement) holds when assigned the integer value X, as a double.
%   X must be an integer-valued double array (exact up to 2^53).
%
%   See also wfdbx.internal.cuint32, wfdbx.internal.cint16, wfdbx.internal.d2i.
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

y = mod(x + 2147483648, 4294967296) - 2147483648;
end
