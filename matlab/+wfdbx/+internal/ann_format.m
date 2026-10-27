function istat = ann_format(D)
%ANN_FORMAT The format of an input annotation file.
%   ISTAT = wfdbx.internal.ann_format(D) returns the format of the
%   annotation file whose bytes are D (a uint8 row): 0 (WFDB_READ, MIT
%   format) or 2 (WFDB_AHA_READ), guessed as annopen does from the first
%   16-bit word (read as C's 16-bit getc() pair: a missing byte reads as
%   EOF, 0xff): an AHA file starts with a null byte followed by an AHA code
%   other than '[' or ']'.  (wfdb-x: this was part of annopen; the sorting
%   of output files, wfdbx.internal.ann_sortfile, uses it too.)
%
%   Part of the translation of lib/annot.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/annot.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: taken out of annopen() so that ann_sortfile can
% use it. Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md
% gives the reasons.
%
% Original C code: lib/annot.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

NOTQRS = 0;         % lib/ecgcodes.h
if numel(D) >= 2
    w = double(D(1)) + 256 * double(D(2));
elseif numel(D) == 1
    w = double(D(1)) + 256 * 255;
else
    w = 65535;
end
a = floor(w / 256);
if mod(w, 256) ~= 0 || wfdbx.ammap(a) == NOTQRS || a == '[' || a == ']'
    istat = 0;      % WFDB_READ
else
    istat = 2;      % WFDB_AHA_READ
end
end
