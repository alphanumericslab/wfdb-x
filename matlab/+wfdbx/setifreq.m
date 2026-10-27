function stat = setifreq(f)
%SETIFREQ Set the frequency at which getvec returns samples.
%   STAT = wfdbx.setifreq(F) makes getvec resample the input signals at F
%   Hz (by linear interpolation); times given to isigsettime and strtim
%   are then in sample intervals at F Hz.  Returns 0, or -1 if F <= 0, if
%   no record is open, or if the sampling frequency of the open record is
%   not specified (WFDB-x; in legacy mode the message is always "no open
%   input record", as in C; see docs/DIVERGENCES.md).
%
%   See also wfdbx.getifreq, wfdbx.getvec.
%
%   Translation of the C function setifreq() (lib/signal.c, WFDB 10.7.0): same
%   arguments and results. Differences: it fails if the sampling frequency of
%   the input record is not specified; see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: it fails, with its own message, when the
% sampling frequency of the open record is not specified. Each change is
% marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
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
g = S.sfreq;
if g <= 0
    S.ifreq = 0;
    if S.nisig > 0 && ~S.legacy_mode    % wfdb-x: the frequency is unspecified
        wfdbx.internal.wfdb_error( ...
            'setifreq: sampling frequency is not specified\n');
    else
        wfdbx.internal.wfdb_error('setifreq: no open input record\n');
    end
    stat = -1;
    return;
end
if f > 0
    n = max(S.nvsig, 1);
    S.gv0 = zeros(1, n);
    S.gv1 = zeros(1, n);
    S.ifreq = f;
    if wfdbx.internal.pkg_has('setafreq')
        wfdbx.setafreq(f);
    end
    while true
        err = f - g;
        if ~(err > 0.005 || err < -0.005)   % tolerance as in C
            break;
        end
        if f > g
            f = f - g;
        else
            g = g - f;
        end
    end
    S.mticks = fix(S.sfreq / f + 0.5);
    S.nticks = fix(S.ifreq / f + 0.5);
    S.mnticks = S.mticks * S.nticks;
    S.gvtime = 0;
    [S.rgvstat, S.gv0] = wfdbx.internal.rgetvec(S, S.gv0);
    [S.rgvstat, S.gv1] = wfdbx.internal.rgetvec(S, S.gv1);
    S.rgvtime = S.nticks;
    stat = 0;
    return;
end
S.ifreq = 0;
wfdbx.internal.wfdb_error('setifreq: improper frequency %g (must be > 0)\n', f);
stat = -1;
end
