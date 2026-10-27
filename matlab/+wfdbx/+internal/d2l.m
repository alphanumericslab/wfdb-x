function y = d2l(x)
%D2L C conversion of a double to a 64-bit long (WFDB_Time).
%   Y = wfdbx.internal.d2l(X) truncates X toward zero, as the C conversion
%   (long)X does.  Values that are NaN or out of the range of a long give
%   LONG_MIN (-2^63), as on x86.  X may be an array.  (Y is a double, so
%   results beyond 2^53 in magnitude are not exact.)
%
%   See also wfdbx.internal.d2i.
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
bad = ~(x < 2^63 & x >= -2^63);
if any(bad(:))
    y(bad) = -2^63;
end
end
