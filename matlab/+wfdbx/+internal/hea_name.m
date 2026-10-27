function name = hea_name(record, name)
%HEA_NAME A name as written into the header of a record.
%   NAME = wfdbx.internal.hea_name(RECORD, NAME) returns NAME relative to
%   the directory of the header of RECORD (where the reader looks for it):
%   outside legacy mode, when NAME begins with the directory part of RECORD
%   (up to and including its last '/'), that part is removed.  In legacy
%   mode, or if NAME is not a char vector, NAME is returned unchanged.
%   Used by setheader (the record line and the signal file names) and
%   setmsheader (the record line and the segment names).
%
%   See also wfdbx.setheader, wfdbx.setmsheader.
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

if ~ischar(name) || wfdbx.wfdbx_get_legacy()
    return;
end
k = find(record == '/', 1, 'last');
if isempty(k)
    return;
end
if numel(name) >= k && strcmp(name(1:k), record(1:k))
    name = name(k + 1:end);
end
end
