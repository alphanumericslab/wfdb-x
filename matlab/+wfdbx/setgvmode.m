function setgvmode(mode)
%SETGVMODE Set the getvec operating mode.
%   wfdbx.setgvmode(MODE) selects how multi-frequency records are read:
%   wfdbx.WFDB_LOWRES() (0: one sample per signal per frame, averaged) or
%   wfdbx.WFDB_HIGHRES() (1: samples at the highest frequency), possibly
%   combined (bitor) with wfdbx.WFDB_GVPAD() (2: replace invalid samples
%   with the previous valid sample).  A negative MODE uses the value of
%   the WFDBGVMODE environment variable (default WFDB_LOWRES).
%
%   See also wfdbx.getgvmode, wfdbx.getspf.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

WFDB_HIGHRES = 1;       % lib/wfdb.h
WFDB_GVPAD = 2;
DEFWFDBGVMODE = 0;      % WFDB_LOWRES (lib/wfdblib.h)

S = wfdbx.internal.sigstate();
if mode < 0
    p = wfdbx.internal.cgetenv('WFDBGVMODE');
    if ischar(p)
        mode = wfdbx.internal.cint32(wfdbx.internal.strtol(p));
    else
        mode = DEFWFDBGVMODE;
    end
end
mode = mod(mode, 4294967296);           % unsigned, for bitand
S.gvmode = bitand(mode, WFDB_HIGHRES + WFDB_GVPAD);
if bitand(mode, WFDB_HIGHRES) == WFDB_HIGHRES
    if S.spfmax == 0
        S.spfmax = 1;
    end
    S.sfreq = S.ffreq * S.spfmax;
else
    S.sfreq = S.ffreq;
end
end
