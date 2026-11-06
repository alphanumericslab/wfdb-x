function lines = meta_info_lines(metadata, comments, id)
%META_INFO_LINES The info strings of metadata entries (wfdbx.write_record).
%   LINES = wfdbx.internal.meta_info_lines(METADATA, COMMENTS, ID) returns
%   the info strings, as wfdbx.putinfo takes them (without the '#'), of
%   the entries of METADATA (an N-by-2 cell array of keys and values; see
%   wfdbx.internal.meta_changes): ' Key: value' (' Key:' for an empty
%   value), as a 1-by-N cell array.  An error (identifier ID.arg) is
%   thrown if an entry is not valid, if two keys are equal without regard
%   to letter case, if a value is [] ("value of metadata key 'KEY' must
%   not be []"), or if one of COMMENTS (the other info strings, a cell
%   array of char rows) is already an entry for one of these keys
%   ("metadata key 'KEY' is also given in comments").
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

[keys, values] = wfdbx.internal.meta_changes(metadata, id);
folded = cellfun(@wfdbx.internal.meta_fold, keys, 'UniformOutput', false);
for k = 1:numel(keys)
    if ~ischar(values{k})
        error(id.arg, 'value of metadata key ''%s'' must not be []', keys{k});
    end
end
for k = 1:numel(comments)
    [key, ~, ok] = wfdbx.internal.meta_entry(['#' reshape(char(comments{k}), 1, [])]);
    if ok && any(strcmp(folded, wfdbx.internal.meta_fold(key)))
        error(id.arg, 'metadata key ''%s'' is also given in comments', key);
    end
end
lines = cell(1, numel(keys));
for k = 1:numel(keys)
    if isempty(values{k})
        lines{k} = [' ' keys{k} ':'];
    else
        lines{k} = [' ' keys{k} ': ' values{k}];
    end
end
end
