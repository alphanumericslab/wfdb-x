function y = d2i(x)
%D2I C conversion of a double to a 32-bit int.
%   Y = wfdbx.internal.d2i(X) truncates X toward zero, as the C conversion
%   (int)X does.  Values that are NaN or out of the range of an int give
%   INT_MIN (-2147483648), as on x86.  X may be an array.
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

y = fix(x);
bad = ~(x < 2147483648 & x > -2147483649);   % outside (INT_MIN - 1, INT_MAX + 1)
if any(bad(:))
    y(bad) = -2147483648;
end
end
