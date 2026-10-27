function f = wfdb_fopen(fname, mode)
%WFDB_FOPEN Open a file by name.
%   F = wfdbx.internal.wfdb_fopen(FNAME, MODE) opens the file FNAME with the
%   C fopen() MODE ('rb', 'wb' or 'ab') and returns a
%   wfdbx.internal.WFDBFile, or [] (NULL) if it cannot be opened.  As in C,
%   when an output file cannot be created, the directories in its name are
%   created and the file is tried again.  Directories cannot be opened for
%   reading.  wfdb-x: an http:// or https:// URL can only be read, if
%   network access is allowed (wfdbx.internal.fetch_open); names
%   containing '..' are accepted.  In legacy mode, names containing '..'
%   or '://' are refused (as by the reference C library, built without
%   network support).
%
%   Translation of the C function wfdb_fopen() (lib/wfdbio.c, WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: an http:// or https:// URL is read only if
% network access is allowed, and names containing '..' are accepted (refused
% in legacy mode, as by the C library built without NETFILES). Each change
% is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
%
% Original C code: lib/wfdbio.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

f = [];
if ~ischar(fname)
    return;
end
if wfdbx.wfdbx_get_legacy()     % wfdb-x: legacy mode (the original)
    if ~isempty(strfind(fname, '..')) || ~isempty(strfind(fname, '://'))
        return;
    end
elseif wfdbx.internal.is_url(fname)
    if mode(1) == 'r'
        f = wfdbx.internal.fetch_open(fname);
    end
    return;
end
fid = fopen(fname, mode);
if fid >= 0 && mode(1) == 'r' && ~wfdbx.internal.is_octave() && ...
        isfolder(fname)
    fclose(fid);    % MATLAB may open directories
    return;
end
if fid >= 0
    f = wfdbx.internal.WFDBFile(fid, 0, fname, 0, mode(1) ~= 'r');
    return;
end
if strcmp(mode, 'wb') || strcmp(mode, 'ab')
    stat = 1;
    slashes = find(fname == '/');
    for k = reshape(slashes, 1, [])
        d = fname(1:k-1);
        % C mkdir() fails if the directory exists (or for an empty name)
        if isempty(d) || isfolder(d)
            stat = 1;
        else
            [ok, msg] = mkdir(d); %#ok<ASGLU>
            stat = double(~ok);
        end
    end
    if stat == 0
        fid = fopen(fname, mode);
        if fid >= 0
            f = wfdbx.internal.WFDBFile(fid, 0, fname, 0, true);
        end
    end
end
end
