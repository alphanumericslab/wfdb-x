function y = cint32(x)
%CINT32 Wrap values to the range of a C 32-bit signed int.
%   Y = wfdbx.internal.cint32(X) returns the value that a C int (32 bits,
%   two's complement) holds when assigned the integer value X, as a double.
%   X must be an integer-valued double array (exact up to 2^53).
%
%   See also wfdbx.internal.cuint32, wfdbx.internal.cint16, wfdbx.internal.d2i.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = mod(x + 2147483648, 4294967296) - 2147483648;
end
