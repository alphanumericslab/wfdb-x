function p = getiwfdb(p)
%GETIWFDB Expand indirect WFDB paths (@FILE).
%   P = wfdbx.internal.getiwfdb(P) replaces a path of the form @FILE by the
%   contents of FILE (without trailing CR/LF characters), up to 10 times.
%   A path still indirect after that gives the error message "getwfdb:
%   files nested too deeply" and an empty path.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

i = 0;
while i < 10 && ischar(p) && ~isempty(p) && p(1) == '@'
    fid = fopen(p(2:end), 'rb');
    if fid >= 0
        d = char(fread(fid, Inf, 'uint8=>uint8')');
        fclose(fid);
        n = numel(d);
        while n > 0 && (d(n) == char(13) || d(n) == char(10))
            n = n - 1;
        end
        p = d(1:n);
    else
        p = '';
    end
    i = i + 1;
end
if ischar(p) && ~isempty(p) && p(1) == '@'
    wfdbx.internal.wfdb_error('getwfdb: files nested too deeply\n');
    p = '';
end
end
