function D = flac_dec_open(ig)
%FLAC_DEC_OPEN The FLAC decoder of an input group.
%   D = wfdbx.internal.flac_dec_open(IG) creates the decoder
%   (wfdbx.internal.flac_decoder) of the FLAC input group IG, on the
%   first read: it reads the whole signal file (IG.fp), which can be
%   positioned unless the header gives a negative block size (IG.seek);
%   the decoded samples go to IG (wfdbx.internal.flac_samples).  The MD5
%   signature of the samples is computed if the environment variable
%   WFDB_FLAC_CHECK_MD5 is set.
%
%   Part of the translation of the FLAC support of lib/signal.c (WFDB
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
% Changes from the original: the stream is decoded by WFDB-x's translation of
% libFLAC's stream decoder (wfdbx.internal.flac_decoder) instead of by libFLAC. Each change is marked "WFDB-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
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

% WFDB-x: WFDB-x's decoder (a port of libFLAC's stream decoder)
opt.seekable = ig.seek ~= 0;
opt.md5 = ~isempty(wfdbx.internal.cgetenv('WFDB_FLAC_CHECK_MD5'));
opt.ig = ig;
D = wfdbx.internal.flac_decoder('new', ig.fp.readall(), opt);
end
