function tf = cisspace(c)
%CISSPACE C isspace() in the C locale.
%   TF = wfdbx.internal.cisspace(C) is true for the characters (or codes)
%   space, \t, \n, \v, \f and \r.  C may be an array; TF has its size.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

c = double(c);
tf = c == 32 | (c >= 9 & c <= 13);   % ' ', \t \n \v \f \r
end
