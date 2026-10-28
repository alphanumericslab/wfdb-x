function status = wfdbx_bench(op, datadir, reps)
%WFDBX_BENCH Benchmark driver for the MATLAB/Octave implementation of WFDB-x.
%   STATUS = wfdbx_bench(OP, DATADIR, REPS) runs the operation OP on the
%   records of DATADIR: one timed call, then REPS timed calls.  It prints
%   one JSON line on the standard output:
%
%     {"op": OP, "first": S, "best": S, "times": [S, ...], "check": C}
%
%   (times in seconds; C, a check value of the first call).  STATUS is 0,
%   or 2 for an unknown OP.  See benchmarks/README.md for the operations.
%   The matlab/ folder of WFDB-x must be on the path.  Works in MATLAB and
%   in Octave (benchmarks/matlab/bench.m runs it from the shell).
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if ischar(reps)
    reps = str2double(reps);
end
ops = {'read_long', 'read_long_phys', 'read_mimic', 'read_wide', ...
       'write_long', 'read_ann', 'write_ann'};
if ~any(strcmp(op, ops))
    fprintf(2, 'unknown operation %s\n', op);
    status = 2;
    return;
end
wfdbx.wfdbx_set_input_dir(datadir);
out = tempname();
mkdir(out);
cleanup = onCleanup(@() remove_dir(out));
src = [];
ann = [];
if strcmp(op, 'write_long')
    src = wfdbx.read_record('long');
elseif strcmp(op, 'write_ann')
    ann = wfdbx.read_annotations('long', 'atr');
end
t = tic();
check = run(op, out, src, ann);
first = toc(t);
times = zeros(1, reps);
for k = 1:reps
    t = tic();
    run(op, out, src, ann);
    times(k) = toc(t);
end
if strcmp(op, 'read_long_phys')
    c = sprintf('%.3f', check);
else
    c = sprintf('%d', check);
end
fprintf('{"op": "%s", "first": %s, "best": %s, "times": [%s], "check": %s}\n', ...
    op, num(first), num(min(times)), ...
    strjoin(arrayfun(@num, times, 'UniformOutput', false), ', '), c);
status = 0;
end

function check = run(op, out, src, ann)
% One call of the operation OP; CHECK is its check value.  The sums are
% exact in double precision (fewer than 2^53 in magnitude).
switch op
    case 'read_long'
        x = wfdbx.read_record('long');
        check = sum(x.signals(:));
    case 'read_long_phys'
        x = wfdbx.read_record('long', 'physical', true);
        v = x.signals(:);
        check = round(sum(v(~isnan(v))) * 1000) / 1000;
    case 'read_mimic'
        x = wfdbx.read_record('mimic');
        check = sum(x.signals(:));
    case 'read_wide'
        x = wfdbx.read_record('wide');
        check = sum(x.signals(:));
    case 'write_long'
        wfdbx.write_record('out', src.signals, src.fs, 'fmt', 16, ...
            'gains', src.gains, 'adcres', 16, 'units', src.units, 'dir', out);
        check = file_size(fullfile(out, 'out.dat'));
    case 'read_ann'
        a = wfdbx.read_annotations('long', 'atr');
        check = numel(a.samples);
    case 'write_ann'
        wfdbx.write_annotations('out', 'atr', ann.samples, 'codes', ann.codes, ...
            'aux', ann.aux, 'dir', out);
        check = file_size(fullfile(out, 'out.atr'));
end
end

function n = file_size(path)
d = dir(path);
n = d.bytes;
end

function s = num(x)
% A time in seconds as a JSON number.
s = sprintf('%.9f', x);
end

function remove_dir(d)
if exist('OCTAVE_VERSION', 'builtin')
    confirm_recursive_rmdir(false);
end
if exist(d, 'dir')
    rmdir(d, 's');
end
end
