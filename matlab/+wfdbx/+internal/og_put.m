function og_put(og, b)
%OG_PUT Append bytes to the output buffer of a signal group (w8 in signal.c).
%   wfdbx.internal.og_put(OG, B) appends the bytes B (values 0-255) to the
%   buffer of the output group OG; each time the buffer holds OG.obuflen
%   bytes, they are written to the file (or discarded if there is none).

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

buf = [og.buf, uint8(b)];
L = og.obuflen;
n = numel(buf);
if L > 0
    k = n - mod(n, L);
else
    k = n;
end
if k > 0
    if ~isempty(og.fp)
        og.fp.write(buf(1:k));
    end
    buf = buf(k + 1:end);
end
og.buf = buf;
end
