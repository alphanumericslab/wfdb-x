function wfdb_freeinfo()
%WFDB_FREEINFO Discard the info strings read by getinfo (wfdb_freeinfo).

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
S.pinfo = [];
S.has_pinfo = false;
S.ninfo = 0;
S.info_i = 0;
end
