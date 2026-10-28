function test_highlevel()
%TEST_HIGHLEVEL Tests of the high-level API (read_record, write_record,
%read_header, read_annotations, write_annotations).

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
oldpath = getenv('WFDB');
d = tempname();
mkdir(d);
cleanup = onCleanup(@() restore(old, oldpath, d)); %#ok<NASGU>
cd(d);
wfdbx.wfdbquit();
copyfile(fullfile(data, '*'), d);   % (read from the current directory)
INV = wfdbx.WFDB_INVALID_SAMPLE();

% --- MATLAB strings are accepted as text arguments (none in Octave)
assert_eq(wfdbx.internal.strarg({'a', 1}), {'a', 1}, 'strarg cell');
assert_eq(wfdbx.internal.strarg('100s'), '100s', 'strarg char');
if exist('string', 'builtin') || exist('string', 'class')
    assert_eq(wfdbx.internal.strarg(string('100s')), '100s', 'strarg string');
    assert_eq(wfdbx.internal.strarg({string('a'), 1}), {'a', 1}, 'strarg string cell');
    h = wfdbx.read_header(string('100s'));
    assert_eq(numel(h.siginfo), 2, 'read_header of a string');
end

% --- read_header
h = wfdbx.read_header('100s');
si = h.siginfo;
assert_eq(numel(si), 2, 'read_header nsig');
assert_eq({si.desc}, {'MLII', 'V5'}, 'read_header desc');
assert_eq([si.fmt], [212 212], 'read_header fmt');
assert_eq({h.name, h.fs, h.counter_freq, h.base_counter, h.nsamples, h.nsig}, ...
    {'100s', 360, 360, 0, 21600, 2}, 'read_header record fields');
assert_true(isempty(h.base_time) && isempty(h.base_time_ms) && ...
    isempty(h.base_date), 'read_header: no base time or date');
assert_true(iscell(h.comments) && size(h.comments, 2) == 1, ...
    'read_header comments');
assert_eq(h.comments{1}, ' 69 M 1085 1629 x1', 'read_header comment text');
h = wfdbx.read_header('vlay');      % (multi-segment: the master header)
assert_eq({h.fs, h.nsamples, h.nsig}, {250, 3201, 3}, ...
    'read_header of a multi-segment record');
wfdbx.wfdbquiet();
assert_error(@() wfdbx.read_header('nosuch'), 'read_header of a missing record');
wfdbx.wfdbverbose();

% --- read_record: whole record, selection, times
wfdbx.wfdbquiet();
r = wfdbx.read_record('100s');
wfdbx.wfdbverbose();
assert_eq(size(r.signals), [21600 2], 'read_record size');
assert_eq(r.fs, 360, 'read_record fs');
assert_eq(r.names, {'MLII', 'V5'}, 'read_record names');
assert_eq(r.gains, [200 200], 'read_record gains');
assert_eq(r.baselines, [1024 1024], 'read_record baselines');
assert_eq(r.signals(1, :), [995 1011], 'read_record first sample');
assert_eq(r.sampfrom, 0, 'read_record sampfrom');
assert_true(iscell(r.comments) && size(r.comments, 2) == 1 && ...
    ~isempty(r.comments), 'read_record comments');
assert_eq(r.comments{1}, ' 69 M 1085 1629 x1', 'read_record comment text');
s = wfdbx.read_record('100s', 'channels', {'V5'}, 'sampfrom', '0:1', ...
    'sampto', 400);
assert_eq(s.signals, r.signals(361:400, 2), 'channels by name, time string');
assert_eq(s.sampfrom, 360, 'sampfrom from a time string');
s = wfdbx.read_record('100s', 'channels', [1 0], 'sampto', 5);
assert_eq(s.signals, r.signals(1:5, [2 1]), 'channels by number (0-based)');
assert_eq(s.names, {'V5', 'MLII'}, 'reordered names');
s = wfdbx.read_record('100s', 'sampfrom', 21590);
assert_eq(s.signals, r.signals(21591:end, :), 'read to the end');
s = wfdbx.read_record('100s', 'sampto', 0);
assert_eq(size(s.signals), [0 2], 'sampto 0');
assert_error(@() wfdbx.read_record('100s', 'channels', 2), 'channel out of range');
assert_error(@() wfdbx.read_record('100s', 'channels', {'nosuch'}), 'unknown channel');
assert_error(@() wfdbx.read_record('100s', 'bogus', 1), 'unknown option');
wfdbx.wfdbquiet();
assert_error(@() wfdbx.read_record('nosuch'), 'missing record');
wfdbx.wfdbverbose();

% --- the bulk reader gives the samples of getvec
recs = {'fmt310', 'fmt8', 'twog', 'mfreq'};
for k = 1:numel(recs)
    rec = recs{k};
    n = wfdbx.isigopen(rec, 0);
    wfdbx.isigopen(rec, n);
    ref = zeros(0, n);
    while true
        [stat, v] = wfdbx.getvec();
        if stat < 0
            break;
        end
        ref(end + 1, :) = v(1:n); %#ok<AGROW>
    end
    wfdbx.wfdbquit();
    wfdbx.wfdbquiet();
    x = wfdbx.read_record(rec);
    wfdbx.wfdbverbose();
    assert_eq(x.signals, ref, ['read_record = getvec: ' rec]);
end

% --- physical units
p = wfdbx.read_record('100s', 'sampto', 3, 'physical', true);
assert_true(max(max(abs(p.signals - repmat([-0.145 -0.065], 3, 1)))) < 1e-12, ...
    'physical units');

% --- multi-frequency records
lo = wfdbx.read_record('mfreq', 'sampto', 10);
hi = wfdbx.read_record('mfreq', 'sampto', 20, 'highres', true);
assert_eq(size(lo.signals), [10 3], 'mfreq lowres size');
assert_eq(size(hi.signals), [20 3], 'mfreq highres size');
assert_eq([lo.fs hi.fs], [100 400], 'mfreq fs');

% --- variable layout: invalid samples (NaN in physical units), padding
wfdbx.wfdbquiet();
v = wfdbx.read_record('vlay', 'sampfrom', 1498, 'sampto', 1502);
vp = wfdbx.read_record('vlay', 'sampfrom', 1498, 'sampto', 1502, 'physical', true);
vpad = wfdbx.read_record('vlay', 'sampfrom', 1498, 'sampto', 1502, 'pad', true);
wfdbx.wfdbverbose();
assert_eq(v.signals(3, :), [INV INV INV], 'vlay invalid samples');
assert_true(all(isnan(vp.signals(3, :))), 'vlay NaN');
assert_true(all(~isnan(vp.signals(v.signals ~= INV))), 'vlay valid samples');
assert_true(~any(vpad.signals(:) == INV) || any(v.signals(1, :) == INV), 'vlay pad');

