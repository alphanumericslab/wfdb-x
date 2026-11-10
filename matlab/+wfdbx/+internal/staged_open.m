function [f, staged] = staged_open(fname, mode)
%STAGED_OPEN Open a file while the output files are staged.
%   [F, STAGED] = wfdbx.internal.staged_open(FNAME, MODE) is called by
%   wfdbx.internal.wfdb_fopen while a high-level writer stages its output
%   files (see wfdbx.internal.staging_begin).  FNAME is a destination,
%   MODE 'rb', 'wb' or 'ab'.  It opens the temporary file that stands for
%   FNAME (keyed by the absolute path of FNAME, wfdbx.internal.staged_key),
%   created for 'wb' and 'ab' if there is none yet: F is a
%   wfdbx.internal.WFDBFile named FNAME (as in messages), or [] if the
%   temporary file cannot be created or opened (also when the destination
%   is a directory), and STAGED is true.  STAGED is false (FNAME is then
%   opened as usual) for 'rb' of a file not written while staging, and for
%   a destination that exists and is not a regular file (a device such as
%   /dev/full, a FIFO).  For a symbolic link, the destination is the file
%   it leads to.  Missing directories in FNAME are created, as wfdb_fopen
%   does.  The temporary file '.NAME.XXXXXXXX.tmp' is created in the
%   directory of the destination by wfdbx.internal.temp_create, with the
%   permissions that the destination will have.
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

f = [];
staged = true;
io = wfdbx.internal.io_state();
key = wfdbx.internal.staged_key(fname);
k = find(strcmp(io.staging_keys, key), 1);
if isempty(k)
    if mode(1) == 'r'
        staged = false;
        return;
    end
    dest = real_path(key);
    if isfolder(dest)
        return;
    end
    if exists(dest) && ~is_regular(dest)
        staged = false;
        return;
    end
    seps = find(dest == '/');
    if ~isempty(seps) && seps(end) > 1 && ~isfolder(dest(1:seps(end) - 1))
        % (missing directories are created, as wfdb_fopen does)
        for j = reshape(find(fname == '/'), 1, [])
            d = fname(1:j-1);
            if ~isempty(d) && ~isfolder(d)
                mkdir(d);
            end
        end
    end
    [fid, tmp] = wfdbx.internal.temp_create(dest);
    if fid < 0
        return;
    end
    fclose(fid);
    io.staging_keys{end + 1} = key;
    io.staging_tmps{end + 1} = tmp;
    io.staging_dests{end + 1} = dest;
    k = numel(io.staging_keys);
end
fid = fopen(io.staging_tmps{k}, mode);
if fid >= 0
    f = wfdbx.internal.WFDBFile(fid, 0, fname, 0, mode(1) ~= 'r');
end
end

function p = real_path(key)
% The file that the absolute name KEY leads to, symbolic links followed
% (as Python's os.path.realpath); KEY itself for a new file.
p = key;
if wfdbx.internal.is_octave()
    [r, err] = canonicalize_file_name(key);
    if err == 0
        p = r;
        return;
    end
    [info, err] = lstat(key);
    if err == 0 && S_ISLNK(info.mode)
        % (a symbolic link to a file that does not exist yet)
        t = readlink(key);
        if ~isempty(t)
            if t(1) ~= '/'
                t = [key(1:find(key == '/', 1, 'last')) t];
            end
            p = wfdbx.internal.staged_key(t);
        end
    end
else
    try
        p = char(java.io.File(key).getCanonicalPath());
    catch
        p = key;
    end
end
end

function tf = exists(name)
% True if the file NAME exists (symbolic links followed).
if wfdbx.internal.is_octave()
    [~, err] = stat(name);
    tf = err == 0;
else
    tf = isfile(name) || isfolder(name);
end
end

function tf = is_regular(name)
% True if the existing file NAME is a regular file.
if wfdbx.internal.is_octave()
    [info, err] = stat(name);
    tf = err == 0 && S_ISREG(info.mode);
else
    try
        tf = java.io.File(name).isFile();
    catch
        tf = isfile(name);
    end
end
end
