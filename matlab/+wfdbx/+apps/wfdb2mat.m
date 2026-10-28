function status = wfdb2mat(args)
%WFDB2MAT Convert a WFDB record into a MATLAB/Octave .mat file.
%   STATUS = wfdbx.apps.wfdb2mat(ARGS) runs the wfdb2mat tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       wfdb2mat -r RECORD [OPTIONS ...]
%   where OPTIONS may include:
%       -f TIME     begin at specified time
%       -h          print a usage summary
%       -H          read multifrequency signals in high resolution mode
%       -l INTERVAL truncate output after the specified time interval
%       -s SIGNAL [SIGNAL ...]  convert only the specified signal(s)
%       -S SIGNAL   begin at the first valid sample of SIGNAL
%       -t TIME     stop at specified time
%   Outputs are written to the current directory as RECORDm.mat and
%   RECORDm.hea.
%
%   WFDB-x: the record must specify its sampling frequency (the C program
%   assumed 250 Hz), and uncalibrated signals remain uncalibrated in the
%   output header (the C program wrote 200 adu/mV); unspecified units are
%   written as "nd" (the C program wrote "mV"); see docs/DIVERGENCES.md.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository; the example writes 100s.mat and 100sm.hea in the current
%   folder):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.wfdb2mat({'-r', '100s'})
%
%   See also wfdbx.apps.rdsamp, wfdbx.read_record.
%
%   Translation of the C program wfdb2mat (convert/wfdb2mat.c, WFDB 10.7.0):
%   same options and output. Differences: no sampling frequency or gain is
%   assumed; see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of convert/wfdb2mat.c from the WFDB
% Software Package 10.7.0, by George B. Moody. The translation follows the
% logic and behavior of the original program, but it is new code, not the
% original C code.
%
% Changes from the original: no built-in sampling frequency, gain or units: the
% record must give the sampling frequency (the original assumed 250 Hz),
% uncalibrated signals stay uncalibrated in the output header (the original
% wrote 200 adu/mV), and unspecified units are written as "nd" (the original
% wrote "mV"); --legacy, as the first argument, restores the original behavior.
% Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the
% reasons.
%
% Original C program: convert/wfdb2mat.c, WFDB Software Package 10.7.0.
%   Copyright (C) 2009-2013 George B. Moody; revised 2014-2021 by
%   Benjamin Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'wfdb2mat'}, args]);
end

function help(pname)
h = {'where RECORD is the name of the input record, and OPTIONS may include:', ...
    ' -f TIME     begin at specified time', ...
    ' -h          print this usage summary', ...
    ' -H          read multifrequency signals in high resolution mode', ...
    ' -l INTERVAL truncate output after the specified time interval (hh:mm:ss)', ...
    ' -s SIGNAL   [SIGNAL ...]  convert only the specified signal(s)', ...
    ' -S SIGNAL   search for a valid sample of the specified SIGNAL at or after', ...
    [char(9) char(9) 'the time specified with -f, and begin converting then'], ...
    ' -t TIME     stop at specified time', ...
    'Outputs are written to the current directory as RECORD.mat and RECORDm.hea.'};
