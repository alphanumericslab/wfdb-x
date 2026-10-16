function p = wfdb_striphea(p)
%WFDB_STRIPHEA Remove a trailing '.hea' from a record name.
%   P = wfdbx.internal.wfdb_striphea(P) returns P without its last four
%   characters if it is longer than 4 characters and ends with '.hea'.
%   [] (NULL) is returned unchanged.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if ischar(p) && numel(p) > 4 && strcmp(p(end-3:end), '.hea')
    p = p(1:end-4);
end
end
