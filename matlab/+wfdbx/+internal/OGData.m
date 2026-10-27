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
%
%   Part of the translation of lib/signal.c (WFDB 10.7.0).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
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
        obuflen = 0
        count = 0
        seek = 0
        force_flush = 0
        nrewind = 0
        flac = []
    end
end
