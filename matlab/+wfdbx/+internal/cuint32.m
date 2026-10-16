function y = cuint32(x)
%CUINT32 Wrap values to the range of a C 32-bit unsigned int.
%   Y = wfdbx.internal.cuint32(X) returns X modulo 2^32 (0 to 4294967295),
%   as a double.  X must be an integer-valued double array.
%
%   See also wfdbx.internal.cint32.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = mod(x, 4294967296);
end
