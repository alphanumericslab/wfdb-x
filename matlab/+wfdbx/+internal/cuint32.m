function y = cuint32(x)
%CUINT32 Wrap values to the range of a C 32-bit unsigned int.
%   Y = wfdbx.internal.cuint32(X) returns X modulo 2^32 (0 to 4294967295),
%   as a double.  X must be an integer-valued double array.
%
%   See also wfdbx.internal.cint32.
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

y = mod(x, 4294967296);
end
