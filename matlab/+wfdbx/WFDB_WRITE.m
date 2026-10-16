function v = WFDB_WRITE()
%WFDB_WRITE File mode: write an output file or annotator (1).
%   V = wfdbx.WFDB_WRITE() returns 1.  Used as the stat field of a
%   wfdbx.anninfo structure, to open an annotator with wfdbx.annopen.
%
%   See also wfdbx.WFDB_READ, wfdbx.anninfo, wfdbx.annopen.

% Copyright (C) 1983-2013 George B. Moody (original C header, lib/wfdb.h;
% revised 2010-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

v = 1;
end
