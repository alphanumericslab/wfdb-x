function v = WFDB_APPEND()
%WFDB_APPEND File mode: open an output file for appending (4).
%   V = wfdbx.WFDB_APPEND() returns 4, the value of WFDB_APPEND in
%   lib/wfdb.h.  The library uses this mode internally (e.g. wfdbx.setinfo
%   appends to an existing .info file); it is not a valid annotator mode
%   for wfdbx.annopen.
%
%   See also wfdbx.WFDB_WRITE, wfdbx.setinfo.

% Copyright (C) 1983-2013 George B. Moody (original C header, lib/wfdb.h;
% revised 2010-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

v = 4;
end
