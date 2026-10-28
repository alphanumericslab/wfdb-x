function status = ad2m(args)
%AD2M Convert an AHA-format signal file to MIT format.
%   STATUS = wfdbx.apps.ad2m(ARGS) runs the ad2m tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       ad2m -i AHAFILE [OPTIONS ...]
%   where AHAFILE is the name of the AHA-format input signal file, and
%   OPTIONS may include:
%       -c         process a compressed input file (default if AHAFILE
%                  ends with .CMP or .cmp; otherwise old AHA tape format)
%       -f TIME    begin at TIME (default: the beginning of the file)
%       -F FREQ    sampling frequency in Hz (required; AHA database: 250)
%       -G GAIN    gain in adu per physical unit (required; AHA database:
%                  400)
%       -h         print a usage summary
%       -r RECORD  output record name (default: the input file name, less
%                  path and extension)
%       -R BITS    ADC resolution in bits (required; AHA database: 12)
%       -t TIME    stop at TIME (default: 35 minutes after the start if
%                  RECORD=x2xx or x3xx, 3 hours if RECORD=x0xx or x1xx, or
%                  the end of the input file)
%       -U UNITS   physical units (required unless the gain is 0; AHA: mV)
%
%   WFDB-x: -F, -G, -R and -U are new and required (the C program assumed
%   the parameters of the AHA database: 250 Hz, 400 adu/mV, 12 bits and
%   millivolts; give -F 250 -G 400 -R 12 -U mV to reproduce it).  The
%   times of -f and -t are converted at the frequency given by -F; see
%   docs/DIVERGENCES.md.
%
%   Example (1201.CMP, a synthetic signal file in the format of the AHA
%   Database, is in the folder tests/data of a copy of the WFDB-x
%   repository; the example writes the record adm in the current folder):
%       wfdbx.apps.ad2m({'-i', '/path/to/wfdb-x/tests/data/1201.CMP', ...
%           '-r', 'adm', '-F', '250', ...
%           '-G', '400', '-R', '12', '-U', 'mV'})
%
%   See also wfdbx.apps.md2a, wfdbx.apps.ahaecg2mit.
%
%   Translation of the C program ad2m (convert/ad2m.c, WFDB 10.7.0): same
%   options and output. Differences: -F, -G, -R and -U are new and required;
%   see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of convert/ad2m.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in signal parameters: the new options -F
% FREQ, -G GAIN, -R BITS and -U UNITS give the sampling frequency, gain, ADC
% resolution and units, and are required (-U unless the gain is 0; the original
% assumed those of the AHA database: 250 Hz, 400 adu/mV, 12 bits and
% millivolts); the -f and -t times are converted at the -F frequency; --legacy,
% as the first argument, restores the original behavior. Each change is marked
% "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
%
% Original C program: convert/ad2m.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1983-2007 George B. Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'ad2m'}, args]);
end

function help(pname)
% (a comma is missing after the -r line in the C source)
h = {'where AHAFILE is the name of the AHA-format input signal file,', ...
    'and OPTIONS may include:', ...
    ' -c         process a compressed input file (default if AHAFILE ends', ...
    '             with .CMP or .cmp;  otherwise old AHA tape format assumed)', ...
    ' -f TIME    begin at specified TIME (default: 0, i.e., the beginning', ...
    '             of the input file)', ...
    ' -F FREQ    sampling frequency in Hz (required; AHA database: 250)', ...
    ' -G GAIN    gain in adu per physical unit (required; AHA database: 400)', ...
    ' -h         print this usage summary', ...
    [' -r RECORD  specify the name of the output RECORD (default: use the,' ...
    '            input file name, less path info and extension, as RECORD)'], ...
    ' -R BITS    ADC resolution in bits (required; AHA database: 12)', ...
    ' -t TIME    stop at specified TIME (default: 35 minutes after the', ...
    '             starting time if RECORD=x2xx or x3xx, 3 hours if', ...
    '             RECORD=x0xx or x1xx, or the end of the input file)', ...
    ' -U UNITS   physical units (required unless the gain is 0; AHA: mV)'};
if wfdbx.wfdbx_get_legacy()  % WFDB-x: legacy mode: the original help text
    h([7 8 11 15]) = [];        % (without -F, -G, -R, -U)
