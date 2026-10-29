function status = edf2mit(args)
%EDF2MIT Convert an EDF file to a WFDB (MIT-format) record.
%   STATUS = wfdbx.apps.edf2mit(ARGS) runs the edf2mit tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       edf2mit -i EDFILE [OPTIONS ...]
%   where OPTIONS may include:
%       -b          input is in big-endian byte order
%       -h          print a usage summary
%       -i EDFILE   read the specified European Data Format file
%       -r RECORD   create the specified RECORD (default: input file name
%                   without suffix)
%       -s SIGNAL [SIGNAL ...]  copy only the specified signal(s) (signal
%                   numbers, beginning with zero)
%       -v          print debugging output
%
%   Example (rec.edf stands for an EDF file in the current folder; the
%   example writes the record rec there):
%       wfdbx.apps.edf2mit({'-i', 'rec.edf', '-r', 'rec'})
%
%   See also wfdbx.apps.mit2edf, wfdbx.apps.rdedfann.
%
%   Translation of the C program edf2mit (convert/edf2mit.c, WFDB 10.7.0):
%   same options and output.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of convert/edf2mit.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language and the --legacy
% option (as the first argument, it restores the original behavior).
%
% Original C program: convert/edf2mit.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1996-2004 George B. Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'edf2mit'}, args]);
end

function help(pname)
h = {'where OPTIONS may include:', ...
    ' -b          input is in big-endian byte order (default: little-endian)', ...
    ' -h          print this usage summary', ...
    ' -i EDFILE   read the specified European Data Format file', ...
    ' -r RECORD   create the specified RECORD (default: input file name without', ...
    '              suffix)', ...
    ' -s SIGNAL [SIGNAL ...]  copy only the specified signal(s) (use signal', ...
    '              numbers, beginning with zero;  default: copy all signals)', ...
    ' -v          print debugging output', ...
    'This program reads an EDF file and creates MIT-format signal and header', ...
    'files containing the same data.'};
