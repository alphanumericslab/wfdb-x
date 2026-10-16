function stat = isigsettime(t)
%ISIGSETTIME Skip to a given time in the input signals.
%   STAT = wfdbx.isigsettime(T) positions all input signals so that the
%   next sample read by getvec is sample number T (in the units of
%   getvec: frames in WFDB_LOWRES mode, samples at the highest frequency
%   in WFDB_HIGHRES mode, or at the frequency set by setifreq).  T is
%   usually obtained from wfdbx.strtim.  Returns 0, or a negative value
%   on error.
%
%   See also wfdbx.isgsettime, wfdbx.strtim, wfdbx.getvec.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
stat = 0;
if S.nisig == 0
    return;
end
if S.ifreq <= 0
    if ~bitand(S.gvmode, 1) || S.ispfmax < 2     % WFDB_HIGHRES
        curtime = S.istime;
    else
        curtime = (S.istime - 1) * S.ispfmax + S.gvc;
    end
    if t == curtime
        return;
    end
end
for g = 1:S.nigroup - 1
    stat = wfdbx.isgsettime(g, t);
    if stat < 0
        break;
    end
end
if stat == 0
    stat = wfdbx.isgsettime(0, t);
end
end
