function test_signals()
%TEST_SIGNALS Signal I/O tests: every storage format round-trips exactly.

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

ranges = [8 1000; 16 32767; 61 32767; 80 127; 160 32767; 212 2047; ...
    310 511; 311 511; 24 8388607; 32 2147483647];
if wfdbx.internal.pkg_has('internal.flac_osinit')
    ranges = [ranges; 508 127; 516 32767; 524 8388607];
end
for r = 1:size(ranges, 1)
    fmt = ranges(r, 1);
    hi = ranges(r, 2);
    for nsig = 1:3
        roundtrip(fmt, hi, nsig);
    end
end

% The bulk reader (getframes) gives the same results as getvec.
recs = {'fmt212', 'fmt310', 'fmt311', 'fmt8', 'twog', 'fmt16', 'fmt24', ...
    'fmt32', 'fmt61', 'fmt80', 'fmt160', 'mfreq', 'skew', 'vlay', 'fmtblk', ...
    'prolog'};
for k = 1:numel(recs)
    bulk_check(recs{k}, 0);
end
for mode = 1:3      % WFDB_HIGHRES, WFDB_GVPAD
    bulk_check('mfreq', mode);
    bulk_check('fmt212', mode);
end
% ... also after positioning in the middle of a frame (high resolution)
bulk_check('mfreq', 1, 7);
bulk_check('mfreq', 0, 7);

% The bulk writer (putframes) writes the same files as putvec.
fmts = [8 16 61 80 160 212 310 311 24 32];
if wfdbx.internal.pkg_has('internal.flac_osinit')
    fmts = [fmts 508 516 524];
end
for fmt = fmts
    putframes_check(fmt, 1, 0);
    putframes_check(fmt, [1 1 1], 1);
    if fmt < 500
        putframes_check(fmt, [2 1], 2);
        putframes_check(fmt, [1 3], 0, true);
    end
end

% Header fields are read as strtok, strtol and strtod read them.
header_fields();

% Physical units
[n, si] = wfdbx.isigopen('100s', 2); %#ok<ASGLU>
x = wfdbx.getframes(3);
p = (x - repmat([si.baseline], 3, 1)) ./ repmat([si.gain], 3, 1);
assert(all(all(abs(p - repmat([-0.145 -0.065], 3, 1)) < 1e-12)), 'physical units');
assert(abs(wfdbx.aduphys(0, x(1, 1)) + 0.145) < 1e-12, 'aduphys');
assert_eq(wfdbx.physadu(0, -0.145), x(1, 1), 'physadu');
assert_eq(wfdbx.adumuv(0, 200), 1000, 'adumuv');
assert_eq(wfdbx.muvadu(0, 1000), 200, 'muvadu');
wfdbx.wfdbquit();

% Multi-frequency records
wfdbx.isigopen('mfreq', 3);
lo = wfdbx.getframes(10);
assert_eq(size(lo), [10 3], 'low resolution');
assert_eq(wfdbx.sampfreq([]), 100, 'low-resolution frequency');
wfdbx.wfdbquit();
wfdbx.isigopen('mfreq', 3);
wfdbx.setgvmode(wfdbx.WFDB_HIGHRES());
hi = wfdbx.getframes(20);
assert_eq(size(hi), [20 3], 'high resolution');
assert_eq(wfdbx.sampfreq([]), 400, 'high-resolution frequency');
assert_eq(wfdbx.getspf(), 4, 'getspf');
wfdbx.setgvmode(wfdbx.WFDB_LOWRES());
wfdbx.wfdbquit();

% Variable-layout multi-segment record (a null segment at 1500)
wfdbx.wfdbquiet();
wfdbx.isigopen('vlay', 3);
wfdbx.isigsettime(1498);
x = wfdbx.getframes(4);
wfdbx.wfdbverbose();
assert_eq(x(3, :), [-32768 -32768 -32768], 'null segment');
segs = wfdbx.getseginfo();
assert_eq(numel(segs), 4, 'segments');
wfdbx.wfdbquit();

