function f = getcfreq()
%GETCFREQ Counter frequency of the open record.
%   F = wfdbx.getcfreq() returns the counter frequency (Hz), or the frame
%   frequency if no counter frequency was defined.
%
%   See also wfdbx.setcfreq, wfdbx.getbasecount.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
if S.cfreq > 0
    f = S.cfreq;
else
    f = S.ffreq;
end
end
