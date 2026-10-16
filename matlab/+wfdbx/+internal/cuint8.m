function y = cuint8(x)
%CUINT8 Wrap values to the range of a C unsigned char.
%   Y = wfdbx.internal.cuint8(X) returns X modulo 256 (0 to 255), as a
%   double.
%
%   See also wfdbx.internal.cint8.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = mod(x, 256);
end
