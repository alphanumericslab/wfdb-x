function stat = flac_osopen(og)
%FLAC_OSOPEN Write the header of a FLAC output group (flac_osopen).
%   STAT = wfdbx.internal.flac_osopen(OG) writes the stream marker, a
%   STREAMINFO block (completed by flac_osclose) and a VORBIS_COMMENT block
%   (vendor "wfdb-x") to OG.fp, and returns 0.
%
%   Translation of the C function flac_osopen() (lib/signal.c, WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of the FLAC support of lib/signal.c (the
% code that connects FLAC to the signal functions) from the WFDB Software
% Package 10.7.0, by Benjamin Moody (2020). The translation follows the logic
% and behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c (FLAC support), WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by
%   Benjamin Moody, including FLAC support (2020).
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

fo = og.flac;
vendor = 'wfdb-x';
nv = numel(vendor);
vc = [mod(nv, 256), mod(floor(nv / 256), 256), mod(floor(nv / 65536), 256), ...
    floor(nv / 16777216), double(vendor), 0, 0, 0, 0];
nvc = numel(vc);
% "fLaC", the STREAMINFO block (type 0, 34 bytes; the number of samples
% and the MD5 signature are filled in when the file is closed), and the
% last block, VORBIS_COMMENT (type 4 + 128), with the vendor string
hdr = [double('fLaC'), 0, 0, 0, 34, ...
    double(wfdbx.internal.flac_streaminfo(fo, 2^36 - 1, zeros(1, 16))), ...
    132, floor(nvc / 65536), mod(floor(nvc / 256), 256), mod(nvc, 256), vc];
if ~isempty(og.fp)
    fo.header_pos = og.fp.tell();
    og.fp.write(uint8(hdr));
else
    fo.header_pos = 0;
end
og.flac = fo;
stat = 0;
end
