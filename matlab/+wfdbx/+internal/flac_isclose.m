function stat = flac_isclose(ig)
%FLAC_ISCLOSE Finish reading a FLAC input group (flac_isclose).
%   STAT = wfdbx.internal.flac_isclose(IG) checks, if the environment
%   variable WFDB_FLAC_CHECK_MD5 was set when the group was opened and the
%   whole stream was decoded without seeking, the MD5 signature of the
%   decoded samples against STREAMINFO ("isigclose: warning: incorrect MD5
%   hash in FLAC input", STAT -1); STAT is 0 otherwise.
%
%   Translation of the C function flac_isclose() (lib/signal.c, WFDB
%   10.7.0).

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

stat = 0;
fi = ig.flac;
if ~isempty(fi) && fi.md5_check && ~isempty(fi.md5) && ...
        ~isempty(fi.decoded_md5) && ~fi.seeked && any(fi.md5) && ...
        ~isequal(fi.md5, fi.decoded_md5)
    wfdbx.internal.wfdb_error('isigclose: warning: incorrect MD5 hash in FLAC input\n');
    stat = -1;
end
end
