function y = cint8(x)
%CINT8 Wrap values to the range of a C (signed) char.
%   Y = wfdbx.internal.cint8(X) returns the value that a C char holds when
%   assigned the integer value X (-128 to 127), as a double.  char is signed
%   on the reference platform (x86-64 Linux).
%
%   See also wfdbx.internal.cuint8.
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

y = mod(x + 128, 256) - 128;
end
