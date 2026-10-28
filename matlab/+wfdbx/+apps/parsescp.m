function status = parsescp(args)
%PARSESCP Parse an SCP-ECG file (read from the standard input).
%   STATUS = wfdbx.apps.parsescp(ARGS) runs the parsescp tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       parsescp -o RECORD [OPTIONS ...] <SCPFILE
%   where RECORD is the name (<= 11 alphanumeric characters) of this case,
%   SCPFILE is the name of a file containing ECG data in SCP-ECG format,
%   and OPTIONS may include:
%       -a    anonymize and copy stdin to stdout (suppresses other output)
%       -f    force parsing of a file with CRC errors
%       -h    print brief help
%       -l    low-pass filter (smooth) the output waveforms
%       -v    print a (very) detailed analysis of SCPFILE
%       -w    produce a WFDB-format record
%       -z    zero-mean the input
%   and, for debugging only:
%       -b    show baseline (residuals); suppress templates
%       -s N  shift templates by N samples before adding
%       -S N  skip parsing of section N
%       -t    show templates; suppress baseline
%       -x    show hex dumps (implies -v)
%
%   The output files are RECORD.des (description), RECORD.ecg (samples),
%   RECORD.key (patient data), RECORD.txt (with -v) and, with -w, the
%   WFDB record RECORD (RECORD.hea, RECORD.dat).  WFDB-x: the record's
%   sampling frequency is the one given in SCPFILE, and no record is
%   written if SCPFILE does not give one (the C program always wrote
%   500 Hz); see docs/DIVERGENCES.md.
%
%   See also wfdbx.apps.rdsamp, wfdbx.apps.wfdbdesc.
%
%   Translation of the C program parsescp (convert/parsescp.c, WFDB 10.7.0):
%   same options and output. Differences: the sampling frequency is the one
%   in the SCP file (C: always 500 Hz); see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of convert/parsescp.c from the WFDB
% Software Package 10.7.0, by George B. Moody and Edna S. Moody. The
% translation follows the logic and behavior of the original program, but it is
% new code, not the original C code.
%
% Changes from the original: the record is written with the sampling frequency
% given in the SCP file, and is not written if the file gives none (the
% original always wrote 500 Hz); signals and reference beats that could not be
% allocated, and samples beyond the end of a signal shorter than lead 0, are
% read as absent or as zeros (undefined behavior in the original); --legacy, as
% the first argument, restores the original behavior. Each change is marked
% "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
%
% Original C program: convert/parsescp.c, WFDB Software Package 10.7.0.
%   Copyright (C) 2000-2014 George B. Moody and Edna S. Moody; revised
%   2016-2020 by Benjamin Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'parsescp'}, args]);
end

% The input is held in one byte buffer (P.D, doubles) and the C program's
% pointers into it are represented by 0-based offsets.  Bytes beyond the
% end of the input (which the C program reads in a few places, e.g. at the
% end of section 7 with -v) are read as 0.  C's 64-bit unsigned values
% (sample counts computed from 32-bit fields) are kept as signed values
% v, standing for v modulo 2^64 (see ugt, umin).

function c = K()
% Constants.
persistent k
if isempty(k)
    k.VERSION_STRING = '#ECG/1.0';
    k.MAXALLOC = 2^28;      % larger allocations fail
    k.MINSIGLEN = 5000;     % minimum length of a signal array
    k.ECGLEN = 5000;        % samples in 10 s (the .ecg output, -z median)
    k.SEGLEN = 1250;        % samples in 2.5 s (the segments of the .ecg file)
    k.NVPERADU = 5000;      % amplitude unit of the output (nanovolts)
    k.MAXAGE = 90;          % older ages are censored to this one
    k.UNDEFAXIS = 999;      % an axis that is undefined
    % special values of the measurements (SCP-ECG)
    k.NOTCOMPUTED = 29999;
    k.REJECTED = 29998;
    k.ABSENT = 19999;
    k.DEFAULTHUFF = 19999;  % number of Huffman tables: the default table only
    k.MONTH = {'January', 'February', 'March', 'April', 'May', 'June', ...
        'July', 'August', 'September', 'October', 'November', 'December'};
    k.LEADNAME = {'<Unspecified lead>', 'I', 'II', 'V1', 'V2', ...
        'V3', 'V4', 'V5', 'V6', 'V7', ...
        'V2R', 'V3R', 'V4R', 'V5R', 'V6R', ...
        'V7R', 'X', 'Y', 'Z', 'CC5', ...
        'CM5', 'Left Arm', 'Right Arm', 'Left Leg', 'I (Frank)', ...
        'E', 'C', 'A', 'M', 'F', ...
        'H', 'I-cal', 'II-cal', 'V1-cal', 'V2-cal', ...
        'V3-cal', 'V4-cal', 'V5-cal', 'V6-cal', 'V7-cal', ...
        'V2R-cal', 'V3R-cal', 'V4R-cal', 'V5R-cal', 'V6R-cal', ...
        'V7R-cal', 'X-cal', 'Y-cal', 'Z-cal', 'CC5-cal', ...
        'CM5-cal', 'Left Arm-cal', 'Right Arm-cal', 'Left Leg-cal', ...
        'I-cal (Frank)', ...
        'E-cal', 'C-cal', 'A-cal', 'M-cal', 'F-cal', ...
        'H-cal', 'III', 'aVR', 'aVL', 'aVF', ...
        '-aVR', 'V8', 'V9', 'V8R', 'V9R', ...
        'D (Nehb - Dorsal)', 'A (Nehb - Anterior)', 'J (Nehb - Inferior', ...
        'Defibrillator lead: anterior-lateral', ...
        'External pacing lead: anterior-posterior', ...
        'A1 (Auxiliary unipolar lead 1)', 'A2 (Auxiliary unipolar lead 2)', ...
        'A3 (Auxiliary unipolar lead 3)', 'A4 (Auxiliary unipolar lead 4)', ...
        'V8-cal', ...
        'V9-cal', 'V8R-cal', 'V9R-cal', 'D-cal (Nehb - Dorsal)', ...
        'A-cal (Nehb - Anterior)', ...
        'J-cal (Nehb - Inferior)'};
    % (label, index of the field in a row of P.ecgmeas) of each row of the
    % measurement table; fields: leadid, vlen, Pdur, PRint, QRSdur, QTint,
    % Qdur, Rdur, Sdur, Rpdur, Spdur, Qamp, Ramp, Samp, Rpamp, Spamp, Jamp,
    % Ppamp, Pnamp, Tpamp, Tnamp, STslope, Pmorph, Tmorph, isoI, isoK,
    % tind, qual, st20, st60, st80, strr16, strr8
    k.MEASROWS = { ...
        'P duration    ms', 3; 'PR interval   ms', 4; ...
        'QRS duration  ms', 5; 'QT interval   ms', 6; ...
        'Q duration    ms', 7; 'R duration    ms', 8; ...
        'S duration    ms', 9; 'R'' duration   ms', 10; ...
        'S'' duration   ms', 11; 'Q amplitude   uV', 12; ...
        'R amplitude   uV', 13; 'S amplitude   uV', 14; ...
        'J amplitude   uV', 17; 'P+ amplitude  uV', 18; ...
        'P- amplitude  uV', 19; 'T+ amplitude  uV', 20; ...
        'T- amplitude  uV', 21; 'ST slope    uV/s', 22; ...
        'P morphology  --', 23; 'T morphology  --', 24; ...
        'Isoelec (I)   ms', 25; 'Isoelec (K)   ms', 26; ...
        'Intrins defl  ms', 27; 'Quality       --', 28; ...
        'ST (J+20ms)   uV', 29; 'ST (J+60ms)   uV', 30; ...
        'ST (J+80ms)   uV', 31; 'ST (J+RRm/16) uV', 32; ...
        'ST (J+RRm/8)  uV', 33};
    k.LEADS = {'leadI', 'leadII', 'leadIII', 'aVR', 'aVF', 'aVL', ...
        'V1', 'V2', 'V3', 'V4', 'V5', 'V6'};
end
c = k;
end

function help(pname)
ep = @wfdbx.internal.ceprintf;
ep('usage: %s -o RECORD [OPTIONS ...] <SCPFILE\n', pname);
nl = char(10);
ep('%s', ['  where RECORD is the name (<= 11 alphanumeric characters) of this case,' nl ...
    '  SCPFILE is the name of a file containing ECG data in SCP-ECG format, and' nl ...
    '  OPTIONS may include:' nl ...
    '   -a    anonymize and copy stdin to stdout (suppresses other output).' nl ...
    '   -f    force parsing of a file with CRC errors.' nl ...
    '   -h    print brief help' nl ...
    '   -l    low-pass filter (smooth) the output waveforms.' nl ...
    '   -v    option to print a (very) detailed analysis of SCPFILE.' nl ...
    '   -w    produce a WFDB-format record' nl ...
    '   -z    zero-mean the input' nl nl ...
    '  Additional options for debugging only:' nl ...
    '   -b    show baseline (residuals);  suppress templates' nl ...
    '   -s N  shift templates by N samples before adding' nl ...
    '   -S N  skip parsing of section N' nl ...
    '   -t    show templates; suppress baseline' nl ...
    '   -x    show hex dumps (implies -v)' nl]);
end

% ---- access to the input buffer ----

function v = bt(P, off)
% The byte at OFF (0 beyond the data).
if off >= 0 && off < P.n
    v = P.D(off + 1);
else
    v = 0;
end
end

function v = g16(P, off)
if off >= 0 && off + 1 < P.n
    v = P.D(off + 1) + 256 * P.D(off + 2);
else
    v = bt(P, off) + 256 * bt(P, off + 1);
end
end

function v = g32(P, off)
% 32-bit little-endian value, sign-extended (*p << 24 is an int).
if off >= 0 && off + 3 < P.n
    d = P.D(off + 1:off + 4);
    v = d(1) + 256 * d(2) + 65536 * d(3) + 16777216 * d(4);
else
    v = bt(P, off) + 256 * bt(P, off + 1) + 65536 * bt(P, off + 2) + ...
        16777216 * bt(P, off + 3);
end
if v >= 2147483648
    v = v - 4294967296;
end
end

function b = bytes(P, off, n)
% N bytes from OFF (0 beyond the data), as a row.
b = zeros(1, n);
lo = max(off, 0);
hi = min(off + n, P.n);
if hi > lo
    b(lo - off + 1:hi - off) = P.D(lo + 1:hi);
end
end

function P = put16(P, val, off)
if off >= 0 && off < P.n
    P.D(off + 1) = mod(val, 256);
