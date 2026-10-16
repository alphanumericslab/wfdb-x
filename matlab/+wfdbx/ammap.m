function y = ammap(a)
%AMMAP Map an AHA annotation code into an MIT annotation code.
%   Y = wfdbx.ammap(A) returns the MIT code corresponding to the AHA
%   annotation code A (a character code, e.g. double('N')), or NOTQRS.
%   A may be an array.
%
%   See also wfdbx.mamap.

% Copyright (C) 1999 George B. Moody (original C header, lib/ecgmap.h).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

persistent t
if isempty(t)
    % MIT codes of the AHA codes 'E' to ']' (NOTQRS = 0 for invalid codes)
    t = [ ...
            10 6 0 0 0 0 0 0 0 1 ...
            22 12 13 41 0 0 14 5 0 0 ...
            0 0 32 0 33];
end
y = zeros(size(a));
k = a >= 'E' & a <= ']';
y(k) = t(a(k) - ('E' - 1));
end
