function r = cmod(a, b)
%CMOD C integer remainder (sign of the dividend).
%   R = wfdbx.internal.cmod(A, B) returns the C remainder A % B of
%   integer-valued doubles: A - B*cdiv(A, B), with the sign of A.
%
%   See also wfdbx.internal.cdiv.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

r = rem(a, b);
end