end
if off + 1 >= 0 && off + 1 < P.n
    P.D(off + 2) = mod(floor(val / 256), 256);
end
end

function s = cstr(P, x)
% The NUL-terminated string at offset X (X may be a char vector).
if ischar(x)
    s = x;
    return;
end
if x < 0 || x >= P.n
    s = '';
    return;
end
j = find(P.D(x + 1:end) == 0, 1);
if isempty(j)
    s = char(P.D(x + 1:end));
else
    s = char(P.D(x + 1:x + j - 1));
end
end

function s = plural(d)
if d == 1
    s = '';
else
    s = 's';
end
end

function crc = getcrc(P, off, len)
% The CRC-CCITT of LEN bytes from OFF (as computed by the C program,
% byte by byte; here two bytes at a time with a 65536-entry table).
persistent T2
if isempty(T2)
    v = 0:65535;
    for k = 1:16
        msb = v >= 32768;
        v = mod(v * 2, 65536);
        v(msb) = bitxor(v(msb), 4129);      % 0x1021
    end
    T2 = v;
end
crc = 65535;
if len <= 0
    return;
end
b = bytes(P, off, len);
nw = floor(len / 2);
w = b(1:2:2*nw) * 256 + b(2:2:2*nw);
for k = 1:nw
    crc = T2(bitxor(crc, w(k)) + 1);
end
if 2 * nw < len
    v = bitxor(crc, b(len) * 256);
    for k = 1:8
        if v >= 32768
            v = bitxor(mod(v * 2, 65536), 4129);   % CRC-CCITT, polynomial 0x1021
        else
            v = mod(v * 2, 65536);
        end
    end
    crc = v;
end
end

function ok = crcok(P, off, len, crcref, desc)
crc = getcrc(P, off, len);
if crc == crcref
    if P.vflag
        wfdbx.internal.cprintf('%s: correct (%d)\n', desc, crc);
    end
    ok = 1;
    return;
end
if P.vflag
    wfdbx.internal.cprintf('%s: error (calculated: %d, expected: %d)\n', ...
        desc, crc, crcref);
end
if P.fflag
    ok = 0;
    return;
end
wfdbx.internal.cexit(1);    % quit on CRC error unless in -f (force) mode
end

% ---- 64-bit unsigned values (kept as signed values) ----

function t = ugt(a, b)
% (unsigned) a > b
if (a < 0) ~= (b < 0)
    t = a < 0;
else
    t = a > b;
end
end

function m = umin(a, b)
if ugt(a, b)
    m = b;
else
    m = a;
end
end

function s = newsig(n)
% calloc(n, sizeof(short)) for a signal; [] if the allocation fails.
c = K();
if n < 0 || n > c.MAXALLOC
    s = [];
else
    s = zeros(max(n, c.MINSIGLEN), 1, 'int16');
end
end

function s = sig(P, k)
% Signal k; a lead index outside the ecg array (undefined behavior in C)
% refers to an array of zero samples, like a missing lead.
if P.has_ecg && k >= 0 && k < numel(P.ecg) && ~isempty(P.ecg{k + 1})
    s = P.ecg{k + 1};
else
    s = zeros(max(P.nout, K().MINSIGLEN), 1, 'int16');
end
end

function P = setsig(P, k, s)
if P.has_ecg && k >= 0 && k < numel(P.ecg) && ~isempty(P.ecg{k + 1})
    P.ecg{k + 1} = s;
end
end

function v = ns(P, k)
% nsamp[k], or 0 if k is outside the nsamp array
if k >= 0 && k < numel(P.nsamp)
    v = P.nsamp(k + 1);
else
    v = 0;
end
end

function y = d2s(x)
% (short)x, via a 32-bit int (vectorized)
y = wfdbx.internal.cint16(wfdbx.internal.d2i(x));
end

function s = escaped(b)
% The bytes B, printable ones as is, others as \ooo.
pr = b >= 32 & b < 127;
if all(pr)
    s = char(b);
    return;
end
c = cell(1, numel(b));
c(pr) = num2cell(char(b(pr)));
np = find(~pr);
for k = reshape(np, 1, [])
    c{k} = sprintf('\\%03o', b(k));
end
s = [c{:}];
end

function out = blockop(f, a, b, out, m)
% out(1:m) = f(a(1:m), b(1:m)) (as doubles), computed in blocks to limit
% the memory used for very long leads.
CHUNK = 1048576;
for b0 = 1:CHUNK:m
    k = b0:min(b0 + CHUNK - 1, m);
    out(k) = f(double(a(k)), double(b(k)));
end
end

% ---- output ----

