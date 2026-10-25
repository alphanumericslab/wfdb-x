function p = wfdb_getirec()
%WFDB_GETIREC The current record name saved by wfdb_setirec, or [].
%   P = wfdbx.internal.wfdb_getirec() returns [] (NULL) if no record name
%   has been saved.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.io_state();
p = st.irec;
if isempty(p)
    p = [];
end
end
