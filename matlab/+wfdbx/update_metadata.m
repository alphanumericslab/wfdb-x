function update_metadata(record, changes, varargin)
%UPDATE_METADATA Make several changes to the metadata of a record at once.
%   wfdbx.update_metadata(RECORD, CHANGES) applies the changes CHANGES to
%   the header of the record RECORD, in one write.  CHANGES is an N-by-2
%   cell array with one change per row, {KEY, VALUE}, applied in order:
%   as wfdbx.set_metadata(RECORD, KEY, VALUE) does, or, if VALUE is [] (an
%   empty double), as wfdbx.remove_metadata(RECORD, KEY) does.  (A
%   structure cannot hold keys with spaces, such as 'Date of birth'.)
%   VALUE '' sets an empty value.  No two keys may be equal without regard
%   to letter case.  An empty CHANGES ({} or cell(0, 2)) changes nothing.
%
%   wfdbx.update_metadata(RECORD, CHANGES, NAME, VALUE, ...) takes the
%   options 'input_dir', 'network' and 'dir' of wfdbx.set_metadata.
%
%   RECORD, the keys, the values, the options and the way the header is
%   written are as for wfdbx.set_metadata.  All the changes are checked
%   first: if one is not valid, none is made.
%
%   Errors: as for wfdbx.set_metadata, with the identifiers
%   'wfdbx:update_metadata' (argument errors, including a CHANGES that is
%   not an N-by-2 cell array, and two keys that differ only in letter
%   case) and 'wfdbx:update_metadata:file' (file errors).
%
%   Example:
%       wfdbx.update_metadata('rec', {'Age', '64'; 'Dx', []});
%
%   See also wfdbx.set_metadata, wfdbx.remove_metadata,
%   wfdbx.read_metadata.
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

id = wfdbx.internal.meta_id('update_metadata');
if nargin < 2
    error(id.arg, 'update_metadata: RECORD and CHANGES are required');
end
record = wfdbx.internal.strarg(record);
opt = wfdbx.internal.hl_options(struct('input_dir', [], 'network', [], ...
    'dir', []), varargin, id.fname);
[keys, values] = wfdbx.internal.meta_changes(changes, id);
wfdbx.internal.meta_change(record, keys, values, opt, id);
end
