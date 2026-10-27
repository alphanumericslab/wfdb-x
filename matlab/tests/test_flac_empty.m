function test_flac_empty()
%TEST_FLAC_EMPTY FLAC output closed before any sample is written.
%   An output group can be closed before any sample has been written (an
%   empty record, or a specification reopened before writing).  Closing it
%   computes the MD5 signature of no data, and must leave no output state
%   behind, so that a later wfdbquit does not fail again.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It tests wfdb-x; it has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

assert_eq(hex(wfdbx.internal.md5(zeros(1, 0, 'uint8'))), ...
    'd41d8cd98f00b204e9800998ecf8427e', 'md5 of no data');
assert_eq(hex(wfdbx.internal.md5_pure(zeros(1, 0, 'uint8'))), ...
    'd41d8cd98f00b204e9800998ecf8427e', 'md5_pure of no data');

old = pwd();
d = tempname();
mkdir(d);
cd(d);
cleanup = onCleanup(@() leave(old, d)); %#ok<NASGU>

% an empty format-516 record, written by the high-level function
wfdbx.write_record('empty', zeros(0, 2), 360, 'fmt', 516, ...
    'gains', 200, 'adcres', 16, 'units', 'mV');
wfdbx.wfdbquit();               % (no error: nothing is left to close)
r = wfdbx.read_record('empty');
assert_eq(size(r.signals, 1), 0, 'empty FLAC record read back');
wfdbx.wfdbquit();

% an output specification reopened before any sample is written
si = wfdbx.siginfo(1);
si(1).fname = 'reopen.dat';
si(1).fmt = 516;
si(1).gain = 200;
si(1).adcres = 16;
si(1).units = 'mV';
assert_eq(wfdbx.osigfopen(si, 1), 1, 'first osigfopen');
assert_eq(wfdbx.osigfopen(si, 1), 1, 'osigfopen again (closes the first)');
wfdbx.wfdbquit();
end

function s = hex(b)
s = lower(reshape(dec2hex(b, 2)', 1, []));
end

function leave(old, d)
wfdbx.wfdbquit();
cd(old);
rmdir(d, 's');
end
