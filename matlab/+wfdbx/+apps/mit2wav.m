function status = mit2wav(args)
%MIT2WAV Convert a WFDB record to a .wav file.
%   STATUS = wfdbx.apps.mit2wav(ARGS) runs the mit2wav tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       mit2wav -o FILE.wav -r RECORD [-n NEWREC]
%   where FILE.wav is the name of the wav-format output signal file,
%   RECORD is the record name, and
%       -h         print a usage summary
%       -n NEWREC  create a header file for the output signal file, so it
%                  may be read as record NEWREC
%
%   wfdb-x: the record must specify its sampling frequency (the C program
%   assumed 250 Hz); see docs/DIVERGENCES.md.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with wfdb-x in the folder tests/data of a copy of
%   the repository; the example writes 100s.wav in the current folder):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.mit2wav({'-r', '100s', '-o', '100s.wav'})
%
%   See also wfdbx.apps.wav2mit.
%
%   Translation of the C program mit2wav (convert/mit2wav.c, WFDB 10.7.0):
%   same options and output. Differences: no sampling frequency is assumed;
%   see docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of convert/mit2wav.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in sampling frequency: the record must
% give it (the original assumed 250 Hz); --legacy, as the first argument,
% restores the original behavior. Each change is marked "wfdb-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
%
% Original C program: convert/mit2wav.c, WFDB Software Package 10.7.0.
%   Copyright (C) 2003-2010 George B. Moody; revised 2018 by Benjamin Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'mit2wav'}, args]);
end

function help(pname)
h = {'where FILE.wav is the name of the wav-format output signal file,', ...
    'RECORD is the record name, and OPTIONS may include:', ...
    ' -h         print this usage summary', ...
    ' -n NEWREC  create a header file for the output signal file, so it', ...
    '             may be read as record NEWREC'};
wfdbx.internal.ceprintf('usage: %s -o FILE.wav -r RECORD [ OPTIONS ... ]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function b = le_bytes(x, n)
% The N low-order bytes of X (modulo 2^(8N)), little-endian.
x = mod(x, 2 ^ (8 * n));
b = zeros(1, n);
for k = 1:n
    b(k) = mod(x, 256);
    x = floor(x / 256);
end
end

function status = main(argv)
pname = argv{1};
argc = numel(argv);
nrec = [];
ofname = [];
record = [];
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
            case 'h'
                help(pname);
                status = 1;
                return;
            case 'n'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: new record name must follow -n\n', pname);
                    status = 1;
                    return;
                end
                nrec = argv{i + 1};
            case 'o'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: name of wav-format output file must follow -o\n', pname);
                    status = 1;
                    return;
                end
                ofname = argv{i + 1};
                if numel(ofname) < 5 || ~strcmp(ofname(end - 3:end), '.wav')
                    wfdbx.internal.ceprintf('%s: name of output file must end in ''.wav''\n', pname);
                    status = 1;
                    return;
                end
            case 'r'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i + 1};
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
if ~ischar(ofname) || ~ischar(record)
    help(pname);
    status = 1;
    return;
end
if ischar(nrec) && strcmp(record, nrec)
    wfdbx.internal.ceprintf('%s: names of input and output records must not be identical\n', pname);
    status = 1;
    return;
end
nsig = wfdbx.isigopen(record, 0);
if nsig <= 0
    status = 2;
    return;
end
[nsig, s] = wfdbx.isigopen(record, nsig);
if nsig <= 0
    status = 3;
    return;
end
% wfdb-x: no default frequency (except in legacy mode)
if ~wfdbx.wfdbx_get_legacy() && wfdbx.sampfreq([]) <= 0
    wfdbx.internal.ceprintf( ...
        '%s: sampling frequency of record %s is not specified\n', pname, record);
    status = 3;
    return;
end
if ischar(nrec) && wfdbx.newheader(nrec) < 0
    status = 3;
    return;
end
bitspersample = 0;
offset = zeros(1, nsig);
shift = zeros(1, nsig);
for k = 1:nsig
    if s(k).adcres > bitspersample
        bitspersample = s(k).adcres;
    end
    offset(k) = s(k).adczero;
    s(k).adczero = 0;
    shift(k) = 16 - s(k).adcres;
    s(k).adcres = 16;
    if shift(k) >= 0
        mag = wfdbx.internal.cint32(2 ^ shift(k));
    else
        mag = 0;
    end
    s(k).gain = s(k).gain * mag;
    s(k).baseline = s(k).baseline - offset(k);
    s(k).baseline = wfdbx.internal.cint32(s(k).baseline * mag);
    s(k).fname = ofname;
    s(k).group = 0;
    s(k).fmt = 16;
    s(k).spf = 1;
end
nsamp = wfdbx.strtim('e');
sps = wfdbx.strtim('1');
framelen = nsig * 2;
if wfdbx.osigfopen(s, nsig) < nsig
    status = 4;
    return;
end
for k = 1:nsig
    wfdbx.wfdbsetstart(k - 1, 44);   % the samples follow the 44-byte WAVE header
end
hdr = [double('RIFF'), le_bytes(nsamp * framelen + 36, 4), double('WAVEfmt '), ...
    le_bytes(16, 4), le_bytes(1, 2), le_bytes(nsig, 2), le_bytes(sps, 4), le_bytes(sps * framelen, 4), ...
    le_bytes(framelen, 2), le_bytes(bitspersample, 2), double('data'), ...
    le_bytes(nsamp * framelen, 4)];
% all the samples (getvec until it fails), shifted to 16 bits
parts = {};
while true
    v = wfdbx.getframes(65536, nsig);   % (getvec(x) == nsig)
    parts{end + 1} = v; %#ok<AGROW>
    if size(v, 1) < 65536
        break;
    end
end
x = vertcat(parts{:});
x = x(:, 1:nsig) - repmat(offset, size(x, 1), 1);
for k = 1:nsig
    if shift(k) >= 0
        x(:, k) = wfdbx.internal.cint32(x(:, k) * 2 ^ shift(k));
    else
        x(:, k) = floor(x(:, k) / 2 ^ -shift(k));
    end
end
wfdbx.putframes(x);
wfdbx.setsampfreq(wfdbx.sampfreq([]));
if ischar(nrec)
    wfdbx.newheader(nrec);
end
wfdbx.wfdbquit();
% Prepend the wav header to the signal file (the C version does this
% using a temporary file and the 'mv', 'cat', and 'rm' commands).
data = zeros(0, 1, 'uint8');
fid = fopen(ofname, 'rb');
if fid >= 0
    data = fread(fid, Inf, 'uint8=>uint8');
    fclose(fid);
end
fid = fopen(ofname, 'wb');
if fid >= 0
    fwrite(fid, [uint8(hdr(:)); data(:)], 'uint8');
    fclose(fid);
end
status = 0;
end
