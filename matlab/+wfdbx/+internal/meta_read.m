function [data, path, url] = meta_read(record, input_dir, network, id)
%META_READ Read the header of a record for the metadata functions.
%   [DATA, PATH, URL] = wfdbx.internal.meta_read(RECORD, INPUT_DIR,
%   NETWORK, ID) reads the header of the record RECORD as the library
%   opens a header (wfdbx.internal.wfdb_open with type 'hea', after
%   removing a trailing '.hea' from the name): under the input directory,
%   or as given for an absolute path, a ~ path or a URL (a URL only if
%   network access is on).  INPUT_DIR and NETWORK are the 'input_dir' and
%   'network' options of the calling function, applied for the reading
%   only (see wfdbx.internal.hl_input; [] for the current settings).
%   DATA is the bytes of the header (a char row), PATH the name of the
%   file read, and URL true if PATH is a URL.
%
%   Errors: identifier ID.arg (see wfdbx.internal.meta_id) if RECORD is
%   empty or not a string ("record name must not be empty") or is '-' (the
%   standard input); identifier ID.file if the header cannot be opened or
%   read ("can't read header for record RECORD").
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

record = wfdbx.internal.strarg(record);
if ~ischar(record) || isempty(record)
    error(id.arg, 'record name must not be empty');
end
if strcmp(record, '-')
    error(id.arg, ['the metadata of a header read from the standard ' ...
        'input cannot be read or changed']);
end
% (the settings of this call, restored when this function returns)
restore = wfdbx.internal.hl_input(input_dir, network, id.fname); %#ok<NASGU>
f = wfdbx.internal.wfdb_open('hea', wfdbx.internal.wfdb_striphea(record), 0);
if isempty(f)
    error(id.file, 'can''t read header for record %s', record);
end
try
    data = char(f.readall());
    failed = f.ferror();
catch
    failed = true;
end
path = f.name;
f.close();
if failed
    error(id.file, 'can''t read header for record %s', record);
end
data = reshape(data, 1, []);
url = wfdbx.internal.is_url(path);
end