function P = lowpass(P)
CHUNK = 1048576;
for i = 0:P.nleads - 1
    inp = P.ecg{i + 1};
    if isempty(inp)
        continue;
    end
    n = P.nsamp(i + 1);
    out = newsig(n);
    if isempty(out)
        wfdbx.internal.ceprintf('Insufficient memory for filtering\n');
        break;
    end
    % Samples beyond the end of the input array read as 0, and writes
    % beyond the end of the output array are skipped.
    nin = numel(inp);
    nout = numel(out);
    x = lpget(inp, nin, 0:3);
    out = lpput(out, nout, 0, d2s(x(1) * 0.67 + x(2) * 0.22 + x(3) * 0.11));
    out = lpput(out, nout, 1, d2s(x(1) * 0.33 + x(2) * 0.34 + ...
        x(3) * 0.22 + x(4) * 0.11));
    % C: for (j = 2; j < nsamp[i] - 2; j++), with an unsigned (wrapping)
    % bound; iterations past the end of the output array would only make
    % skipped writes, so the loop stops there (the final writes below are
    % then skipped too).
    if n - 2 < 0
        jend = nout;
    else
        jend = min(n - 2, nout);
    end
    j = 2;
    if jend > 2
        % (in blocks, to limit the memory used for very long leads)
        for b0 = 3:CHUNK:jend
            jj = (b0:min(b0 + CHUNK - 1, jend))';
            x = lpget(inp, nin, (jj(1) - 3:jj(end) + 1)');
            k = (3:numel(x) - 2)';
            out(jj) = d2s(x(k) * 0.34 + (x(k - 1) + x(k + 1)) * 0.22 + ...
                (x(k - 2) + x(k + 2)) * 0.11);
        end
        j = jend;
    end
    x = lpget(inp, nin, j - 2:j + 1);
    out = lpput(out, nout, j, ...
        d2s(x(1) * 0.11 + x(2) * 0.22 + x(3) * 0.34 + x(4) * 0.33));
    out = lpput(out, nout, j + 1, d2s(x(2) * 0.11 + x(3) * 0.22 + x(4) * 0.67));
    P.ecg{i + 1} = out;
end
end

function x = lpget(inp, nin, k)
% Samples k (0-based) of inp, as doubles; samples beyond its end read as 0.
x = zeros(size(k));
v = k < nin;
x(v) = double(inp(k(v) + 1));
end

function out = lpput(out, nout, k, v)
% out[k] = v (0-based); a write beyond the end of out is skipped.
if k < nout
    out(k + 1) = v;
end
end

function fwr(f, varargin)
f.write(uint8(wfdbx.internal.csprintf(varargin{:})));
end

function P = write_output(P)
c = K();
CHUNK = 262144;
if isempty(P.recname)
    P.recname = 'ecg';              % default record name
end
recname = P.recname;
names = {[recname '.des'], [recname '.ecg'], [recname '.key'], ...
    [recname '.txt']};
nf = 3 + (P.vflag ~= 0);
files = cell(1, nf);
for k = 1:nf
    files{k} = wfdbx.internal.OutputFile(names{k}, P.pname, 'ieee-le');
    if files{k}.fid < 0
        for kk = 1:k - 1
            files{kk}.close();
        end
        wfdbx.internal.ceprintf('%s: can''t create ''%s''\n', P.pname, names{k});
        return;
    end
end
dfile = files{1};
efile = files{2};
kfile = files{3};

% Write the description file first.
fwr(dfile, [c.VERSION_STRING ' description\n']);
fwr(dfile, 'Record: %s (%s %s)\n', recname, P.recdate, P.rectime);
fwr(dfile, 'Age: %d\n', P.age);
fwr(dfile, 'Sex: ');
switch P.sex
    case 1
        fwr(dfile, 'M\n');
    case 2
        fwr(dfile, 'F\n');
    case 0
        fwr(dfile, 'not known\n');
    case 9
        fwr(dfile, 'unspecified\n');
    otherwise
        fwr(dfile, '<error>\n');
end
fwr(dfile, 'Referring Dr: %s\n', P.referring_dr);
fwr(dfile, 'Comments: %s\n', P.comments);
if P.tdevid == 0
    fwr(dfile, 'Cart ID: <missing>\n');
else
    fwr(dfile, 'Cart ID: %d\n', P.tdevid);
end
dept = cstr(P, P.dept);
fwr(dfile, 'Department: %s\n', dept);
if P.tdept == 0
    fwr(dfile, 'Department #: <missing>\n');
else
    fwr(dfile, 'Department #: %s\n', dept);
end
fwr(dfile, 'Institution: %s\n', cstr(P, P.inst));
if P.tinst == 0
    fwr(dfile, 'Institution #: <missing>\n');
else
    fwr(dfile, 'Institution #: %d\n', P.tinst);
end
for i = 0:P.stmnts - 1
    r = P.report(i + 1);
    if isnan(r)
        fwr(dfile, 'Report %d: %s\n', i, '(null)');
    else
        fwr(dfile, 'Report %d: %s\n', i, cstr(P, r));
    end
end
fwr(dfile, 'Bandwidth: %g-%d Hz\n', P.blfilt * 0.0001, P.lpfilt);
fwr(dfile, 'Filtering:');
fb = P.filter_bit;
fbb = mod(fb, 2^32);
if bitand(fbb, 1)
    fwr(dfile, ' 60 Hz notch');
end
if bitand(fbb, 2)
    fwr(dfile, ' 50 Hz notch');
end
if bitand(fbb, 4)
    fwr(dfile, ' Artifact filter');
end
if bitand(fbb, 8)
    fwr(dfile, ' Baseline filter');
end
if bitand(fbb, 240)
    fwr(dfile, ' <undefined>');
end
if fb == 0
    fwr(dfile, ' <not specified>');
end
fwr(dfile, '\n\n');
fwr(dfile, 'RR interval: %d\n', P.RRint);
fwr(dfile, 'P onset: %d\n', P.Pon);
fwr(dfile, 'P end: %d\n', P.Pend);
fwr(dfile, 'QRS onset: %d\n', P.QRSon);
fwr(dfile, 'QRS end: %d\n', P.QRSend);
fwr(dfile, 'T end: %d\n', P.Tend);
fwr(dfile, 'P axis: %d\n', P.Paxis);
fwr(dfile, 'QRS axis: %d\n', P.QRSaxis);
fwr(dfile, 'T axis: %d\n', P.Taxis);
dfile.write(uint8(precgmeas(P)));
dfile.close();          % WFDB-x: reports a write error

% Generate the key file.
fwr(kfile, [c.VERSION_STRING ' key\n']);
fwr(kfile, 'Record: %s (%s %s)\n', recname, P.recdate, P.rectime);
fwr(kfile, 'Name: %s\n', P.patient_name);
fwr(kfile, 'MRN: %s\n', P.patient_id);
kfile.close();

% Zero-mean the signals (-z).
if P.zflag
    buf = zeros(1, c.ECGLEN);
    for s = 0:P.nleads - 1
        x = P.ecg{s + 1};
        ns_ = P.nsamp(s + 1);
        if ns_ < 0 || ns_ > c.ECGLEN
            imax = c.ECGLEN;
        else
            imax = ns_;
        end
        buf(1:imax) = sort(double(x(1:imax)));
        m = buf(floor(imax / 2) + 1);
        k = ns_ - 1;
        if k >= 1 && k < numel(x) && x(k + 1) == 0
            x(k + 1) = x(k);
        end
        for b0 = 1:CHUNK:P.nout
            kk = b0:min(b0 + CHUNK - 1, P.nout);
            v = wfdbx.internal.cint16(double(x(kk)) - m);
            v(v < -2000 | v > 2000) = -32768;   % +/-10 mV: WFDB_INVALID_SAMPLE
            x(kk) = v;
        end
        P.ecg{s + 1} = x;
    end
end

% Write the WFDB-format record if requested (-w option).
if P.wflag
    write_wfdb_record(P);
end

order = zeros(1, 12);
for k = 1:12
    order(k) = P.(c.LEADS{k});
end
% Write the ECG in text form if requested (-v option).
if P.vflag
    tfile = files{4};
    if P.vflag > 1
        tfile.write(uint8(['samp#      I     II    III    aVR    aVF    aVL' ...
            '     V1     V2     V3     V4     V5     V6']));
    end
    sigs = cell(1, 12);
    for k = 1:12
        sigs{k} = sig(P, order(k));
    end
    fmt = ['%5d' repmat('%7d', 1, 12) '\n'];
    for b0 = 1:CHUNK:P.nout
        kk = b0:min(b0 + CHUNK - 1, P.nout);
        M = zeros(13, numel(kk));
        M(1, :) = kk - 1;
        for k = 1:12
            M(k + 1, :) = double(sigs{k}(kk))';
        end
        tfile.write(uint8(sprintf(fmt, M)));
    end
    tfile.close();
end

% Finally, output the ECG in vector (binary) form.
if P.lflag == 0
    prolog = wfdbx.internal.csprintf([c.VERSION_STRING ...
        ' signals\nRecord: %s (%s %s)\n'], recname, P.recdate, P.rectime);
else
    prolog = wfdbx.internal.csprintf([c.VERSION_STRING ...
        ' signals\nRecord: %s (%s %s)\nLow-pass filtered\n'], ...
        recname, P.recdate, P.rectime);
    P = lowpass(P);
end
prolog = double(prolog(1:min(end, 512)));
efile.write(uint8([prolog, zeros(1, 512 - numel(prolog))]));
rows = [1 4 7 10; 2 6 8 11; 3 5 9 12];  % (I aVR V1 V4) (II aVL V2 V5) (III aVF V3 V6)
for r = 1:3
    for k = 0:3
        x = sig(P, order(rows(r, k + 1)));
        efile.write(x(c.SEGLEN * k + 1:c.SEGLEN * (k + 1)), 'int16');
    end
end
x = sig(P, order(2));
efile.write(x(1:c.ECGLEN), 'int16');
efile.close();
end

function write_wfdb_record(P)
c = K();
recname = P.recname;
filename = [recname '.dat'];
leadname = {'I', 'II', 'III', 'aVR', 'aVF', 'aVL', 'V1', 'V2', 'V3', ...
    'V4', 'V5', 'V6'};
% WFDB-x: the sampling frequency is the one given in the SCP file (the C
% program always wrote 500 Hz, as legacy mode does); without one, no
% record is written.
legacy = wfdbx.wfdbx_get_legacy();
if ~legacy
    if P.sfreq <= 0
        wfdbx.internal.ceprintf(['%s: sampling frequency not specified; ' ...
            'record %s not written\n'], P.pname, recname);
        return;
    end
    wfdbx.setsampfreq(P.sfreq);
end
if wfdbx.newheader(recname) < 0
    return;
end
if legacy
    wfdbx.setsampfreq(500);     % (as in the C program: "FIXME")
end
s = wfdbx.siginfo(12);
for i = 1:12
    s(i).fname = filename;
    s(i).desc = leadname{i};
    s(i).units = 'mV';
    s(i).fmt = 16;
    % WFDB-x: exact, not assumed: the samples have been rescaled to units
    % of NVPERADU (5000) nV (see gref and gres), i.e., 200 adu/mV
    s(i).gain = 1e6 / c.NVPERADU;   % adu/mV
    s(i).adcres = 16;
    s(i).spf = 0;
end
if wfdbx.osigfopen(s, 12) < 12
    return;
end
wfdbx.setbasetime(sprintf('%s %s\n', P.recdate, P.rectime));
sigs = cell(1, 12);
for k = 1:12
    sigs{k} = sig(P, P.(c.LEADS{k}));
end
CHUNK = 262144;
for b0 = 1:CHUNK:P.nout
    kk = b0:min(b0 + CHUNK - 1, P.nout);
    M = zeros(numel(kk), 12);
    for k = 1:12
        M(:, k) = double(sigs{k}(kk));
    end
    wfdbx.putframes(M);
end
wfdbx.newheader(recname);
age = P.age;
if age >= c.MAXAGE
    age = c.MAXAGE;
end
if P.sex == 1
    sx = 'M';
elseif P.sex == 2
    sx = 'F';
else
    sx = '?';
end
wfdbx.putinfo(wfdbx.internal.csprintf('<age>: %d <sex>: %c', age, sx));
wfdbx.wfdbquit();
end

% ---- sections ----

function hexdump(P, p, ln)
if ln <= 0
    wfdbx.internal.cout(sprintf('Hex dump of data area:\n\n\n\n'));
    return;
end
b = bytes(P, p, ln);
parts = cell(1, ceil(ln / 16));
for r = 1:ceil(ln / 16)
    i0 = (r - 1) * 16;
    parts{r} = [sprintf('\n%4d:  ', i0), ...
        sprintf(' %2x', b(i0 + 1:min(i0 + 16, ln)))];
end
wfdbx.internal.cout([sprintf('Hex dump of data area:\n\n'), [parts{:}], ...
    sprintf('\n\n')]);
end

function P = section0(P, p, ln)
pr = @wfdbx.internal.cprintf;
vflag = P.vflag;
if ~isequal(bytes(P, p + 10, 6), double('SCPECG'))
    if vflag
        pr(' Warning: SCPECG identifier is missing in header\n');
    end
end
p = p + 16;
ln = ln - 16;            % the section ID header
if ln < 10
    if vflag
        pr(' Error: section 0 contains no data\n');
    end
    return;
end
nent = ceil(ln / 10);
if vflag
    for k = 1:nent
        pr('  Section %2d:%6ld bytes beginning at byte %6ld\n', ...
            g16(P, p), g32(P, p + 2), g32(P, p + 6));
        p = p + 10;
    end
end
ln = ln - 10 * nent;
if ln < 0
    if vflag
        pr(' Error: section 0 overlaps the next section\n');
    end
end
end

function P = censor(P, p, ln, c)
cnt = mod(ln - 1, 65536);
hi = min(p + cnt, P.n);
if hi > p
    P.D(p + 1:hi) = c;
end
if p + cnt < P.n
    P.D(p + cnt + 1) = 0;
end
end

function P = section1(P, p, ln)
c = K();
vflag = P.vflag;
aflag = P.aflag;
pr = @wfdbx.internal.cprintf;
tpatid = []; trefdr = []; tcomments = []; tdate = []; ttime = [];
pyob = [];
firstname = []; lastname = [];
p_save = p;
len_save = ln;
TEXT = 0; DATE = 1; TIME = 2; B1 = 3; B2 = 4; B2B1 = 5; BN = 6; MIXED = 7;
X = double('x');
ZERO = double('0');

p = p + 16;
ln = ln - 16;            % the section ID header
if ln < 3
    if vflag
        pr(' Error: section 1 contains no data\n');
    end
    return;
end
names = {17, '\n  Analyzing institution\n'; 18, '\n  Acquiring department\n'; ...
    19, '\n  Analyzing department\n'; 20, '\n  Referring physician\n'; ...
    21, '\n  Latest confirming physician\n'; 22, '\n  Technician\n'; ...
    23, '\n  Room\n'};
while ln > 2
    tag = bt(P, p);
    if tag == 255
        break;          % tag 255 is the terminator
    end
    vlen = g16(P, p + 1);
    if vlen > ln
        if vflag
            pr(' Error: tagged field overlaps next section\n');
        end
        return;
    end
    switch tag
        case 0
            if vflag, pr('\n  Last name\n'); end
            vtype = TEXT;
            lastname = p + 3;
            if aflag
                P = censor(P, lastname, vlen, X);
            end
        case 1
            if vflag, pr('\n  First name\n'); end
            vtype = TEXT;
            firstname = p + 3;
            if aflag
                P = censor(P, firstname, vlen, X);
            end
        case 2
            if vflag, pr('\n  Patient ID number\n'); end
            vtype = TEXT;
            tpatid = p + 3;
            if aflag
                P = censor(P, tpatid, vlen, ZERO);
            end
        case 3
            if vflag, pr('\n  Second last name\n'); end
            vtype = TEXT;
            if aflag
                P = censor(P, p + 3, vlen, X);
            end
        case 4
            if vflag, pr('\n  Age\n'); end
            vtype = B2B1;
            P.age = g16(P, p + 3);
            if aflag && P.age > c.MAXAGE
                P = put16(P, c.MAXAGE, p + 3);  % censor age
            end
        case 5
            if vflag, pr('\n  Date of birth\n'); end
            vtype = DATE;
            if aflag
                pyob = p + 3;
                P = put16(P, 257, p + 5);   % censor month and day
            end
        case 6
            if vflag, pr('\n  Height\n'); end
            vtype = B2B1;
        case 7
            if vflag, pr('\n  Weight\n'); end
            vtype = B2B1;
        case 8
            if vflag, pr('\n  Sex\n'); end
            vtype = B1;
            P.sex = bt(P, p + 3);
        case 9
            if vflag, pr('\n  Race\n'); end
            vtype = B1;
        case 10
            if vflag, pr('\n  Drug\n'); end
            vtype = MIXED;
        case 11
            if vflag, pr('\n  Systolic blood pressure\n'); end
            vtype = B2;
        case 12
            if vflag, pr('\n  Diastolic blood pressure\n'); end
            vtype = B2;
        case 13
            if vflag, pr('\n  Diagnosis or referral indication\n'); end
            vtype = TEXT;
        case 14
            if vflag, pr('\n  ID of the acquiring device\n'); end
            P.tdevid = g16(P, p + 7);
            P.tinst = g16(P, p + 3);    % institution #
            P.tdept = g16(P, p + 5);    % department #
            if vflag
                pr('   Institution number: %d\n', g16(P, p + 3));
                pr('   Department number: %d\n', g16(P, p + 5));
                pr('   Device ID: %d\n', g16(P, p + 7));
                cc = bt(P, p + 9);
                if cc == 0
                    s = 'cart';
                elseif cc == 1
                    s = 'system or host';
                else
                    s = '<error>';
                end
                pr('   Device type: %d (%s)\n', cc, s);
                pr('   Manufacturer code: %d\n', bt(P, p + 10));
                pr('   Text model description: [%d]', bt(P, p + 11));
                pr('   SCP-ECG protocol revision number: %g\n', bt(P, p + 17) / 10.0);
                pr('   SCP-ECG protocol compatibility level: %d\n', bt(P, p + 18));
                pr('   Language support code: %d\n', bt(P, p + 19));
                pr('   Device capabilities: %d\n', bt(P, p + 20));
                cc = bt(P, p + 21);
                pr('   AC mains frequency environment: %d ', cc);
                switch cc
                    case 0
                        pr('(unspecified)\n');
                    case 1
                        pr('(50 Hz)\n');
                    case 2
                        pr('(60 Hz)\n');
                    otherwise
                        pr('<error>');
                end
                q = p + 39;
                labels = {'Analyzing program revision number', ...
                    'Serial number of acquisition device', ...
                    'Acquisition device system software ID', ...
                    'Acquisition device SCP implementation ID', ...
                    'Manufacturer of acquisition device'};
                for k = 1:5
                    s = cstr(P, q);
                    pr('   %s: [%s]\n', labels{k}, s);
                    q = q + numel(s) + 1;
                end
            end
            vtype = MIXED;
        case 15
            if vflag, pr('\n  ID of the analyzing device\n'); end
            vtype = MIXED;
        case 16
            if vflag, pr('\n  Acquiring institution\n'); end
            vtype = TEXT;
            P.inst = p + 3;
            if aflag
                P = censor(P, p + 3, vlen, X);
            end
        case {17, 18, 19, 20, 21, 22, 23}
            if vflag
                pr(names{tag - 16, 2});
            end
            vtype = TEXT;
            if aflag
                P = censor(P, p + 3, vlen, X);
            end
            if tag == 18
                P.dept = p + 3;
            elseif tag == 20
                trefdr = p + 3;
            end
        case 24
            if vflag, pr('\n  Stat code (urgency)\n'); end
            vtype = B1;
        case 25
            if vflag, pr('\n  Date of acquisition\n'); end
            tdate = p + 3;
            if aflag
                P = put16(P, 257, p + 5);   % censor month and day
            end
            vtype = DATE;
        case 26
            if vflag, pr('\n  Time of acquisition\n'); end
            ttime = p + 3;
            vtype = TIME;
        case 27
            if vflag, pr('\n  Baseline filter\n'); end
            vtype = B2;
            P.blfilt = g16(P, p + 3);
        case 28
            if vflag, pr('\n  Low-pass filter\n'); end
            vtype = B2;
            P.lpfilt = g16(P, p + 3);
        case 29
            if vflag, pr('\n  Filter bit map\n'); end
            vtype = B1;
            P.filter_bit = bt(P, p + 3);
        case 30
            if vflag, pr('\n  Free text field (comments)\n'); end
            tcomments = p + 3;
            vtype = TEXT;
        case 31
            if vflag, pr('\n  Sequence number\n'); end
            vtype = TEXT;
        case 32
            if vflag, pr('\n  Medical history codes\n'); end
            vtype = BN;
        case 33
            if vflag, pr('\n  Electrode configuration code\n'); end
            vtype = B2;
        case 34
            if vflag, pr('\n  Time zone\n'); end
            vtype = MIXED;
        case 35
            if vflag, pr('\n  Free text medical history\n'); end
            vtype = TEXT;
        otherwise
            if vflag, pr('\n  <Undefined tag>\n'); end
            vtype = MIXED;
    end
    if vflag
        pr('   Tag%3d (%2d bytes): ', tag, vlen);
    end
    p = p + 3;
    ln = ln - (vlen + 3);
    if vlen == 0
        if vflag
            pr('<not defined>\n');
        end
    elseif vtype == TEXT
        if vflag
            pr('[%*s]', vlen - 1, cstr(P, p));
        end
        p = p + vlen;
    elseif vtype == DATE
        if vlen ~= 4
            if vflag
                pr('  Error: incorrect date format (%d bytes)\n', vlen);
            end
        elseif vflag
            pr('%4d/%02d/%02d', g16(P, p), bt(P, p + 2), bt(P, p + 3));
        end
        p = p + vlen;
    elseif vtype == TIME
        if vlen ~= 3
            if vflag
                pr('  Error: incorrect time format (%d bytes)\n', vlen);
            end
        elseif vflag
            pr('%02d:%02d:%02d', bt(P, p), bt(P, p + 1), bt(P, p + 2));
        end
        p = p + vlen;
    elseif vtype == B1
        if vlen ~= 1
            if vflag
                pr('  Error: incorrect format (%d bytes instead of 1)\n', vlen);
            end
        elseif vflag
            pr('%d', bt(P, p));
        end
        p = p + vlen;
    elseif vtype == B2
        if vlen ~= 2
            if vflag
                pr('  Error: incorrect format (%d bytes instead of 2)\n', vlen);
            end
        elseif vflag
            pr('%d', g16(P, p));
        end
        p = p + vlen;
    elseif vtype == B2B1
        if vlen ~= 3
            if vflag
                pr('  Error: incorrect format (%d bytes instead of 3)\n', vlen);
            end
        elseif vflag
            pr('%d (code %d)', g16(P, p), bt(P, p + 2));
        end
        p = p + vlen;
    elseif vtype == BN
        if vflag
            wfdbx.internal.cout(sprintf('%d, ', bytes(P, p, vlen)));
        end
        p = p + vlen;
    else    % MIXED
        if vflag
            wfdbx.internal.cout([escaped(bytes(P, p, vlen)), char(10)]);
        end
        p = p + vlen;
    end
end

% (tdate and ttime are pointers to signed char)
if ~isempty(tdate)
    mon = wfdbx.internal.cint8(bt(P, tdate + 2)) - 1;
    if mon >= 0 && mon < 12
        ms = c.MONTH{mon + 1};
    else
        ms = '???';
    end
    P.recdate = sprintf('%d %s %d', wfdbx.internal.cint8(bt(P, tdate + 3)), ...
        ms, g16(P, tdate));
end
if ~isempty(ttime)
    P.rectime = sprintf('%02d:%02d:%02d', wfdbx.internal.cint8(bt(P, ttime)), ...
        wfdbx.internal.cint8(bt(P, ttime + 1)), ...
        wfdbx.internal.cint8(bt(P, ttime + 2)));
end
if isempty(lastname)
    lastname = '<last name missing>';
else
    lastname = cstr(P, lastname);
end
if isempty(firstname)
    firstname = '<first name missing>';
else
    firstname = cstr(P, firstname);
end
if numel(lastname) + numel(firstname) < 100 - 3
    P.patient_name = [lastname ', ' firstname];
else
    wfdbx.internal.ceprintf('Patient name (%s, %s) is too long\n', ...
        lastname, firstname);
    P.patient_name = 'Name not available -- too long';
end
if isempty(tpatid)
    tpatid = '<patient ID missing>';
end
s = cstr(P, tpatid);
P.patient_id = s(1:min(end, 30));
if isempty(trefdr)
    trefdr = '<referring physician missing>';
end
s = cstr(P, trefdr);
P.referring_dr = s(1:min(end, 100));
if isempty(tcomments)
    tcomments = '<comments missing>';
end
s = cstr(P, tcomments);
P.comments = s(1:min(end, 200));

if bt(P, p) ~= 255
    if vflag
        pr(' Error: header terminator (tag 255) is missing\n');
    end
end
% (tpatid cannot be NULL here, so that error is never reported)
if P.tdevid == -1 || P.tinst == -1 || P.tdept == -1
    if vflag
        pr(' Error: device ID number (tag 14) is missing\n');
    end
end
if isempty(tdate)
    if vflag
        pr(' Error: date of acquisition (tag 25) is missing\n');
    end
end
if isempty(ttime)
    if vflag
        pr(' Error: time of acquisition (tag 26) is missing\n');
    end
end
if aflag && ~isempty(pyob)
    % (the censored year of birth is computed but never stored)
    % Recalculate the CRC for this section.
    crc = getcrc(P, p_save + 2, len_save - 2);
    P = put16(P, crc, p_save);
end
end

function P = section2(P, p, ln)
p = p + 16;
ln = ln - 16;            % the section ID header
if ln < 2
    if P.vflag
        wfdbx.internal.cprintf('  Error: section 2 contains no data\n');
    end
    return;
end
ntables = g16(P, p);
if ntables == K().DEFAULTHUFF
    if P.vflag
        wfdbx.internal.cprintf('  Using standard Huffman table only\n');
    end
elseif P.vflag
    wfdbx.internal.cprintf('  Number of Huffman tables defined: %d\n', g16(P, p));
    wfdbx.internal.cprintf('  Number of code structures in table 1: %d\n', ...
        g16(P, p + 2));
end
end

function P = section3(P, p, ln)
c = K();
vflag = P.vflag;
pr = @wfdbx.internal.cprintf;
nsmax = 0;
p = p + 16;
ln = ln - 16;            % the section ID header
if ln < 2
    if vflag
        pr('  Error: section3 contains no data\n');
    end
    return;
end
nleads = bt(P, p);
P.nleads = nleads;
p = p + 1;
if vflag
    pr('  Number of leads: %d\n', nleads);
end
ln = ln - 1;
nsamp = zeros(1, nleads + 4);
flags = bt(P, p);
if vflag
    pr('  Flag byte: %xH\n', flags);
end
ln = ln - 1;
if bitand(flags, 1)
    if vflag
        pr('   Reference beat subtraction used for compression\n');
    end
elseif vflag
    pr('   Reference beat subtraction not used for compression\n');
end
if bitand(flags, 4)
    if vflag
        pr('   All leads recorded simultaneously\n');
    end
elseif vflag
    pr('   %d leads recorded simultaneously\n', bitand(floor(flags / 8), 15));
end
p = p + 1;

% the leads: 9 bytes each (start, end, lead ID)
nent = max(0, ceil((ln - 8) / 9));
if nent > 0
    E = reshape(bytes(P, p, 9 * nent), 9, nent);
    s0 = E(1, :) + 256 * E(2, :) + 65536 * E(3, :) + 16777216 * E(4, :);
    s1 = E(5, :) + 256 * E(6, :) + 65536 * E(7, :) + 16777216 * E(8, :);
    s0 = s0 - 4294967296 * (s0 >= 2147483648);
    s1 = s1 - 4294967296 * (s1 >= 2147483648);
    ids = E(9, :);
    ids_map = [1 2 61 62 64 63 3 4 5 6 7 8];  % I II III aVR aVF aVL V1-V6
    for i = 0:nent - 1
        j = ids(i + 1);
        if j < numel(c.LEADNAME)
            if vflag
                pr('  %s', c.LEADNAME{j + 1});
            end
            kk = find(ids_map == j, 1);
            if ~isempty(kk)
                P.(c.LEADS{kk}) = i;
            end
        elseif j < 100
            if vflag
                pr('  <Reserved lead>');
            end
        elseif vflag
            pr('  <Manufacturer-defined lead>');
        end
        if vflag
            pr(': ID %d, samples %lu to %lu\n', j, s0(i + 1), s1(i + 1));
        end
    end
    nsv = s1 - s0 + 1;
    if nent > numel(nsamp)
        nsamp(nent) = 0;
    end
    nsamp(1:nent) = nsv;
    ln = ln - 9 * nent;
end

% allocate space for 4 extra signals that will be calculated later
P.ecg = cell(1, nleads + 5);
P.has_ecg = true;
for i = 0:nleads + 3
    if i >= nleads
        nsamp(i + 1) = nsmax;
    elseif ugt(nsamp(i + 1), nsmax)
        nsmax = wfdbx.internal.cint32(nsamp(i + 1));
    end
    if nsamp(i + 1) == 0
        nsamp(i + 1) = 1;
    end
    P.nsamp = nsamp;
    sg = newsig(nsamp(i + 1));
    if isempty(sg)
        if vflag
            pr('  Error: too many (%d) leads\n', nleads);
        end
        return;
    end
    P.ecg{i + 1} = sg;
end
P.nsamp = nsamp;
end

function P = section4(P, p, ln)
vflag = P.vflag;
pr = @wfdbx.internal.cprintf;
p = p + 16;
ln = ln - 16;            % the section ID header
if ln < 6
    if vflag
        pr('  Error: section 4 contains no data\n');
    end
    return;
end
P.rblenms = g16(P, p);
P.fcM = g16(P, p + 2);
nqrs = g16(P, p + 4);
P.nqrs = nqrs;
if vflag
    pr('  Length of reference beat type 0 data: %ld msec\n', P.rblenms);
    pr('  Sample # of fiducial relative to start of ref beat type 0: %d\n', P.fcM);
    pr('  Number of QRS complexes in the entire record: %d\n', nqrs);
end
if nqrs < 1
    return;     % no beats -- nothing else to do here
end
p = p + 6;
ln = ln - 6;
P.zset = false(1, nqrs);
P.ztype = zeros(1, nqrs);
P.zt0 = zeros(1, nqrs);
P.zt1 = zeros(1, nqrs);
P.zt2 = zeros(1, nqrs);
P.has_subz = true;
if ln >= nqrs * 14
    if vflag
        pr('  Reference beat subtraction zones:\n');
    end
    E = reshape(bytes(P, p, 14 * nqrs), 14, nqrs);
    ty = E(1, :) + 256 * E(2, :);
    ty = ty - 65536 * (ty >= 32768);
    t = zeros(3, nqrs);
    for k = 1:3
        o = 4 * k - 1;
        v = E(o, :) + 256 * E(o + 1, :) + 65536 * E(o + 2, :) + ...
            16777216 * E(o + 3, :);
        t(k, :) = v - 4294967296 * (v >= 2147483648);
    end
    ty(ty == 0 & t(3, :) == 0) = 9;
    P.zset(:) = true;
    P.ztype = ty;
    P.zt0 = t(1, :);
    P.zt1 = t(2, :);
    P.zt2 = t(3, :);
    if vflag
        for i = 1:nqrs
            wfdbx.internal.cout(sprintf( ...
                '   %2d  Type: %2d  start: %7d  fiducial: %7d  end: %7d\n', ...
                i, ty(i), t(1, i), t(2, i), t(3, i)));
            if ty(i) ~= 0 && (t(1, i) ~= 0 || t(3, i) ~= 0)
                pr('  Error: start and end should be zero for beats of non-zero types\n');
            end
        end
    end
    p = p + 14 * nqrs;
    ln = ln - 14 * nqrs;
else
    if vflag
        pr('  Error: reference beat subtraction zones are missing\n');
    end
end
if ln >= nqrs * 8
    if vflag
        pr('  QRS locations:\n');
        E = reshape(bytes(P, p, 8 * nqrs), 8, nqrs);
        a = E(1, :) + 256 * E(2, :) + 65536 * E(3, :) + 16777216 * E(4, :);
        b = E(5, :) + 256 * E(6, :) + 65536 * E(7, :) + 16777216 * E(8, :);
        % (long) of a signed 32-bit value, printed as unsigned (%lu)
        a(a >= 2^31) = a(a >= 2^31) + (2^64 - 2^32);
        b(b >= 2^31) = b(b >= 2^31) + (2^64 - 2^32);
        if all(a < 2^53 & b < 2^53)
            wfdbx.internal.cout(sprintf('   %2d  start: %7d  end: %7d\n', ...
                [1:nqrs; a; b]));
        else
            for i = 0:nqrs - 1
                pr('   %2d  start: %7lu  end: %7lu\n', i + 1, ...
                    g32(P, p + 8 * i), g32(P, p + 8 * i + 4));
            end
        end
    end
else
    if vflag
        pr('  Error: QRS locations are missing\n');
    end
end
end

function P = section5(P, p, ln)
c = K();
p = p + 16;
ln = ln - 16;            % the section ID header
if ln <= 0
    if P.vflag
        wfdbx.internal.cprintf(' Error: section 5 contains no data\n');
    end
    return;
end
% Calculate length of template in samples
d = g16(P, p + 2);
x = P.rblenms * 1000.0;
if d
    x = x / d;
elseif x == 0
    x = NaN;
else
    x = Inf;
end
% (long)x: LONG_MIN if out of range
if isnan(x) || x >= 2^63 || x < -2^63
    rblen = -2^63;
else
    rblen = fix(x);
end
P.rblen = rblen;
nleads = P.nleads;
P.refbeat = cell(1, max(nleads + 1, 0));
for i = 0:nleads - 1
    if rblen < 0 || rblen > c.MAXALLOC
        wfdbx.internal.ceprintf('  Error: too many (%d) leads\n', nleads);
        return;
    end
    P.refbeat{i + 1} = zeros(rblen, 1, 'int16');
end
P = huffdecode(P, p, ln, 5);
end

function P = section6(P, p, ln)
p = p + 16;
ln = ln - 16;            % the section ID header
if ln <= 6
    if P.vflag
        wfdbx.internal.cprintf(' Error: section 6 contains no data\n');
    end
    return;
end
P = huffdecode(P, p, ln, 6);
end

function [vis, nb] = huffchain(P, p, tbits, nmax)
% Decode Huffman codes (the default table of the SCP standard) from the
% bits that begin at the MSB of the byte at P while fewer than NMAX values
% have been decoded and fewer than TBITS bits read.  VIS: the bit
% positions at which the codes decoded begin; NB: the number of bits read.
% Returns also (as a third output) the decoded values: see huffvals.
vis = zeros(1, 0);
nb = 0;
if nmax <= 0 || tbits <= 0
    return;
end
nbytes = ceil(tbits / 8) + 5;
by = bytes(P, p, nbytes);
B = reshape(bitand(repmat(by, 8, 1), repmat([128; 64; 32; 16; 8; 4; 2; 1], ...
    1, nbytes)) ~= 0, 1, []);
L = numel(B);
% number of one bits starting at each position (up to the next zero)
zpos = (1:L);
zpos(B) = Inf;
nz = fliplr(cummin(fliplr(zpos)));          % next zero (1-based)
r = nz(1:tbits) - (1:tbits);                % run of ones from each start
len = ones(1, tbits);
k = r >= 1 & r <= 8;
len(k) = r(k) + 2;
len(r == 9) = 18;
len(r >= 10) = 26;
% follow the chain of codes from position 0 (pointer doubling)
nxt = min((1:tbits) + len, tbits + 1);
nxt(tbits + 1) = tbits + 1;
on = false(1, tbits + 1);
on(1) = true;
J = nxt;
while J(1) <= tbits
    on(J(on)) = true;
    J = J(J);
end
on(J(on)) = true;
vis = find(on(1:tbits)) - 1;                % (0-based)
if numel(vis) > nmax
    vis = vis(1:nmax);
end
nb = vis(end) + len(vis(end) + 1);
end

function x = huffvals(P, p, vis, tbits)
% The values of the codes that begin at the bit positions VIS.
nbytes = ceil(tbits / 8) + 5;
by = bytes(P, p, nbytes);
B = double(reshape(bitand(repmat(by, 8, 1), repmat([128; 64; 32; 16; 8; 4; 2; 1], ...
    1, nbytes)) ~= 0, 1, []));
L = numel(B);
zpos = (1:L);
zpos(B ~= 0) = Inf;
nz = fliplr(cummin(fliplr(zpos)));
s = vis + 1;                                % 1-based starts
r = nz(s) - s;
x = zeros(1, numel(vis));
k = r >= 1 & r <= 8;
sg = B(s(k) + r(k) + 1);                    % sign bit after the zero
x(k) = r(k) .* (1 - 2 * sg);
k = find(r == 9);
if ~isempty(k)
    W = B(bsxfun(@plus, s(k)' + 10, 0:7));
    v = W * (2 .^ (7:-1:0))';
    x(k) = v' - 256 * (v' >= 128);
end
k = find(r >= 10);
if ~isempty(k)
    W = B(bsxfun(@plus, s(k)' + 10, 0:15));
    v = W * (2 .^ (15:-1:0))';
    x(k) = v' - 65536 * (v' >= 32768);
end
end

function P = huffdecode(P, p, ln, section)
pr = @wfdbx.internal.cprintf;
vflag = P.vflag;
tleadlen = 0;
g = g16(P, p);
if section == 5
    P.gref = g / K().NVPERADU;
else
    P.gres = g / K().NVPERADU;
end
if vflag
    pr('  Amplitude value multiplier: %g nanovolts per unit\n', g);
end
sampint = g16(P, p + 2);
if vflag
    pr('  Sample time interval: %d microseconds\n', sampint);
end
if sampint > 0
    if P.sfreq > 0 && P.sfreq ~= 1.0e6 / sampint
        pr('Warning: section 5 and 6 sample intervals don''t match');
    end
    P.sfreq = 1.0e6 / sampint;
elseif wfdbx.wfdbx_get_legacy()    % WFDB-x: as in the C program
    pr('Error: sampling frequency not specified;  assuming 500 Hz\n');
    P.sfreq = 500;
else    % WFDB-x: the C program assumed 500 Hz
    pr('Error: sampling frequency not specified\n');
end
c = bt(P, p + 3);
if vflag
    pr('  Encoding type: %d ', c);
end
if c <= 2
    if vflag
        e = {'(amplitudes)\n', '(first differences)\n', '(second differences)\n'};
        pr(e{c + 1});
    end
    enctype = c;
else
    if vflag
        pr('<undefined, assuming second differences>\n');
    end
    enctype = 2;
end
if section == 6
    c = bt(P, p + 4);
    if vflag
        pr('  Compression type: %d ', c);
        if c == 0
            pr('(non-bimodal)\n');
        elseif c == 1
            pr('(bimodal)\n');
        else
            pr('<undefined, assuming bimodal>\n');
        end
    end
end
p = p + 6;
ln = ln - 6;

nleads = P.nleads;
if nleads < 0
    if vflag
        pr('  Error: number of leads undefined -- section 3 missing or out of order\n');
    end
    return;
end
if nleads == 0
    if vflag
        pr('  Error: no leads recorded\n');
    end
    return;
end
by = bytes(P, p, 2 * nleads);
leadlen = by(1:2:end) + 256 * by(2:2:end);
tleadlen = sum(leadlen);
if vflag
    wfdbx.internal.cout(sprintf('  Lead %d:%5d bytes\n', [0:nleads - 1; leadlen]));
end
p = p + 2 * nleads;
ln = ln - 2 * nleads;

if ln >= 0 && ln < tleadlen
    if vflag
        d = tleadlen - ln;
        pr('  Error: %lu data byte%s missing from section %d\n', ...
            d, plural(d), section);
    end
    return;
elseif ln < 0 || ln > tleadlen + mod(tleadlen, 2)
    if vflag
        d = ln - tleadlen;
        pr('  Warning: %lu extra byte%s in section %d\n', d, plural(d), section);
    end
end

for i = 0:nleads - 1
    if vflag
        pr('  Lead %d data\n', i);
        wfdbx.internal.cout([sprintf(' %02x', bytes(P, p, 10)), char(10)]);
    end
    if section == 6
        explen = wfdbx.internal.cint32(P.nsamp(i + 1));
        if P.has_ecg
            dest = P.ecg{i + 1};
        else
            dest = [];
        end
        gain = P.gres;
    else
        explen = wfdbx.internal.cint32(P.rblen);
        dest = P.refbeat{i + 1};
        gain = P.gref;
    end
    tbits = leadlen(i + 1) * 8;
    [vis, ibits] = huffchain(P, p, tbits, explen);
    j = numel(vis);
    if j > 0
        x = huffvals(P, p, vis, tbits);
        S = cumsum(x);
        xx = wfdbx.internal.cint16(S);
        xxx = x;
        if j >= 2
            dx = wfdbx.internal.cint16(S(2:end) - 2 * x(1));    % j >= 1
            xxx(2:end) = wfdbx.internal.cint16(x(2) + [0, cumsum(dx(2:end))]);
        end
        if enctype == 0
            xout = x;
        elseif enctype == 1
            xout = xx;
        else
            xout = xxx;
        end
        if ~isempty(dest)
            m = min(j, numel(dest));
            dest(1:m) = d2s(xout(1:m) * gain);
            if section == 6
                P.ecg{i + 1} = dest;
            else
                P.refbeat{i + 1} = dest;
            end
        end
        if vflag > 1
            wfdbx.internal.cout(sprintf('   %5d %5d %5d %5d\n', ...
                [0:j - 1; x; xx; xxx]));
        end
    end
    if j < explen
        if vflag
            d = leadlen(i + 1) - j;
            pr('   Error: %ld sample%s missing in lead %d\n', d, plural(d), i);
        end
    end
    if ibits < tbits
        if vflag
            d = tbits - ibits;
            pr('   Warning: %ld extra bit%s in lead %d\n', d, plural(d), i);
        end
    end
    p = p + leadlen(i + 1);
    if vflag
        pr('\n');
    end
end
end

function P = section7(P, p, ln)
vflag = P.vflag;
pr = @wfdbx.internal.cprintf;
p = p + 16;
ln = ln - 16;            % the section ID header
if ln <= 0
    if vflag
        pr(' Error: section 7 contains no data\n');
    end
    return;
end
if P.xflag && vflag
    hexdump(P, p, ln);
end
if ln < 20      % there isn't enough room left for measurements
    if vflag
        pr(' Error: section 7 is too short (len = %ld)\n', ln);
    end
    return;
end
P.RRint = g16(P, p + 2);
% get P onset, etc from first measurement block
q = p + 6;
P.Pon = g16(P, q);
P.Pend = g16(P, q + 2);
P.QRSon = g16(P, q + 4);
P.QRSend = g16(P, q + 6);
P.Tend = g16(P, q + 8);
P.Paxis = wfdbx.internal.cint16(g16(P, q + 10));
P.QRSaxis = wfdbx.internal.cint16(g16(P, q + 12));
P.Taxis = wfdbx.internal.cint16(g16(P, q + 14));

nmb = bt(P, p);
nps = bt(P, p + 1);
off = wfdbx.internal.cint16(6 + 16 * nmb + 10 * nps);
if off > ln
    off = wfdbx.internal.cint16(ln);
end
sec7qrs = mod(g16(P, p + off), 256);

if vflag
    pr(' QRS complexes measured: %d\n', sec7qrs);
    pr(' Measurement blocks: %d\n', nmb);
    if nmb == sec7qrs + 1
        pr(['  (First measurement block contains measurements for reference beat type 0;\n' ...
            '   Others contain measurements for each individual beat)\n']);
    else
        pr('  (Measurements for each reference beat type)\n');
    end
    pr('  Number of measurement blocks: %d\n', nmb);
    pr('  Number of pacemaker spikes: %d\n', nps);
    pr('  Mean RR interval: %d ms\n', P.RRint);
    pr('  Mean PP interval: %d ms\n', g16(P, p + 4));
    q = p + 6;
    labels = {'P axis:   ', 'QRS axis: ', 'T axis:   '};
    for i = 0:nmb - 1
        pr('   Block %d\n', i);
        pr('    P onset:   %d ms\n', g16(P, q));
        pr('    P end:     %d ms\n', g16(P, q + 2));
        pr('    QRS onset: %d ms\n', g16(P, q + 4));
        pr('    QRS  end:  %d ms\n', g16(P, q + 6));
        pr('    T end:     %d ms\n', g16(P, q + 8));
        for k = 1:3
            n = wfdbx.internal.cint16(g16(P, q + 8 + 2 * k));
            if n == K().UNDEFAXIS
                pr('    %s undefined\n', labels{k});
            else
                pr('    %s %d degrees\n', labels{k}, n);
            end
        end
        q = q + 16;
    end
    if nps > 0
        pr(' Pacemaker spike measurement data\n');
    end
    r = q + nps * 4;
    for i = 0:nps - 1
        pr('Spike %d: %u ms, %d microvolts ', i, g16(P, q), g16(P, q + 2));
        c = bt(P, r);
        switch c
            case 0
                pr('(unknown spike type, ');
            case 1
                pr('(triggers neither P nor QRS, ');
            case 2
                pr('(triggers a QRS, ');
            case 3
                pr('(triggers a P, ');
            otherwise
                pr('(spike type %d, ', c);
        end
        c = bt(P, r + 1);
        switch c
            case 0
                pr('source unknown, ');
            case 1
                pr('internal, ');
            case 2
                pr('external, ');
            otherwise
                pr('source type %d, ', c);
        end
        n = wfdbx.internal.cint16(g16(P, r + 2));
        if n == 0
            pr(' not linked to a QRS, ');
        else
            pr(' linked to QRS #%d, ', n);
        end
        n = wfdbx.internal.cint16(g16(P, r + 4));
        if n == 0
            pr('width unknown)\n');
        else
            pr('%d microseconds\n)', n);
        end
        q = q + 4;
        r = r + 6;
    end
    % The next part doesn't seem to be right ...
    pr(' <!> sec7qrs = <%d>\n', sec7qrs);
    if sec7qrs > 0
        pr(' QRS type information (%d beats)\n', g16(P, r));
    end
    q = r + 2;
    if sec7qrs > 0
        wfdbx.internal.cout(sprintf('  QRS %d: reference beat type %d\n', ...
            [0:sec7qrs - 1; bytes(P, q, sec7qrs)]));
    end
    q = q + sec7qrs;
    pr('%ld bytes remaining in section 7\n', ln - (q - p));
    nrem = p + ln - q;
    if nrem > 0
        % get16(q) reads one byte past the end of the section at the last
        % iteration (read as 0 beyond the end of the data)
        b = bytes(P, q, nrem + 1);
        w = b(1:nrem) + 256 * b(2:nrem + 1);
        wfdbx.internal.cout(sprintf(' %5d [%3d]', [w; b(1:nrem)]));
    end
    wfdbx.internal.cout(char(10));
end
end

function P = section8(P, p, ln)
vflag = P.vflag;
pr = @wfdbx.internal.cprintf;
p = p + 16;
ln = ln - 16;            % the section ID header
if ln <= 0
    if vflag
        pr(' Error: section 8 contains no data\n');
    end
    return;
end
if vflag
    c = bt(P, p);
    pr(' Status: %d ', c);
    switch c
        case 0
            pr('(original report, not confirmed)\n');
        case 1
            pr('(confirmed report)\n');
        case 2
            pr('(overread report, but not confirmed)\n');
        otherwise
            pr('<undefined>\n');
    end
    pr(' Date: %4d/%02d/%02d\n', g16(P, p + 1), bt(P, p + 3), bt(P, p + 4));
    pr(' Time: %02d:%02d:%02d\n', bt(P, p + 5), bt(P, p + 6), bt(P, p + 7));
end
n = bt(P, p + 8);
P.stmnts = n;
if vflag
    pr(' Number of statements: %d\n', n);
end
p = p + 9;
ln = ln - 9;
i = 0;
while i < n && ln > 2
    P.report(i + 1) = p + 3;
    slen = g16(P, p + 1);
    if vflag
        pr('  Statement %2d: (%d bytes)\n', bt(P, p), slen);
        pr('   [%*s]\n', slen, cstr(P, p + 3));
    end
    p = p + slen + 3;
    ln = ln - (slen + 3);
    i = i + 1;
end
if i < n
    if vflag
        pr('  Error: data missing in section 8\n');
    end
end
end

function P = section9(P, p, ln)
p = p + 16;
ln = ln - 16;            % the section ID header
if ln <= 0
    if P.vflag
        wfdbx.internal.cprintf(' Error: section 9 contains no data\n');
    end
    return;
end
if P.vflag
    wfdbx.internal.cout([sprintf('  Data:\n   '), escaped(bytes(P, p, ln)), ...
        char(10)]);
end
end

function s = precgmeas(P)
% The measurement table (as precgmeas() prints it).
c = K();
M = P.ecgmeas;
nm = size(M, 1);
hdr = cell(1, nm);
for k = 1:nm
    id = M(k, 1);
    if id > 0 && id <= 85
        hdr{k} = sprintf('%8s', c.LEADNAME{id + 1});
    else
        hdr{k} = sprintf('  <%4d>', id);
    end
end
rows = cell(1, size(c.MEASROWS, 1));
for r = 1:size(c.MEASROWS, 1)
    v = M(:, c.MEASROWS{r, 2})';
    cells = cell(1, nm);
    for k = 1:nm
        if v(k) == c.NOTCOMPUTED
            cells{k} = '  n/comp';     % not computed by analyzer
        elseif v(k) == c.REJECTED
            cells{k} = '     rej';     % lead rejected
        elseif v(k) == c.ABSENT
            cells{k} = '  absent';     % wave not present
        else
            cells{k} = sprintf('%8d', v(k));
        end
    end
    rows{r} = [char(10), c.MEASROWS{r, 1}, cells{:}];
end
s = ['Parameter  Units', hdr{:}, rows{:}, char(10)];
end

function P = section10(P, p, ln)
p = p + 16;
ln = ln - 16;            % the section ID header
if ln <= 0
    if P.vflag
        wfdbx.internal.cprintf(' Error: section 10 contains no data\n');
    end
    return;
end
nsecleads = g16(P, p);
P.nsecleads = nsecleads;
M = zeros(nsecleads, 33);
p = p + 4;
for i = 1:nsecleads
    b = bytes(P, p, 66);
    v = b(1:2:end) + 256 * b(2:2:end);
    v = v - 65536 * (v >= 32768);
    M(i, :) = v;
    p = p + v(2) + 4;
end
P.ecgmeas = M;
if P.vflag
    wfdbx.internal.cprintf(' Results for %d leads\n', nsecleads);
    wfdbx.internal.cout(precgmeas(P));
end
end

function P = section11(P, ~, ln)
ln = ln - 16;            % the section ID header
if ln <= 0
    if P.vflag
        wfdbx.internal.cprintf(' Error: section 11 contains no data\n');
    end
end
end

% ---- main ----

function status = main(argv)
c = K();
ep = @wfdbx.internal.ceprintf;
pr = @wfdbx.internal.cprintf;
a0 = argv{1};
k = find(a0 == '/', 1, 'last');
if ~isempty(k)
    a0 = a0(k + 1:end);
end
P = struct();
P.pname = a0;
pname = a0;
P.D = zeros(1, 0);
P.n = 0;
P.aflag = 0; P.bflag = 0; P.fflag = 0; P.lflag = 0; P.tflag = 0;
P.vflag = 0; P.wflag = 0; P.xflag = 0; P.zflag = 0;
P.shift = 0;
skip = zeros(1, 12);
P.nleads = -1;
P.nqrs = -1;
P.nsamp = zeros(1, 0);
P.rblen = 0;
P.rblenms = 0;
P.fcM = 0;
P.gref = 0; P.gres = 0;
P.sfreq = -1.0;
P.recdate = '';
P.rectime = '';
P.recname = '';
P.patient_name = '';
P.referring_dr = '';
P.comments = '';
P.patient_id = '';
P.age = -1;
P.sex = -1;
P.RRint = -1; P.Pon = -1; P.Pend = -1;
P.QRSon = -1; P.QRSend = -1; P.Tend = -1;
P.Paxis = c.UNDEFAXIS; P.QRSaxis = c.UNDEFAXIS; P.Taxis = c.UNDEFAXIS;
P.blfilt = -1; P.lpfilt = -1; P.filter_bit = -1;
P.tdevid = -1; P.tinst = -1; P.tdept = -1;
P.dept = '<missing>';
P.inst = '<missing>';
P.stmnts = -1;
P.report = NaN(1, 1200);
P.has_subz = false;
P.zset = false(1, 0);
P.ztype = []; P.zt0 = []; P.zt1 = []; P.zt2 = [];
P.ecg = {};
P.has_ecg = false;
P.refbeat = {};
for k = 1:12
    P.(c.LEADS{k}) = -1;
end
P.ecgmeas = zeros(0, 33);
P.nsecleads = 0;
P.nout = 0;

argc = numel(argv);
i = 1;
while i < argc
    a = argv{i + 1};
    if ~isempty(a) && a(1) == '-'
        if numel(a) >= 2
            ch = a(2);
        else
            ch = '';
        end
        switch ch
            case 'a'
                P.aflag = 1;
                P.xflag = 0;
                P.vflag = 0;
            case 'b'
                P.bflag = 1;
                P.tflag = 0;
            case 'f'
                P.fflag = 1;
            case 'h'
                help(pname);
                status = 1;
                return;
            case 'l'
                P.lflag = 1;
            case 'o'
                i = i + 1;
                if i < argc && numel(argv{i + 1}) <= 11
                    P.recname = argv{i + 1};
                else
                    ep(['%s: a record name of 11 or fewer alphanumeric' ...
                        'characters must\n follow -o\n'], pname);
                    status = 1;
                    return;
                end
            case 's'
                i = i + 1;
                if i < argc
                    P.shift = wfdbx.internal.atoi(argv{i + 1});
                else
                    ep('%s: number of samples to shift templates must follow -s\n', ...
                        pname);
                    status = 1;
                    return;
                end
            case 'S'
                i = i + 1;
                if i < argc
                    if strncmp(argv{i + 1}, '-', 1)
                        skip(:) = 1;
                    else
                        index = wfdbx.internal.atoi(argv{i + 1});
                        if index >= 0 && index <= 11
                            skip(index + 1) = 1 - skip(index + 1);
                        end
                    end
                else
                    ep('%s: number of section to skip, or ''-'', must follow -S\n', ...
                        pname);
                    status = 1;
                    return;
                end
            case 't'
                P.tflag = 1;
                P.bflag = 0;
            case 'v'
                P.vflag = P.vflag + 1;
                P.aflag = 0;
            case 'w'
                P.wflag = P.wflag + 1;
            case 'x'
                P.xflag = 1;
                P.vflag = 1;
                P.aflag = 0;
            case 'z'
                P.zflag = P.zflag + 1;
            otherwise
                ep('%s: unrecognized option ''%s''\n', pname, a);
                help(pname);
                status = 1;
                return;
        end
    else
        ep('%s: unrecognized argument ''%s''\n', pname, a);
        help(pname);
        status = 1;
        return;
    end
    i = i + 1;
end

vflag = P.vflag;
inbytes = wfdbx.internal.stdin_bytes();
if numel(inbytes) < 6
    ep('%s: input too short (only %lu bytes)\n', pname, numel(inbytes));
    status = 1;
    return;
end
P.D = double(inbytes(1:6));
P.n = 6;
crc = g16(P, 0);
reclen = g32(P, 2);
if vflag
    pr('CRC = %d, expected length = %ld bytes\n', crc, reclen);
end
if reclen < 0
    ep('%s: insufficient memory (%ld bytes needed)\n', pname, reclen);
    status = 2;
    return;
end
bytesread = max(6, min(reclen, numel(inbytes)));
if bytesread < reclen
    d = reclen - bytesread;
    ep('%s: input too short (%lu byte%s missing)\n', pname, d, plural(d));
    status = 3;
    return;
end
P.D = double(inbytes(1:bytesread));
P.n = bytesread;
if vflag
    pr('Record length: %ld bytes\n', reclen);
end
crcok(P, 2, reclen - 2, crc, 'Top-level CRC');

% Now check the sections.
p = 6;      % skip the record header -- p points to section 0
contents = { ...
    ' Pointers to data areas in the record\n', ...
    ' Header information - Patient data/ECG acquisition data\n', ...
    ' Huffman tables used in encoding of ECG data\n', ...
    ' ECG lead definition\n', ...
    ' QRS locations\n', ...
    ' Encoded reference beat data\n', ...
    [' Residual signal after reference beat subtraction (if reference' ...
    ' beats\n  are stored);  otherwise, encoded rhythm data\n'], ...
    ' Global measurements\n', ...
    ' Textual diagnosis from the interpretive device\n', ...
    ' Manufacturer specific diagnostic and overreading data\n', ...
    ' Lead measurement results\n', ...
    ' Universal statement codes resulting from the interpretation\n'};
while p < reclen        % true if there is at least 1 more section
    crc = g16(P, p);
    sec_id = g16(P, p + 2);
    sec_len = g32(P, p + 4);
    if vflag
        pr('\nSection %d length: %ld bytes\n', sec_id, sec_len);
    end
    if sec_len >= 0 && sec_len < 8
        if vflag
            pr([' Warning: section length too short (must be at least 8 bytes)\n' ...
                '  Remaining data (%lu bytes) following short section will not be read\n'], ...
                reclen - (p + 8));
        end
        sec_len = 8;
    end
    if sec_len < 0 || sec_len > reclen - p
        if vflag
            pr([' Warning: section length exceeds amount of remaining data\n' ...
                '  This section will not be parsed\n']);
        end
        break;
    end
    crcok(P, p + 2, sec_len - 2, crc, sprintf(' Section %d CRC', sec_id));
    if vflag
        pr(' Section version number: %d\n', bt(P, p + 8));
        pr(' Protocol version number: %d\n', bt(P, p + 9));
        pr(' Contents: ');
    end
    if sec_id < 12
        if vflag
            pr(contents{sec_id + 1});
        end
        if skip(sec_id + 1)
            pr('  [skipped]\n');
        else
            switch sec_id
                case 0
                    P = section0(P, p, sec_len);
                case 1
                    P = section1(P, p, sec_len);
                case 2
                    P = section2(P, p, sec_len);
                case 3
                    P = section3(P, p, sec_len);
                case 4
                    P = section4(P, p, sec_len);
                case 5
                    P = section5(P, p, sec_len);
                case 6
                    P = section6(P, p, sec_len);
                case 7
                    P = section7(P, p, sec_len);
                case 8
                    P = section8(P, p, sec_len);
                case 9
                    P = section9(P, p, sec_len);
                case 10
                    P = section10(P, p, sec_len);
                case 11
                    P = section11(P, p, sec_len);
            end
        end
    elseif vflag
        pr(' Manufacturer-defined (non-standard) section %d\n', sec_id);
    end
    p = p + sec_len;
end

nleads = P.nleads;
nqrs = P.nqrs;
CHUNK = 1048576;

% Low-pass filter the residuals.
for i = 0:nleads - 1
    inp = P.ecg{i + 1};
    if isempty(inp)
        continue;
    end
    n = P.nsamp(i + 1);
    out = newsig(n);
    if isempty(out)
        ep('Insufficient memory for filtering\n');
        break;
    end
    if P.tflag == 0     % true unless -t was given
        out(1) = inp(1);
        if n - 1 > 1
            % (in blocks, to limit the memory used for very long leads)
            for b0 = 2:CHUNK:n - 1
                j = (b0:min(b0 + CHUNK - 1, n - 1))';  % (1-based)
                v = double(inp(j - 1)) + double(inp(j)) + double(inp(j + 1));
                y = zeros(size(v));
                y(v > 0) = floor((v(v > 0) + 2) / 3);
                y(v < 0) = -floor((2 - v(v < 0)) / 3);
                out(j) = y;
            end
            je = n - 1;
        else
            je = 1;
        end
        out(je + 1) = inp(je + 1);
        if P.has_subz
            for k = reshape(find(P.zset(1:max(nqrs, 0)) & P.ztype(1:max(nqrs, 0)) == 0), 1, [])
                % restore unfiltered samples within protected zones
                % and adjacent samples on either end of them
                j0 = max(P.zt0(k) - 1, 0);
                j1 = min(P.zt2(k) + 2, numel(out));
                if j1 > j0
                    out(j0 + 1:j1) = inp(j0 + 1:j1);
                end
            end
        end
    end
    P.ecg{i + 1} = out;
end

% Add the reference beats back into the residuals.
if P.bflag == 0 && nqrs > 0 && P.has_subz && nleads > 0
    rblen = P.rblen;
    for k = reshape(find(P.zset(1:nqrs) & P.ztype(1:nqrs) == 0), 1, [])
        t0 = P.zt0(k);
        t1 = P.zt1(k);
        t2 = P.zt2(k);
        if t2 - t0 + 1 > rblen
            m = -1;
        else
            m = wfdbx.internal.cint32(P.fcM - t1 + t0 - 1);
        end
        if m < 0
            ep('error: subtraction zone is larger than template\n');
            status = 1;
            return;
        end
        for i = 0:nleads - 1
            s = P.ecg{i + 1};
            % WFDB-x: a reference beat that was not allocated (e.g. section
            % 3 follows section 5 and gives more leads) is absent
            if i < numel(P.refbeat)
                ref = P.refbeat{i + 1};
            else
                ref = [];
            end
            if isempty(s) || isempty(ref)
                continue;
            end
            j = t0 - 1 + P.shift;
            jend = t2 - 1 + P.shift;
            mm = m;
            if j < 0    % skip samples before the start of the signal
                mm = mm - j;
                j = 0;
            end
            cnt = min([jend - j + 1, numel(s) - j, numel(ref) - mm]);
            if cnt > 0
                s(j + 1:j + cnt) = wfdbx.internal.cint16(double(s(j + 1:j + cnt)) + ...
                    double(ref(mm + 1:mm + cnt)));
                P.ecg{i + 1} = s;
            end
        end
    end
end

% WFDB-x: signals that could not be allocated (undefined behavior in C)
% are read as zeros, and so are samples beyond the end of a signal shorter
% than lead 0.
n0 = 0;
if P.has_ecg
    if ~isempty(P.nsamp)
        n0 = P.nsamp(1);
    end
    if n0 < 0 || n0 > c.MAXALLOC
        n0 = 0;
    end
    P.nout = n0;
    for k = 1:numel(P.ecg)
        s = P.ecg{k};
        if isempty(s)
            s = newsig(0);
        end
        if numel(s) < n0
            s(n0, 1) = 0;
        end
        P.ecg{k} = s;
    end
end

% Now calculate the missing leads.
cint16 = @wfdbx.internal.cint16;
if P.leadIII < 0        % we need to calculate lead III
    if P.leadI >= 0 && P.leadII >= 0
        if vflag
            pr(' Calculating lead III\n');
        end
        P.leadIII = nleads;
        nleads = nleads + 1;
        l1 = sig(P, P.leadI);
        l2 = sig(P, P.leadII);
        l3 = sig(P, P.leadIII);
        P.nsamp(P.leadIII + 1) = umin(ns(P, P.leadI), ns(P, P.leadII));
        nn = P.nsamp(P.leadIII + 1);
        lens = [numel(l1), numel(l2), numel(l3)];
        if nn < 0
            m = min(lens);
        else
            m = min([nn, lens]);
        end
        l3 = blockop(@(a, b) cint16(b - a), l1, l2, l3, m);
        P = setsig(P, P.leadIII, l3);
    elseif P.leadI < 0
        if P.leadII < 0
            ep('Leads I, II, and III are missing\n');
        else
            ep('Leads I and III are missing\n');
        end
    else
        ep('Leads II and III are missing\n');
    end
elseif P.leadII < 0     % we need to calculate lead II
    if P.leadI >= 0
        if vflag
            pr(' Calculating lead II\n');
        end
        P.leadII = nleads;
        nleads = nleads + 1;
        P.nsamp(P.leadII + 1) = umin(ns(P, P.leadI), ns(P, P.leadIII));
        l1 = sig(P, P.leadI);
        l2 = sig(P, P.leadII);
        l3 = sig(P, P.leadIII);
        l2 = blockop(@(a, b) cint16(a + b), l1, l3, l2, n0);
        P = setsig(P, P.leadII, l2);
    else
        ep('Leads I and II are missing\n');
    end
elseif P.leadI < 0      % we need to calculate lead I
    if vflag
        pr(' Calculating lead I\n');
    end
    P.leadI = nleads;
    nleads = nleads + 1;
    P.nsamp(P.leadI + 1) = umin(ns(P, P.leadII), ns(P, P.leadIII));
    l1 = sig(P, P.leadI);
    l2 = sig(P, P.leadII);
    l3 = sig(P, P.leadIII);
    l1 = blockop(@(a, b) cint16(a - b), l2, l3, l1, n0);
    P = setsig(P, P.leadI, l1);
end

% We need both lead I and lead II to derive aVR.
if P.aVR < 0
    if P.leadI >= 0 && P.leadII >= 0
        if vflag
            pr(' Calculating lead aVR\n');
        end
        P.aVR = nleads;
        nleads = nleads + 1;
        P.nsamp(P.aVR + 1) = umin(ns(P, P.leadI), ns(P, P.leadII));
        l1 = sig(P, P.leadI);
        l2 = sig(P, P.leadII);
        out = sig(P, P.aVR);
        out = blockop(@(a, b) cint16(-fix((a + b) / 2)), l1, l2, out, n0);
        P = setsig(P, P.aVR, out);
    else
        ep('Lead aVR cannot be derived\n');
    end
end

% We need both lead II and lead III to derive aVL.
if P.aVL < 0
    if P.leadII >= 0 && P.leadIII >= 0
        if vflag
            pr(' Calculating lead aVL\n');
        end
        P.aVL = nleads;
        nleads = nleads + 1;
        P.nsamp(P.aVL + 1) = umin(ns(P, P.leadII), ns(P, P.leadIII));
        l2 = sig(P, P.leadII);
        l3 = sig(P, P.leadIII);
        out = sig(P, P.aVL);
        out = blockop(@(a, b) cint16(fix(a / 2) - b), l2, l3, out, n0);
        P = setsig(P, P.aVL, out);
    else
        ep('Lead aVL cannot be derived\n');
    end
end

% We need both lead I and lead III to derive aVF.
if P.aVF < 0
    if P.leadI >= 0 && P.leadII >= 0
        if vflag
            pr(' Calculating lead aVF\n');
        end
        P.aVF = nleads;
        nleads = nleads + 1;
        P.nsamp(P.aVF + 1) = umin(ns(P, P.leadI), ns(P, P.leadIII));
        l1 = sig(P, P.leadI);
        l3 = sig(P, P.leadIII);
        out = sig(P, P.aVF);
        out = blockop(@(a, b) cint16(fix(a / 2) + b), l1, l3, out, n0);
        P = setsig(P, P.aVF, out);
    else
        ep('Lead aVF cannot be derived\n');
    end
end

vn = {'V1', 'V2', 'V3', 'V4', 'V5', 'V6'};
for k = 1:6
    if P.(vn{k}) < 0
        ep('Lead %s is missing\n', vn{k});
    end
end

if nleads > 0
    miss = false;
    for k = 1:12
        miss = miss || P.(c.LEADS{k}) < 0;
    end
    if miss
        % Use an array of zero samples for the missing lead(s).
        if isempty(P.ecg{nleads + 1})
            P.ecg{nleads + 1} = newsig(0);
        end
        for k = 1:12
            if P.(c.LEADS{k}) < 0
                P.(c.LEADS{k}) = nleads;
            end
        end
    end
end
P.nleads = nleads;

if P.aflag
    % Recalculate the top-level CRC.
    crc = getcrc(P, 2, bytesread - 2);
    P = put16(P, crc, 0);
    wfdbx.internal.cout(char(P.D(1:bytesread)));
elseif nleads > 0
    write_output(P);
end
status = 0;
end
