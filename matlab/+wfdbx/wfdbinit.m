function [stat, si] = wfdbinit(record, aiarray, nann, nsig)
%WFDBINIT Open the annotation files and input signals of a record.
%   [STAT, SI] = wfdbx.wfdbinit(RECORD, AIARRAY, NANN, NSIG) calls
%   wfdbx.annopen(RECORD, AIARRAY, NANN) and, if it succeeds,
%   [STAT, SI] = wfdbx.isigopen(RECORD, NSIG).
%
%   See also wfdbx.annopen, wfdbx.isigopen, wfdbx.wfdbquit.

% Copyright (C) 1983-2012 George B. Moody (original C implementation,
% lib/wfdbinit.c; revised 2012-2019 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

si = wfdbx.siginfo(0);
stat = wfdbx.annopen(record, aiarray, nann);
if stat == 0
    [stat, si] = wfdbx.isigopen(record, nsig);
end
end
