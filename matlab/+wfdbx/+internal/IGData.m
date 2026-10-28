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
%     ahead         WFDB-x: blocks read from fp by the bulk reader
%                   (wfdbx.internal.bulk_frames) but not yet reached
%                   (uint8 row); the next refill of buf takes its block
%                   from them first
%
%   The FLAC functions (wfdbx.internal.flac_isopen, flac_getsamp,
%   flac_isseek, flac_isclose) may use fp, start, stat, count, bsize and
%   flac.
%
%   Part of the translation of lib/signal.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: the blocks read ahead by the bulk reader are
% kept (ahead). Each change is marked "WFDB-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
%
% Original C code: lib/signal.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

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
        ahead = zeros(1, 0, 'uint8')    % WFDB-x (see above)
    end
end
