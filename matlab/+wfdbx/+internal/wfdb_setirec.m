function wfdb_setirec(p)
%WFDB_SETIREC Save the current record name (for %r in the WFDB path).
%   wfdbx.internal.wfdb_setirec(P) saves the last component of the record
%   name P (unless it is '-'), truncated to WFDB_MAXRNL (50) characters.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

k = find(p == '/', 1, 'last');
if ~isempty(k)
    p = p(k+1:end);
end
if ~strcmp(p, '-')
    st = wfdbx.internal.io_state();
    st.irec = p(1:min(end, 50));        % WFDB_MAXRNL
end
end
