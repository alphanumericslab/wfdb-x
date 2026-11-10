function ok = staging_end(commit)
%STAGING_END End writing the output files to temporary files.
%   OK = wfdbx.internal.staging_end(COMMIT) ends what
%   wfdbx.internal.staging_begin started.  If COMMIT is true, every
%   temporary file is renamed over its destination (all of them are then
%   complete), and OK is true; if a rename fails, the temporary files not
%   yet renamed are removed and OK is false.  If COMMIT is false, the
%   temporary files are all removed (the existing files are left as they
%   were), and OK is false.  The temporary files have the permissions of
%   their destinations from their creation (see
%   wfdbx.internal.temp_create).  Without staging_begin, OK is COMMIT.
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
ok = logical(commit);
if ~io.staging
    return;
end
tmps = io.staging_tmps;
dests = io.staging_dests;
io.staging = false;
io.staging_keys = cell(1, 0);
io.staging_tmps = cell(1, 0);
io.staging_dests = cell(1, 0);
for k = 1:numel(tmps)
    if ok && wfdbx.internal.staging_rename(tmps{k}, dests{k})
        continue;
    end
    ok = false;
    remove(tmps{k});
end
end

function remove(name)
% (delete, without a message if the file is not there)
if isfile(name)
    delete(name);
end
end
