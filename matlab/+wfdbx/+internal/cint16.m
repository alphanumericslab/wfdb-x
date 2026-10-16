function y = cint16(x)
%CINT16 Wrap values to the range of a C short (16-bit signed).
%   Y = wfdbx.internal.cint16(X) returns the value that a C short holds when
%   assigned the integer value X (-32768 to 32767), as a double.
%
%   See also wfdbx.internal.cuint16, wfdbx.internal.cint32.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = mod(x + 32768, 65536) - 32768;
end
