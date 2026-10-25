function n = wfdbgetstart(s)
%WFDBGETSTART Byte offset of the first sample of an input signal.
%   N = wfdbx.wfdbgetstart(S) returns the number of bytes preceding
%   sample 0 (the prolog) in the signal file of input signal S.
%
%   See also wfdbx.wfdbsetstart.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
if s < S.nisig
    n = S.igd{S.vsd(s + 1).info.group + 1}.start;
elseif s == 0 && ~isempty(S.hsd)
    n = S.hsd(1).start;
else
    n = 0;
end
end