wfdbx.internal.ceprintf('usage: %s -r RECORD [OPTIONS ...]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function [rows, stat] = read_vecs(n, nsig, vec)
% Up to N calls of getvec, stopping after the first one that fails; ROWS
% holds the vector left by each call (including the failing one, as C
% leaves it), STAT the status of the last call.
parts = {};
got = 0;
stat = nsig;
acc = zeros(0, nsig);
nrows = 0;
while got < n
    [blk, ok] = wfdbx.internal.bulk_frames(n - got);
    if ok && ~isempty(blk)
        if nrows > 0
            parts{end + 1} = acc(1:nrows, :); %#ok<AGROW>
            nrows = 0;
        end
        parts{end + 1} = blk(:, 1:nsig); %#ok<AGROW>
        got = got + size(blk, 1);
        vec(1:nsig) = blk(end, 1:nsig);
        continue;
    end
    [stat, vec] = wfdbx.getvec(vec);
    if nrows == size(acc, 1)
        acc = [acc; zeros(max(16, nrows), nsig)]; %#ok<AGROW>
    end
    nrows = nrows + 1;
    acc(nrows, :) = vec(1:nsig);
    got = got + 1;
    if stat < 0
        break;
    end
end
if nrows > 0
    parts{end + 1} = acc(1:nrows, :);
end
if isempty(parts)
    rows = zeros(0, nsig);
else
    rows = vertcat(parts{:});
end
end

function s = lstrip(s)
k = find(s ~= ' ', 1);
if isempty(k)
    s = '';
else
    s = s(k:end);
end
end

function b = le32(x)
x = mod(x, 4294967296);
b = mod(floor(x ./ [1 256 65536 16777216]), 256);
end

function status = main(argv)
MAT8 = 2; MAT16 = 3; MAT32 = 5;
pname = argv{1};
argc = numel(argv);
record = [];
search = [];
highres = 0;
nosig = 0;
isiglist = 0;
frm = 0; maxl = 0; to = 0;
i = 1;
while i < argc
    a = argv{i + 1};
    if strncmp(a, '-', 1)
        if numel(a) >= 2
            c = a(2);
        else
            c = char(0);
        end
        switch c
            case 'f'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: time must follow -f\n', pname);
                    status = 1;
                    return;
                end
                frm = i;
            case 'h'
                help(pname);
                status = 0;
                return;
            case 'H'
                highres = 1;
            case 'l'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: max output length must follow -l\n', pname);
                    status = 1;
                    return;
                end
                maxl = i;
            case 'r'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i + 1};
            case 's'
                isiglist = i + 1;
                while i + 1 < argc && ~strncmp(argv{i + 2}, '-', 1)
                    i = i + 1;
                    nosig = nosig + 1;
                end
                if nosig == 0
                    wfdbx.internal.ceprintf('%s: signal list must follow -s\n', pname);
                    status = 1;
                    return;
                end
            case 'S'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: signal name or number must follow -S\n', pname);
                    status = 1;
                    return;
                end
                search = argv{i + 1};
            case 't'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: time must follow -t\n', pname);
                    status = 1;
                    return;
                end
                to = i;
            otherwise
                wfdbx.internal.ceprintf('%s: unrecognized option %s\n', pname, a);
                status = 1;
                return;
        end
    else
        wfdbx.internal.ceprintf('%s: unrecognized argument %s\n', pname, a);
        status = 1;
        return;
    end
    i = i + 1;
end
if ~ischar(record)
    help(pname);
    status = 1;
    return;
end
nisig = wfdbx.isigopen(record, 0);
if nisig <= 0
    status = 2;
    return;
end
[nisig, si] = wfdbx.isigopen(record, nisig);
if nisig <= 0
    status = 2;
    return;
end
vi = zeros(1, nisig);
% WFDB-x: uncalibrated signals remain uncalibrated in the output (the C
% program assumed 200 adu/mV), and the output header needs the sampling
% frequency (the C program assumed 250 Hz).  Legacy mode: as in the C
% program.
legacy = wfdbx.wfdbx_get_legacy();
if legacy
    for k = 1:nisig
        if si(k).gain == 0
            si(k).gain = 200;   % WFDB_DEFGAIN
        end
    end
end
if highres
    wfdbx.setgvmode(1);     % WFDB_HIGHRES
end
freq = wfdbx.sampfreq([]);
if freq <= 0 && ~legacy
    wfdbx.internal.ceprintf( ...
        '%s: sampling frequency of record %s is not specified\n', pname, record);
    status = 2;
    return;
end
if frm > 0
    frm = wfdbx.strtim(argv{frm + 1});
    if frm < 0
        frm = -frm;
    end
end
if wfdbx.isigsettime(frm) < 0
    status = 2;
    return;
end
if to > 0
    to = wfdbx.strtim(argv{to + 1});
    if to < 0
        to = -to;
    end
end
if nosig
    sig = zeros(1, nosig);
    for k = 1:nosig
        s = wfdbx.findsig(argv{isiglist + k});
        if s < 0
            wfdbx.internal.ceprintf('%s: can''t read signal ''%s''\n', pname, argv{isiglist + k});
            status = 2;
            return;
        end
        sig(k) = s;
    end
else
    nosig = nisig;
    sig = 0:nosig - 1;