% --- write_record / read_record round trips in every format
% (format, sample range, ADC resolution)
ranges = [8 1000 12; 16 32767 16; 61 32767 16; 80 127 8; 160 32767 16; ...
    212 2047 12; 310 511 10; 311 511 10; 24 8388607 24; 32 2147483647 32; ...
    508 127 8; 516 32767 16; 524 8388607 24];
for r = 1:size(ranges, 1)
    fmt = ranges(r, 1);
    hi = ranges(r, 2);
    for nsig = 1:3
        if fmt >= 500
            n = 5003;
        else
            n = 1001;
        end
        if fmt == 8
            x = cumsum(pseudo(n, nsig, 60, fmt * 10 + nsig), 1);
        else
            x = pseudo(n, nsig, hi - 1, fmt * 10 + nsig);
        end
        wfdbx.write_record('rt', x, 250, 'fmt', fmt, 'gains', 200, ...
            'adcres', ranges(r, 3), 'units', 'mV');
        y = wfdbx.read_record('rt');
        y = y.signals;
        if any(fmt == [310 311]) && mod(n * nsig, 3) == 2
            % a final group of two samples is written in 4 bytes, so the
            % file appears to contain an extra (zero) sample, as in C
            assert_eq(y(end, :), zeros(1, nsig), 'format 310/311 last frame');
            y = y(1:end - 1, :);
        end
        assert_eq(y, x, sprintf('round trip, format %d, %d signals', fmt, nsig));
    end
end
hea = wfdbx.read_header('rt');
assert_eq([hea.siginfo.adcres], [24 24 24], 'adcres (format 524)');

% --- physical write: rounding as physadu, NaN -> invalid
xp = [0.0025 -0.0025; 1 -1; NaN 0.5; -0.0074 0.0074];
wfdbx.write_record('ph', xp, 100, 'physical', true, 'gains', [200 1000], ...
    'baselines', [10 -5], 'adcres', 16, 'units', {'mV', 'uV'});
y = wfdbx.read_record('ph');
assert_eq(y.signals, [11 -8; 210 -1005; INV 495; 9 2], 'physical write');
assert_eq(y.units, {'mV', 'uV'}, 'units');
yp = wfdbx.read_record('ph', 'physical', true);
assert_true(isnan(yp.signals(3, 1)) && abs(yp.signals(2, 2) + 1) < 1e-12, ...
    'physical read of a physical write');

% --- multi-frequency write (samps_per_frame)
m = [(1:50)', (101:150)', (201:250)', -(1:50)'];   % spf 1, 2, 1
wfdbx.write_record('mf', m, 100, 'samps_per_frame', [1 2 1], 'fmt', 16, ...
    'gains', 200, 'adcres', 16, 'units', 'mV');
