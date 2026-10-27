function nsig = edfparse(ifile)
%EDFPARSE Read the header of an EDF or EDF+ file (edfparse in signal.c).
%   N = wfdbx.internal.edfparse(F) reads the header of the EDF file F (a
%   WFDBFile) into the signal state, as readheader does for a WFDB header,
%   closes F, and returns the number of signals (-2 if F is not an EDF
%   file).
%
%   Translation of the C function edfparse() (lib/signal.c, WFDB 10.7.0).

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

S = wfdbx.internal.sig_state();
io = wfdbx.internal.io_state();
edf_fname = io.wfdb_filename;
magic = char(ifile.read(8));
if strcmp(magic, '0       ')
    fmt = 16;
elseif numel(magic) >= 8 && strcmp(magic(2:8), 'BIOSEMI')
    fmt = 24;
else
    wfdbx.internal.wfdb_error('init: ''%s'' is not EDF or EDF+\n', edf_fname);
    nsig = -2;
    return;
end
edfstr(ifile, 80);   % patient, then recording identification
edfstr(ifile, 80);   % patient, then recording identification
v = scan_ints(edfstr(ifile, 8), 3);
day = v(1);
month = v(2);
year = v(3) + 1900;
if year < 1985   % EDF dates: 1985 to 2084
    year = year + 100;
end
v = scan_ints(edfstr(ifile, 8), 3);
hour = v(1);
minute = v(2);
second = v(3);
offset = scan_ints(edfstr(ifile, 8), 1);
edfstr(ifile, 44);   % reserved
nframes = wfdbx.internal.strtol(edfstr(ifile, 8));
if nframes < 0
    nframes = 0;
end
S.nsamples = nframes;
spr = wfdbx.internal.strtod(edfstr(ifile, 8));
if spr <= 0
    spr = 1;
end
nsig = scan_ints(char(ifile.read(4)), 1);
if nsig < 1 || (nsig + 1) * 256 ~= offset
    wfdbx.internal.wfdb_error('init: ''%s'' is not EDF or EDF+\n', edf_fname);
    nsig = -2;
    return;
end
hsd = S.hsd;
if numel(hsd) < nsig
    if isempty(hsd)
        hsd = repmat(wfdbx.internal.hsdata(), 1, nsig);
    else
        hsd(end + 1:nsig) = repmat(wfdbx.internal.hsdata(), 1, nsig - numel(hsd));
    end
end
% Strip any path from the EDF file name.
p = numel(edf_fname) - 4 - 1;       % 0-based
base = 0;
while p > 0
    if edf_fname(p + 1) == '/'
        base = p + 1;
        break;
    end
    p = p - 1;
end
fname = edf_fname(base + 1:end);
pmin = zeros(1, nsig);
pmax = zeros(1, nsig);
dmin = zeros(1, nsig);
dmax = zeros(1, nsig);
for s = 1:nsig
    hsd(s).start = offset;
    hsd(s).skew = 0;
    hsd(s).info.fname = fname;
    hsd(s).info.group = 0;
    hsd(s).info.bsize = 0;
    hsd(s).info.cksum = 0;
    hsd(s).info.fmt = fmt;
    hsd(s).info.nsamp = nframes;
    hsd(s).info.desc = edfstr(ifile, 16);
end
for s = 1:nsig
    edfstr(ifile, 80);   % patient, then recording identification
end
for s = 1:nsig
    hsd(s).info.units = edfstr(ifile, 8);
end
for s = 1:nsig
    pmin(s) = wfdbx.internal.strtod(edfstr(ifile, 8));
end
for s = 1:nsig
    pmax(s) = wfdbx.internal.strtod(edfstr(ifile, 8));
end
for s = 1:nsig
    dmin(s) = wfdbx.internal.strtol(edfstr(ifile, 8));
end
for s = 1:nsig
    dmax(s) = wfdbx.internal.strtol(edfstr(ifile, 8));
    z = wfdbx.internal.cint32(fix((dmax(s) + 1 + dmin(s)) / 2));
    hsd(s).info.initval = z;
    hsd(s).info.adczero = z;
    adcrange = dmax(s) - dmin(s);
    i = 0;
    while adcrange > 0
        adcrange = fix(adcrange / 2);
        i = i + 1;
    end
    hsd(s).info.adcres = i;
    if pmax(s) ~= pmin(s)
        g = (dmax(s) - dmin(s)) / (pmax(s) - pmin(s));
        hsd(s).info.gain = g;
        baseline = dmax(s) - pmax(s) * g;
        if baseline >= 0
            hsd(s).info.baseline = fix(baseline + 0.5);
        else
            hsd(s).info.baseline = fix(baseline - 0.5);
        end
    else
        hsd(s).info.gain = 0;
        hsd(s).info.baseline = 0;
    end
end
for s = 1:nsig
    edfstr(ifile, 80);   % patient, then recording identification
end
for s = 1:nsig
    n = scan_ints(edfstr(ifile, 8), 1);
    hsd(s).info.spf = n;
    if n > S.spfmax
        S.spfmax = n;
    end
end
S.hsd = hsd;
ifile.close();
S.hheader = [];
S.ffreq = 1 / spr;
S.cfreq = S.ffreq;
S.sfreq = S.ffreq * S.spfmax;
if wfdbx.internal.pkg_has('getafreq') && wfdbx.internal.pkg_has('setafreq')
    if wfdbx.getafreq() == 0
        wfdbx.setafreq(S.sfreq);
    end
end
S.gvmode = bitor(S.gvmode, 1);     % WFDB_HIGHRES
wfdbx.setbasetime(sprintf('%02d:%02d:%02d %02d/%02d/%04d', ...
    hour, minute, second, day, month, year));
S.isedf = 1;
end

function s = edfstr(f, size)
% A field of SIZE bytes, up to its first NUL, without trailing spaces.
b = f.read(size);
if numel(b) ~= size
    s = '';
    return;
end
k = find(b == 0, 1);
if ~isempty(k)
    b = b(1:k - 1);
end
k = find(b ~= 32, 1, 'last');
if isempty(k)
    s = '';
else
    s = char(b(1:k));
end
end

function out = scan_ints(s, n)
% sscanf(s, "%d%*c%d%*c%d"): up to N ints (0 for those missing).
out = zeros(1, n);
pos = 1;
for k = 1:n
    [v, e] = wfdbx.internal.strtol(s, 10, pos);
    if e == pos
        break;
    end
    out(k) = wfdbx.internal.cint32(v);
    pos = e;
    if k < n
        if pos > numel(s)
            break;
        end
        pos = pos + 1;
    end
end
end
