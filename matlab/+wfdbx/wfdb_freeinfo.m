function wfdb_freeinfo()
%WFDB_FREEINFO Discard the info strings read by getinfo.
%   wfdbx.wfdb_freeinfo() makes the next wfdbx.getinfo([]) start again from
%   the first info string of the current input record.
%
%   See also wfdbx.getinfo.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

wfdbx.internal.wfdb_freeinfo();
end