% Header writing
si = wfdbx.siginfo(2);
[si.fname] = deal('hw.dat');
[si.fmt] = deal(16);
si(1).gain = 100; si(2).gain = 0;
si(1).units = 'mV'; si(2).units = 'uV';
si(1).desc = 'lead I'; si(2).desc = 'pressure';
si(1).adcres = 16; si(2).adcres = 16;
assert_eq(wfdbx.osigfopen(si), 2, 'osigfopen');
wfdbx.setsampfreq(125.5);
wfdbx.setcfreq(0);      % (not reset by wfdbquit, as in C)
wfdbx.setbasetime('12:00:00 01/02/2003');
for k = 1:10
    wfdbx.putvec([0 0]);
end
assert_eq(wfdbx.newheader('hw'), 0, 'newheader');
assert_eq(wfdbx.putinfo('c1'), 0, 'putinfo');
wfdbx.wfdbquit();
text = char(read_file('hw.hea'));
line1 = sprintf('hw 2 125.5 10 12:00:00 01/02/2003\r\n');
assert(strncmp(text, line1, numel(line1)), 'header line');
assert(~isempty(strfind(text, sprintf('hw.dat 16 100/mV 16 0 0 0 0 lead I\r\n'))), ...
    'signal line');
assert(numel(text) >= 5 && strcmp(text(end-4:end), sprintf('#c1\r\n')), 'info');
assert_eq(wfdbx.getinfo('hw'), 'c1', 'getinfo');
assert_eq(wfdbx.getinfo([]), [], 'getinfo end');
wfdbx.wfdbquit();

write_record_write_error();
write_record_frame_checks();
end

function write_record_write_error()
% A signal file or header that cannot be written raises an error, in both
% modes, after the library's messages.
FULL = '/dev/full';     % a device on which every write fails (ENOSPC)
if exist(FULL, 'file') == 0
    return;             % (no /dev/full on this system)
end
targets = {'full.dat', 'full.hea'};
for t = 1:numel(targets)
    for n = [10 100000]
        for legacy = [false true]
            what = sprintf('write error (%s, %d frames, legacy %d)', ...
                targets{t}, n, legacy);
            link(FULL, targets{t});
            before = wfdbx.wfdbx_write_errors();
            msg = '';
            wfdbx.wfdbquiet();
            try
                wfdbx.write_record('full', zeros(n, 2), 250, 'gains', 200, ...
                    'adcres', 16, 'units', 'mV', 'legacy', legacy);
            catch err
                msg = err.message;
            end
            wfdbx.wfdbverbose();
            assert_eq(msg, 'write error on record full', what);
            assert(wfdbx.wfdbx_write_errors() > before, [what ': count']);
            assert(~isempty(strfind(wfdbx.wfdberror(), ...
                'osigclose: write error')), [what ': message']);
            delete('full.dat');
            delete('full.hea');
        end
    end
end
end

function write_record_frame_checks()
% The columns of signals must add up to a whole frame, and each signal
% has at least one sample per frame; nothing is written otherwise.
x = reshape(0:7, 2, 4)';
opts = {'gains', 200, 'adcres', 16, 'units', 'mV'};
cols = 'signals has 2 columns, but samps_per_frame adds up to ';
ints = 'samps_per_frame must hold integers >= 1';
bad = {1, [cols '1']; 3, [cols '3']; [1 2], [cols '3']; [0 2], ints; ...
    [2 0], ints; [-1 3], ints; [1.5 0.5], ints};
for k = 1:size(bad, 1)
    for legacy = [false true]
        what = sprintf('frame check %d, legacy %d', k, legacy);
        msg = '';
        try
            wfdbx.write_record('bad', x, 250, 'samps_per_frame', bad{k, 1}, ...
                'legacy', legacy, opts{:});
        catch err
            msg = err.message;
        end
        assert_eq(msg, bad{k, 2}, what);
        assert(~isfile('bad.hea') && ~isfile('bad.dat'), [what ': files']);
    end
