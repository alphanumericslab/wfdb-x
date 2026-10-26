function wfdb_addtopath(s)
%WFDB_ADDTOPATH Add the directory of a file to the front of the WFDB path.
%   wfdbx.internal.wfdb_addtopath(S) moves (or adds) the directory part of
%   the file name S to the beginning of the WFDB path (after '.', if '.' is
%   the first component), so that the other files of a record found there
%   are found in the same place.  Called by wfdb_open for every file found
%   in legacy mode (wfdb-x: nothing is searched otherwise).

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
