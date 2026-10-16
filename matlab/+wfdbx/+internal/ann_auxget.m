function a = ann_auxget(buf, pos)
%ANN_AUXGET The aux string at a position of the aux ring buffer.
%   A = wfdbx.internal.ann_auxget(BUF, POS) returns, as a uint8 row, what
%   a C program finds at annot->aux when it points to position POS
%   (0-based) of the buffer BUF (AUXBUFLEN = 771 bytes): the length byte, the data, and
%   any further bytes up to a null (the buffer may contain stale data).

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

AUXBUFLEN = numel(buf);
e = pos + 1 + buf(pos+1);       % 0-based end of the data
if e >= AUXBUFLEN
    e = AUXBUFLEN;
else
    z = find(buf(e+1:AUXBUFLEN) == 0, 1);
    if isempty(z)
        e = AUXBUFLEN;
    else
        e = e + z - 1;
    end
end
a = uint8(buf(pos+1:e));
end
