function test_bulk_read()
%TEST_BULK_READ The bulk reader gives the results of the per-frame path.
%   Multi-frequency records, multi-segment records (fixed and variable
%   layout, null segments) and the test records are read with read_record
%   with the bulk reader (wfdbx.internal.bulk_frames) on and off, and
%   getframes is mixed with getvec and isigsettime: the samples, statuses
%   and library state are the same.  The signal names of the high-level
%   readers have no white space at their ends.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It tests WFDB-x; it has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

here = fileparts(mfilename('fullpath'));
data = fullfile(fileparts(fileparts(here)), 'tests', 'data');
old = pwd();
d = tempname();
mkdir(d);
S = wfdbx.internal.sig_state();
ibsize = S.ibsize;
cleanup = onCleanup(@() restore(old, d, ibsize)); %#ok<NASGU>
cd(d);
wfdbx.wfdbquit();
copyfile(fullfile(data, '*'), d);   % (read from the current directory)

bulk_read_multifrequency();
bulk_read_multisegment();
bulk_multifrequency_interleaved(false);
bulk_multifrequency_interleaved(true);
names_without_spaces();
bulk_read_test_records(data);
end

function bulk_read_multifrequency()
% Records of several sampling frequencies are read in blocks: the same
% samples as frame by frame, in low- and high-resolution modes.  (The
% records are shorter than in the Python tests, as Octave reads them frame
% by frame slowly; small input buffers make them span many.)
S = wfdbx.internal.sig_state();
ibsize = S.ibsize;
S.ibsize = 1000;
fmts = [8 16 61 80 160 212 310 311 24 32];
spfs = {[4 1 1 1], [2 3], [1 2], [8 1], [3 3 1]};
for fmt = fmts
    r = wfdbx.internal.GlibcRand(fmt + 1);
    for k = 1:numel(spfs)
        spf = spfs{k};
        n = 400 + mod(r.rand(), 240);
        mf_record('m', r, fmt, spf, n, 200, {});
        what = sprintf('format %d, spf %s', fmt, mat2str(spf));
        modes = mf_modes();
        for j = 1:numel(modes)
            read_both('m', modes{j}, sprintf('%s, mode %d', what, j));
        end
        % (all but the frames near the end are read in blocks)
        [rows, bulk] = bulk_rows('m', {'highres', true});
        assert_true(rows - bulk <= 4 * max(spf), ['read in blocks: ' what]);
    end
end
S.ibsize = ibsize;
end

function bulk_read_multisegment()
% Multi-segment records, of fixed and of variable layout (with signals
% missing from some segments, other gains, and null segments), are read in
% blocks: the same samples as frame by frame.
r = wfdbx.internal.GlibcRand(11);
names = {'ECG', 'ABP', 'RESP'};
% fixed layout
segs = write_segments('fx', r, 212, [4 1 1], [900 701 1200], 200, names);
write_text('fx.hea', sprintf('fx/3 3 250 %d\n%s', 2801, seg_lines(segs)));
modes = [mf_modes(), {{'sampfrom', 899, 'sampto', 1602}}];
for j = 1:numel(modes)
    read_both('fx', modes{j}, sprintf('fixed layout, mode %d', j));
end
a = wfdbx.read_record('fx');
assert_eq(size(a.signals), [2801 3], 'fixed layout: size');
[rows, bulk] = bulk_rows('fx', {});
assert_true(rows - bulk <= 2 * 3, 'fixed layout: read in blocks');
% variable layout
write_text('vl_0.hea', ['vl_0 3 250 0' char(10) ...
    '~ 0x4 400(10)/mV 12 0 0 0 0 ECG' char(10) ...
    '~ 0 100/mV 16 0 0 0 0 ABP' char(10) ...
    '~ 0 50/mV 16 0 0 0 0 RESP' char(10)]);
s1 = write_segments('va', r, 16, [4 1 1], 500, [400 100 50], names);
s2 = write_segments('vb', r, 16, [1 4], 603, [25 200], {'RESP', 'ECG'});
s3 = write_segments('vc', r, 212, 1, 400, 100, {'ABP'});
segs = [{'vl_0', 0}; s1; {'~', 250}; s2; s3];
write_text('vl.hea', sprintf('vl/%d 3 250 %d\n%s', size(segs, 1), ...
    1753, seg_lines(segs)));
wfdbx.wfdbquiet();
modes = [mf_modes(), {{'sampfrom', 499, 'sampto', 900}}];
for j = 1:numel(modes)
    read_both('vl', modes{j}, sprintf('variable layout, mode %d', j));
