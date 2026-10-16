function tf = pkg_has(name)
%PKG_HAS True if a function of the wfdbx package exists.
%   TF = wfdbx.internal.pkg_has(NAME) returns true if the package function
%   NAME (e.g. 'getafreq' for wfdbx.getafreq, or 'internal.flac_isopen')
%   is defined.  The result is cached.  (exist() does not find package
%   functions in Octave.)  This lets the signal module call functions of
%   modules that may be missing (annotations, FLAC) only if they exist.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

persistent cache root
if isempty(cache)
    cache = struct();
    root = fileparts(fileparts(mfilename('fullpath')));    % .../+wfdbx
end
key = strrep(name, '.', '_');
if isfield(cache, key)
    tf = cache.(key);
    return;
end
parts = regexp(name, '\.', 'split');
p = root;
for k = 1:numel(parts) - 1
    p = fullfile(p, ['+' parts{k}]);
end
tf = exist(fullfile(p, [parts{end} '.m']), 'file') == 2;
cache.(key) = tf;
end
