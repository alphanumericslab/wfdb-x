function f = open_at(p, s)
%OPEN_AT Open a file for reading at one location.
%   F = wfdbx.internal.open_at(P, S) (wfdb-x) opens, for reading, the file
%   of type S at location P (a resolved name: P.S), or else its 8.3 form
%   (the type truncated to 3 characters), there only.  The name tried last
%   is io_state().wfdb_filename.  Returns a WFDBFile, or [].

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