end
[rows, bulk] = bulk_rows('vl', {});
assert_true(rows - bulk <= 2 * 6, 'variable layout: read in blocks');
wfdbx.wfdbverbose();
a = wfdbx.read_record('vl', 'physical', true);
assert_eq(size(a.signals), [1753 3], 'variable layout: size');
assert_true(all(all(isnan(a.signals(501:750, :)))), 'the null segment');
end

function bulk_read_test_records(data)
% Every test record of the repository (except 8 and 16, read from the
% standard input): the same samples in blocks as frame by frame, in every
% reading mode.
d = dir(fullfile(data, '*.hea'));
modes = {{}, {'pad', true}, {'highres', true}, ...
    {'highres', true, 'pad', true}, {'sampfrom', 3}};
wfdbx.wfdbquiet();
for k = 1:numel(d)
    rec = d(k).name(1:end - 4);
    if any(strcmp(rec, {'8', '16'}))
        continue;
    end
    for j = 1:numel(modes)
        read_both(rec, modes{j}, sprintf('record %s, mode %d', rec, j));
    end
end
wfdbx.wfdbverbose();
end

function bulk_multifrequency_interleaved(hr)
% getframes (bulk) mixed with getvec and isigsettime on a multi-frequency
% record, in high resolution also from the middle of a frame: the same
% vectors, statuses and library state as getvec alone.
r = wfdbx.internal.GlibcRand(5);
mf_record('mf', r, 212, [4 1 3], 5001, 200, {});
if hr
    mode = 1 + 2;       % WFDB_HIGHRES | WFDB_GVPAD
else
    mode = 2;           % WFDB_LOWRES | WFDB_GVPAD
end
steps = {'f', 999; 'v', 3; 'f', 4097; 't', 17; 'v', 1; 'f', 9001; ...
    'v', 2; 't', 30; 'f', 200000};
S = wfdbx.internal.sig_state();
out = cell(1, 2);
for b = 1:2
    S.bulk_read = b == 1;
    assert_eq(wfdbx.isigopen('mf', 3), 3, 'isigopen');
    wfdbx.setgvmode(mode);
    got = {};
    for k = 1:size(steps, 1)
        m = steps{k, 2};
        switch steps{k, 1}
            case 'f'
                [x, stat] = wfdbx.getframes(m);
                got{end + 1} = {x, stat}; %#ok<AGROW>
            case 'v'
                for i = 1:m
                    [stat, v] = wfdbx.getvec();
                    got{end + 1} = {stat, v}; %#ok<AGROW>
                end
            otherwise
                got{end + 1} = wfdbx.isigsettime(m); %#ok<AGROW>
        end
        isd = S.isd;
        info = [isd.info];
        got{end + 1} = {S.istime, [isd.samp], [info.cksum], [info.nsamp], ...
            S.gvc}; %#ok<AGROW>
    end
    wfdbx.wfdbquit();
    out{b} = got;
end
S.bulk_read = true;
wfdbx.setgvmode(0);
assert_eq(out{1}, out{2}, sprintf('interleaved reads (highres %d)', hr));
end

function names_without_spaces()
% Descriptions that end (or begin) with white space in the header are
% given without it by the high-level readers, and found by that name; the
% C-style functions keep it, as in C.
write_text('sp.hea', ['sp 3 250 4' char(10) ...
    'fmt16.dat 16 200/mV 16 0 0 0 0 III ' char(10) ...
    'fmt16.dat 16 200/mV 16 0 0 0 0 ABP' char(9) ' ' char(10) ...
    'fmt16.dat 16 200/mV 16 0 0 0 0 PLETH' char(10)]);
want = {'III', 'ABP', 'PLETH'};
for legacy = [false true]
    r = wfdbx.read_record('sp', 'legacy', legacy, 'checksum_warning', false);
    assert_eq(r.names, want, 'read_record names');
    assert_eq({r.siginfo.desc}, want, 'read_record siginfo desc');
    h = wfdbx.read_header('sp', 'legacy', legacy);
    assert_eq({h.siginfo.desc}, want, 'read_header siginfo desc');
    r2 = wfdbx.read_record('sp', 'channels', {'ABP', 'III ', 2}, ...
        'checksum_warning', false);
    assert_eq(r2.names, {'ABP', 'III', 'PLETH'}, 'channels by name');
    assert_eq(r2.signals, r.signals(:, [2 1 3]), 'channels by name: samples');
