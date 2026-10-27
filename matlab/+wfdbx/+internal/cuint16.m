function y = cuint16(x)
%CUINT16 Wrap values to the range of a C unsigned short.
%   Y = wfdbx.internal.cuint16(X) returns X modulo 2^16 (0 to 65535), as a
%   double.
%
%   See also wfdbx.internal.cint16.
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

y = mod(x, 65536);
end