end
if ischar(search)
    s = wfdbx.findsig(search);
    if s >= 0
        frm = wfdbx.tnextvec(s, frm);
    end
    if s < 0 || frm < 0
        wfdbx.internal.ceprintf('%s: can''t read signal ''%s''\n', pname, search);
        status = 2;
        return;
    end
end
if maxl > 0
    maxl = wfdbx.strtim(argv{maxl + 1});
    if maxl < 0
        maxl = -maxl;
    end
end
if maxl && (to == 0 || to > frm + maxl)
    to = frm + maxl;
end
t = wfdbx.strtim('e');
if t == 0
    % the record length is unknown: find it by a binary search
    wfdbx.wfdbquiet();
    TMAX = 9223372036854775807;     % LONG_MAX
    lower = 0;
    upper = TMAX;
    t = 16 * 1024;
    while lower < upper
        ok = wfdbx.isigsettime(t) >= 0;
        if ok
            [st, vi] = wfdbx.getvec(vi);
            ok = st > 0;
        end
        if ok
            lower = t + 1;
        else
            upper = t;
        end
        if upper == TMAX && t < floor(TMAX / 2)
            t = t * 2;
        else
            t = lower + floor((upper - lower) / 2);
        end
    end
    wfdbx.wfdbverbose();
    if wfdbx.isigsettime(frm) < 0
        status = 2;
        return;
    end
end
if to == 0 || to > t
    to = t;
end
if to <= frm
    wfdbx.wfdbquit();
    wfdbx.internal.ceprintf('%s: no output\n', pname);
    wfdbx.internal.ceprintf(' Use the -f and -t options to specify time limits\n(or type ''%s -h'' for help)\n', ...
        pname);
    status = 1;
    return;
end
sfname = numel(record) > 0 && record(end) == '/';
p = numel(record) - 1;
while true
    p = p - 1;
    if ~(p > 0)
        break;
    end
    if record(p + 1) == '/'
        p = p + 1;
        break;
    end
end
if p < 0
    p = 0;
end
base = record(p + 1:end);
orec = base(1:numel(base) - sfname);
orec(orec == '.') = '_';
orec = [orec 'm'];
matname = [orec '.mat'];
nbytes = 1;
for k = 1:nosig
    s = si(sig(k) + 1);
    if s.adcres > 0
        if s.adcres > 16
            nbytes = 4;
        elseif s.adcres > 8 && nbytes < 2
            nbytes = 2;
        end
    else
        if s.fmt == 24 || s.fmt == 32
            nbytes = 4;
        elseif s.fmt ~= 80 && nbytes < 2
            nbytes = 2;
        end
    end
end
if nbytes == 1
    sub4type = MAT8;
    wfdbtype = 80;
elseif nbytes == 2
    sub4type = MAT16;
    wfdbtype = 16;
else
    sub4type = MAT32;
    wfdbtype = 32;
end
so = wfdbx.siginfo(nosig);
adczero = zeros(1, nosig);
for k = 1:nosig
    o = si(sig(k) + 1);
    adczero(k) = o.adczero;
    o.fname = matname;
    o.group = 0;
    o.spf = 1;
    o.fmt = wfdbtype;
    o.adczero = 0;
    o.baseline = o.baseline - adczero(k);
    if ~ischar(o.units)
        o.units = 'nd';     % WFDB-x: missing units are not assumed to be millivolts
        if legacy           % (except in legacy mode, as in the C program)
            o.units = 'mV';
        end
    elseif isempty(o.units)
        o.units = 'nd';
    end
    so(k) = o;
end
max_length = floor(floor(2147483648 / nbytes) / nosig);   % 2 GB limit
if (to - frm) > max_length
    wfdbx.internal.ceprintf('%s: cannot write mat file - data size exceeds 2GB limit\n', pname);
    status = 1;
    return;
end
nbytesofdata = nbytes * nosig * (to - frm);
% the size of the matrix element: the subelements (56 bytes) and the
% data, padded to a multiple of 8 bytes
lremain = mod(nbytesofdata, 8);
if lremain == 0
    nbytesmaster = nbytesofdata + 56;
else
    nbytesmaster = nbytesofdata + 64 - lremain;
    for k = 1:nosig
        so(k).bsize = 8;
    end
