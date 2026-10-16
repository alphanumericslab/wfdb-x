function stat = setsampfreq(freq)
%SETSAMPFREQ Set the sampling frequency.
%   STAT = wfdbx.setsampfreq(F) sets the sampling frequency (Hz) used for
%   output headers and time conversions.  Returns 0, or -1 if F < 0.
%
%   See also wfdbx.sampfreq.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
if freq >= 0
    S.sfreq = freq;
    S.ffreq = freq;
    if S.spfmax == 0
        S.spfmax = 1;
    end
    if bitand(S.gvmode, 1) == 1     % WFDB_HIGHRES
        S.sfreq = S.sfreq * S.spfmax;
    end
    stat = 0;
    return;
end
wfdbx.internal.wfdb_error('setsampfreq: sampling frequency must not be negative\n');
stat = -1;
end
