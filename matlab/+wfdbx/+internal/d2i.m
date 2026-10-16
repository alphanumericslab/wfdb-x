function y = d2i(x)
%D2I C conversion of a double to a 32-bit int.
%   Y = wfdbx.internal.d2i(X) truncates X toward zero, as the C conversion
%   (int)X does.  Values that are NaN or out of the range of an int give
%   INT_MIN (-2147483648), as on x86.  X may be an array.
%
%   See also wfdbx.internal.cint32.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = fix(x);
bad = ~(x < 2147483648 & x > -2147483649);   % outside (INT_MIN - 1, INT_MAX + 1)
if any(bad(:))
    y(bad) = -2147483648;
end
end
