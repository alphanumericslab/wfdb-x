function st = wfdb_checkname(p, s)
%WFDB_CHECKNAME Check that a record or annotator name is legal.
%   ST = wfdbx.internal.wfdb_checkname(P, S) returns 0 if P contains only
%   letters, digits, '_', '~', '-' and '/', or -1 after reporting the first
%   illegal character ("init: illegal character N in S name"; N is the
%   signed char code, 0 for an empty name).  wfdb-x: for a record name
%   (S = 'record'), outside legacy mode, only its last component (after
%   the last '/') is checked.
%
%   Translation of the C function wfdb_checkname() (lib/wfdbio.c, WFDB
%   10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: for a record name, outside legacy mode, only
% its last component is checked, so that records can be written in
% directories with other characters. Each change is marked "wfdb-x:" in the
% code; docs/DIVERGENCES.md gives the reasons.
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

st = 0;
% wfdb-x: a record name may be a path; outside legacy mode only its last
% component (the record's own name) is checked, so that directories with
% other characters (such as 'my.data/rec') can be written.
if ischar(p) && strcmp(s, 'record') && ~wfdbx.wfdbx_get_legacy()
    k = find(p == '/', 1, 'last');
    if ~isempty(k)
        p = p(k + 1:end);
    end
end
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
