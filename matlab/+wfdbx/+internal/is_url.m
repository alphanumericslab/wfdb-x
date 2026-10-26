function tf = is_url(name)
%IS_URL True if a name is an http:// or https:// URL.
%   TF = wfdbx.internal.is_url(NAME) (wfdb-x; case-sensitive, as in the C
%   reference).

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

tf = strncmp(name, 'http://', 7) || strncmp(name, 'https://', 8);
end
