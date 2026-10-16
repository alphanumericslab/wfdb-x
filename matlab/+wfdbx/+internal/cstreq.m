function tf = cstreq(a, b)
%CSTREQ Equality of two C strings that may be NULL ([]).
%   TF = wfdbx.internal.cstreq(A, B) is true if A and B are both char
%   vectors with the same contents, or both NULL (non-char).

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if ischar(a) && ischar(b)
    tf = strcmp(a, b);
else
    tf = ~ischar(a) && ~ischar(b);
end
end
