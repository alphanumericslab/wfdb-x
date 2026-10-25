function out = sigmap(ivec)
%SIGMAP Map a frame of a variable-layout segment to the record layout.
%   OUT = wfdbx.internal.sigmap(IVEC) returns the tspf samples of the
%   record's layout computed from the frame IVEC of the current segment
%   (sigmap in signal.c), rescaling them with the rounding rule of C.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

WFDB_INVALID_SAMPLE = -32768;
WFDB_SAMPLE_MIN = -2147483648;  % INT_MIN
WFDB_SAMPLE_MAX = 2147483647;   % INT_MAX

S = wfdbx.internal.sig_state();
smi = S.smi;
tspf = S.tspf;
idx = [smi(1:tspf).index] + 1;
scale = [smi(1:tspf).scale];
offset = [smi(1:tspf).offset];
so = [smi(1:tspf).sample_offset];
x = ivec(idx);
v = x .* scale + offset;
out = zeros(1, tspf);
for i = 1:tspf
    if x(i) == WFDB_INVALID_SAMPLE
        out(i) = WFDB_INVALID_SAMPLE;
    elseif so(i) ~= 0
        r = fix(v(i)) + so(i);
        out(i) = r - 4294967296 * floor((r + 2147483648) / 4294967296);   % (int)
    elseif v(i) >= 0
        if v(i) <= WFDB_SAMPLE_MAX
            out(i) = fix(v(i));
        else
            out(i) = WFDB_SAMPLE_MAX;
        end
    elseif v(i) >= WFDB_SAMPLE_MIN
        out(i) = floor(v(i));
    else
        out(i) = WFDB_SAMPLE_MIN;
    end
end
end
