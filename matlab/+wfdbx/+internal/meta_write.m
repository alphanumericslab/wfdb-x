function meta_write(dest, data, record, id)
%META_WRITE Replace a header file in one step.
%   wfdbx.internal.meta_write(DEST, DATA, RECORD, ID) writes the bytes DATA
%   (a char row) to a temporary file in the directory of DEST (named
%   '.NAME.XXXXXXXX.tmp', NAME being the file name of DEST), which then
%   replaces DEST (rename), so that an error never leaves a partly written
%   header.  The temporary file is created by
%   wfdbx.internal.temp_create with the permissions that DEST has (in
%   Octave, its read and write permissions), whatever its name, so that
%   the header keeps them (a private 0600 header stays 0600), and no shell
%   command is run.  On any failure the temporary file is removed and an
%   error (identifier ID.file) is thrown: "can't write header for record
%   RECORD".
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

tmp = '';
fid = -1;
try
    % (with the permissions of DEST: see wfdbx.internal.temp_create)
    [fid, tmp] = wfdbx.internal.temp_create(dest);
    if fid < 0
        error('wfdbx:meta_write', 'cannot create %s', tmp);
    end
    n = fwrite(fid, uint8(data));
    % (fseek flushes the file and reports a failure; see DEVELOPING.md)
    ok = n == numel(data) && fseek(fid, 0, 'cof') == 0;
    ok = fclose(fid) == 0 && ok;
    fid = -1;
    if ~ok
        error('wfdbx:meta_write', 'cannot write %s', tmp);
    end
    if wfdbx.internal.is_octave()
        status = rename(tmp, dest);     % (Octave's movefile runs a shell)
        ok = status == 0;
    else
        ok = movefile(tmp, dest, 'f');
    end
    if ~ok
        error('wfdbx:meta_write', 'cannot rename %s', tmp);
    end
catch
    if fid >= 0
        fclose(fid);
    end
    if ~isempty(tmp) && isfile(tmp)
        delete(tmp);
    end
    error(id.file, 'can''t write header for record %s', record);
end
end
