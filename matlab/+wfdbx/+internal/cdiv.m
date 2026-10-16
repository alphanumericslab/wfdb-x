function q = cdiv(a, b)
%CDIV C integer division (truncation toward zero).
%   Q = wfdbx.internal.cdiv(A, B) returns A/B truncated toward zero, as the
%   C operator / does for integers.  A and B are integer-valued doubles
%   (scalars or arrays of compatible sizes).
%
%   See also wfdbx.internal.cmod.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

q = fix(a ./ b);
end
