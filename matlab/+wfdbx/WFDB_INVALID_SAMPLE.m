function v = WFDB_INVALID_SAMPLE()
%WFDB_INVALID_SAMPLE Value of an invalid (missing) sample.
%   V = wfdbx.WFDB_INVALID_SAMPLE() returns -32768, the value of
%   WFDB_INVALID_SAMPLE in lib/wfdb.h.  wfdbx.getvec returns it for
%   missing samples, and wfdbx.putvec writes it as the invalid value of
%   the signal's format.
%
%   See also wfdbx.getvec, wfdbx.putvec.

% Copyright (C) 1983-2013 George B. Moody (original C header, lib/wfdb.h;
% revised 2010-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

v = -32768;
end
