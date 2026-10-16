function stat = flac_putsamp(v, fmt, og)
%FLAC_PUTSAMP Append a sample to a FLAC output group (flac_putsamp).
%   STAT = wfdbx.internal.flac_putsamp(V, FMT, OG) adds the sample V
%   (wrapped to 8, 16 or 24 bits for format FMT 508, 516 or 524) to the
%   output group OG.  Samples come in WFDB frame order (for each frame,
%   spf samples of each signal of the group in turn); frames of 4096
%   samples per signal are encoded and written as they fill.  Returns 0.
%
%   See also wfdbx.internal.flac_putsamps (many samples at once).

% Original C implementation: the FLAC support of lib/signal.c, written by
% Benjamin Moody (2020); lib/signal.c is Copyright (C) 1989-2013 George
% B. Moody.
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

fo = og.flac;
switch fmt
    case 508
        v = mod(v + 128, 256) - 128;
    case 516
        v = mod(v + 32768, 65536) - 32768;
    case 524
        v = mod(v + 8388608, 16777216) - 8388608;
end
np = fo.np + 1;
fo.pend(np) = v;
if np == numel(fo.pend)
    spf = fo.spf;
    fo.cbuf(:, fo.nbuf+1:fo.nbuf+spf) = reshape(fo.pend, spf, fo.nsig)';
    fo.nbuf = fo.nbuf + spf;
    np = 0;
    if fo.nbuf >= 4096
        fo = wfdbx.internal.flac_writeblock(og, fo, 4096);
    end
end
fo.np = np;
og.flac = fo;
stat = 0;
end
