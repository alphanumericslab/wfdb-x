function [chans, bps, md5] = flac_decode(data)
%FLAC_DECODE Decode a complete FLAC stream.
%   [CHANS, BPS, MD5] = wfdbx.internal.flac_decode(DATA) decodes the FLAC
%   stream DATA (a uint8 vector: the whole file) and returns its samples
%   as a matrix CHANS (one row per channel, double values), the number of
%   bits per sample BPS of the stream (from STREAMINFO) and the MD5
%   signature stored in STREAMINFO (16 bytes, uint8).  All features of
%   FLAC are supported: constant, verbatim, fixed and LPC subframes, Rice
%   and Rice2 partitions with escape codes, wasted bits, stereo
%   decorrelation, variable block sizes; header (CRC-8) and frame (CRC-16)
%   checksums are verified.  The decoder is wfdbx.internal.flac_decoder,
%   a port of libFLAC's stream decoder.
%
%   The first error is thrown, with the identifier wfdbx:flac:STATUS,
%   where STATUS is 'meta' (invalid stream header or metadata), 'sync'
%   (lost sync: also bytes after the last frame, or a truncated stream),
%   'header' (invalid frame header), 'crc' (CRC mismatch) or 'unparseable'
%   (unsupported format, or frames with different numbers of channels).
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin. It
% has no counterpart in the original package, which reads FLAC with libFLAC: it
% is WFDB-x's own code, which runs wfdbx.internal.flac_decoder (a translation of
% libFLAC 1.4.3's stream decoder, under libFLAC's license) to the end of the
% stream.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

opt.seekable = true;
opt.md5 = false;
opt.ig = [];
D = wfdbx.internal.flac_decoder('new', data, opt);
while D.state ~= 4 && D.state ~= 5     % END_OF_STREAM, ABORTED
    [D, ok] = wfdbx.internal.flac_decoder('process', D);
    if ~ok
        error('wfdbx:flac:meta', 'FLAC decoding error: meta');
    end
end
if isempty(D.out)
    chans = zeros(max(D.si_channels, 1), 0);
else
    chans = [D.out{:}];
end
bps = D.si_bps;
md5 = D.si_md5;
end
