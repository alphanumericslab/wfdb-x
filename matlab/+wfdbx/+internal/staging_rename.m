function ok = staging_rename(tmp, dest)
%STAGING_RENAME Rename a temporary file over its destination.
%   OK = wfdbx.internal.staging_rename(TMP, DEST) renames the file TMP to
%   DEST, replacing DEST, and returns true if this was done.  No shell
%   command is run (Octave's rename; MATLAB's movefile).
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

if wfdbx.internal.is_octave()
    ok = rename(tmp, dest) == 0;    % (Octave's movefile runs a shell)
else
    ok = movefile(tmp, dest, 'f');
end
end
