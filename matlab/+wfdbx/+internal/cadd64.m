function y = cadd64(a, b)
%CADD64 Add two values as C 64-bit signed integers, with wrap-around.
%   Y = wfdbx.internal.cadd64(A, B) returns, as an int64 scalar, the sum of
%   the scalars A and B (int64 values, or integer-valued doubles, which are
%   converted with int64: 2^63 and more become 2^63-1) wrapped to the range
%   of a long long, as a WFDB_Time sum wraps in C on x86-64. MATLAB and
%   Octave integer arithmetic saturates instead.
%
%   See also wfdbx.internal.cint32.
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

a = int64(a);
b = int64(b);
lo = intmin('int64');
if a > 0 && b > 0 && a > intmax('int64') - b
    y = (a + lo) + (b + lo);        % (a + b - 2^64, exact)
elseif a < 0 && b < 0 && a < lo - b
    y = (a - lo) + (b - lo);        % (a + b + 2^64, exact)
else
    y = a + b;
end
end
