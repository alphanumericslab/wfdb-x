function ok = flac_samples(ig, chans, bps)
%FLAC_SAMPLES Store a block of decoded samples (iflac_samples).
%   OK = wfdbx.internal.flac_samples(IG, CHANS, BPS) is called by the
%   decoder of the FLAC input group IG (wfdbx.internal.flac_decoder) for
%   each block of samples it decodes: CHANS has one row per channel, and
%   BPS is the number of bits per sample of the frame.  The samples are
%   appended to IG.flac.samples in WFDB frame order (spf samples of each
%   signal in turn; the samples of an incomplete frame wait in
%   IG.flac.partial), after the samples to skip after a seek.  A frame
%   with a number of channels other than the number of signals of the
%   group, or with more bits per sample than its format, is an error
%   (with a message; IG.stat is set to -2).  OK is false, which makes the
%   decoder abort, after an error (also after an earlier one: IG.stat
%   negative).
%
%   Translation of the C function iflac_samples() (lib/signal.c, WFDB
%   10.7.0).

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

fi = ig.flac;
ig.flac = [];       % (fi.samples is then modified in place)
if size(chans, 1) ~= fi.nsig
    wfdbx.internal.wfdb_error( ...
        'getvec: wrong number of signals in FLAC signal file\n');
    ig.stat = -2;
end
if bps > fi.datb
    wfdbx.internal.wfdb_error( ...
        'getvec: wrong sample resolution in FLAC signal file\n');
    ig.stat = -2;
end
ok = ig.stat >= 0;
if ~ok
    ig.flac = fi;
    return;
end
n = size(chans, 2);
if fi.skip > n
    fi.skip = fi.skip - n;
    ig.flac = fi;
    return;
end
if fi.skip
    chans = chans(:, fi.skip+1:end);
    fi.skip = 0;
end
if fi.pos
    fi.samples(1:fi.len-fi.pos) = fi.samples(fi.pos+1:fi.len);
    fi.len = fi.len - fi.pos;
    fi.pos = 0;
end
spf = fi.spf;
if spf == 1 && isempty(fi.partial)
    x = reshape(chans, 1, []);
else
    if ~isempty(fi.partial)
        chans = [fi.partial, chans];
        fi.partial = [];
    end
    nch = size(chans, 1);
    n = size(chans, 2);
    nfr = floor(n / spf);
    % for each frame, the spf samples of each channel in turn
    Y = reshape(chans(:, 1:nfr*spf)', spf, nfr, nch);
    x = reshape(permute(Y, [1 3 2]), 1, []);
    if n > nfr * spf
        fi.partial = chans(:, nfr*spf+1:end);
    end
end
% (appended to fi.samples, whose capacity is doubled when needed)
m = fi.len + numel(x);
if m > numel(fi.samples)
    fi.samples(max(m, 2 * numel(fi.samples))) = 0;
end
fi.samples(fi.len+1:m) = x;
fi.len = m;
ig.flac = fi;
end
