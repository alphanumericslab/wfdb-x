function wfdb_sampquit()
%WFDB_SAMPQUIT Free the buffer of wfdbx.sample (wfdb_sampquit in signal.c).

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
if ~isempty(S.sbuf)
    S.sbuf = [];
    S.sample_vflag = 0;
end
end
