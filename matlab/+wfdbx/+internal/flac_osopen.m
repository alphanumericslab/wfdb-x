function stat = flac_osopen(og)
%FLAC_OSOPEN Write the header of a FLAC output group (flac_osopen).
%   STAT = wfdbx.internal.flac_osopen(OG) writes the stream marker, a
%   STREAMINFO block (completed by flac_osclose) and a VORBIS_COMMENT block
%   (vendor "wfdb-x") to OG.fp, and returns 0.

% Original C implementation: the FLAC support of lib/signal.c, written by
% Benjamin Moody (2020); lib/signal.c is Copyright (C) 1989-2013 George
% B. Moody.
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
