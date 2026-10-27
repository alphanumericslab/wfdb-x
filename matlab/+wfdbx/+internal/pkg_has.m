function tf = pkg_has(name)
%PKG_HAS True if a function of the wfdbx package exists.
%   TF = wfdbx.internal.pkg_has(NAME) returns true if the package function
%   NAME (e.g. 'getafreq' for wfdbx.getafreq, or 'internal.flac_isopen')
%   is defined.  The result is cached.  (exist() does not find package
%   functions in Octave.)  This lets the signal module call functions of
%   modules that may be missing (annotations, FLAC) only if they exist.
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

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
