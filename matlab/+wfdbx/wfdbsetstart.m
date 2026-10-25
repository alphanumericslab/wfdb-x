function wfdbsetstart(s, nbytes)
%WFDBSETSTART Set the byte offset of the first sample of an output signal.
%   wfdbx.wfdbsetstart(S, N) sets the prolog length (bytes before sample 0)
%   written in the header for output signal S.
%
%   See also wfdbx.wfdbgetstart, wfdbx.wfdbputprolog.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
if s < S.nosig
    S.ogd{S.osd(s + 1).info.group + 1}.start = nbytes;
end
S.prolog_bytes = nbytes;
end