wfdbx.internal.ceprintf('usage: %s [OPTIONS ...]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function x = gcd_f(x, y)
if x > y
    tol = 0.001 * y;   % relative tolerance (as in C)
else
    tol = 0.001 * x;
end
while true
    if x > y && x - y > tol
        x = x - y;
    elseif y > x && y - x > tol
        y = y - x;
    else
        return;
    end
end
end

function [fb, j] = fb_read(fb, n, trim_from)
% Read N bytes of the input into the 81-byte field buffer (stale bytes
% beyond them are kept), then trim trailing spaces from TRIM_FROM back.
% J is the (0-based) index of the last byte kept (-1 if none).
if nargin < 3
    trim_from = n;
end
avail = min(n, numel(fb.data) - fb.pos);
if avail > 0
    fb.buf(1:avail) = fb.data(fb.pos + 1:fb.pos + avail);
    fb.pos = fb.pos + avail;
end
if n < numel(fb.buf)
    fb.buf(n + 1) = 32;
end
j = trim_from;
while j >= 0 && fb.buf(j + 1) == 32
    fb.buf(j + 1) = 0;
    j = j - 1;
end
end

function s = fb_str(fb)
k = find(fb.buf == 0, 1);
if isempty(k)
    s = char(fb.buf);
else
    s = char(fb.buf(1:k - 1));
end
end

function show(fb, vflag, label)
if vflag
    wfdbx.internal.cout(sprintf('%s: ''%s''\n', label, fb_str(fb)));
end
end

function M = record_frames(B, siglist, so_spf, fpb, big_endian)
% The frames of F data records.  B{k} holds the bytes of input signal k
% (2*spb(k)-by-F); returns (fpb*F)-by-tspf samples.
F = size(B{1}, 2);
nosig = numel(siglist);
cols = cell(1, nosig);
for jj = 1:nosig
    b = double(B{siglist(jj) + 1});
    nsb = floor(size(b, 1) / 2);
    spf = so_spf(jj);
    n = fpb * spf;
    if big_endian
        x = b(1:2:2 * nsb, :) * 256 + b(2:2:2 * nsb, :);
    else
        x = b(2:2:2 * nsb, :) * 256 + b(1:2:2 * nsb, :);
    end
    x = x - 65536 * (x >= 32768);
    if nsb >= n
        x = x(1:n, :);
    else
        x = [x; zeros(n - nsb, F)]; %#ok<AGROW>
    end
    cols{jj} = reshape(x, spf, fpb * F).';
end
M = [cols{:}];
end

function status = main(argv)
pname = argv{1};
argc = numel(argv);
record = '';
big_endian = 0;
vflag = 0;
siglist = [];
data = [];
iname = '';
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
            case 'b'
                big_endian = 1;
            case 'h'
                help(pname);
                status = 0;
                return;
            case 'i'
                i = i + 1;
                if i < argc
                    iname = argv{i + 1};
                    if strcmp(argv{i + 1}, '-')
                        data = wfdbx.internal.stdin_bytes();
                    else
                        fid = fopen(argv{i + 1}, 'rb');
                        if fid < 0
                            wfdbx.internal.ceprintf('%s: can''t read %s\n', pname, argv{i + 1});
                            status = 1;
                            return;
                        end
                        data = fread(fid, Inf, 'uint8=>uint8')';
                        fclose(fid);
                        if isempty(record)
                            nm = argv{i + 1};
                            nm = nm(1:min(numel(nm), 50));     % WFDB_MAXRNL
                            r = nm;
                            nr = 0;
                            for q = 1:numel(nm)
                                ch = nm(q);
                                if (ch >= '0' && ch <= '9') || (ch >= 'A' && ch <= 'Z') ...
                                        || (ch >= 'a' && ch <= 'z')
                                    nr = nr + 1;
                                    r(nr) = ch;
                                elseif ch == '.'
                                    break;
                                else
                                    nr = nr + 1;
                                    r(nr) = '_';
                                end
                            end
                            record = r(1:nr);
                        end
                    end
                    data = reshape(uint8(data), 1, []);
                end
            case 'r'
                i = i + 1;
                if i < argc
                    record = argv{i + 1};
                    record = record(1:min(numel(record), 50));   % WFDB_MAXRNL
                else
                    wfdbx.internal.ceprintf('%s: record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
            case 's'
                j = 0;
                while i + j + 1 < argc && ~strncmp(argv{i + j + 2}, '-', 1)
                    j = j + 1;
                end
                if j == 0
                    wfdbx.internal.ceprintf('%s: signal list must follow -s\n', pname);
                    status = 1;
                    return;
                end
                for q = 1:j
                    siglist(end + 1) = wfdbx.internal.atoi(argv{i + q + 1}); %#ok<AGROW>
                end
                i = i + j;
            case 'v'
                vflag = 1;
        end
    end
    i = i + 1;
end
if ~isa(data, 'uint8')
    help(pname);
    status = 1;
    return;
end
if isempty(record) || wfdbx.newheader(record) < 0
    wfdbx.internal.ceprintf('\n');
    help(pname);
    wfdbx.internal.ceprintf('\nRun %s again, specifying a valid name for the output record,\n', argv{1});
    wfdbx.internal.ceprintf('using the -r option as described above.\n\n');
    wfdbx.internal.ceprintf('  Valid record names may include letters, digits, and underscores only.\n');
    status = 1;
    return;
end
io = wfdbx.internal.io_state();
hea_file = io.wfdb_filename;     % (the header newheader created)
% WFDB-x: if the input is shorter than the 256-byte fixed part of the EDF
% header (C takes the missing fields from uninitialized memory; see
% KNOWN_C_BEHAVIORS.md), and its first 8 bytes are not those of another
% format, the program stops, and no output file remains.
if numel(data) < 256 && (numel(data) < 8 || isequal(char(data(1:8)), '0       '))
    wfdbx.wfdbquit();
    if ischar(hea_file) && isfile(hea_file)
        delete(hea_file);
    end
    wfdbx.internal.ceprintf('%s: incomplete EDF header in %s\n', pname, iname);
    status = 2;
    return;
end
fb.data = data;
fb.pos = 0;
fb.buf = zeros(1, 81, 'uint8');   % the longest header field (80 bytes) + null
navail = min(8, numel(data));
fb.buf(1:navail) = data(1:navail);
fb.pos = navail;
if ~isequal(char(fb.buf(1:8)), '0       ')
    wfdbx.internal.ceprintf('%s: input does not appear to be EDF -- no conversion attempted.\n', pname);
    status = 2;
    return;
end
fb.buf(9) = 32;
j = 8;
while j >= 0 && fb.buf(j + 1) == 32
    fb.buf(j + 1) = 0;
    j = j - 1;
end
show(fb, vflag, 'EDF version number');
fb = fb_read(fb, 80);
show(fb, vflag, 'Patient ID');
fb = fb_read(fb, 80);
show(fb, vflag, 'Recording ID');
fb = fb_read(fb, 8);
show(fb, vflag, 'Recording date');
[n, v] = wfdbx.internal.csscanf(fb_str(fb), '%d%*c%d%*c%d');
dmy = [0 0 0];
for q = 1:max(n, 0)
    dmy(q) = wfdbx.internal.cint32(v{q});
end
day = dmy(1); month = dmy(2); year = dmy(3);
if year < 1970          % a two-digit year: 1970 to 2069
    year = year + 1900;
end
if year < 1970
    year = year + 100;
end
fb = fb_read(fb, 8);
show(fb, vflag, 'Recording time');
[n, v] = wfdbx.internal.csscanf(fb_str(fb), '%d%*c%d%*c%d');
hms = [0 0 0];
for q = 1:max(n, 0)
    hms(q) = wfdbx.internal.cint32(v{q});
end
fb = fb_read(fb, 8);
show(fb, vflag, 'Number of bytes in header record');
[fb, j] = fb_read(fb, 44);
if j > 0
    show(fb, vflag, 'Free space');
end
fb = fb_read(fb, 8);
show(fb, vflag, 'Number of data records');
fb = fb_read(fb, 8);
show(fb, vflag, 'Duration of each data record in seconds');
[n, v] = wfdbx.internal.csscanf(fb_str(fb), '%lf');
spr = 0;
if n == 1
    spr = v{1};
end
if spr <= 0
    spr = 1;
end
fb = fb_read(fb, 4);
show(fb, vflag, 'Number of signals');
[n, v] = wfdbx.internal.csscanf(fb_str(fb), '%d');
nsig = 0;
if n == 1
    nsig = wfdbx.internal.cint32(v{1});
end
if nsig < 1
    status = 1;
    return;
end
si = wfdbx.siginfo(nsig);
for k = 1:nsig
    si(k).spf = 0;
end
spb = zeros(1, nsig);
sigdmax = zeros(1, nsig);
sigdmin = zeros(1, nsig);
sigpmax = zeros(1, nsig);
sigpmin = zeros(1, nsig);
sampfreq = zeros(1, nsig);
if isempty(siglist)
    siglist = 0:nsig - 1;
else
    for q = 1:numel(siglist)
        s = siglist(q);
        if s < 0 || s >= nsig
            wfdbx.internal.ceprintf('%s: invalid signal number, %d, in signal list\n', pname, s);
            status = 1;
            return;
        end
    end
end
nosig = numel(siglist);
for k = 1:nsig
    fb = fb_read(fb, 16, 15);
    if vflag
        wfdbx.internal.cout(sprintf('Signal %d label: ''%s''\n', k - 1, fb_str(fb)));
    end
    si(k).desc = fb_str(fb);
end
for k = 1:nsig
    [fb, j] = fb_read(fb, 80);
    if vflag && j > 0
        wfdbx.internal.cout(sprintf('Signal %d transducer type: ''%s''\n', k - 1, fb_str(fb)));
    end
end
for k = 1:nsig
    fb = fb_read(fb, 8);
    if vflag
        wfdbx.internal.cout(sprintf('Signal %d physical dimension: ''%s''\n', k - 1, fb_str(fb)));
    end
    si(k).units = fb_str(fb);
end
labels = {'physical minimum', 'physical maximum', 'digital minimum', 'digital maximum'};
convs = {'%lf', '%lf', '%ld', '%ld'};
for L = 1:4
    for k = 1:nsig
        fb = fb_read(fb, 8);
        if vflag
            wfdbx.internal.cout(sprintf('Signal %d %s: ''%s''\n', k - 1, labels{L}, fb_str(fb)));
        end
        [n, v] = wfdbx.internal.csscanf(fb_str(fb), convs{L});
        if n == 1
            switch L
                case 1
                    sigpmin(k) = v{1};
                case 2
                    sigpmax(k) = v{1};
                case 3
                    sigdmin(k) = v{1};
                case 4
                    sigdmax(k) = v{1};
            end
        end
    end
end
for k = 1:nsig
    if sigpmax(k) == sigpmin(k)
        wfdbx.internal.ceprintf('gain for signal %d is undefined\n', k - 1);
        continue;
    end
    si(k).adczero = wfdbx.internal.cint32(wfdbx.internal.cdiv(sigdmax(k) + 1 + sigdmin(k), 2));
    adcrange = sigdmax(k) - sigdmin(k);
    si(k).gain = adcrange / (sigpmax(k) - sigpmin(k));
    j = 0;
    while adcrange > 1
        adcrange = wfdbx.internal.cdiv(adcrange, 2);
        j = j + 1;
    end
    si(k).adcres = j;
    si(k).baseline = wfdbx.internal.d2i(sigdmax(k) - sigpmax(k) * si(k).gain + 1);
end
for k = 1:nsig
    [fb, j] = fb_read(fb, 80);
    if vflag && j > 0
        wfdbx.internal.cout(sprintf('Signal %d filtering information: ''%s''\n', k - 1, fb_str(fb)));
    end
end
for k = 1:nsig
    fb = fb_read(fb, 8);
    if vflag
        wfdbx.internal.cout(sprintf('Signal %d number of samples per record: ''%s''\n', ...
            k - 1, fb_str(fb)));
    end
    [n, v] = wfdbx.internal.csscanf(fb_str(fb), '%lf');
    if n == 1
        sampfreq(k) = v{1};
    end
    [n, v] = wfdbx.internal.csscanf(fb_str(fb), '%d');
    if n == 1
        spb(k) = wfdbx.internal.cint32(v{1});
    end
    sampfreq(k) = sampfreq(k) / spr;
end
for k = 1:nsig
    [fb, j] = fb_read(fb, 32);
    if vflag && j > 0
        wfdbx.internal.cout(sprintf('Signal %d free space: ''%s''\n', k - 1, fb_str(fb)));
    end
end
sps = sampfreq(siglist(1) + 1);
for k = 2:nosig
    if sampfreq(siglist(k) + 1) ~= sps
        sps = gcd_f(sps, sampfreq(siglist(k) + 1));
    end
end
wfdbx.setsampfreq(sps);
wfdbx.setbasetime(sprintf('%02d:%02d:%02d %02d/%02d/%04d', hms(1), hms(2), ...
    hms(3), day, month, year));
fname = [record '.dat'];
so = wfdbx.siginfo(nosig);
for k = 1:nosig
    s = siglist(k) + 1;
    si(s).fname = fname;
    si(s).fmt = 16;
    si(s).spf = fix(sampfreq(s) / sps + 0.5);
    so(k) = si(s);
end
fpb = wfdbx.internal.cdiv(spb(siglist(1) + 1), si(siglist(1) + 1).spf);
if vflag
    wfdbx.internal.cout(sprintf('\nOUTPUT:\nBase sampling frequency: %s Hz\n', ...
        wfdbx.internal.csprintf('%g', sps)));
end
for k = 1:nosig
    j = si(siglist(k) + 1).spf;
    if vflag
        if j > 1
            pl = 's';
        else
            pl = '';
        end
        wfdbx.internal.cout(wfdbx.internal.csprintf( ...
            ' Signal %d samples per second: %g (%d sample%s per frame)\n', ...
            k - 1, sampfreq(siglist(k) + 1), j, pl));
    end
end
so_spf = [so.spf];
wfdbx.osigfopen(so, nosig);
% The data records: whole records are converted at once; the last
% (partial) one is read as C does, keeping stale bytes from the record
% before it.
nb = 2 * max(spb, 0);
R = sum(nb);
rest = fb.data(fb.pos + 1:end);
rest = rest(:);
L = numel(rest);
if nb(nsig) >= 2 && fpb > 0
    if R > 0
        F = floor(L / R);
    else
        F = 0;
    end
    vin = cell(1, nsig);
    for k = 1:nsig
        vin{k} = zeros(nb(k), 1, 'uint8');
    end
    if F > 0
        blk = reshape(rest(1:F * R), R, F);
        off = 0;
        B = cell(1, nsig);
        for k = 1:nsig
            B{k} = blk(off + 1:off + nb(k), :);
            vin{k} = B{k}(:, end);
            off = off + nb(k);
        end
        wfdbx.putframes(record_frames(B, siglist, so_spf, fpb, big_endian));
    end
    pos = F * R;
    jl = 0;
    for k = 1:nsig
        got = min(nb(k), L - pos);
        if got > 0
            vin{k}(1:got) = rest(pos + 1:pos + got);
            pos = pos + got;
        else
            got = 0;
        end
        jl = floor(got / 2);
    end
    if jl > 0
        wfdbx.putframes(record_frames(vin, siglist, so_spf, fpb, big_endian));
    end
end
wfdbx.newheader(record);
wfdbx.wfdbquit();
status = 0;
end
