function [stat, vector] = getvec(vector)
%GETVEC Read a sample from each input signal.
%   [STAT, V] = wfdbx.getvec() reads the next sample of each input signal
%   (in WFDB_LOWRES mode, the samples of a frame of a multi-frequency
%   signal are averaged; in WFDB_HIGHRES mode, samples are returned at
%   the highest frequency; with setifreq, at the frequency chosen) and
%   returns them in the row vector V.  STAT is the number of input
%   signals, 0 if none are open, -1 at the end of the record, -3 if a
%   signal file cannot be read, -4 on a checksum error.  Invalid samples
%   are -32768 (wfdbx.WFDB_INVALID_SAMPLE()).
%
%   [STAT, V] = wfdbx.getvec(V) starts from the vector V (whose elements
%   are left unchanged where C leaves them unchanged).
%
%   To read many samples quickly, use wfdbx.getframes.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.isigopen('100s', 2);
%       [stat, v] = wfdbx.getvec();
%
%   See also wfdbx.isigopen, wfdbx.getframes, wfdbx.getframe,
%   wfdbx.isigsettime, wfdbx.setgvmode, wfdbx.setifreq.
%
%   Translation of the C function getvec() (lib/signal.c, WFDB 10.7.0): same
%   arguments and results.

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
if nargin < 1
    vector = zeros(1, max(S.nvsig, S.nisig));
end
ifreq = S.ifreq;
if ifreq == 0 || ifreq == S.sfreq
    if S.ispfmax < 2 && ~S.has_dsbuf
        % (rgetvec and getframe, simplified)
        [stat, vector] = wfdbx.internal.getskewedframe(S, vector);
        S.istime = S.istime + 1;
    else
        [stat, vector] = wfdbx.internal.rgetvec(S, vector);
    end
    return;
end
if S.rgvtime > S.mnticks
    S.rgvtime = S.rgvtime - S.mnticks;
    S.gvtime = S.gvtime - S.mnticks;
end
nsig = max(S.nvsig, S.nisig);
gv0 = S.gv0;
gv1 = S.gv1;
while S.gvtime > S.rgvtime
    gv0(1:nsig) = gv1(1:nsig);
    [S.rgvstat, gv1] = wfdbx.internal.rgetvec(S, gv1);
    S.rgvtime = S.rgvtime + S.nticks;
end
nt = S.nticks;
gm = rem(S.gvtime, nt);
for i = 1:nsig
    x = gv0(i) + fix(gm * (gv1(i) - gv0(i)) / nt);
    vector(i) = x - 4294967296 * floor((x + 2147483648) / 4294967296);   % (int)
    gv0(i) = gv1(i);
end
S.gv0 = gv0;
S.gv1 = gv1;
S.gvtime = S.gvtime + S.mticks;
stat = S.rgvstat;
end
