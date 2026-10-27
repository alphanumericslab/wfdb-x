function y = cint16(x)
%CINT16 Wrap values to the range of a C short (16-bit signed).
%   Y = wfdbx.internal.cint16(X) returns the value that a C short holds when
%   assigned the integer value X (-32768 to 32767), as a double.
%
%   See also wfdbx.internal.cuint16, wfdbx.internal.cint32.
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

y = mod(x + 32768, 65536) - 32768;
end
