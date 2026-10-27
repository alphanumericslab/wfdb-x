function oa = ann_oadata(f, name, ostat)
%ANN_OADATA A new output annotator structure (C's struct oadata).
%   OA = wfdbx.internal.ann_oadata(F, NAME, OSTAT) returns the output
%   annotator structure of the file F (a WFDBFile, just created) of
%   annotator NAME, in format OSTAT (1: MIT, 3: AHA).  Fields: file, name,
%   stat, rname and fname (the record name and the name of the file, set
%   by annopen), ann (the last annotation written), afreq (the time
%   resolution written), seqno (AHA serial number), out_of_order,
%   table_written, and the output buffer obuf (uint8) with its length
%   olen (see wfdbx.internal.ann_oflush).
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
% Changes from the original: none, apart from the language.
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

OBUFLEN = 4096;     % initial size of the output buffer (bytes)
oa.file = f;
oa.name = name;
oa.stat = ostat;
oa.rname = [];
oa.fname = [];
oa.ann = wfdbx.annotation();
oa.afreq = 0;
oa.seqno = 0;
oa.out_of_order = 0;
oa.table_written = 0;
oa.obuf = zeros(1, OBUFLEN, 'uint8');
oa.olen = 0;
end
