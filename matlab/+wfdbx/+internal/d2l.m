function y = d2l(x)
%D2L C conversion of a double to a 64-bit long (WFDB_Time).
%   Y = wfdbx.internal.d2l(X) truncates X toward zero, as the C conversion
%   (long)X does.  Values that are NaN or out of the range of a long give
%   LONG_MIN (-2^63), as on x86.  X may be an array.  (Y is a double, so
%   results beyond 2^53 in magnitude are not exact.)
%
%   See also wfdbx.internal.d2i.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = fix(x);
bad = ~(x < 2^63 & x >= -2^63);
if any(bad(:))
    y(bad) = -2^63;
end
end
