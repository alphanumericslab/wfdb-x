function si = siginfo(n)
%SIGINFO A WFDB_Siginfo structure (signal information).
%   SI = wfdbx.siginfo() returns a structure with the fields of the C
%   WFDB_Siginfo structure, with their initial values:
%
%     fname    [] (NULL)  name of the signal file
%     desc     [] (NULL)  signal description
%     units    [] (NULL)  physical units ([] means millivolts)
%     gain     0          ADC units per physical unit (0: uncalibrated)
%     initval  0          initial value
%     group    0          signal group number
%     fmt      0          storage format (8, 16, 212, ...)
%     spf      1          samples per frame
%     bsize    0          block size
%     adcres   0          ADC resolution in bits
%     adczero  0          ADC output for zero input
%     baseline 0          ADC output for 0 physical units
%     nsamp    0          number of samples (0: unspecified)
%     cksum    0          16-bit checksum of the samples
%
%   SI = wfdbx.siginfo(N) returns a 1-by-N array of such structures.
%
%   See also wfdbx.isigopen, wfdbx.osigopen.
%
%   Translation of the C structure WFDB_Siginfo (lib/wfdb.h, WFDB 10.7.0):
%   same fields.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdb.h from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/wfdb.h, WFDB Software Package 10.7.0.
%   Copyright (C) 1983-2013 George B. Moody; revised 2010-2020 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    n = 1;
end
s = struct('fname', [], 'desc', [], 'units', [], 'gain', 0, ...
    'initval', 0, 'group', 0, 'fmt', 0, 'spf', 1, 'bsize', 0, ...
    'adcres', 0, 'adczero', 0, 'baseline', 0, 'nsamp', 0, 'cksum', 0);
si = repmat(s, 1, n);
end
