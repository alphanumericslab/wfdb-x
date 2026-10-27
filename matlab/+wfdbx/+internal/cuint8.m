function y = cuint8(x)
%CUINT8 Wrap values to the range of a C unsigned char.
%   Y = wfdbx.internal.cuint8(X) returns X modulo 256 (0 to 255), as a
%   double.
%
%   See also wfdbx.internal.cint8.
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

y = mod(x, 256);
end
