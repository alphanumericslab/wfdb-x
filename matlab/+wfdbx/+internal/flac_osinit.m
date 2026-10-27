function stat = flac_osinit(og, si, ns)
%FLAC_OSINIT Prepare to write a FLAC signal group (flac_osinit).
%   STAT = wfdbx.internal.flac_osinit(OG, SI, NS) is called by osigfopen
%   for an output group OG (a wfdbx.internal.OGData) of format 508, 516
%   or 524 with NS signals described by SI (1-by-NS siginfo structures).
%   It checks that the group can be stored in a FLAC file, sets OG.flac
%   to the encoder state and OG.bsize, and returns 0 (or -1 after an
%   error message).  OG.fp is opened afterwards, then flac_osopen is
%   called.
%
%   OG.flac is a structure: nsig, bps, spf, pend/np (samples of the
%   current frame), cbuf/nbuf (samples not yet encoded, one row per
%   signal), frame_no, total, minfs, maxfs, md5data (the bytes whose MD5
%   signature is recorded), header_pos.
%
%   See also wfdbx.internal.flac_putsamp, wfdbx.internal.flac_osclose.
%
%   Translation of the C function flac_osinit() (lib/signal.c, WFDB 10.7.0).

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
        'osigfopen: cannot store %u signals in a single FLAC file\n', ns);
    stat = -1;
    return;
end
for i = 2:ns
    if si(i).spf ~= si(1).spf
        wfdbx.internal.wfdb_error(['osigfopen: every signal in a FLAC file must have\n' ...
            '  the same sampling frequency\n']);
        stat = -1;
        return;
    end
end
spf = si(1).spf;
fo.nsig = ns;
fo.bps = si(1).fmt - 500;               % bits per sample (formats 508, 516, 524)
fo.spf = spf;
fo.pend = zeros(1, ns * spf);
fo.np = 0;
fo.cbuf = zeros(ns, 4096 + spf);
fo.nbuf = 0;
fo.frame_no = 0;
fo.total = 0;
fo.minfs = [];
fo.maxfs = 0;
fo.md5data = zeros(1, 0, 'uint8');
fo.md5len = 0;
fo.header_pos = 0;
og.flac = fo;
og.bsize = ns * spf * 4;
stat = 0;
end