end
[n, si] = wfdbx.isigopen('sp', 3);
assert_eq(n, 3, 'isigopen');
assert_eq({si.desc}, {'III ', ['ABP' char(9) ' '], 'PLETH'}, 'isigopen desc');
wfdbx.wfdbquit();
end

% --- helpers

function modes = mf_modes()
modes = {{}, {'pad', true}, {'highres', true}, ...
    {'highres', true, 'pad', true}, {'physical', true}, ...
    {'sampfrom', 123}, {'sampfrom', 7, 'sampto', 300}, ...
    {'highres', true, 'sampfrom', 3, 'sampto', 1001}, ...
    {'channels', [1 0 1]}};
end

function x = mf_record(name, r, fmt, spf, n, gains, names)
% A random multi-frequency record (SPF: samples per frame of each signal;
% N frames), with invalid samples; returns its frames.
ranges = [8 1000 12; 16 32767 16; 61 32767 16; 80 127 8; 160 32767 16; ...
    212 2047 12; 310 511 10; 311 511 10; 24 8388607 24; 32 2147483647 32];
k = find(ranges(:, 1) == fmt);
hi = ranges(k, 2);
cols = sum(spf);
u = reshape(r.rand(n * cols), n, cols) / wfdbx.internal.GlibcRand.RAND_MAX;
if fmt == 8
    x = cumsum(floor(u * 121) - 60);
else
    x = floor(u * (2 * hi)) - hi + 1;
    w = reshape(r.rand(n * cols), n, cols) / wfdbx.internal.GlibcRand.RAND_MAX;
    x(w < 0.01) = -32768;       % WFDB_INVALID_SAMPLE
    x(1:2, 1) = -32768;
end
opts = {'fmt', fmt, 'gains', gains, 'adcres', ranges(k, 3), 'units', 'mV', ...
    'samps_per_frame', spf};
if ~isempty(names)
    opts = [opts, {'names', names}];
end
wfdbx.write_record(name, x, 250, opts{:});
end

function segs = write_segments(name, r, fmt, spf, lens, gains, names)
segs = cell(numel(lens), 2);
for k = 1:numel(lens)
    seg = sprintf('%s_%d', name, k);
    mf_record(seg, r, fmt, spf, lens(k), gains, names);
    segs(k, :) = {seg, lens(k)};
end
end

function s = seg_lines(segs)
s = '';
for k = 1:size(segs, 1)
    s = [s sprintf('%s %d\n', segs{k, 1}, segs{k, 2})]; %#ok<AGROW>
end
end

function read_both(rec, opts, what)
% read_record with the bulk path, and with the per-frame path only: the
% same results (or the same error).
S = wfdbx.internal.sig_state();
[a, ea] = try_read(rec, opts);
S.bulk_read = false;
on = onCleanup(@() set_bulk(S)); %#ok<NASGU>
[b, eb] = try_read(rec, opts);
S.bulk_read = true;
assert_eq(ea, eb, [what ' (error)']);
if isempty(ea)
    assert_eq(size(a.signals), size(b.signals), [what ' (size)']);
    assert_true(isequaln(a.signals, b.signals), [what ' (samples)']);
    assert_eq(a.checksum_ok, b.checksum_ok, [what ' (checksum)']);
end
end

function [r, e] = try_read(rec, opts)
r = [];
e = '';
w = warning('off', 'wfdbx:checksum');
try
    r = wfdbx.read_record(rec, opts{:});
catch err
    e = err.message;
end
warning(w);
end

function [rows, bulk] = bulk_rows(rec, opts)
% (rows read by read_record, rows of them read in blocks)
S = wfdbx.internal.sig_state();
S.bulk_vectors = 0;
r = wfdbx.read_record(rec, opts{:});
rows = size(r.signals, 1);
bulk = S.bulk_vectors;
end

function set_bulk(S)
S.bulk_read = true;
end

function write_text(name, s)
fid = fopen(name, 'wb');
fwrite(fid, uint8(s));
fclose(fid);
end

function restore(old, d, ibsize)
wfdbx.wfdbquit();
wfdbx.wfdbverbose();
S = wfdbx.internal.sig_state();
S.bulk_read = true;
S.ibsize = ibsize;
cd(old);
if isfolder(d)
    rmdir(d, 's');
end
end

function assert_true(c, what)
if ~c
    error('wfdbx:test', '%s: failed', what);
end
end
