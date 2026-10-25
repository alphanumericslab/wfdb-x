function wfdb_sigclose()
%WFDB_SIGCLOSE Close all signals and reset the signal state (wfdb_sigclose).
%   wfdbx.internal.wfdb_sigclose() closes the input and output signals
%   and resets the time base, sampling frequency, segments, skew buffer
%   and sigmap state.  (The counter frequency and base count are kept, as
%   in C.)

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
wfdbx.internal.isigclose();
wfdbx.internal.osigclose();
S.btime = 0;
S.bdate = 0;
S.nsamples = 0;
S.msbtime = 0;
S.msbdate = 0;
S.msnsamples = 0;
S.sfreq = 0;
S.ifreq = 0;
S.ffreq = 0;
S.pdays = -1;
S.segments = 0;
S.in_msrec = 0;
S.skewmax = 0;
if S.has_dsbuf
    S.dsbuf = [];
    S.has_dsbuf = false;
    S.dsbi = -1;
end
if ~isempty(S.segarray)
    S.segarray = [];
    S.segp = 0;
    S.segend = 0;
end
S.gv0 = [];
S.gv1 = [];
S.tvector = [];
S.uvector = [];
S.vvector = [];
S.tuvlen = 0;
S.need_sigmap = 0;
S.nvsig = 0;
S.tspf = 0;
S.vspfmax = 0;
S.ovec = [];
S.smi = [];
S.vsd = [];
end
