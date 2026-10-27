function stat = flac_osclose(og)
%FLAC_OSCLOSE Finish writing a FLAC output group (flac_osclose).
%   STAT = wfdbx.internal.flac_osclose(OG) encodes the remaining samples,
%   rewrites STREAMINFO (sample count, frame sizes and MD5 signature) if
%   OG.fp is seekable, and sets OG.flac to [] and OG.buf to an empty
%   buffer (the caller then closes OG.fp).  Returns 0.
%
%   Translation of the C function flac_osclose() (lib/signal.c, WFDB
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

fo = og.flac;
try
    while fo.nbuf > 0
        fo = wfdbx.internal.flac_writeblock(og, fo, min(fo.nbuf, 4096));
    end
    if ~isempty(og.fp) && og.fp.seek(fo.header_pos + 8, 0) == 0
        md5 = wfdbx.internal.md5(fo.md5data(1:fo.md5len));
        og.fp.write(wfdbx.internal.flac_streaminfo(fo, fo.total, md5));
        og.fp.seek(0, 2);
    end
catch err
    % (the group is closed even if finishing it failed, so that a later
    % wfdbquit does not try again)
    og.flac = [];
    og.buf = zeros(1, 0, 'uint8');
    rethrow(err);
end
og.flac = [];
og.buf = zeros(1, 0, 'uint8');
stat = 0;
end
