function ok = staging_commit_one(fname)
%STAGING_COMMIT_ONE Replace one staged destination now.
%   OK = wfdbx.internal.staging_commit_one(FNAME) renames the temporary
%   file of the destination FNAME (a file opened while staging: see
%   wfdbx.internal.staging_begin) over FNAME now, before the end of the
%   staging, and returns true if this was done; false if FNAME is not a
%   staged destination, or if the rename fails (the temporary file is then
%   removed).  oannclose calls it in legacy mode, before it runs the
%   sortann program on an annotation file written out of order.
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

ok = false;
io = wfdbx.internal.io_state();
if ~io.staging || ~ischar(fname) || isempty(fname)
    return;
end
k = find(strcmp(io.staging_keys, wfdbx.internal.staged_key(fname)), 1);
if isempty(k)
    return;
end
tmp = io.staging_tmps{k};
dest = io.staging_dests{k};
io.staging_keys(k) = [];
io.staging_tmps(k) = [];
io.staging_dests(k) = [];
ok = wfdbx.internal.staging_rename(tmp, dest);
if ~ok && isfile(tmp)
    delete(tmp);
end
end
