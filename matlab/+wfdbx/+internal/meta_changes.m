function [keys, values] = meta_changes(changes, id)
%META_CHANGES Check a list of metadata changes or entries.
%   [KEYS, VALUES] = wfdbx.internal.meta_changes(CHANGES, ID) checks
%   CHANGES, an N-by-2 cell array whose row k holds a key and a value (the
%   'metadata' of wfdbx.write_record, the changes of
%   wfdbx.update_metadata; [] or an empty cell array for none).  KEYS{k}
%   is the key checked by wfdbx.internal.meta_key; VALUES{k} is the value
%   checked by wfdbx.internal.meta_value, or [] if the value given is []
%   (an empty double: "remove").  Both are 1-by-N cell arrays.  An error
%   (identifier ID.arg) is thrown if CHANGES is not such a cell array, if
%   a key or value is not valid, or if two keys are equal without regard
%   to letter case ("metadata key 'KEY' is given more than once (keys are
%   compared without regard to letter case)").  The rows are checked in
%   order: the key, then whether it was given before, then the value.
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

keys = cell(1, 0);
values = cell(1, 0);
changes = wfdbx.internal.strarg(changes);
if isempty(changes) && (iscell(changes) || isa(changes, 'double'))
    return;
end
if ~iscell(changes) || ndims(changes) ~= 2 || size(changes, 2) ~= 2
    error(id.arg, ['metadata must be an N-by-2 cell array of keys and ' ...
        'values (one entry per row)']);
end
n = size(changes, 1);
keys = cell(1, n);
values = cell(1, n);
folded = cell(1, n);
for r = 1:n
    key = changes{r, 1};
    k = wfdbx.internal.meta_key(key, id);
    f = wfdbx.internal.meta_fold(k);
    if any(strcmp(folded(1:r-1), f))
        error(id.arg, ['metadata key ''%s'' is given more than once (keys ' ...
            'are compared without regard to letter case)'], ...
            wfdbx.internal.meta_text(key, 'metadata key', id));
    end
    folded{r} = f;
    keys{r} = k;
    v = wfdbx.internal.strarg(changes{r, 2});
    if isa(v, 'double') && isempty(v)
        values{r} = [];
    else
        values{r} = wfdbx.internal.meta_value(key, v, id);
    end
end
end
