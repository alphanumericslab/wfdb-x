function value = get_metadata(record, key, varargin)
%GET_METADATA Return the value of one metadata entry of a record.
%   VALUE = wfdbx.get_metadata(RECORD, KEY) returns the value of the
%   "Key: value" entry for KEY in the header of the record RECORD (see
%   wfdbx.read_metadata for RECORD and the rules): a char row vector (''
%   for an entry with an empty value), or [] if the header has no entry
%   for KEY (test with ischar).  Letter case is ignored (A-Z and a-z), and
%   spaces, tabs, VT, FF and CR at either end of KEY are removed.  If the
%   header has more than one entry for KEY, the first is returned, with
%   the warning 'wfdbx:duplicate_key'.
%
%   VALUE = wfdbx.get_metadata(RECORD, KEY, NAME, VALUE, ...) takes the
%   options 'input_dir' and 'network' of wfdbx.read_metadata.
%
%   Errors: an error is thrown if RECORD is empty or '-', if KEY is not a
%   valid key (see wfdbx.set_metadata), or if an option is not valid
%   (identifier 'wfdbx:get_metadata'), or if the header cannot be found or
%   read (identifier 'wfdbx:get_metadata:file').
%
%   Example:
%       age = wfdbx.get_metadata('rec', 'age');     % '63'
%
%   See also wfdbx.read_metadata, wfdbx.set_metadata.
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

id = wfdbx.internal.meta_id('get_metadata');
if nargin < 2
    error(id.arg, 'get_metadata: RECORD and KEY are required');
end
record = wfdbx.internal.strarg(record);
opt = wfdbx.internal.hl_options(struct('input_dir', [], 'network', []), ...
    varargin, id.fname);
f = wfdbx.internal.meta_fold(wfdbx.internal.meta_key(key, id));
data = wfdbx.internal.meta_read(record, opt.input_dir, opt.network, id);
M = wfdbx.internal.meta_entries(data, record);
value = [];
for k = 1:size(M, 1)
    if strcmp(wfdbx.internal.meta_fold(M{k, 1}), f)
        value = M{k, 2};
        return;
    end
end
end
