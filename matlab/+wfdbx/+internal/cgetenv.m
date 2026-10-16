function v = cgetenv(name)
%CGETENV C getenv(): the value of an environment variable, or [] if unset.
%   V = wfdbx.internal.cgetenv(NAME) returns the value of the environment
%   variable NAME as a char vector, or [] (C NULL) if it is not set.
%
%   An unset variable cannot be told apart from one set to the empty
%   string in Octave (nor in MATLAB before R2022b, which added isenv); for
%   the same behavior everywhere, both are reported as unset ([]).

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

v = getenv(name);
if isempty(v)
    v = [];
end
end
