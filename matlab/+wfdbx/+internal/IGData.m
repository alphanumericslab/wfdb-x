classdef IGData < handle
%IGDATA State of an input signal group (one signal file) -- igdata in signal.c.
%   Properties (as in the C structure):
%
%     data, datb    bit-packed format state (formats 212, 310, 311)
%     fp            the WFDBFile, or [] (format 0)
%     start         byte offset of sample 0 in the file
%     bsize         block size (bytes)
%     buf, bp, be   input buffer (uint8 row), number of bytes consumed
%                   from it, and number of valid bytes in it
%     count         position in a bit-packed group (0, 1, 2)
%     seek          1 if the file can be positioned with fseek, 0 if not
%     initial_skip  1 if the prolog must be skipped before the first read
%     stat          result of the last read: number of bytes (> 0), 0 at
%                   end of file, -2 for a decoding error
%     flac          the state of the FLAC decoder (formats 508, 516, 524),
%                   [] otherwise
%
%   The FLAC functions (wfdbx.internal.flac_isopen, flac_getsamp,
%   flac_isseek, flac_isclose) may use fp, start, stat, count, bsize and
%   flac.

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
        bp = 0
        be = 0
        count = 0
        seek = 0
        initial_skip = 0
        stat = 0
        flac = []
    end
end
