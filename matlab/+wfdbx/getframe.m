function [stat, vector] = getframe(vector)
%GETFRAME Read a frame of samples from the open input signals.
%   [STAT, V] = wfdbx.getframe() reads the next frame: all samples of
%   every input signal (spf samples of each signal, in signal order), and
%   returns them in the row vector V.  STAT is the number of input
%   signals, or as for wfdbx.getvec: -1 at the end of the record, -3 if
%   a file cannot be read, -4 on a checksum error.
%
%   [STAT, V] = wfdbx.getframe(V) starts from the vector V (whose
%   elements are left unchanged when no signals are open, as in C).
%
%   See also wfdbx.getvec, wfdbx.getframes.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
if nargin < 1
    vector = zeros(1, S.tspf);
end
[stat, vector] = wfdbx.internal.getframe_s(S, vector);
end
