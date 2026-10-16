function bits = fmt_bits(fmt)
%FMT_BITS Number of bits of a sample in a signal storage format.
%   BITS = wfdbx.internal.fmt_bits(FMT) returns the width of the samples
%   of the storage format FMT (8 for formats 80 and 508, 10 for 310 and
%   311, 12 for 212, 16 for 16, 61, 160 and 516, 24 for 24 and 524, 32
%   for 32), or 0 for formats without a fixed sample width (0, 8 and
%   unknown formats).  The lowest value of a format, -2^(BITS-1),
%   represents an invalid sample in a signal file.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

switch fmt
    case {80, 508}
        bits = 8;
    case {310, 311}
        bits = 10;
    case 212
        bits = 12;
    case {16, 61, 160, 516}
        bits = 16;
    case {24, 524}
        bits = 24;
    case 32
        bits = 32;
    otherwise
        bits = 0;
end
end
