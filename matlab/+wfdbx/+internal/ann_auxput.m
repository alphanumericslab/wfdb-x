function [buf, index, auxpos] = ann_auxput(buf, index, P, m)
%ANN_AUXPUT Store the aux string of an AUX word in the aux ring buffer.
%   [BUF, INDEX, AUXPOS] = wfdbx.internal.ann_auxput(BUF, INDEX, P, M)
%   does what getann does for the M-th AUX word of the decoded MIT file P
%   (wfdbx.internal.ann_parse): it stores the length byte and the data
%   read (with a null after the data) in the ring buffer BUF (AUXBUFLEN = 771 bytes)
%   (positions 0-based; the buffer wraps when the string would not fit).

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

ln = P.tokln(m);
if index >= numel(buf) - 2 - ln  % AUXBUFLEN - 2 - ln
    index = 0;
end
auxpos = index;
buf(index+1) = ln;
index = index + 1;
av = P.tokav(m);
if av > 0
    o = P.tokoff(m);
    buf(index+1:index+av) = double(P.D(o+1:o+av));
end
buf(index+ln+1) = 0;
index = index + ln + 1;
end
