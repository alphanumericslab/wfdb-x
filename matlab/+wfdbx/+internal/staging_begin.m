function staging_begin()
%STAGING_BEGIN Start writing the output files to temporary files.
%   wfdbx.internal.staging_begin() is called by the high-level writers
%   (wfdbx.write_record, wfdbx.write_annotations) before they open their
%   output files.  Until wfdbx.internal.staging_end, each file that the
%   library opens for writing ('wb' or 'ab', through
%   wfdbx.internal.wfdb_fopen) is written to a temporary file in the
%   directory of its destination ('.NAME.XXXXXXXX.tmp'; see
%   wfdbx.internal.staged_open), and the temporary files replace their
%   destinations together, only once all of them are complete, so that a
%   failure leaves the existing files as they were.  The library opens the
%   destination by its name as usual (in messages, and for the in-process
%   sorting of annotation files, which reads and rewrites the temporary
%   file).  A destination that exists and is not a regular file (a device
%   such as /dev/full, a FIFO) is opened directly, as before; for a
%   symbolic link, the file it leads to is replaced.
%
%   See also wfdbx.internal.staging_end, wfdbx.internal.staging_commit_one.
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

io = wfdbx.internal.io_state();
io.staging = true;
io.staging_keys = cell(1, 0);
io.staging_tmps = cell(1, 0);
io.staging_dests = cell(1, 0);
end
