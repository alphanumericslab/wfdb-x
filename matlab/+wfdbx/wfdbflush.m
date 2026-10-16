function wfdbflush()
%WFDBFLUSH Write all buffered output annotations and samples.
%   wfdbx.wfdbflush() writes any buffered output annotations and samples
%   to their files (the files remain open).
%
%   See also wfdbx.wfdbquit.

% Copyright (C) 1983-2012 George B. Moody (original C implementation,
% lib/wfdbinit.c; revised 2012-2019 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if wfdbx.internal.pkg_has('internal.wfdb_oaflush')
    wfdbx.internal.wfdb_oaflush();
end
wfdbx.internal.wfdb_osflush();
end
