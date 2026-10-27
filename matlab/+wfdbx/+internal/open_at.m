function f = open_at(p, s)
%OPEN_AT Open a file for reading at one location.
%   F = wfdbx.internal.open_at(P, S) (wfdb-x) opens, for reading, the file
%   of type S at location P (a resolved name: P.S), or else its 8.3 form
%   (the type truncated to 3 characters), there only.  The name tried last
%   is io_state().wfdb_filename.  Returns a WFDBFile, or [].
%
%   Part of the translation of lib/wfdbio.c (WFDB 10.7.0).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: files are opened at the one location their name
% designates (no search). docs/DIVERGENCES.md gives the reasons.
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

if ~ischar(s)
    s = '';
end
st = wfdbx.internal.io_state();
if isempty(s)
    long = p;
    short = [p '.'];
else
    long = [p '.' s];
    short = [p '.' s(1:min(end, 3))];
end
st.wfdb_filename = long;
f = wfdbx.internal.wfdb_fopen(long, 'rb');
if isempty(f) && ~strcmp(short, long)
    st.wfdb_filename = short;
    f = wfdbx.internal.wfdb_fopen(short, 'rb');
end
end
