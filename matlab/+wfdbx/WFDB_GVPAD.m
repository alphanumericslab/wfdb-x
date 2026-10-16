function v = WFDB_GVPAD()
%WFDB_GVPAD getvec mode flag: replace invalid samples by the previous one.
%   V = wfdbx.WFDB_GVPAD() returns 2, the value of WFDB_GVPAD in
%   lib/wfdb.h.
%
%   See also wfdbx.setgvmode, wfdbx.WFDB_LOWRES, wfdbx.WFDB_HIGHRES.

% Copyright (C) 1983-2013 George B. Moody (original C header, lib/wfdb.h;
% revised 2010-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

v = 2;
end