end
if wfdbx.osigfopen(so, nosig) ~= nosig
    wfdbx.wfdbquit();
    status = 1;
    return;
end
% The MAT-file (version 5) prolog: a 128-byte text header (version 0x0100,
% 'IM': little-endian), then a matrix element: its tag (type, size) and
% the subelements array flags, dimensions, name ('val') and the tag of
% the data.  (prolog(k + 1) is C's prolog[k].)
mastertype = 14;        % miMATRIX
sub1type = 6;           % miUINT32: array flags
sub1class = 6;          % mxDOUBLE_CLASS
sub2type = 5;           % miINT32: dimensions
sub3type = 1;           % miINT8: name
fieldversion = 256;
prolog = zeros(1, 192);
prolog(1:10) = double('MATLAB 5.0');
prolog(125:126) = [mod(fieldversion, 256), floor(fieldversion / 256)];
prolog(127) = double('I');
prolog(128) = double('M');
prolog(129) = mastertype;
prolog(133:136) = le32(nbytesmaster);
prolog(137) = sub1type;
prolog(141) = 8;
prolog(145) = sub1class;
prolog(153) = sub2type;
prolog(157) = 8;
prolog(161:164) = le32(nosig);
prolog(165:168) = le32(to - frm);
prolog(169) = sub3type;
prolog(173) = 3;
prolog(177:179) = double('val');
prolog(185) = sub4type;
prolog(189:192) = le32(nbytesofdata);
wfdbx.wfdbputprolog(uint8(prolog), numel(prolog), 0);
rows = read_vecs(to - frm, nisig, vi);
vo = rows(:, sig + 1) - repmat(adczero, size(rows, 1), 1);
wfdbx.putframes(vo);
t = frm + size(rows, 1);
if t ~= to
    wfdbx.internal.ceprintf('%s (warning): final %d columns are invalid\n', pname, to - t);
    wfdbx.putframes(-32768 * ones(to - t, nosig));     % WFDB_INVALID_SAMPLE
end
wfdbx.setsampfreq(freq);
p = wfdbx.mstimstr(-frm);
if strncmp(p, '[', 1)
    wfdbx.setbasetime(p(2:end));
end
wfdbx.newheader(orec);
p = wfdbx.getinfo([]);
while ischar(p)
    wfdbx.putinfo(p);
    p = wfdbx.getinfo([]);
end
wfdbx.putinfo(['Creator: ' pname]);
p = ['Source: record ' record];
q = lstrip(wfdbx.mstimstr(0));
if frm ~= 0 || strncmp(q, '[', 1)
    p = [p '  Start: ' q];
end
wfdbx.putinfo(p);
if wfdbtype == 80
    offset = 128;
else
    offset = 0;
end
cs = @wfdbx.internal.csprintf;
out = {};
out{end + 1} = sprintf('%s\n', p);
if nosig == 1
    s1 = '';
else
    s1 = 's';
end
if to == frm + 1
    s2 = '';
else
    s2 = 's';
end
out{end + 1} = sprintf('val has %d row%s (signal%s) and %d column%s (sample%s/signal)\n', ...
    nosig, s1, s1, to - frm, s2, s2);
out{end + 1} = sprintf('Duration: %s\n', wfdbx.timstr(to - frm));
out{end + 1} = sprintf('Sampling frequency: %s Hz  Sampling interval: %s sec\n', ...
    cs('%.12g', freq), cs('%.10g', 1 / freq));
out{end + 1} = sprintf('Row\tSignal\tGain\tBase\tUnits\n');
for k = 1:nosig
    out{end + 1} = cs('%d\t%s\t%s\t%d\t%s\n', k, so(k).desc, cs('%.12g', so(k).gain), ...
        so(k).baseline + offset, so(k).units); %#ok<AGROW>
end
out{end + 1} = sprintf(['\nTo convert from raw units to the physical units shown\n' ...
    'above, call the ''rdmat.m'' function from the wfdb-matlab\n' ...
    'toolbox: https://physionet.org/physiotools/matlab/wfdb-app-matlab/\n']);
wfdbx.internal.cout([out{:}]);
wfdbx.wfdbquit();
status = 0;
end
