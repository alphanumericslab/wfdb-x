function status = wav2mit(args)
%WAV2MIT Create a header file so that a .wav file can be read as a record.
%   STATUS = wfdbx.apps.wav2mit(ARGS) runs the wav2mit tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       wav2mit -i FILE.wav -G GAIN [-U UNITS] [-r RECORD]
%   where FILE.wav is the name of the wav-format input signal file, and
%       -G GAIN    gain in adu per physical unit (required; 0: uncalibrated)
%       -h         print a usage summary
%       -r RECORD  create RECORD.hea (default: FILE.hea)
%       -U UNITS   physical units (required unless the gain is 0)
%
%   wfdb-x: -G and -U are new and required (the C program wrote 12.5 adu/mV
%   for 8-bit and 6400 adu/mV for 16-bit files, with no units, i.e.,
%   millivolts; give -G 12.5 -U mV or -G 6400 -U mV to reproduce it).  The
%   sampling frequency and the resolution are those given in the WAV file;
%   see docs/DIVERGENCES.md.
%
%   Example (sound.wav stands for a .wav file in the current folder; the
%   example writes the header of the record sound there):
%       wfdbx.apps.wav2mit({'-i', 'sound.wav', '-r', 'sound', '-G', '0'})
%
%   See also wfdbx.apps.mit2wav.
%
%   Translation of the C program wav2mit (convert/wav2mit.c, WFDB 10.7.0):
%   same options and output. Differences: -G and -U are new and required;
%   see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of convert/wav2mit.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in gain or units: the new options -G GAIN
% (required) and -U UNITS (required unless the gain is 0) give them (the
% original wrote 12.5 adu/mV for 8-bit and 6400 adu/mV for 16-bit files, in
% millivolts); --legacy, as the first argument, restores the original behavior.
% Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md gives the
% reasons.
%
% Original C program: convert/wav2mit.c, WFDB Software Package 10.7.0.
%   Copyright (C) 2003-2004 George B. Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'wav2mit'}, args]);
end

function help(pname)
h = {'where FILE.wav is the name of the wav-format input signal file,', ...
    'and OPTIONS may include:', ...
    ' -G GAIN    gain in adu per physical unit (required; 0: uncalibrated)', ...
    ' -h         print this usage summary', ...
    ' -r RECORD  create RECORD.hea (default: FILE.hea)', ...
    ' -U UNITS   physical units (required unless the gain is 0)'};
if wfdbx.wfdbx_get_legacy()  % wfdb-x: legacy mode: the original help text
    h([3 6]) = [];              % (without -G and -U)
