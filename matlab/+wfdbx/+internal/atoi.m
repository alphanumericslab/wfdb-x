function v = atoi(s)
%ATOI Emulate the C function atoi().
%   V = wfdbx.internal.atoi(S) returns the decimal integer at the start of
%   the char vector S (after optional white space and sign), or 0, wrapped
%   to a 32-bit int as with glibc (strtol truncated to int).
%
%   See also wfdbx.internal.strtol, wfdbx.internal.atof.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

v = wfdbx.internal.cint32(wfdbx.internal.strtol(s));
end