end
wfdbx.internal.ceprintf('usage: %s -i AHAFILE [ OPTIONS ... ]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function status = main(argv)
EODF = 32768;           % 0100000
CHUNK = 65536;
pname = argv{1};
argc = numel(argv);
ep = @wfdbx.internal.ceprintf;
P = wfdbx.internal.sigparams();     % WFDB-x: -F, -G, -R, -U
legacy = wfdbx.wfdbx_get_legacy();
if legacy
    % WFDB-x: in legacy mode, the parameters of the AHA database, set by the
    % C program (250 Hz, 400 adu/mV, 12 bits, and no units, i.e.,
    % millivolts); -F, -G, -R and -U are not options then.
    P.F = 250;
    P.G = 400;
    P.Gset = 1;
    P.R = 12;
    wfdbx.setsampfreq(250);
end
fstr = [];
tstr = [];
cflag = 0;
ifname = [];
record = [];
t = 0;
start_time = 0;
end_time = 0;
i = 1;
while i < argc
    a = argv{i+1};
    if ~isempty(a) && a(1) == '-'
        if numel(a) >= 2
            c = a(2);
        else
            c = '';
        end
        if legacy && any(c == 'FGRU')   % WFDB-x: legacy mode: not options
            c = '';                     % of the original (unrecognized)
        end
        switch c
            case 'c'
                cflag = 1;
            case 'f'
                i = i + 1;
                if i >= argc
                    ep('%s: start time must follow -f\n', pname);
                    status = 1;
                    return;
                end
                if legacy   % WFDB-x: as in the C program
                    start_time = wfdbx.strtim(argv{i+1});
                else
                    fstr = argv{i+1};   % converted once -F is known (WFDB-x)
                end
            case 'h'
                help(pname);
                status = 1;
                return;
            case 'i'
                i = i + 1;
                if i >= argc
                    ep('%s: name of AHA-format input file must follow -i\n', pname);
                    status = 1;
                    return;
                end
                ifname = argv{i+1};
            case 'r'
                i = i + 1;
                if i >= argc
                    ep('%s: record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i+1};
            case 't'
                i = i + 1;
                if i >= argc
                    ep('%s: end time must follow -t\n', pname);
                    status = 1;
                    return;
                end
                if legacy   % WFDB-x: as in the C program
                    end_time = wfdbx.strtim(argv{i+1});
                else
                    tstr = argv{i+1};   % converted once -F is known (WFDB-x)
                end
            case {'F', 'G', 'R', 'U'}   % signal parameters (WFDB-x)
                [P, i, ok] = wfdbx.internal.opt_sigparam(argv, i, P);
                if ~ok
                    status = 1;
                    return;
                end
            otherwise
                ep('%s: unrecognized option %s\n', pname, a);
                status = 1;
                return;
        end
    else
        ep('%s: unrecognized argument %s\n', pname, a);
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
% WFDB-x: the signal parameters must be given explicitly; the C program
% assumed those of the AHA database (250 Hz, 400 adu/mV, 12 bits, and no
% units, i.e., millivolts), as legacy mode does (the values set above for
% legacy mode pass these checks, and no units are required then).
checks = 'FGRU';
if legacy
    checks = 'FGR';
end
[P, ok] = wfdbx.internal.sigparams(pname, P, checks);
if ~ok
    status = 1;
    return;
end
wfdbx.setsampfreq(P.F);
if ischar(fstr)
    start_time = wfdbx.strtim(fstr);
end
if ischar(tstr)
    end_time = wfdbx.strtim(tstr);
end
if end_time > 0 && end_time <= start_time
    help(pname);
    status = 1;
    return;
end
if cflag == 0 && numel(ifname) > 4 && ...
        any(strcmp(ifname(end-3:end), {'.CMP', '.cmp'}))
    cflag = 1;
end
[ok, infid] = redirect_stdin(ifname);
if ~ok
    ep('%s: can''t read input file `%s''\n', pname, ifname);
    status = 2;
    return;
end
if ~ischar(record)
    record = basename_record(ifname);
end
if end_time == 0 && numel(record) == 4
    if any(record(2) == '23')
        end_time = wfdbx.strtim('35:0');
    elseif any(record(2) == '01')
        end_time = wfdbx.strtim('3:0:0');
    end
end
if end_time == 0
    ep('%s: warning: end time not specified, output may be truncated\n', pname);
    ep('               rerun with -t TIME to override\n');
    end_time = start_time + wfdbx.strtim('100:0:0');
end
dfname = [record '.dat'];
dfarray = wfdbx.siginfo(2);
for k = 1:2
    dfarray(k).fname = dfname;
    dfarray(k).desc = '';
    dfarray(k).gain = P.G;
    dfarray(k).units = P.U;
    dfarray(k).fmt = 212;
    dfarray(k).adcres = P.R;
    dfarray(k).spf = 0;
end
if wfdbx.osigfopen(dfarray, 2) < 0
    status = 3;
    return;
end
if ~cflag
    if wfdbx.isigopen('16', 2) < 2
        status = 2;
        return;
    end
    if start_time > 0
        t = start_time;
        if wfdbx.isigsettime(t) < 0
            status = 2;
            return;
        end
    end
    % while (getvec(v) == 2 && v[0] != EODF && putvec(v) > 0 &&
    %        ++t < end_time) ;
    done = false;
    while ~done
        [v, st] = wfdbx.getframes(CHUNK);
        n = size(v, 1);
        k = find(v(:, 1) == EODF, 1);
        if ~isempty(k)
            n = k - 1;
            done = true;
        end
        % the putvec calls left before t reaches end_time
        m = max(end_time - t, 1);
        if n >= m
            n = m;
            done = true;
        end
        if n > 0
            if wfdbx.putframes(v(1:n, 1:2)) <= 0
                break;
            end
            t = t + n;
        end
        if st ~= 2
            break;
        end
    end
    wfdbx.newheader(record);
    while true
        [~, st] = wfdbx.getframes(CHUNK);
        if st < 0
            break;
        end
    end
else
    inb = read_stdin(infid);
    % Decode the compressed samples (getcvec) needed: the samples skipped
    % until start_time, then those written until end_time.
    if start_time > t
        nskip = start_time - t;
    else
        nskip = 0;
    end
    tm = t + nskip;
    nmax = nskip + max(end_time - tm, 1);
    [V, nok, bad] = getcvecs(double(inb), nmax);
    if nok < nmax && bad
        ep('unexpected EOF in input file\n');
    end
    if nok > nskip
        wfdbx.putframes(V(nskip+1:nok, :));
    end
    wfdbx.newheader(record);
end
wfdbx.wfdbquit();
status = 0;
end

function [V, nok, bad] = getcvecs(b, nmax)
% Up to NMAX successive getcvec() calls: V holds the NOK samples decoded
% (one row each); BAD is true if decoding stopped inside a sample (the
% "unexpected EOF" case).
nb = numel(b);
pos = zeros(nmax, 1);
long = false(nmax, 1);
nok = 0;
bad = false;
k = 1;
while nok < nmax
    if k > nb
        break;
    end
    if b(k) >= 128
        if k + 3 > nb
            bad = true;
            break;
        end
        nok = nok + 1;
        pos(nok) = k;
        long(nok) = true;
        k = k + 4;
    else
        if k + 1 > nb
            bad = true;
            break;
        end
        nok = nok + 1;
        pos(nok) = k;
        k = k + 2;
    end
end
pos = pos(1:nok);
long = long(1:nok);
x = b(pos);
y = b(pos + 1);
d0 = zeros(nok, 1);
d1 = zeros(nok, 1);
s = ~long;
xs = x(s);
ys = y(s);
d0(s) = bitand(xs, 127) - 128 * (bitand(xs, 64) ~= 0);
d1(s) = ys - 256 * (ys >= 128);
pl = pos(long);
xl = x(long);
xl = bitand(xl, 63) - 64 * (bitand(xl, 64) ~= 0);
d0(long) = xl * 256 + y(long);
x2 = b(pl + 2);
x2 = x2 - 256 * (x2 >= 128);
d1(long) = x2 * 256 + b(pl + 3);
V = wfdbx.internal.cint32([cumsum(d0), cumsum(d1)]);
end

function [ok, fid] = redirect_stdin(ifname)
% freopen(ifname, "rb", stdin): the file becomes the standard input (as
% a regular, seekable file).  FID is its file identifier (-1 for '-').
% (It is read only when C reads it: output files opened before may be
% the same file, truncated.)
fid = -1;
ok = true;
if strcmp(ifname, '-')
    return;
end
fid = fopen(ifname, 'rb');
if fid < 0
    ok = false;
    return;
end
st = wfdbx.internal.io_state();
st.stdin_file = wfdbx.internal.WFDBFile(fid, 0, '-', 0);
end

function data = read_stdin(fid)
% The rest of the standard input (as redirected by redirect_stdin).
if fid < 0
    data = wfdbx.internal.stdin_bytes();
else
    data = fread(fid, Inf, 'uint8=>uint8')';
end
end

function rec = basename_record(ifname)
% The input file name without its directory and extension.
k = find(ifname == '/', 1, 'last');
if isempty(k)
    rec = ifname;
else
    rec = ifname(k+1:end);
end
j = find(rec(2:end) == '.', 1);
if ~isempty(j)
    rec = rec(1:j);
end
end
