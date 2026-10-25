function stat = wfdbputprolog(buf, size, s)
%WFDBPUTPROLOG Write a prolog to the signal file of an output signal.
%   STAT = wfdbx.wfdbputprolog(BUF, SIZE, S) writes the first SIZE bytes
%   of BUF (char or uint8) at the current position of the signal file of
%   output signal S, and records the prolog length for the header.
%   Returns 0, or -1 if not all bytes could be written.
%
%   See also wfdbx.wfdbsetstart.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
g = S.osd(s + 1).info.group;
b = uint8(buf(1:min(end, size)));
n = S.ogd{g + 1}.fp.write(b);
wfdbx.wfdbsetstart(s, n);
if n ~= size
    wfdbx.internal.wfdb_error('wfdbputprolog: only %d of %d bytes written\n', n, size);
    stat = -1;
else
    stat = 0;
end
end
