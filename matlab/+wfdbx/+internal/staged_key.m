function p = staged_key(fname)
%STAGED_KEY The absolute path of a file name, for the staging of files.
%   P = wfdbx.internal.staged_key(FNAME) returns FNAME as an absolute path
%   (relative to the current folder), with '.' and '..' components and
%   repeated separators removed (as Python's os.path.abspath), so that
%   the names under which a file is opened while staging (see
%   wfdbx.internal.staging_begin) lead to the same temporary file.
%   Symbolic links are not followed.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU Lesser General Public License as published by
% the Free Software Foundation, either version 2.1 of the License, or (at
% your option) any later version. See LICENSE.

p = fname;
if ispc()
    p(p == '\') = '/';
end
root = '';
if ispc() && numel(p) >= 2 && p(2) == ':'
    root = p(1:2);
    p = p(3:end);
end
if isempty(p) || p(1) ~= '/'
    if ~isempty(root) || (ispc() && numel(p) >= 2 && strcmp(p(1:2), '//'))
        % (a drive-relative or UNC name: as given)
        p = [root p];
        return;
    end
    c = pwd();
    if ispc()
        c(c == '\') = '/';
        if numel(c) >= 2 && c(2) == ':'
            root = c(1:2);
            c = c(3:end);
        end
    end
    p = [c '/' p];
end
% (split at '/' without regexp, which fails on bytes above 127 in Octave)
b = [0, find(p == '/'), numel(p) + 1];
out = cell(1, 0);
for k = 1:numel(b) - 1
    s = p(b(k) + 1:b(k + 1) - 1);
    if isempty(s) || strcmp(s, '.')
        continue;
    elseif strcmp(s, '..')
        if ~isempty(out)
            out(end) = [];
        end
    else
        out{end + 1} = s; %#ok<AGROW>
    end
end
p = [root '/' strjoin(out, '/')];
end
