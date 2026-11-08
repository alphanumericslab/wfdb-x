function meta_write(dest, data, record, id)
%META_WRITE Replace a header file in one step.
%   wfdbx.internal.meta_write(DEST, DATA, RECORD, ID) writes the bytes DATA
%   (a char row) to a temporary file in the directory of DEST (named
%   '.NAME.XXXX.tmp', NAME being the file name of DEST), which then
%   replaces DEST (rename), so that an error never leaves a partly written
%   header.  If DEST exists, the temporary file is made as a copy of it
%   (copyfile) before it is written, so that it has the permissions of
%   DEST where the system allows; if that copy cannot be made or written
%   (a read-only DEST), or in Octave for a name with other characters than
%   letters, digits, spaces and . _ / + , = @ ~ - (Octave's copyfile runs
%   a shell command), the temporary file is a new file with the default
%   permissions.  On any failure the temporary file is removed and an
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

seps = find(dest == '/' | (ispc() & dest == '\'));
if isempty(seps)
    prefix = '';
    base = dest;
else
    prefix = dest(1:seps(end));
    base = dest(seps(end)+1:end);
end
tmp = '';
fid = -1;
try
    while true
        [~, token] = fileparts(tempname());
        tmp = [prefix '.' base '.' token '.tmp'];
        if ~isfile(tmp) && ~isfolder(tmp)
            break;
        end
    end
    % (the permissions of DEST, where the system keeps them in a copy;
    % Octave's copyfile runs a shell command, so only for plain names)
    plain = ['A':'Z' 'a':'z' '0':'9' '._/+,=@~ -'];
    if ispc()
        plain = [plain '\:'];
    end
    if isfile(dest) && (~wfdbx.internal.is_octave() || all(ismember(tmp, plain)))
        if copyfile(dest, tmp)
            fid = fopen(tmp, 'wb');
            if fid < 0
                delete(tmp);
            end
        elseif isfile(tmp)
            delete(tmp);
        end
    end
    if fid < 0
        fid = fopen(tmp, 'wb');
    end
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
