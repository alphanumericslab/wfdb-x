function s = shell_quote(s)
%SHELL_QUOTE Quote a string for /bin/sh.
%   Q = wfdbx.internal.shell_quote(S) returns S enclosed in single quotes
%   (with each single quote in S written as '\''), for use in a command
%   passed to system().

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

s = ['''' strrep(s, '''', '''\''''') ''''];
end
