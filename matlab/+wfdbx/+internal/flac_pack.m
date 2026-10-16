function fi = flac_pack(fi, base)
%FLAC_PACK Arrange decoded FLAC samples in WFDB frame order.
%   FI = wfdbx.internal.flac_pack(FI, BASE) sets FI.samples to the samples
%   from sample number BASE (0-based, per signal) onward in frame order
%   (for each frame: FI.spf samples of each signal in turn), as the C
%   library reads them after a seek to that sample; FI.leftover is the
%   number of samples at the end that do not fill a frame, and FI.pos 0.

% Original C implementation: the FLAC support of lib/signal.c, written by
% Benjamin Moody (2020); lib/signal.c is Copyright (C) 1989-2013 George
% B. Moody.
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

spf = fi.spf;
nch = size(fi.arr, 1);
nfr = floor((fi.total - base) / spf);
fi.leftover = (fi.total - base) - nfr * spf;
X = fi.arr(:, base+1:base+nfr*spf);
Y = reshape(X', spf, nfr, nch);
Z = permute(Y, [1 3 2]);
fi.samples = reshape(Z, 1, []);
fi.pos = 0;
fi.base = base;
end
