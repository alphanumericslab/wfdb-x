function b = flac_streaminfo(fo, total, md5)
%FLAC_STREAMINFO The STREAMINFO block of a FLAC stream being written.
%   B = wfdbx.internal.flac_streaminfo(FO, TOTAL, MD5) returns the 34 bytes
%   of STREAMINFO (as the Python implementation of wfdb-x writes it) for
%   the encoder state FO (see wfdbx.internal.flac_osinit), with TOTAL
%   samples per channel and the 16-byte signature MD5: block sizes 4096,
%   frame sizes FO.minfs (0 if none) and FO.maxfs, sample rate 96000.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if isempty(fo.minfs)
    minfs = 0;
else
    minfs = fo.minfs;
end
% the fields (min/max block size, min/max frame size, sample rate,
% channels - 1, bits per sample - 1, total samples) and their widths
v = [4096, 4096, minfs, fo.maxfs, 96000, fo.nsig - 1, fo.bps - 1, total];
w = [16, 16, 24, 24, 20, 3, 5, 36];
bits = zeros(1, 144);
p = 0;
for k = 1:numel(v)
    x = v(k);
    for j = w(k)-1:-1:0
        p = p + 1;
        bits(p) = mod(floor(x / 2^j), 2);
    end
end
b = uint8([[128 64 32 16 8 4 2 1] * reshape(bits, 8, 18), double(md5)]);
end