end
wfdbx.write_record('good', x, 250, 'samps_per_frame', 2, opts{:});
r = wfdbx.read_record('good');
assert_eq(size(r.signals), [4 1], 'samps_per_frame 2');
wfdbx.write_record('good', x, 250, 'samps_per_frame', [1 1], opts{:});
r = wfdbx.read_record('good');
assert_eq(r.signals, x, 'samps_per_frame [1 1]');
end

function link(target, name)
% a symbolic link NAME to TARGET
if wfdbx.internal.is_octave()
    symlink(target, name);
else
    [~, out] = system(['ln -s ' target ' ' name]); %#ok<ASGLU>
end
end

function bulk_check(rec, mode, t0)
if nargin < 3
    t0 = 0;
end
wfdbx.wfdbquiet();
n = wfdbx.isigopen(rec, 0);
wfdbx.isigopen(rec, n);
wfdbx.setgvmode(mode);
wfdbx.isigsettime(t0);
ref = zeros(0, n);
[stat, v] = wfdbx.getvec();
while stat >= 0
    ref(end + 1, :) = v(1:n); %#ok<AGROW>
    [stat, v] = wfdbx.getvec(v);
end
wfdbx.wfdbquit();
wfdbx.isigopen(rec, n);
wfdbx.setgvmode(mode);
wfdbx.isigsettime(t0);
[x, stat2] = wfdbx.getframes(1e9);
wfdbx.wfdbquit();
wfdbx.setgvmode(0);
wfdbx.wfdbverbose();
what = sprintf('getframes = getvec for %s, mode %d', rec, mode);
assert_eq(x, ref, what);
assert_eq(stat2, stat, [what ' (status)']);
end

function roundtrip(fmt, hi, nsig)
r = wfdbx.internal.GlibcRand(fmt * 10 + nsig);
if fmt >= 500
    n = 5003;
else
    n = 1001;
end
u = reshape(r.rand(n * nsig), n, nsig) / wfdbx.internal.GlibcRand.RAND_MAX;
if fmt == 8
    x = cumsum(floor(u * 121) - 60);
else
    x = floor(u * (2 * hi)) - hi + 1;
end
si = wfdbx.siginfo(nsig);
[si.fname] = deal('rt.dat');
[si.fmt] = deal(fmt);
[si.gain] = deal(200);
assert_eq(wfdbx.osigfopen(si), nsig, sprintf('osigfopen %d', fmt));
wfdbx.setsampfreq(250);
wfdbx.putvec(x(1, :));
wfdbx.putframes(x(2:end, :));
wfdbx.newheader('rt');
wfdbx.wfdbquit();
wfdbx.isigopen('rt', nsig);
y = wfdbx.getframes(n + 10);
wfdbx.wfdbquit();
if (fmt == 310 || fmt == 311) && mod(n * nsig, 3) == 2
    % A final group of two samples is written in 4 bytes, so the file
    % appears to contain an extra (zero) sample, as with the C library.
    assert_eq(y(end, :), zeros(1, nsig), sprintf('format %d extra sample', fmt));
    y = y(1:end - 1, :);
end
assert_eq(y, x, sprintf('format %d, %d signals', fmt, nsig));
if nsig ~= 2
    return;
end
% Random access with the per-sample interface
wfdbx.isigopen('rt', nsig);
for t = [n - 1, 0, floor(n / 2), 3, n - 2]
    for s = 0:nsig - 1
        assert_eq(wfdbx.sample(s, t), x(t + 1, s + 1), ...
            sprintf('sample(%d, %d), format %d', s, t, fmt));
    end
end
wfdbx.wfdbquit();
end

function b = read_file(name)
fid = fopen(name, 'rb');
b = fread(fid, Inf, 'uint8=>uint8')';
fclose(fid);
end

function restore(old, oldpath, d)
wfdbx.wfdbquit();
wfdbx.wfdbverbose();
cd(old);
wfdbx.wfdbx_set_input_dir([]);
if isfolder(d)
    rmdir(d, 's');
end
end

