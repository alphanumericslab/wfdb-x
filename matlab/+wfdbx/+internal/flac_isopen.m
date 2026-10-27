function stat = flac_isopen(ig, hs, ns)
%FLAC_ISOPEN Prepare to read a FLAC signal group (flac_isopen in signal.c).
%   STAT = wfdbx.internal.flac_isopen(IG, HS, NS) is called by isigopen
%   for an input group IG (a wfdbx.internal.IGData whose fp is open) of
%   format 508, 516 or 524 with NS signals described by HS (the 1-by-NS
%   struct array of header data, fields info.fmt and info.spf).  It checks
%   that the group can be stored in a FLAC file, sets IG.flac to the
%   decoder state and IG.count to 0, and returns 0 (or -1 after an error
%   message).  The stream is decoded on the first read (flac_getsamp,
%   flac_getsamps, flac_isseek).
%
%   IG.flac is a structure: nsig, datb (8, 16 or 24), spf, decoded,
%   error ('' or the decoding error status), arr (the decoded samples, one
%   row per signal), total (samples per signal), samples (the samples from
%   the current position, in WFDB frame order: for each frame, spf samples
%   of each signal in turn), pos (number of them already returned),
%   leftover (samples at the end that do not fill a frame), md5_check,
%   md5 (from STREAMINFO), decoded_md5, seeked.
%
%   See also wfdbx.internal.flac_getsamp, wfdbx.internal.flac_isseek.
%
%   Translation of the C function flac_isopen() (lib/signal.c, WFDB 10.7.0).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
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

if ns > 8                               % FLAC__MAX_CHANNELS
    wfdbx.internal.wfdb_error( ...
        'isigopen: cannot store %u signals in a single FLAC file\n', ns);
    stat = -1;
    return;
end
for i = 2:ns
    if hs(i).info.spf ~= hs(1).info.spf
        wfdbx.internal.wfdb_error(['isigopen: every signal in a FLAC file must have\n' ...
            '  the same sampling frequency\n']);
        stat = -1;
        return;
    end
end
fi.nsig = ns;
fi.datb = hs(1).info.fmt - 500;         % bits per sample (formats 508, 516, 524)
fi.spf = hs(1).info.spf;
fi.decoded = false;
fi.error = '';
fi.arr = [];
fi.total = 0;
fi.samples = zeros(1, 0);
fi.pos = 0;
fi.leftover = 0;
fi.md5_check = ~isempty(wfdbx.internal.cgetenv('WFDB_FLAC_CHECK_MD5'));
fi.md5 = [];
fi.decoded_md5 = [];
fi.seeked = false;
% State of the libFLAC decoder of the C library, which decodes one FLAC
% block at a time: the end of each block (in samples per channel), the end
% of the blocks decoded so far, the sample from which fi.samples starts,
% whether the buffered samples were discarded by a failed seek, and whether
% decoding was aborted (after a failed seek, iflac_samples() aborts the
% decoding of the next block, and libFLAC then refuses to seek).
fi.block_ends = zeros(1, 0);
fi.dec_end = 0;
fi.base = 0;
fi.discarded = false;
fi.aborted = false;
ig.flac = fi;
ig.count = 0;
stat = 0;
end
