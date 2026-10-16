function h = hsdata()
%HSDATA A header data structure (hsdata in signal.c): info, start, skew.
%   H = wfdbx.internal.hsdata() returns a structure with fields info (a
%   wfdbx.siginfo structure), start (byte offset of sample 0) and skew.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

persistent h0
if isempty(h0)
    h0 = struct('info', wfdbx.siginfo(), 'start', 0, 'skew', 0);
end
h = h0;
end