function header_fields()
% Signal specifications written in many ways (blanks and tabs between the
% fields, signs, leading zeros, long numbers, missing fields, suffixes of
% the format, baselines and units of the gain, descriptions with blanks)
% are read as strtok, strtol and strtod read them.  (Each signal has its
% own file, so that formats and block sizes may differ.)
r = wfdbx.internal.GlibcRand(23);
ints = {'0', '12', '-7', '+5', '007', '-0', '123456789012345678', ...
    '2147483648', '-2147483649', '12abc', '0x1F', '+', '-', ['1' char(11)]};
gains = {'200', '200.5', '1e3', '200(5)/mV', '200(-12)/uV', '/mV', '200/', ...
    '100(3)', '7(+2)/a/b', '0', '0x10/mV', '2000/NU', ...
    '1234567890123456/mV'};
fmts = {'16', '212', '16x2', '16:3', '16x4:7+100', '212+512', '16x', '16x0', ...
    '16:-2', '0016', '+16'};
sep = {' ', '  ', char(9), [' ' char(9) ' ']};
pick = @(c) c{1 + mod(r.rand(), numel(c))};
nsig = 40;
lines = cell(1, nsig);
for s = 1:nsig
    f = {sprintf('hf%d.dat', s), pick(fmts), pick(gains), pick(ints), ...
        pick(ints), pick(ints), pick(ints), pick({'0', '0', '512', '-3'}), ''};
    nf = 2 + mod(r.rand(), 8);      % the fields written (2-9)
    if nf == 9
        f{9} = pick({'ECG', ' lead II ', 'A  B', ['x' char(9) 'y'], ['z' char(13) 'w']});
    end
    t = f{1};
    for j = 2:nf
        t = [t pick(sep) f{j}]; %#ok<AGROW>
    end
    lines{s} = [t pick({'', ' ', char(9), char(13)})];
end
write_text('hf.hea', sprintf('hf %d 250 1000\n%s\n', nsig, strjoin(lines, char(10))));
[n, si] = wfdbx.isigopen('hf', -nsig);
S = wfdbx.internal.sig_state();
hsd = S.hsd;
wfdbx.wfdbquit();
assert_eq(n, nsig, 'header fields: signals');
for s = 1:nsig
    what = sprintf('header fields: %s', lines{s});
    % the fields, as strtok gives them
    tok = wfdbx.internal.Strtok([lines{s} char(10)]);
    f = cell(1, 9);
    for j = 1:8
        f{j} = tok.next(sprintf(' \t\n\r'));
    end
    f{9} = tok.next(sprintf('\n\r'));
    i = si(s);
    assert_eq(i.fname, f{1}, [what ' (file)']);
    assert_eq(i.fmt, cint32(wfdbx.internal.strtol(f{2})), [what ' (format)']);
    [spf, skew, start] = suffixes(f{2});
    assert_eq(i.spf, spf, [what ' (spf)']);
    assert_eq(hsd(s).skew, fix(skew / spf + 0.5), [what ' (skew)']);
    assert_eq(hsd(s).start, start, [what ' (start)']);
    vals = zeros(1, 5);
    for j = 4:8
        if ischar(f{j})
            vals(j - 3) = wfdbx.internal.strtol(f{j});
        end
    end
    if ischar(f{3})
        assert_eq(i.gain, wfdbx.internal.strtod(f{3}), [what ' (gain)']);
    else
        assert_eq(i.gain, 0, [what ' (gain)']);
    end
    assert_eq(i.adcres, cint32(vals(1)), [what ' (adcres)']);
    assert_eq(i.adczero, cint32(vals(2)), [what ' (adczero)']);
    [base, units] = gain_parts(f{3});
    if isempty(base)
        base = cint32(vals(2));
    end
    assert_eq(i.baseline, base, [what ' (baseline)']);
    assert_eq(i.units, units, [what ' (units)']);
    if ischar(f{6})
        assert_eq(i.initval, cint32(vals(3)), [what ' (initval)']);
    else
        assert_eq(i.initval, cint32(vals(2)), [what ' (initval)']);
    end
    assert_eq(i.cksum, cint32(vals(4)), [what ' (cksum)']);
    assert_eq(i.nsamp, 1000 * ischar(f{7}), [what ' (nsamp)']);
    assert_eq(i.bsize, cint32(vals(5)), [what ' (bsize)']);
    if ischar(f{9})
        assert_eq(i.desc, f{9}, [what ' (desc)']);
    else
        assert_eq(i.desc, sprintf('record hf, signal %d', s - 1), [what ' (desc)']);
    end
