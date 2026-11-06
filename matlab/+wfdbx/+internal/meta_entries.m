function M = meta_entries(data, record)
%META_ENTRIES The metadata entries of a header, one per key.
%   M = wfdbx.internal.meta_entries(DATA, RECORD) returns the "Key: value"
%   entries of the header whose bytes are DATA (see
%   wfdbx.internal.meta_parse), as an N-by-2 cell array of char rows (key,
%   value) in file order, with one entry per key (keys compared without
%   regard to letter case): the first.  For each key that has more than
%   one entry, the warning 'wfdbx:duplicate_key' is issued: "header of
%   record RECORD has more than one entry for key KEY (lines L1, L2, ...);
%   the first is used" (line numbers from 1).
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

H = wfdbx.internal.meta_parse(data);
n = numel(H.key);
first = zeros(1, n);        % (the entry whose key each entry repeats)
for j = 1:n
    k = find(strcmp(H.fkey(1:j-1), H.fkey{j}), 1);
    if isempty(k)
        first(j) = j;
    else
        first(j) = first(k);
    end
end
u = find(first == 1:n);
M = cell(numel(u), 2);
M(:, 1) = reshape(H.key(u), [], 1);
M(:, 2) = reshape(H.value(u), [], 1);
for j = u
    lines = H.line(first == j);
    if numel(lines) > 1
        L = sprintf('%d, ', lines);
        warning('wfdbx:duplicate_key', ['header of record %s has more than ' ...
            'one entry for key %s (lines %s); the first is used'], record, ...
            H.key{j}, L(1:end-2));
    end
end
end
