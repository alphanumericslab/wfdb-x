function id = meta_id(fname, arg_id, file_id)
%META_ID Error identifiers of a metadata function.
%   ID = wfdbx.internal.meta_id(FNAME) returns the structure that the
%   metadata functions (wfdbx.read_metadata, ...) pass to their helpers:
%   ID.fname is FNAME (used in the messages of the options), ID.arg the
%   identifier of argument errors ('wfdbx:FNAME') and ID.file that of file
%   errors, a header that cannot be read or written ('wfdbx:FNAME:file').
%   ID = wfdbx.internal.meta_id(FNAME, ARG_ID, FILE_ID) gives other
%   identifiers (wfdbx.read_header uses 'wfdbx:read_header' for both).
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

if nargin < 2
    arg_id = ['wfdbx:' fname];
end
if nargin < 3
    file_id = ['wfdbx:' fname ':file'];
end
id = struct('fname', fname, 'arg', arg_id, 'file', file_id);
end
