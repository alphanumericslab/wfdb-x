function d = wfdb_dirname(name)
%WFDB_DIRNAME The directory part of a file name or URL.
%   D = wfdbx.internal.wfdb_dirname(NAME) (wfdb-x) returns NAME up to and
%   including its last directory separator ('/', and on MS-Windows '\'),
%   or '' if it has none.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if ispc()
    k = find(name == '/' | name == '\', 1, 'last');
else
    k = find(name == '/', 1, 'last');
end
if isempty(k)
    d = '';
else
    d = name(1:k);
end
end
