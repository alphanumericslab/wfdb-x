function stat = setifreq(f)
%SETIFREQ Set the frequency at which getvec returns samples.
%   STAT = wfdbx.setifreq(F) makes getvec resample the input signals at F
%   Hz (by linear interpolation); times given to isigsettime and strtim
%   are then in sample intervals at F Hz.  Returns 0, or -1 if F <= 0, if
%   no record is open, or if the sampling frequency of the open record is
%   not specified (wfdb-x; in legacy mode the message is always "no open
%   input record", as in C; see docs/DIVERGENCES.md).
%
%   See also wfdbx.getifreq, wfdbx.getvec.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
