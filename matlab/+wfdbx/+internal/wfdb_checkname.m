function st = wfdb_checkname(p, s)
%WFDB_CHECKNAME Check that a record or annotator name is legal.
%   ST = wfdbx.internal.wfdb_checkname(P, S) returns 0 if P contains only
%   letters, digits, '_', '~', '-' and '/', or -1 after reporting the first
%   illegal character ("init: illegal character N in S name"; N is the
%   signed char code, 0 for an empty name).

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = 0;
if ~ischar(p) || isempty(p)
    wfdbx.internal.wfdb_error('init: illegal character %d in %s name\n', 0, s);
    st = -1;
    return;
end
ok = (p >= '0' & p <= '9') | (p >= 'a' & p <= 'z') | (p >= 'A' & p <= 'Z') ...
    | p == '_' | p == '~' | p == '-' | p == '/';
k = find(~ok, 1);
if ~isempty(k)
    o = double(p(k));
    if o > 127
        o = o - 256;
    end
    wfdbx.internal.wfdb_error('init: illegal character %d in %s name\n', o, s);
    st = -1;
end
end