end
wfdbx.internal.ceprintf('usage: %s -i FILE.wav -r RECORD [ OPTIONS ... ]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function [x, pos] = in16(d, pos)
if pos + 2 > numel(d)
    x = -1;
    pos = numel(d);
    return;
end
x = d(pos + 1) + 256 * d(pos + 2);
x = x - 65536 * (x >= 32768);
pos = pos + 2;
end

function [x, pos] = in32(d, pos)
if pos + 4 > numel(d)
    x = -1;
    pos = numel(d);
    return;
end
x = d(pos + 1) + 256 * d(pos + 2) + 65536 * d(pos + 3) + 16777216 * d(pos + 4);
pos = pos + 4;
end

function [tf, pos] = expect(d, pos, s)
n = min(4, numel(d) - pos);
tf = n == 4 && isequal(char(d(pos + 1:pos + 4)), s);
pos = pos + n;
end

function status = main(argv)
pname = argv{1};
argc = numel(argv);
ifname = [];
record = [];
P = wfdbx.internal.sigparams();     % wfdb-x: -G and -U
legacy = wfdbx.wfdbx_get_legacy();
i = 1;
while i < argc
    a = argv{i + 1};
    if strncmp(a, '-', 1)
        if numel(a) >= 2
            c = a(2);
        else
            c = char(0);
        end
        if legacy && any(c == 'GU')     % wfdb-x: legacy mode: not options of
            c = char(0);                % the original (unrecognized)
        end
        switch c
            case {'G', 'U'}     % gain, units (WFDB-x)
                [P, i, ok] = wfdbx.internal.opt_sigparam(argv, i, P);
                if ~ok
                    status = 1;
                    return;
                end
            case 'h'
                help(pname);
                status = 1;
                return;
            case 'i'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: name of wav-format input file must follow -i\n', pname);
                    status = 1;
                    return;
                end
                ifname = argv{i + 1};
                if numel(ifname) < 5 || ~strcmp(ifname(end - 3:end), '.wav')
                    wfdbx.internal.ceprintf('%s: name of input file must end in ''.wav''\n', pname);
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
if ~ischar(ifname)
    help(pname);
    status = 1;
    return;
end
% wfdb-x: the gain and units must be given explicitly; the C program wrote
% 12.5 adu/mV for 8-bit and 6400 adu/mV for 16-bit files, with no units
% (millivolts).  (The sampling frequency and the resolution are those given
% in the file.)
checks = 'GU';      % (WFDB-x; legacy mode: no checks, as in the C program)
if legacy
    checks = '';
end
[P, ok] = wfdbx.internal.sigparams(pname, P, checks);
if ~ok
    status = 1;
    return;
end
if ~ischar(record)
    record = ifname(1:end - 4);
end
fid = fopen(ifname, 'rb');
if fid < 0
    wfdbx.internal.ceprintf('%s: can''t open %s\n', pname, ifname);
    status = 2;
    return;
end
d = fread(fid, 64, 'uint8=>double')';     % the header (44 bytes)
fseek(fid, 0, 'eof');
flen = ftell(fid);
fclose(fid);
[ok, pos] = expect(d, 0, 'RIFF');
if ~ok
    wfdbx.internal.ceprintf('%s: %s is not a .wav-format file\n', pname, ifname);
    status = 3;
    return;
end
[ln, pos] = in32(d, pos);
ln = ln + 8;
if ln ~= flen
    wfdbx.internal.ceprintf('%s: header chunk of %s has incorrect length (%d, should be %d)\n', ...
        pname, ifname, ln, flen);
    status = 3;
    return;
end
[ok, pos] = expect(d, pos, 'WAVE');
if ~ok
    wfdbx.internal.ceprintf('%s: %s is not a .wav-format file\n', pname, ifname);
    status = 3;
    return;
end
[ok, pos] = expect(d, pos, 'fmt ');
if ~ok
    wfdbx.internal.ceprintf('%s: format chunk missing or corrupt in %s\n', pname, ifname);
    status = 3;
    return;
end
[ln, pos] = in32(d, pos);
[tag, pos] = in16(d, pos);
if ln ~= 16 || tag ~= 1
    wfdbx.internal.ceprintf('%s: unsupported format %d in %s\n', pname, tag, ifname);
    status = 3;
    return;
end
[nsig, pos] = in16(d, pos);
[sps, pos] = in32(d, pos);
[~, pos] = in32(d, pos);
[framelen, pos] = in16(d, pos);
[bitspersample, pos] = in16(d, pos);
if bitspersample <= 8
    wres = 8;
    if legacy
        P.G = 12.5;     % wfdb-x: the C program's gain (legacy mode)
    end
elseif bitspersample <= 16
    wres = 16;
    if legacy
        P.G = 6400;     % wfdb-x: the C program's gain (legacy mode)
    end
else
    wfdbx.internal.ceprintf('%s: unsupported resolution (%d bits/sample) in %s\n', ...
        pname, bitspersample, ifname);
    status = 3;
    return;
end
if framelen ~= nsig * wres / 8
    wfdbx.internal.ceprintf('%s: format chunk of %s has incorrect frame length\n', pname, ifname);
    status = 3;
    return;
end
[ok, pos] = expect(d, pos, 'data');
if ~ok
    wfdbx.internal.ceprintf('%s: data chunk missing or corrupt in %s\n', pname, ifname);
    status = 3;
    return;
end
ln = in32(d, pos);
if framelen
    wnsamp = floor(ln / framelen);
else
    wnsamp = 0;
end
s = wfdbx.siginfo(max(nsig, 0));
for k = 1:nsig
    s(k).fname = ifname;
    s(k).units = P.U;
    s(k).gain = P.G;
    s(k).initval = 0;
    s(k).group = 0;
    if wres == 16
        s(k).fmt = 16;
        s(k).adczero = 0;
    else
        s(k).fmt = 80;
        s(k).adczero = 128;
    end
    s(k).spf = 1;
    s(k).bsize = 0;
    s(k).adcres = wres;
    s(k).nsamp = wnsamp;
    s(k).cksum = 0;
    s(k).baseline = s(k).adczero;
    wfdbx.wfdbsetstart(k - 1, 44);   % the samples follow the 44-byte WAVE header
end
wfdbx.setsampfreq(sps);
if wfdbx.setheader(record, s, nsig)
    status = 4;
    return;
end
wfdbx.wfdbquit();
status = 0;
end
