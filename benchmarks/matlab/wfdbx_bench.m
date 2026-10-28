function status = wfdbx_bench(op, datadir, reps)
%WFDBX_BENCH Benchmark driver for the MATLAB/Octave implementation of WFDB-x.
%   STATUS = wfdbx_bench(OP, DATADIR, REPS) runs the operation OP on the
%   records of DATADIR: one timed call, then REPS timed calls.  It prints
%   one JSON line on the standard output:
%
%     {"op": OP, "first": S, "best": S, "times": [S, ...], "check": C}
%
%   (times in seconds; C, a check value of the first call).  If the
%   environment variable WFDBX_BENCH_DUMP is set (not empty), the result of
%   the first call is saved in that directory (outside the timed calls).
%   STATUS is 0,
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
dump = getenv('WFDBX_BENCH_DUMP');
t = tic();
result = run(op, out, src, ann);
first = toc(t);
check = check_value(op, out, result);
if ~isempty(dump)
    save_result(op, out, result, fullfile(dump, op));
end
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

function x = run(op, out, src, ann)
% One call of the operation OP; X is its result (the samples, the
% annotations, or [] for the writers).
x = [];
switch op
    case {'read_long', 'read_mimic', 'read_wide'}
        x = wfdbx.read_record(op(6:end));
        x = x.signals;
    case 'read_long_phys'
        x = wfdbx.read_record('long', 'physical', true);
        x = x.signals;
    case 'write_long'
        wfdbx.write_record('out', src.signals, src.fs, 'fmt', 16, ...
            'gains', src.gains, 'adcres', 16, 'units', src.units, 'dir', out);
    case 'read_ann'
        x = wfdbx.read_annotations('long', 'atr');
    case 'write_ann'
        wfdbx.write_annotations('out', 'atr', ann.samples, 'codes', ann.codes, ...
            'aux', ann.aux, 'dir', out);
end
end

function check = check_value(op, out, x)
% The check value of the result X of OP.  The sums are exact in double
% precision (fewer than 2^53 in magnitude).
switch op
    case {'read_long', 'read_mimic', 'read_wide'}
        check = sum(double(x(:)));
    case 'read_long_phys'
        v = x(:);
        check = round(sum(v(~isnan(v))) * 1000) / 1000;
    case 'write_long'
        check = file_size(fullfile(out, 'out.dat'));
    case 'read_ann'
        check = numel(x.samples);
    case 'write_ann'
        check = file_size(fullfile(out, 'out.atr'));
end
end

function save_result(op, out, x, p)
% Saves the result X of OP in the files P.* (little-endian): the samples
% frame by frame (row-major), the annotations, or copies of the files
% written.
switch op
    case {'read_long', 'read_mimic', 'read_wide'}
        write_file([p '.bin'], x.', 'int32');
    case 'read_long_phys'
        x(isnan(x)) = NaN;
        write_file([p '.bin'], x.', 'double');
    case 'write_long'
        copyfile(fullfile(out, 'out.hea'), [p '.hea']);
        copyfile(fullfile(out, 'out.dat'), [p '.dat']);
    case 'read_ann'
        % each annotation: time (int64), code, subtype, chan, num, the
        % length of the aux text (int32; -1 if none) and the aux text
        f = fopen([p '.ann'], 'w', 'ieee-le');
        for k = 1:numel(x.samples)
            a = x.aux{k};
            if ischar(a)
                b = uint8(double(a));
                n = numel(b);
            else
                b = uint8([]);
                n = -1;
            end
            fwrite(f, x.samples(k), 'int64');
            fwrite(f, [x.codes(k), x.subtypes(k), x.chans(k), x.nums(k), n], 'int32');
            fwrite(f, b, 'uint8');
        end
        fclose(f);
    case 'write_ann'
        copyfile(fullfile(out, 'out.atr'), [p '.atr']);
end
end

function write_file(path, x, precision)
f = fopen(path, 'w', 'ieee-le');
fwrite(f, x, precision);
fclose(f);
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
