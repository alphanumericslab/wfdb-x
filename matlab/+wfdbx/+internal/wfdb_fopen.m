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

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
    f = wfdbx.internal.WFDBFile(fid, 0, fname);
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
            f = wfdbx.internal.WFDBFile(fid, 0, fname);
        end
    end
end
end
