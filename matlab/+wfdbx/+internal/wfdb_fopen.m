function f = wfdb_fopen(fname, mode)
%WFDB_FOPEN Open a file by name.
%   F = wfdbx.internal.wfdb_fopen(FNAME, MODE) opens the file FNAME with the
%   C fopen() MODE ('rb', 'wb' or 'ab') and returns a
%   wfdbx.internal.WFDBFile, or [] (NULL) if it cannot be opened.  As in C,
%   names containing '..' are refused, and when an output file cannot be
%   created, the directories in its name are created and the file is tried
%   again.  Directories cannot be opened for reading.  URLs (names
%   containing '://') are not supported (remote files are not available in
%   the MATLAB/Octave implementation), so [] is returned for them.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

f = [];
if ~ischar(fname) || ~isempty(strfind(fname, '..')) || ...
        ~isempty(strfind(fname, '://'))
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
    for k = slashes
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
