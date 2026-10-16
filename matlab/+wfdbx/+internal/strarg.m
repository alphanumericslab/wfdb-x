function x = strarg(x)
%STRARG Convert MATLAB string arguments to char.
%   X = wfdbx.internal.strarg(X) returns char(X) if X is a string scalar
%   ("100s"), a cell row of char vectors if X is a string array, and X
%   otherwise, with the strings of a cell X converted to char vectors.
%   The high-level functions apply it to their arguments, so that they
%   accept strings as well as char vectors.  (GNU Octave has no string
%   class: X is then returned unchanged.)

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if isa(x, 'string')
    if isscalar(x)
        x = char(x);
    else
        x = reshape(cellstr(x), 1, []);
    end
elseif iscell(x)
    for k = reshape(find(cellfun('isclass', x, 'string')), 1, [])
        x{k} = char(x{k});
    end
end
end
