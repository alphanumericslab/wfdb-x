function y = cint8(x)
%CINT8 Wrap values to the range of a C (signed) char.
%   Y = wfdbx.internal.cint8(X) returns the value that a C char holds when
%   assigned the integer value X (-128 to 127), as a double.  char is signed
%   on the reference platform (x86-64 Linux).
%
%   See also wfdbx.internal.cuint8.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

y = mod(x + 128, 256) - 128;
end
