function wfdb_addtopath(s)
%WFDB_ADDTOPATH Add the directory of a file to the front of the WFDB path.
%   wfdbx.internal.wfdb_addtopath(S) moves (or adds) the directory part of
%   the file name S to the beginning of the WFDB path (after '.', if '.' is
%   the first component), so that the other files of a record found there
%   are found in the same place.  Called by wfdb_open for every file found
%   in legacy mode (wfdb-x: nothing is searched otherwise).
%
%   Translation of the C function wfdb_addtopath() (lib/wfdbio.c, WFDB
%   10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: called only in legacy mode, since nothing is
% searched otherwise. Each change is marked "wfdb-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
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

if isempty(s)
    return;
end
k = find(s == '/' | s == '\' | s == ':', 1, 'last');
if isempty(k)
    return;
end
p = k - 1;          % length of the directory part (as in C)
if p == 0
    p = 1;
end
st = wfdbx.internal.io_state();
if ~ischar(st.wfdbpath)
    wfdbx.getwfdb();
end
prefix = st.path_prefix;
ptype = st.path_type;
if isempty(prefix)
    return;
end
found = 0;
for idx = 1:numel(prefix)
    if strncmp_eq(prefix{idx}, s, p)
        if idx == 1 || (idx == 2 && strcmp(prefix{1}, '.'))
            return;     % no changes needed
        end
        found = idx;
        break;
    end
end
if found
    c = prefix{found};
    t = ptype(found);
    prefix(found) = [];
    ptype(found) = [];
else
    c = s(1:p);
    t = double(~isempty(strfind(c, '://')));
end
if strcmp(prefix{1}, '.')
    prefix = [prefix(1) {c} prefix(2:end)];
    ptype = [ptype(1) t ptype(2:end)];
else
    prefix = [{c} prefix];
    ptype = [t ptype];
end
st.path_prefix = prefix;
st.path_type = ptype;
end

function tf = strncmp_eq(a, b, n)
% strncmp(a, b, n) == 0 for C strings a and b.
a = [a(1:min(end, n)) char(zeros(1, n))];
b = [b(1:min(end, n)) char(zeros(1, n))];
a = a(1:n);
b = b(1:n);
k = find(a ~= b | a == char(0), 1);
tf = isempty(k) || a(k) == b(k);
end
