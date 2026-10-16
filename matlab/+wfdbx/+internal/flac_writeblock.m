function fo = flac_writeblock(og, fo, n)
%FLAC_WRITEBLOCK Encode and write the first N buffered samples of each signal.
%   FO = wfdbx.internal.flac_writeblock(OG, FO, N) encodes one FLAC frame
%   from the first N samples per signal of FO.cbuf, writes it to OG.fp
%   and updates the encoder state FO (frame number, totals, frame sizes,
%   MD5 data).

% Original C implementation: the FLAC support of lib/signal.c, written by
% Benjamin Moody (2020); lib/signal.c is Copyright (C) 1989-2013 George
% B. Moody.
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

block = fo.cbuf(:, 1:n);
fo.cbuf = fo.cbuf(:, n+1:end);
fo.nbuf = fo.nbuf - n;
if size(fo.cbuf, 2) < 4096 + fo.spf
    fo.cbuf(fo.nsig, 4096 + fo.spf) = 0;
end
nb = floor((fo.bps + 7) / 8);
b = reshape(typecast(int32(reshape(block, 1, [])), 'uint8'), 4, []);
b = reshape(b(1:nb, :), 1, []);
m = fo.md5len + numel(b);
if m > numel(fo.md5data)
    fo.md5data(max(2 * m, 65536)) = 0;
end
fo.md5data(fo.md5len+1:m) = b;
fo.md5len = m;
frame = wfdbx.internal.flac_encode_frame(block, fo.bps, fo.frame_no);
if ~isempty(og.fp)
    og.fp.write(frame);
end
fo.frame_no = fo.frame_no + 1;
fo.total = fo.total + n;
fs = numel(frame);
if isempty(fo.minfs)
    fo.minfs = fs;
else
    fo.minfs = min(fo.minfs, fs);
end
fo.maxfs = max(fo.maxfs, fs);
end
