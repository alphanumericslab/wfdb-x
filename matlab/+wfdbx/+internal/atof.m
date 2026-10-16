function v = atof(s)
%ATOF Emulate the C function atof().
%   V = wfdbx.internal.atof(S) returns the floating-point number at the start
%   of the char vector S, or 0 (see wfdbx.internal.strtod).
%
%   See also wfdbx.internal.strtod, wfdbx.internal.atoi.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

v = wfdbx.internal.strtod(s);
end
