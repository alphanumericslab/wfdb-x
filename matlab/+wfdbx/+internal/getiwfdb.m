function p = getiwfdb(p)
%GETIWFDB Expand indirect WFDB paths (@FILE).
%   P = wfdbx.internal.getiwfdb(P) replaces a path of the form @FILE by the
%   contents of FILE (without trailing CR/LF characters), up to 10 times.
%   A path still indirect after that gives the error message "getwfdb:
%   files nested too deeply" and an empty path.
%
%   Part of the translation of lib/wfdbio.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
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
