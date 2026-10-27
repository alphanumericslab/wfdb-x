function wfdb_sigclose()
%WFDB_SIGCLOSE Close all signals and reset the signal state (wfdb_sigclose).
%   wfdbx.internal.wfdb_sigclose() closes the input and output signals
%   and resets the time base, sampling frequency, segments, skew buffer
%   and sigmap state.  (The counter frequency and base count are kept, as
%   in C.)
%
%   Translation of the C function wfdb_sigclose() (lib/signal.c, WFDB
%   10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

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
S.hdr_dir = [];         % WFDB-x
S.msrec_dir = [];
S.msrec_name = [];
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
