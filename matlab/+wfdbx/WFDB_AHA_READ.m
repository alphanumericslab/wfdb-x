function v = WFDB_AHA_READ()
%WFDB_AHA_READ File mode: read an AHA-format annotation file (2).
%   V = wfdbx.WFDB_AHA_READ() returns 2.  Used as the stat field of a
%   wfdbx.anninfo structure, to open an annotator with wfdbx.annopen.
%
%   See also wfdbx.WFDB_AHA_WRITE, wfdbx.anninfo, wfdbx.annopen.

% Copyright (C) 1983-2013 George B. Moody (original C header, lib/wfdb.h;
% revised 2010-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

v = 2;
end