hea = wfdbx.read_header('mf');
assert_eq([hea.siginfo.spf], [1 2 1], 'samps_per_frame header');
hr = wfdbx.read_record('mf', 'highres', true);
assert_eq(hr.fs, 200, 'multi-frequency fs');
assert_eq(hr.signals(1:4, 2)', [101 201 102 202], 'multi-frequency samples');
lr = wfdbx.read_record('mf');
assert_eq(size(lr.signals), [50 3], 'multi-frequency lowres');
assert_eq(lr.signals(:, 1), (1:50)', 'multi-frequency signal 0');

% --- header writing
z = zeros(10, 2);
wfdbx.write_record('hw', z, 125.5, 'fmt', 16, 'gains', [100 0], ...
    'adcres', 16, 'units', {'mV', 'uV'}, 'names', {'lead I', 'pressure'}, ...
    'base_time', '12:00:00 01/02/2003', 'comments', {'c1'});
text = char(readfile('hw.hea'));
assert_true(strncmp(text, sprintf('hw 2 125.5 10 12:00:00 01/02/2003\r\n'), 35), ...
    'header record line');
assert_true(~isempty(strfind(text, sprintf('hw.dat 16 100/mV 16 0 0 0 0 lead I\r\n'))), ...
    'header signal line');
assert_true(strcmp(text(end-4:end), sprintf('#c1\r\n')), 'header comment');
h = wfdbx.read_record('hw');
assert_eq(h.base_time, '[12:00:00 01/02/2003]', 'base_time');
assert_eq(h.comments, {'c1'}, 'comments');
assert_eq(h.names, {'lead I', 'pressure'}, 'names');
% a counter frequency set before must not leak into a new header
wfdbx.setcfreq(1000);
wfdbx.setbasecount(5);
wfdbx.write_record('hw2', z, 250, 'gains', 200, 'adcres', 16, 'units', 'mV');
text = char(readfile('hw2.hea'));
assert_true(strncmp(text, sprintf('hw2 2 250 10\r\n'), 14), 'cfreq reset');
assert_error(@() wfdbx.write_record('bad', z, 250, 'fmt', [16 212], ...
    'gains', 200, 'adcres', 12, 'units', 'mV'), 'mixed formats');

% --- WFDB-x: no default sampling frequency or gain (docs/DIVERGENCES.md)
assert_error(@() wfdbx.write_record('bad', z, 250), 'gains must be specified');
assert_error(@() wfdbx.write_record('bad', z, 0, 'gains', 200, ...
    'adcres', 16, 'units', 'mV'), 'fs 0');
assert_error(@() wfdbx.write_record('bad', z, -1, 'gains', 200, ...
    'adcres', 16, 'units', 'mV'), 'fs < 0');
assert_error(@() wfdbx.write_record('bad', z, 250, 'gains', [200 0], ...
    'adcres', 16, 'units', 'mV', 'physical', true), ...
    'physical with an uncalibrated signal');
assert_error_msg(@() wfdbx.write_record('bad', z, 250, 'gains', [200 0], ...
    'adcres', 16, 'units', 'mV', 'physical', true), ...
    'signal 1 is uncalibrated', 'uncalibrated message');
assert_error_msg(@() wfdbx.write_record('bad', z, 250), ...
    'gains must be specified', 'gains message');
% WFDB-x: no default ADC resolution or units either
assert_error_msg(@() wfdbx.write_record('bad', z, 250, 'gains', 200, ...
    'units', 'mV'), 'ADC resolution(s) must be specified', 'adcres missing');
assert_error_msg(@() wfdbx.write_record('bad', z, 250, 'gains', 200, ...
    'adcres', [16 0], 'units', 'mV'), 'ADC resolution(s) must be specified', ...
    'adcres < 1');
assert_error_msg(@() wfdbx.write_record('bad', z, 250, 'gains', 200, ...
    'adcres', 16), 'units must be specified', 'units missing');
assert_error_msg(@() wfdbx.write_record('bad', z, 250, 'gains', [200 100], ...
    'adcres', 16, 'units', {'mV', ''}), 'units must be specified', ...
    'units of signal 1 empty');
assert_true(~isfile('bad.hea'), 'no record written after an error');
wfdbx.write_record('nu', z, 250, 'gains', [0 100], 'adcres', [12 16], ...
    'units', {[], 'uV'});   % units not needed for an uncalibrated signal
nu = wfdbx.read_header('nu');
nu = nu.siginfo;
assert_eq([nu.adcres], [12 16], 'adcres per signal');
assert_true(isempty(nu(1).units) && strcmp(nu(2).units, 'uV'), 'units per signal');
% a header without ADC resolutions or units: 0 and [] (never 12 bits, mV)
fid = fopen('nr.hea', 'wb');
fwrite(fid, uint8(sprintf('nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n')));
fclose(fid);
nr = wfdbx.read_record('nr', 'sampto', 5);
assert_eq([nr.siginfo.adcres], [0 0], 'read_record unspecified adcres');
assert_true(isempty(nr.units{1}) && isempty(nr.units{2}), ...
    'read_record unspecified units');
wfdbx.write_record('unc', [1 2; 3 4], 100, 'gains', [0 50], ...
    'adcres', 16, 'units', {[], 'mV'});  % ADC units
u = wfdbx.read_record('unc');
assert_eq(u.gains, [0 50], 'uncalibrated signal written');
assert_eq(u.signals, [1 2; 3 4], 'uncalibrated signal samples');
p = wfdbx.read_record('unc', 'physical', true, 'channels', 1);
assert_eq(p.signals, [0.04; 0.08], 'physical read of a calibrated signal');
assert_error_msg(@() wfdbx.read_record('unc', 'physical', true), ...
    'signal 0 of record unc is uncalibrated', 'physical read, uncalibrated');
% a header without a sampling frequency
fid = fopen('nf.hea', 'wb');
fwrite(fid, uint8(sprintf('nf 1\nunc.dat 16 0 16 0 1 0 0 x\n')));
fclose(fid);
fid = fopen('nf.atr', 'wb');    % (an empty annotation file: EOF word)
fwrite(fid, uint8([0 0]));
fclose(fid);
nf = wfdbx.read_record('nf');
assert_eq(nf.fs, 0, 'read_record fs of a record without frequency');
assert_true(isempty(nf.base_time), 'no base time without frequency');
h = wfdbx.read_header('nf');
assert_eq({h.fs, h.counter_freq, h.nsamples, h.nsig}, {0, 0, 0, 1}, ...
    'read_header without frequency or length');
h = wfdbx.read_header('nf', 'legacy', true);
assert_eq(h.fs, 250, 'legacy read_header: 250 Hz without frequency');
nf = wfdbx.read_record('nf', 'sampfrom', 's1', 'sampto', 's3');
assert_eq(nf.signals, [2; 3], 'sample-number times without frequency');
assert_error_msg(@() wfdbx.read_record('nf', 'sampto', '0:1'), ...
    'sampling frequency of record nf is not specified', 'time string, no fs');
assert_error_msg(@() wfdbx.read_record('nf', 'sampfrom', 'f1'), ...
    'sampling frequency of record nf is not specified', 'frame, no fs');
wfdbx.wfdbquiet();
na = wfdbx.read_annotations('nf', 'atr');
assert_eq([numel(na.samples) na.fs], [0 0], 'read_annotations without fs');
na = wfdbx.read_annotations('nf', 'atr', 'fs', 125);
assert_eq(na.fs, 125, 'read_annotations fs option');
na = wfdbx.read_annotations('nf', 'atr', 0, '0:1', 'fs', 125);
assert_eq(na.fs, 125, 'read_annotations positional and fs');
assert_error_msg(@() wfdbx.read_annotations('nf', 'atr', 'sampto', '0:1'), ...
    'sampling frequency of record nf is not specified', ...
    'read_annotations time string without fs');
assert_error(@() wfdbx.read_annotations('nf', 'atr', 'fs', 0), 'fs 0');
a = wfdbx.read_annotations('100s', 'atr', 'fs', 125);
assert_eq(a.fs, 360, 'fs option ignored if the header gives one');
wfdbx.wfdbverbose();

% --- WFDB-x: the 'legacy' option (the original package's behavior)
wfdbx.write_record('lg', z, 250, 'legacy', true);
lg = wfdbx.read_header('lg');
lg = lg.siginfo;
assert_eq([lg.gain], [200 200], 'legacy write_record: default gain 200');
assert_eq([lg.adcres], [16 16], 'legacy write_record: adcres from fmt 16');
assert_true(isempty(lg(1).units), 'legacy write_record: no units needed');
% the library's legacy mode also applies, without 'legacy', true
wfdbx.wfdbx_set_legacy(1);
wfdbx.write_record('lgg', z, 250);
wfdbx.wfdbx_set_legacy(0);
lgg = wfdbx.read_header('lgg');
lgg = lgg.siginfo;
assert_eq([lgg.gain], [200 200], 'library legacy mode: default gain 200');
wfdbx.write_record('lg', z, 250, 'fmt', 212, 'legacy', true);
lg = wfdbx.read_header('lg');
lg = lg.siginfo;
assert_eq([lg.adcres], [12 12], 'legacy write_record: adcres from fmt 212');
assert_eq(wfdbx.wfdbx_get_legacy(), 0, 'legacy mode restored');
lg = wfdbx.read_record('null', 'physical', true, 'sampto', 3, 'legacy', true);
% (the null record's samples are all invalid: NaN in physical units)
assert_true(isequal(size(lg.signals), [3 2]) && all(isnan(lg.signals(:))) && ...
    isequal(lg.gains, [0 0]), 'legacy physical read of null (uncalibrated)');
u = wfdbx.read_record('unc', 'physical', true, 'legacy', true);
assert_eq(u.signals, [0.005 0.04; 0.015 0.08], ...
    'legacy physical read of an uncalibrated signal (gain 200)');
assert_error(@() wfdbx.read_record('null', 'physical', true), ...
    'null physical without legacy');
nf = wfdbx.read_record('nf', 'sampto', '0:1', 'legacy', true);
assert_eq(nf.fs, 250, 'legacy read_record: 250 Hz without frequency');
assert_eq(size(nf.signals, 1), 4, 'legacy read_record: time at 250 Hz');
nr = wfdbx.read_header('nr', 'legacy', true);
assert_eq([nr.siginfo.adcres], [12 12], 'legacy read_header: adcres from fmt 212');
na = wfdbx.read_annotations('nf', 'atr', 'sampto', '0:1', 'legacy', true);
assert_eq(na.fs, 250, 'legacy read_annotations: 250 Hz');
assert_eq(wfdbx.wfdbx_get_legacy(), 0, 'legacy mode restored after reads');
wfdbx.wfdbquiet();
assert_error(@() wfdbx.read_record('nosuch', 'legacy', true), ...
    'legacy read_record of a missing record');
wfdbx.wfdbverbose();
assert_eq(wfdbx.wfdbx_get_legacy(), 0, 'legacy mode restored after an error');
wfdbx.wfdbx_set_legacy(1);
wfdbx.read_header('100s');
assert_eq(wfdbx.wfdbx_get_legacy(), 1, 'previous setting (on) restored');
wfdbx.wfdbx_set_legacy(0);
assert_error(@() wfdbx.read_record('100s', 'legacy', 'yes'), ...
    'legacy must be true or false');

% --- annotations
a = wfdbx.read_annotations('100s', 'atr');
assert_eq(numel(a.samples), 75, 'number of annotations');
assert_eq(size(a.samples), [75 1], 'column vectors');
assert_eq(a.symbols(1:3), {'+'; 'N'; 'N'}, 'symbols');
assert_eq(a.aux{1}, '(N', 'aux');
assert_eq(a.fs, 360, 'annotation fs');
b = wfdbx.read_annotations('100s', 'atr', 'sampfrom', 1000, 'sampto', '0:30');
k = a.samples >= 1000 & a.samples < 10800;
assert_eq(b.samples, a.samples(k), 'sampfrom/sampto');
c = wfdbx.read_annotations('100s', 'atr', 'sampto', 2000);
assert_eq(c.samples, a.samples(a.samples < 2000), 'sampto only');
wfdbx.wfdbquiet();
assert_error(@() wfdbx.read_annotations('100s', 'nosuch'), 'missing annotator');
wfdbx.wfdbverbose();

% round trip, including times beyond 2^32 and long aux strings
C = wfdbx.ecgcodes();
samples = [0, 5, 5, 5, 300, 70000, 70001, 5000000000, 5000000000];
codes = [C.NOTE, C.NORMAL, C.NORMAL, C.NORMAL, C.PVC, C.ARFCT, C.RHYTHM, ...
    C.NORMAL, C.NOISE];
chans = [0, 0, 1, 1, 0, 3, 0, 0, 2];
nums = [0, 0, 0, 2, 0, -1, 0, 0, 1];
sub = [0, 0, 0, 0, 3, 0, 0, 0, -1];
aux = {'start', [], [], [], [], [], '(AFIB', [], repmat('x', 1, 200)};
wfdbx.write_annotations('100s', 'rt', samples, 'codes', codes, 'chans', ...
    chans', 'nums', nums, 'subtypes', sub, 'aux', aux);
wfdbx.wfdbquiet();
r = wfdbx.read_annotations('100s', 'rt');
wfdbx.wfdbverbose();
% (the NOTE at time 0 is consumed as a modification label by annopen)
assert_eq(r.samples, samples(2:end)', 'rt samples');
assert_eq(r.codes, codes(2:end)', 'rt codes');
assert_eq(r.chans, chans(2:end)', 'rt chans');
assert_eq(r.nums, nums(2:end)', 'rt nums');
assert_eq(r.subtypes, sub(2:end)', 'rt subtypes');
assert_eq(r.aux, aux(2:end)', 'rt aux');

% symbols (cell or char), aux up to the first NUL and at most 255 bytes,
% time resolution
wfdbx.write_annotations('100s', 'sy', [10 20 30], 'symbols', {'N', 'V', '+'}, ...
    'aux', {[], ['ab' char(0) 'cd'], repmat('y', 1, 300)}, 'fs', 1000);
s = wfdbx.read_annotations('100s', 'sy');
assert_eq(s.symbols, {'N'; 'V'; '+'}, 'symbols round trip');
assert_eq(s.codes, [C.NORMAL; C.PVC; C.RHYTHM], 'codes from symbols');
assert_eq(s.aux{2}, 'ab', 'aux up to the first NUL');
assert_eq(numel(s.aux{3}), 255, 'aux truncated to 255 bytes');
assert_true(isempty(s.aux{1}), 'no aux');
% (times in ticks of 1/1000 s, read back in samples of the record)
assert_eq(s.samples, [4; 7; 11], 'annotation times with fs');
assert_eq(s.fs, 360, 'annotation fs');
wfdbx.write_annotations('100s', 'sc', [1; 2; 3], 'symbols', 'NVN');
s = wfdbx.read_annotations('100s', 'sc');
assert_eq(s.symbols, {'N'; 'V'; 'N'}, 'symbols as a char vector');
assert_eq(s.fs, 360, 'fs not carried over');
assert_error(@() wfdbx.write_annotations('100s', 'zz', [1 2]), 'no codes');

% --- WFDB-x: the 'dir' option of the writers
write_dir();
dotted_names();
dir_checks_first();

% --- WFDB-x: a signal file shorter than its header says
truncated_signal_file();
checksum_warning();
highres_checksum();
truncated_annotations();
base_time_fields();
end

function highres_checksum()
% In high-resolution mode getvec returns -4 for each sample vector of the
% frame at which the checksums are verified; read_record returns all the
% samples, with one warning.
wfdbx.wfdbquiet();
q = onCleanup(@() wfdbx.wfdbverbose()); %#ok<NASGU>
% the reproduction: spf 2 and 3, first sample changed to 99
for spf = [2 3]
    frames = reshape(1:4 * spf, spf, 4).';
    wfdbx.write_record('hc', frames, 100, 'samps_per_frame', spf, ...
        'gains', 100, 'adcres', 16, 'units', 'mV');
    poke('hc.dat', 0, 99);
    r = wfdbx.read_record('hc', 'highres', true, 'checksum_warning', false);
    assert_eq(r.signals, [99, 2:4 * spf].', sprintf('highres spf %d', spf));
    assert_eq(r.checksum_ok, false, sprintf('highres spf %d checksum_ok', spf));
end
cases = {2, [1 2], [2 3], [3 1 2]};
for c = 1:numel(cases)
    spf = cases{c};
    nf = 5;
    x = reshape(1:nf * sum(spf), sum(spf), nf).';
    for where = 1:2
        y = x;
        if where == 1
            y(1, 1) = 99;
            pos = 0;
        else
            y(end, end) = 99;
            pos = 2 * (numel(x) - 1);
        end
        what = sprintf('highres spf %s, sample %d', mat2str(spf), pos / 2);
        wfdbx.write_record('hc', x, 100, 'samps_per_frame', spf, ...
            'gains', 100, 'adcres', 16, 'units', 'mV');
        poke('hc.dat', pos, 99);
        % (the same samples with correct checksums)
        wfdbx.write_record('hg', y, 100, 'samps_per_frame', spf, ...
            'gains', 100, 'adcres', 16, 'units', 'mV');
        for hr = [true false]
            m = 1;
            if hr
                m = max(spf);
            end
            good = wfdbx.read_record('hg', 'highres', hr);
            assert_eq(size(good.signals, 1), nf * m, [what ': length']);
            for warn = [true false]
                [r, n] = read_counting('hc', {'highres', hr, ...
                    'checksum_warning', warn});
                assert_eq(r.signals, good.signals, [what ': samples']);
                assert_eq(r.checksum_ok, false, [what ': checksum_ok']);
                assert_eq(n, double(warn), [what ': number of warnings']);
            end
            % channel selection
            for ch = 0:numel(spf) - 1
                r = wfdbx.read_record('hc', 'highres', hr, 'channels', ch, ...
                    'checksum_warning', false);
                assert_eq(r.signals, good.signals(:, ch + 1), ...
                    sprintf('%s: channel %d', what, ch));
                assert_eq(r.checksum_ok, false, [what ': channel checksum_ok']);
            end
            % sampto before the last frame: no checksum is verified
            r = wfdbx.read_record('hc', 'highres', hr, 'sampto', (nf - 1) * m);
            assert_eq(r.signals, good.signals(1:(nf - 1) * m, :), ...
                [what ': sampto']);
            assert_eq(r.checksum_ok, true, [what ': sampto checksum_ok']);
        end
    end
end
end

function [r, n] = read_counting(record, args)
% read_record, without displaying its warnings, and the number of checksum
% warnings it gives (other warnings are ignored)
txt = evalc('r = wfdbx.read_record(record, args{:});');
n = numel(strfind(txt, ['checksum error in record ' record ':']));
end

function poke(name, pos, value)
% set the 16-bit sample at byte POS of file NAME
fid = fopen(name, 'r+b');
fseek(fid, pos, 'bof');
fwrite(fid, [value 0], 'uint8');
fclose(fid);
end

function truncated_annotations()
% An annotation file cut at every byte position: read_annotations returns
% what getann returns, or (if getann ends with a status other than -1
% before 'sampto') throws an error naming that status.
wfdbx.write_record('ta', ones(100, 1), 100, 'gains', 100, 'adcres', 16, ...
    'units', 'mV');
% (an aux string, a SKIP (5000 - 20 > 1023) and a channel change)
wfdbx.write_annotations('ta', 'atr', [10 20 5000 5010], ...
    'codes', [1 5 28 1], 'aux', {[], [], '(AFIB', []}, 'chans', [0 0 0 1]);
full = readfile('ta.atr');
ref = wfdbx.read_annotations('ta', 'atr');
assert_eq(ref.samples, [10; 20; 5000; 5010], 'complete file');
assert_eq(ref.aux{3}, '(AFIB', 'complete file: aux');
% the reproduction: the EOF word removed
wfdbx.write_annotations('ta', 'ab', [10 20 30], 'codes', [1 5 1]);
b = readfile('ta.ab');
writefile('ta.ab', b(1:end - 2));
for legacy = [false true]
    assert_error_msg(@() wfdbx.read_annotations('ta', 'ab', 'legacy', legacy), ...
        'can''t read annotation file ab of record ta (getann status -3)', ...
        'truncated annotations: error');
    a = wfdbx.read_annotations('ta', 'ab', 'sampto', 15, 'legacy', legacy);
    assert_eq(a.samples, 10, 'truncated annotations: sampto 15');
end
wfdbx.wfdbquiet();
q = onCleanup(@() wfdbx.wfdbverbose()); %#ok<NASGU>
tos = {[], 15, 20, 5000, 5005, 6000};
for cut = 0:numel(full)
    writefile('ta.atr', full(1:cut));
    for j = 1:numel(tos)
        to = tos{j};
        [t, c, aux, stat, ok] = getann_all('ta', 'atr', to);
        what = sprintf('cut %d, sampto %s', cut, mat2str(to));
        m = '';
        a = [];
        try
            if isempty(to)
                a = wfdbx.read_annotations('ta', 'atr');
            else
                a = wfdbx.read_annotations('ta', 'atr', 'sampto', to);
            end
        catch err
            m = err.message;
        end
        wfdbx.wfdbquit();
        if ~ok
            assert_eq(m, 'can''t read annotator atr for record ta', ...
                [what ': annopen']);
        elseif stat == 0 || stat == -1
            assert_eq(m, '', [what ': no error']);
            assert_eq(a.samples, t, [what ': samples']);
            assert_eq(a.codes, c, [what ': codes']);
            assert_eq(a.aux, aux, [what ': aux']);
        else
            assert_eq(m, sprintf(['can''t read annotation file atr of ' ...
                'record ta (getann status %d)'], stat), [what ': error']);
        end
    end
end
writefile('ta.atr', full);
a = wfdbx.read_annotations('ta', 'atr');
assert_eq(a.samples, ref.samples, 'complete file again');
end

function [t, c, aux, stat, ok] = getann_all(record, annotator, to)
% the annotations getann reads before 'to' (all if empty), and the status
% of the last call (0 if an annotation at or after 'to' was read)
t = zeros(0, 1);
c = zeros(0, 1);
aux = cell(0, 1);
stat = 0;
wfdbx.wfdbquit();
ok = wfdbx.annopen(record, wfdbx.anninfo(annotator, 0)) >= 0;
while ok
    [stat, a] = wfdbx.getann(0);
    if stat ~= 0 || (~isempty(to) && a.time >= to)
        break;
    end
    t(end + 1, 1) = a.time; %#ok<AGROW>
    c(end + 1, 1) = a.anntyp; %#ok<AGROW>
    x = [];
    if ~isempty(a.aux)
        x = a.aux(2:min(end, double(a.aux(1)) + 1));
        x = char(x(1:find([x 0] == 0, 1) - 1));
    end
    aux{end + 1, 1} = x; %#ok<AGROW>
end
wfdbx.wfdbquit();
end

function writefile(name, b)
fid = fopen(name, 'wb');
fwrite(fid, b, 'uint8');
fclose(fid);
end

function base_time_fields()
% base_time_ms and base_date of read_record and read_header
fid = fopen('bt.dat', 'wb');
fwrite(fid, zeros(1, 20), 'uint8');     % 10 samples, format 16
fclose(fid);
cases = {'14:00:03.500 21/06/2024', '[14:00:03 21/06/2024]', 50403500, [2024 6 21]; ...
    '14:00:03', '[14:00:03]', 50403000, []; ...
    '', [], [], []; ...
    '0:0:0.001 1/3/1900', '[00:00:00 01/03/1900]', 1, [1900 3 1]; ...
    '23:59:59.999 31/12/1999', '[23:59:59 31/12/1999]', 86399999, [1999 12 31]};
for k = 1:size(cases, 1)
    fid = fopen('bt.hea', 'wb');
    fwrite(fid, uint8(sprintf('bt 1 250 10 %s\nbt.dat 16 200 16 0 0 0 0 x\n', ...
        cases{k, 1})));
    fclose(fid);
    h = wfdbx.read_header('bt');
    r = wfdbx.read_record('bt');
    for x = {h, r}
        x = x{1}; %#ok<FXSET>
        what = sprintf('base time ''%s''', cases{k, 1});
        assert_eq(x.base_time, cases{k, 2}, [what ': text']);
        assert_eq(x.base_time_ms, cases{k, 3}, [what ': ms']);
        assert_eq(x.base_date, cases{k, 4}, [what ': date']);
        assert_true(isempty(x.base_time_ms) || isa(x.base_time_ms, 'double'), ...
            [what ': double']);
    end
end
end

function truncated_signal_file()
% A signal file shorter than its header says (getvec status -3, unexpected
% EOF) is an error of read_record, not the end of the data; the low-level
% API is unchanged.
wfdbx.wfdbquiet();
x = [1 2; 3 4; 5 6; 7 8];
wfdbx.write_record('tr', x, 100, 'gains', 100, 'adcres', 16, 'units', 'mV');
wfdbx.write_record('ok', x, 100, 'gains', 100, 'adcres', 16, 'units', 'mV');
b = readfile('tr.dat');
fid = fopen('tr.dat', 'wb');
fwrite(fid, b(1:8), 'uint8');      % 2 of the 4 frames (format 16)
fclose(fid);
for legacy = [false true]
    for phys = [false true]
        % (1) the error, and the library is left usable
        m = '';
        try
            wfdbx.read_record('tr', 'physical', phys, 'legacy', legacy);
        catch err
            m = err.message;
        end
        assert_eq(m, 'can''t read signal data of record tr (getvec status -3)', ...
            'truncated: error');
        r = wfdbx.read_record('ok', 'legacy', legacy);
        assert_eq(r.signals, x, 'truncated: then a good record');
    end
    % reading only what the file holds is not an error
    r = wfdbx.read_record('tr', 'sampto', 2, 'legacy', legacy);
    assert_eq(r.signals, x(1:2, :), 'truncated: sampto 2');
    % (2) a sub-interval, and sampto past the end of a record whose header
    % gives its length (what there is, no error)
    r = wfdbx.read_record('ok', 'sampfrom', 1, 'sampto', 3, 'legacy', legacy);
    assert_eq(r.signals, x(2:3, :), 'sub-interval');
    r = wfdbx.read_record('ok', 'sampto', 10, 'legacy', legacy);
    assert_eq(r.signals, x, 'sampto past the end');
end
% (3) the low-level API: getvec returns -3 at the end of the truncated
% file, getframes the frames read and that status
assert_eq(wfdbx.isigopen('tr', 2), 2, 'truncated: isigopen');
st = zeros(1, 3);
for k = 1:3
    st(k) = wfdbx.getvec();
end
assert_eq(st, [2 2 -3], 'truncated: getvec');
wfdbx.wfdbquit();
wfdbx.isigopen('tr', 2);
[v, stat] = wfdbx.getframes(10);
assert_eq(stat, -3, 'truncated: getframes status');
assert_eq(v, x(1:2, :), 'truncated: getframes');
wfdbx.wfdbquit();
wfdbx.isigopen('ok', 2);
[v, stat] = wfdbx.getframes(10);
assert_eq(stat, -1, 'complete: getframes status');
assert_eq(v, x, 'complete: getframes');
wfdbx.wfdbquit();
wfdbx.wfdbverbose();
end

function checksum_warning()
% A checksum error (getvec status -4) is a warning of read_record (the
% data, all of them, are returned), not an error; 'checksum_warning',
% false turns it off.  The library's getvec message is not printed then
% (but recorded).
msg = ['checksum error in record ck: the signal data do not match the ' ...
    'checksums in its header'];
x = [1 2; 3 4; 5 6; 7 8];
wfdbx.write_record('ck', x, 100, 'gains', 100, 'adcres', 16, 'units', 'mV');
fid = fopen('ck.dat', 'r+b');       % sample (1, 0): 3 -> 9
fseek(fid, 4, 'bof');
fwrite(fid, [9 0], 'uint8');
fclose(fid);
y = x;
y(2, 1) = 9;
% (the same samples with correct checksums: every frame, the last one
% included, is returned in both cases)
wfdbx.write_record('good', y, 100, 'gains', 100, 'adcres', 16, 'units', 'mV');
for legacy = [false true]
    good = wfdbx.read_record('good', 'legacy', legacy);
    for phys = [false true]
        wfdbx.wfdbquiet();      % (wfdberror shows what would be printed)
        [r, n] = read_counting('ck', {'physical', phys, 'legacy', legacy});
        wfdbx.wfdbverbose();
        assert_eq(n, 1, 'checksum warning given once');
        if phys
            assert_eq(r.signals, y / 100, 'checksum: physical');
        else
            assert_eq(r.signals, y, 'checksum: all frames');
        end
        assert_eq(size(r.signals), size(good.signals), 'checksum: length');
        assert_eq(wfdbx.wfdberror(), sprintf('getvec: checksum error in signal 0\n'), ...
            'getvec message recorded');
        S = wfdbx.internal.sig_state();
        assert_eq(S.cksum_quiet, false, 'message printed again after the read');
    end
    assert_eq(r.checksum_ok, false, 'checksum_ok false (warning on)');
    assert_eq(good.checksum_ok, true, 'checksum_ok true');
    % the identifier and message of the warning (turned into an error)
    [id, m] = warning_of(@() wfdbx.read_record('ck', 'legacy', legacy), ...
        'wfdbx:checksum');
    assert_eq({id, m}, {'wfdbx:checksum', msg}, 'checksum warning');
    r = wfdbx.read_record('ck', 'checksum_warning', false, 'legacy', legacy);
    assert_eq(r.signals, good.signals, 'checksum_warning false: same frames');
    assert_eq(r.checksum_ok, false, 'checksum_ok false (warning off)');
    % not read to the end: no checksum is verified
    r = wfdbx.read_record('ck', 'sampto', 3, 'legacy', legacy);
    assert_eq(r.signals, y(1:3, :), 'checksum: sampto 3');
    assert_eq(r.checksum_ok, true, 'checksum_ok: not verified before the end');
    [r, n] = read_counting('ck', {'sampfrom', 1, 'sampto', 'e', ...
        'checksum_warning', false, 'legacy', legacy});
    assert_eq(r.signals, y(2:end, :), 'checksum: sampfrom 1');
    assert_eq(n, 0, 'no warning');
    % the truncated case is still an error
    wfdbx.wfdbquiet();
    assert_error_msg(@() wfdbx.read_record('tr', 'legacy', legacy), ...
        'can''t read signal data of record tr (getvec status -3)', ...
        'checksum: truncated still an error');
    wfdbx.wfdbverbose();
end
% the low-level API is unchanged: getvec returns -4 for the last frame
% (filled), getframes stops before it (LAST is that frame), and the
% message is printed
wfdbx.wfdbquiet();
wfdbx.isigopen('ck', 2);
st = zeros(1, 4);
for k = 1:4
    [st(k), v] = wfdbx.getvec();
end
assert_eq([st, v], [2 2 2 -4 7 8], 'checksum: getvec');
wfdbx.wfdbquit();
wfdbx.isigopen('ck', 2);
[v, stat, last] = wfdbx.getframes(10);
assert_eq(stat, -4, 'checksum: getframes status');
assert_eq(v, y(1:3, :), 'checksum: getframes');
assert_eq(last, [7 8], 'checksum: getframes LAST');
wfdbx.wfdbquit();
wfdbx.wfdbverbose();
end

function [id, m] = warning_of(f, wid)
% the identifier and message of the warning WID given by F (by turning
% that warning, and no other, into an error); '' if there is none
old = warning('query', wid);
warning('error', wid);
id = '';
m = '';
try
    f();
catch err
    id = err.identifier;
    m = err.message;
end
warning(old);
wfdbx.wfdbquit();
end

function dir_checks_first()
% the dir checks come before any other argument validation
x = [1 2; 3 4];
r = 'record name must not contain a directory when dir is given';
assert_error_msg(@() wfdbx.write_record('x/rec', x, 360, 'dir', 'out'), ...
    r, 'write_record: record checked first (no gains)');
assert_error_msg(@() wfdbx.write_record('rec', x, -1, 'dir', 'nosuch'), ...
    'directory nosuch does not exist', 'write_record: dir checked first');
assert_error_msg(@() wfdbx.write_record('x/rec', x, 360, 'dir', 'nosuch', ...
    'legacy', 'bad'), r, 'write_record: record checked before dir');
assert_error_msg(@() wfdbx.write_record('rec', x, 360, 'dir', 'out'), ...
    'gains must be specified', 'write_record: then the other checks');
assert_error_msg(@() wfdbx.write_annotations('x/rec', 'atr', 1, ...
    'dir', 'out'), r, 'write_annotations: record checked first');
assert_error_msg(@() wfdbx.write_annotations('rec', 'atr', 1, ...
    'dir', 'nosuch'), 'directory nosuch does not exist', ...
    'write_annotations: dir checked first');
assert_error_msg(@() wfdbx.write_annotations('rec', 'atr', 1, ...
    'dir', 'out'), 'symbols or codes must be given', ...
    'write_annotations: then the other checks');
end

function write_dir()
x = reshape(0:19, 2, 10).';
mkdir('out');
prev = wfdbx.wfdbx_set_output_dir('elsewhere');
wfdbx.write_record('rec', x, 360, 'gains', 200, 'adcres', 12, ...
    'units', 'mV', 'dir', 'out');
assert_eq(wfdbx.wfdbx_get_output_dir(), 'elsewhere', 'output dir restored');
wfdbx.wfdbx_set_output_dir(prev);
d = dir('out');
assert_eq(sort({d(~[d.isdir]).name}), {'rec.dat', 'rec.hea'}, 'files in out');
assert_true(~isfile('rec.hea') && ~isfile('rec.dat'), 'no files in .');
hea = char(readfile(fullfile('out', 'rec.hea')));
assert_eq(hea(1:find(hea == char(13), 1) - 1), 'rec 2 360 10', ...
    'header names the plain record');
assert_true(strncmp(hea(find(hea == char(10), 1) + 1:end), 'rec.dat 16 ', 11), ...
    'header names the plain signal file');
oldpath = wfdbx.getwfdb();
wfdbx.setwfdb('out');
r = wfdbx.read_record('rec');
wfdbx.setwfdb(oldpath);
assert_eq(r.signals, x, 'record read from out');
r = wfdbx.read_record('out/rec');
assert_eq(r.signals, x, 'record read as out/rec');
assert_eq(wfdbx.wfdbx_get_output_dir(), [], 'no output dir');
assert_error_msg(@() wfdbx.write_record('rec', x, 360, 'gains', 200, ...
    'adcres', 12, 'units', 'mV', 'dir', 'nosuch'), ...
    'directory nosuch does not exist', 'write_record missing dir');
assert_error_msg(@() wfdbx.write_record('sub/rec', x, 360, 'gains', 200, ...
    'adcres', 12, 'units', 'mV', 'dir', 'out'), ...
    'record name must not contain a directory when dir is given', ...
    'write_record record with a directory');
% restored after an error, too
assert_error(@() wfdbx.write_record('rec', x, 360, 'dir', 'out'), ...
    'write_record without gains');
assert_eq(wfdbx.wfdbx_get_output_dir(), [], 'output dir restored after an error');
assert_true(~isfolder('nosuch') && ~isfolder('sub'), 'no directory created');
% the same in legacy mode
wfdbx.write_record('leg', x, 360, 'dir', 'out', 'legacy', true);
hea = char(readfile(fullfile('out', 'leg.hea')));
assert_true(strncmp(hea, 'leg 2 360 10', 12), 'dir in legacy mode');

% write_annotations: an out-of-order file is sorted in place
wfdbx.wfdbquiet();
wfdbx.write_annotations('rec', 'atr', [30 10 20], 'symbols', 'NVN', ...
    'dir', 'out');
wfdbx.wfdbverbose();
assert_true(isfile(fullfile('out', 'rec.atr')) && ~isfile('rec.atr'), ...
    'annotation file in out');
assert_eq(wfdbx.wfdbx_get_output_dir(), [], 'output dir restored (annotations)');
a = wfdbx.read_annotations('out/rec', 'atr');
assert_eq([a.samples, a.codes], [10 20 30; 5 1 1].', 'sorted in place');
assert_error_msg(@() wfdbx.write_annotations('rec', 'atr', 1, ...
    'symbols', 'N', 'dir', 'nosuch'), 'directory nosuch does not exist', ...
    'write_annotations missing dir');
assert_error_msg(@() wfdbx.write_annotations('x/rec', 'atr', 1, ...
    'symbols', 'N', 'dir', 'out'), ...
    'record name must not contain a directory when dir is given', ...
    'write_annotations record with a directory');
end

function dotted_names()
% A record in a directory whose name has a dot: only the last component of
% a record name is checked when writing (not in legacy mode), and the
% header names the record and its signal file without the directory.
x = reshape(0:19, 2, 10).';
args = {'gains', 200, 'adcres', 12, 'units', 'mV'};
mkdir('my.data');
wfdbx.write_record('my.data/rec', x, 360, args{:});
hea = char(readfile(fullfile('my.data', 'rec.hea')));
assert_eq(hea(1:find(hea == char(13), 1) - 1), 'rec 2 360 10', ...
    'dotted directory: record line');
assert_true(strncmp(hea(find(hea == char(10), 1) + 1:end), 'rec.dat 16 ', 11), ...
    'dotted directory: signal file');
r = wfdbx.read_record('my.data/rec');
assert_eq(r.signals, x, 'dotted directory: read back');
% an absolute path with a dotted directory
p = [pwd() '/abs.dir/sub'];
mkdir(p);
wfdbx.write_record([p '/rec'], x, 360, args{:});
hea = char(readfile(fullfile(p, 'rec.hea')));
assert_true(strncmp(hea, 'rec 2 360 10', 12), 'absolute path: record line');
r = wfdbx.read_record([p '/rec']);
assert_eq(r.signals, x, 'absolute path: read back');
% newheader with the C-style API
wfdbx.wfdbquit();
si = wfdbx.siginfo(1);
si.fname = 'my.data/c.dat';
si.desc = 'sig';
si.units = 'mV';
si.gain = 200;
si.fmt = 16;
si.adcres = 12;
assert_eq(wfdbx.osigfopen(si, 1), 1, 'osigfopen');
wfdbx.setsampfreq(100);
wfdbx.putvec(5);
assert_eq(wfdbx.newheader('my.data/c'), 0, 'newheader my.data/c');
wfdbx.wfdbquit();
hea = char(readfile(fullfile('my.data', 'c.hea')));
assert_true(strncmp(hea, 'c 1 100', 7) && strncmp(hea(find(hea == char(10), 1) ...
    + 1:end), 'c.dat 16 200/mV 12', 18), ...
    'newheader: names relative to the header');
r = wfdbx.read_record('my.data/c');
assert_eq(r.signals, 5, 'newheader: read back');
% the last component is checked as before
wfdbx.wfdbquiet();
assert_error(@() wfdbx.write_record('rec.1', x, 360, args{:}), 'rec.1 refused');
assert_eq(wfdbx.wfdberror(), sprintf('init: illegal character 46 in record name\n'), ...
    'rec.1 message');
% legacy mode: the whole name is checked, and names are written as given
assert_error(@() wfdbx.write_record('my.data/leg', x, 360, args{:}, ...
    'legacy', true), 'legacy: my.data/rec refused');
wfdbx.wfdbverbose();
mkdir('out2');
wfdbx.write_record('out2/leg', x, 360, args{:}, 'legacy', true);
hea = char(readfile(fullfile('out2', 'leg.hea')));
assert_true(strncmp(hea, 'out2/leg 2 360 10', 17), 'legacy: record line as given');
assert_true(strncmp(hea(find(hea == char(10), 1) + 1:end), 'out2/leg.dat 16 ', 16), ...
    'legacy: signal file as given');
end

function x = pseudo(n, nsig, hi, seed)
% Deterministic pseudo-random integers in [-hi, hi] (an LCG).
x = zeros(n, nsig);
s = seed;
for k = 1:numel(x)
    s = mod(s * 69069 + 1, 4294967296);
    x(k) = mod(s, 2 * hi + 1) - hi;
end
end

function assert_true(c, what)
if ~c
    error('wfdbx:test', '%s: failed', what);
end
end

function assert_error(f, what)
failed = false;
try
    f();
catch
    failed = true;
end
wfdbx.wfdbquit();
if ~failed
    error('wfdbx:test', '%s: no error thrown', what);
end
end

function assert_error_msg(f, msg, what)
% the error thrown by F must have the message MSG
m = '';
try
    f();
catch err
    m = err.message;
end
wfdbx.wfdbquit();
if ~strcmp(m, msg)
    error('wfdbx:test', '%s: error ''%s'' (expected ''%s'')', what, m, msg);
end
end

function b = readfile(name)
fid = fopen(name, 'rb');
b = fread(fid, inf, 'uint8=>uint8')';
fclose(fid);
end

function restore(old, oldpath, d)
wfdbx.wfdbquit();
wfdbx.wfdbx_set_input_dir([]);
cd(old);
rmdir(d, 's');
end
