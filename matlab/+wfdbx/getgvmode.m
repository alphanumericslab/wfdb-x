function mode = getgvmode()
%GETGVMODE The getvec operating mode.
%   MODE = wfdbx.getgvmode() returns the mode set by wfdbx.setgvmode.
%
%   See also wfdbx.setgvmode.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
mode = S.gvmode;
end
