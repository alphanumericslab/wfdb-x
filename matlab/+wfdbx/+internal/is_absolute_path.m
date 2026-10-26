function tf = is_absolute_path(s)
%IS_ABSOLUTE_PATH True if a name is an absolute local path.
%   TF = wfdbx.internal.is_absolute_path(S) (wfdb-x): on POSIX systems, S
%   begins with '/'; on MS-Windows, also with 'X:\', 'X:/' or '\'.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

tf = ~isempty(s) && s(1) == '/';
if ~tf && ispc() && numel(s) >= 2
    tf = (numel(s) >= 3 && s(2) == ':' && (s(3) == '\' || s(3) == '/') && ...
        ((s(1) >= 'A' && s(1) <= 'Z') || (s(1) >= 'a' && s(1) <= 'z'))) || ...
        (s(1) == '\' && s(2) == '\');
end
end
