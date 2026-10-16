function y = cuint16(x)
%CUINT16 Wrap values to the range of a C unsigned short.
%   Y = wfdbx.internal.cuint16(X) returns X modulo 2^16 (0 to 65535), as a
%   double.
%
%   See also wfdbx.internal.cint16.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = mod(x, 65536);
end
