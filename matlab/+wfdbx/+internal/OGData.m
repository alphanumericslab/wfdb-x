classdef OGData < handle
%OGDATA State of an output signal group (one signal file) -- ogdata in signal.c.
%   Properties (as in the C structure):
%
%     data, datb    bit-packed format state (formats 212, 310, 311)
%     fp            the WFDBFile, or [] (no file)
%     start         byte offset of sample 0 (prolog size)
%     bsize         block size (bytes)
%     buf           bytes not yet written (uint8 row); they are written
%                   when obuflen bytes have accumulated
%     obuflen       size of the output buffer
%     count         position in a bit-packed group
%     seek          1 if the file is seekable, -1 if not, 0 if unknown
%     force_flush   set when the file is being closed
%     nrewind       bytes to rewind after a flush of a partial group
%     flac          the state of the FLAC encoder (formats 508, 516, 524),
%                   [] otherwise
%
%   The FLAC functions (wfdbx.internal.flac_osinit, flac_osopen,
%   flac_putsamp, flac_osclose) may use fp, bsize, buf, obuflen and flac.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

    properties
        data = 0
        datb = 0
        fp = []
        start = 0
        bsize = 0
        buf = zeros(1, 0, 'uint8')
        obuflen = 0
        count = 0
        seek = 0
        force_flush = 0
        nrewind = 0
        flac = []
    end
end
