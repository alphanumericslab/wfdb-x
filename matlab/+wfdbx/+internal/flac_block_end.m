function e = flac_block_end(fi, n)
%FLAC_BLOCK_END End of the FLAC block that contains a sample.
%   E = wfdbx.internal.flac_block_end(FI, N) is the end of the FLAC block
%   (frame) that contains sample N - 1 (N > 0) of the input FI: the number
%   of samples (per channel) that the C library has decoded once sample
%   N - 1 is.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

k = find(fi.block_ends >= n, 1);
if isempty(k)
    e = fi.total;
else
    e = fi.block_ends(k);
end
end
