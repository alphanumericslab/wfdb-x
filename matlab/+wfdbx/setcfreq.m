function setcfreq(freq)
%SETCFREQ Set the counter frequency.
%   wfdbx.setcfreq(F) sets the counter frequency (Hz) written by
%   setheader and used by strtim for "c" times.
%
%   See also wfdbx.getcfreq.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
S.cfreq = freq;
end
