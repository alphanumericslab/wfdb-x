function r = expand_record(record)
%EXPAND_RECORD The record name as wfdb_open uses it.
%   R = wfdbx.internal.expand_record(RECORD) returns RECORD, except that a
%   name ending with '/' gets another copy of its final element
%   ('abc/123/' -> 'abc/123/123').  (wfdb-x: moved out of wfdb_open, for
%   wfdbx.internal.output_file.)
%
%   Part of the translation of lib/wfdbio.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: taken out of wfdb_open() so that output_file
% can use it. Each change is marked "wfdb-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
%
% Original C code: lib/wfdbio.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

rlen = numel(record);
r = record;
if rlen > 1 && record(rlen) == '/'
    p = rlen;           % 1-based index of the final '/'
    q = p - 1;
    while q > 1
        if record(q) == '/'
            q = q + 1;
            break;
        end
        q = q - 1;
    end
    if q < p
        r = [record record(q:p-1)];
    end
end
end
