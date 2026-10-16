function stat = flac_putsamps(v, fmt, og)
%FLAC_PUTSAMPS Append many samples to a FLAC output group.
%   STAT = wfdbx.internal.flac_putsamps(V, FMT, OG) has exactly the effect
%   of calling wfdbx.internal.flac_putsamp(V(k), FMT, OG) for each element
%   of V in turn (the samples in WFDB frame order).  Returns 0.

% Original C implementation: the FLAC support of lib/signal.c, written by
% Benjamin Moody (2020); lib/signal.c is Copyright (C) 1989-2013 George
% B. Moody.
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

fo = og.flac;
v = reshape(v, 1, []);
switch fmt
    case 508
        v = mod(v + 128, 256) - 128;
    case 516
        v = mod(v + 32768, 65536) - 32768;
    case 524
        v = mod(v + 8388608, 16777216) - 8388608;
end
spf = fo.spf;
fl = numel(fo.pend);
s = [fo.pend(1:fo.np), v];
nfr = floor(numel(s) / fl);
if nfr > 0
    X = reshape(s(1:nfr*fl), spf, fo.nsig, nfr);
    X = reshape(permute(X, [2 1 3]), fo.nsig, spf * nfr);
    fo.cbuf = [fo.cbuf(:, 1:fo.nbuf), X];
    fo.nbuf = fo.nbuf + spf * nfr;
    while fo.nbuf >= 4096
        fo = wfdbx.internal.flac_writeblock(og, fo, 4096);
    end
    r = s(nfr*fl+1:end);
else
    r = s;
end
fo.np = numel(r);
fo.pend(1:fo.np) = r;
og.flac = fo;
stat = 0;
end