end
end

function [spf, skew, start] = suffixes(p)
% The xSPF, :SKEW and +START suffixes of a format field, read with strtol.
spf = 1;
skew = 0;
start = 0;
k = find(p == 'x', 1);
if ~isempty(k) && k > 1 && k < numel(p)
    spf = max(1, cint32(wfdbx.internal.strtol(p, 10, k + 1)));
end
k = find(p == ':', 1);
if ~isempty(k) && k > 1 && k < numel(p)
    skew = max(0, cint32(wfdbx.internal.strtol(p, 10, k + 1)));
end
k = find(p == '+', 1);
if ~isempty(k) && k > 1 && k < numel(p)
    start = max(0, wfdbx.internal.strtol(p, 10, k + 1));
end
end

function [base, units] = gain_parts(p)
% The baseline ("(B)") and units ("/U") of a gain field.
base = [];
units = [];
if ~ischar(p)
    return;
end
k = find(p == '(' | p == '/', 1);
if ~isempty(k) && p(k) == '('
    base = cint32(wfdbx.internal.strtol(p, 10, k + 1));
end
if isempty(k)
    return;
end
j = find(p(k:end - 1) == '/', 1);
if ~isempty(j)
    units = p(k + j:end);
end
end

function y = cint32(x)
y = mod(x + 2147483648, 4294967296) - 2147483648;
end

function putframes_check(fmt, spf, rows0, wide)
% wfdbx.putframes writes the same files as putvec (including after
% ROWS0 frames written by putvec, and with invalid samples, the first and
% the last ones among them).  WIDE: also with values outside the range of
% the format (which wrap as in C).
if nargin < 4
    wide = false;
end
nsig = numel(spf);
r = wfdbx.internal.GlibcRand(fmt + 7 * nsig + rows0);
n = 257;
w = sum(spf);
switch fmt
    case 8
        x = cumsum(mod(reshape(r.rand(n * w), n, w), 301) - 150);
    case {212}
        x = mod(reshape(r.rand(n * w), n, w), 4096) - 2048;
    case {310, 311}
        x = mod(reshape(r.rand(n * w), n, w), 1024) - 512;
    case {80, 508}
        x = mod(reshape(r.rand(n * w), n, w), 256) - 128;
    otherwise
        x = mod(reshape(r.rand(n * w), n, w), 65536) - 32768;
end
x(5, 1) = -32768;
x(rows0 + 1, 1) = -32768;
x(n, end) = -32768;
if wide
    x(7, :) = x(7, :) + 2^20;
    x(9, 1) = -2^31 - 5;
end
si = wfdbx.siginfo(nsig);
for k = 1:nsig
    si(k).fname = 'pf.dat';
    si(k).fmt = fmt;
    si(k).spf = spf(k);
    si(k).gain = 200;
end
files = cell(1, 2);
for method = 1:2
    wfdbx.osigfopen(si);
    wfdbx.setsampfreq(100);
    for t = 1:rows0
        wfdbx.putvec(x(t, :));
    end
    if method == 1
        for t = rows0 + 1:n
            st1 = wfdbx.putvec(x(t, :)); %#ok<NASGU>
        end
    else
        wfdbx.putframes(x(rows0 + 1:end, :));
    end
    wfdbx.newheader('pf');
    wfdbx.wfdbquit();
    files{method} = [read_file('pf.dat'), read_file('pf.hea')];
end
assert_eq(files{2}, files{1}, sprintf('putframes, format %d, spf %s, %d, %d', ...
    fmt, mat2str(spf), rows0, wide));
end

function write_text(name, s)
fid = fopen(name, 'wb');
fwrite(fid, uint8(s));
fclose(fid);
end
