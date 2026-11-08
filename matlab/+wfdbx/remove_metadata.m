function n = remove_metadata(record, key, varargin)
%REMOVE_METADATA Remove a metadata entry from the header of a record.
%   N = wfdbx.remove_metadata(RECORD, KEY) removes every "Key: value" entry
%   for KEY (ignoring letter case) from the header of the record RECORD,
%   line ending included, and returns the number of lines removed (0 if
%   the header has no entry for KEY).  It also repairs a header that has
%   more than one entry for KEY.  Every other byte of the header is kept.
%   Nothing is written if the header has no entry for KEY (unless 'dir' is
%   given).
%
%   N = wfdbx.remove_metadata(RECORD, KEY, NAME, VALUE, ...) takes the
%   options 'input_dir', 'network' and 'dir' of wfdbx.set_metadata.
%
%   RECORD, KEY, the options and the way the header is written are as for
%   wfdbx.set_metadata.
%
%   Errors: as for wfdbx.set_metadata, with the identifiers
%   'wfdbx:remove_metadata' (argument errors) and
%   'wfdbx:remove_metadata:file' (file errors).
%
%   Example:
%       n = wfdbx.remove_metadata('rec', 'Age');     % 1
%
%   See also wfdbx.set_metadata, wfdbx.update_metadata.
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

id = wfdbx.internal.meta_id('remove_metadata');
if nargin < 2
    error(id.arg, 'remove_metadata: RECORD and KEY are required');
end
record = wfdbx.internal.strarg(record);
opt = wfdbx.internal.hl_options(struct('input_dir', [], 'network', [], ...
    'dir', []), varargin, id.fname);
k = wfdbx.internal.meta_key(key, id);
n = wfdbx.internal.meta_change(record, {k}, {[]}, opt, id);
end
