function stat = flac_isopen(ig, hs, ns)
%FLAC_ISOPEN Prepare to read a FLAC signal group (flac_isopen in signal.c).
%   STAT = wfdbx.internal.flac_isopen(IG, HS, NS) is called by isigopen
%   for an input group IG (a wfdbx.internal.IGData whose fp is open) of
%   format 508, 516 or 524 with NS signals described by HS (the 1-by-NS
%   struct array of header data, fields info.fmt and info.spf).  It checks
%   that the group can be stored in a FLAC file, sets IG.flac to the
%   decoder state and IG.count to 0, and returns 0 (or -1 after an error
%   message).  The stream is decoded one FLAC frame at a time, as it is
%   read (flac_getsamp, flac_getsamps, flac_isseek).
%
%   IG.flac is a structure: nsig, datb (8, 16 or 24), spf, dec (the
%   decoder, wfdbx.internal.flac_decoder, created on the first read),
%   samples (the samples decoded, in WFDB frame order: for each frame, spf
%   samples of each signal in turn; complete frames only), len (their
%   number: samples may have more elements), pos (the number of them
%   already returned), partial (the samples of an incomplete
%   frame, one row per signal, or []), skip (samples to discard after a
%   seek), pending (a failure found by decoding ahead, or []: see
%   wfdbx.internal.flac_refill).
%
%   See also wfdbx.internal.flac_getsamp, wfdbx.internal.flac_isseek.
%
%   Translation of the C function flac_isopen() (lib/signal.c, WFDB 10.7.0).

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
fi.dec = [];
fi.samples = zeros(1, 0);
fi.len = 0;
fi.pos = 0;
fi.partial = [];
fi.skip = 0;
fi.pending = [];
ig.flac = fi;
ig.count = 0;
stat = 0;
end
