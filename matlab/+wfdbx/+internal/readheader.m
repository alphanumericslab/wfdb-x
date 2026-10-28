function nsig = readheader(record)
%READHEADER Read the header of a record (readheader in signal.c).
%   N = wfdbx.internal.readheader(RECORD) reads the header file of RECORD
%   (or an EDF file, if RECORD has an extension other than .hea) into the
%   signal state (sig_state().hsd, the sampling and counter frequencies,
%   base time, number of samples, segment table).  It returns the number
%   of signals, 0 for a multi-segment record's master header (or a record
%   without signals), -1 if the header cannot be opened, -2 if it is
%   invalid.  The record '~' is a null segment of a multi-segment record.
%
%   Translation of the C function readheader() (lib/signal.c, WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: no sampling frequency or ADC resolution is
% assumed when the header gives none (the C library assumed 250 Hz and 12
% bits or a value based on the format); the signal files and segments named
% in a header are read from the header's directory or below it, and a name
% that is absolute, begins with '~', is a URL or contains '..' is refused.
% Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the
% reasons.
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
sep = false(1, 256);   % the delimiters ' \t\n\r'
sep(double(sprintf(' \t\n\r')) + 1) = true;
if ~isempty(S.hheader)
    S.hheader.close();
    S.hheader = [];
end
S.spfmax = 1;
S.sfreq = S.ffreq;
S.isedf = 0;
if strcmp(record, '~')
    if S.in_msrec && ~isempty(S.vsd)
        h = wfdbx.internal.hsdata();
        h.info.desc = '~';
        h.info.spf = 1;
        h.info.fmt = 0;
        S.nsamples = S.segarray(S.segp + 1).nsamp;
        h.info.nsamp = S.nsamples;
        S.hsd = h;
        nsig = 1;
        return;
    end
    nsig = 0;
    return;
end
% Find the last '.', '/', ':' or '\' (0-based index q, as in the Python port).
q = numel(record) - 1;
while q > 0 && ~any(record(q + 1) == './:\')
    q = q - 1;
end
if q >= 0 && numel(record) > q && record(q + 1) == '.'
    S.hheader = open_header(S, [], record);
    if isempty(S.hheader)
        wfdbx.internal.wfdb_error('init: can''t open %s\n', record);
        nsig = -1;
        return;
    elseif ~strcmp(record(q + 2:end), 'hea')
        nsig = wfdbx.internal.edfparse(S.hheader);
        return;
    end
else
    S.hheader = open_header(S, 'hea', record);
    if isempty(S.hheader)
        wfdbx.internal.wfdb_error( ...
            'init: can''t open header for record %s\n', record);
        nsig = -1;
        return;
    end
end
hh = S.hheader;
line = hh.getline();
if isempty(line)
    wfdbx.internal.wfdb_error('init: record %s header is empty\n', record);
    nsig = -2;
    return;
end
if strncmp(line, '#wfdb', 5)
    vals = [];
    pos = 6;
    for k = 1:3
        [v, e] = wfdbx.internal.strtol(line, 10, pos);
        if e == pos
            break;
        end
        vals(end + 1) = v; %#ok<AGROW>
        pos = e;
        if k < 3
            if pos > numel(line) || line(pos) ~= '.'
                break;
            end
            pos = pos + 1;
        end
    end
    i = numel(vals);
    vals(end + 1:3) = 0;
    major = vals(1);
    minor = vals(2);
    release = vals(3);
    if (i > 0 && major > 10) || (i > 1 && major == 10 && minor > 7) || ...
            (i > 2 && major == 10 && minor == 7 && release > 0)
        wfdbx.internal.wfdb_error(['init: reading record %s requires ' ...
            'WFDB library version %d.%d.%d or later\n' ...
            '  (the most recent version is always available from ' ...
            'http://physionet.org)\n'], record, major, minor, release);
        nsig = -1;
        return;
    end
end
[t, rest] = tokens(line, sep, 4);
p = t{1};
while ~ischar(p) || p(1) == '#'
    line = hh.getline();
    if isempty(line)
        wfdbx.internal.wfdb_error( ...
            'init: can''t find record name in record %s header\n', record);
        nsig = -2;
        return;
    end
    [t, rest] = tokens(line, sep, 4);
    p = t{1};
end
slash = find(p(2:end) == '/', 1);
if ~isempty(slash)
    slash = slash + 1;      % 1-based index of the '/'
    if S.in_msrec
        wfdbx.internal.wfdb_error(['init: record %s cannot be nested in ' ...
            'another multi-segment record\n'], record);
        nsig = -2;
        return;
    end
    S.segments = wfdbx.internal.cint32(wfdbx.internal.strtol(p, 10, slash + 1));
    p = p(1:slash - 1);
end
if hh.type == 0 && ~hh.is_std && ~strncmp(record, p, numel(p))
    r = record;
    sidx = numel(r) - 1;
    q2 = sidx;
    while sidx > 0
        if any(r(sidx + 1) == '/\:')
            break;
        end
        sidx = sidx - 1;
    end
    if q2 > sidx && (0 > sidx || ~strcmp(p, r(sidx + 2:end)))
        wfdbx.internal.wfdb_error( ...
            'init: record name in record %s header is incorrect\n', record);
        nsig = -2;
        return;
    end
end
p = t{2};
if ~ischar(p)
    wfdbx.internal.wfdb_error('init: obsolete format in record %s header\n', ...
        record);
    nsig = -2;
    return;
end
nsig = mod(tol(p), 4294967296);   % unsigned
p = t{3};
if ischar(p)
    f = tod(p);
    if f <= 0
        wfdbx.internal.wfdb_error(['init: sampling frequency in record %s ' ...
            'header is incorrect\n'], record);
        nsig = -2;
        return;
    end
    if S.ffreq > 0 && f ~= S.ffreq
        wfdbx.internal.wfdb_error('warning (init):\n');
        wfdbx.internal.wfdb_error(' record %s sampling frequency differs', ...
            record);
        wfdbx.internal.wfdb_error(' from that of previously opened record\n');
    else
        S.ffreq = f;
    end
elseif S.legacy_mode && S.ffreq == 0
    % WFDB-x: if the header does not specify the sampling frequency (and
    % the caller has not set one with setsampfreq), it remains unspecified
    % (0); the C library assumed WFDB_DEFFREQ (250 Hz), as legacy mode
    % does.  See docs/DIVERGENCES.md.
    S.ffreq = 250;      % WFDB_DEFFREQ
end
S.sfreq = S.ffreq;
S.cfreq = 0;
S.bcount = 0;
if ischar(p)
    k = find(p == '/', 1);
    if ~isempty(k)
        S.cfreq = wfdbx.internal.strtod(p, k + 1);
        k2 = find(p(k + 1:end) == '(', 1);
        if ~isempty(k2)
            S.bcount = wfdbx.internal.strtod(p, k + k2 + 1);
        end
    end
end
if S.cfreq <= 0
    S.cfreq = S.ffreq;
end
p = t{4};
if ischar(p)
    ns = tol(p);
    if ns < 0
        wfdbx.internal.wfdb_error(['init: number of samples in record %s ' ...
            'header is incorrect\n'], record);
        nsig = -2;
        return;
    end
    if S.nsamples == 0
        S.nsamples = ns;
    elseif ns > 0 && ns ~= S.nsamples && ~S.in_msrec
        wfdbx.internal.wfdb_error('warning (init):\n');
        wfdbx.internal.wfdb_error(' record %s duration differs', record);
        wfdbx.internal.wfdb_error(' from that of previously opened record\n');
        if S.nsamples > ns
            S.nsamples = ns;
        end
    end
else
    ns = 0;
end
p = line_rest(line, rest);
if ischar(p) && S.btime == 0 && wfdbx.setbasetime(p) < 0
    nsig = -2;
    return;
end
% The master header of a multi-segment record.
if S.segments && ~S.in_msrec
    if ~wfdbx.wfdbx_get_legacy()    % WFDB-x: the segments are next to it
        S.msrec_dir = S.hdr_dir;
        S.msrec_name = record;
    end
    S.msbtime = S.btime;
    S.msbdate = S.bdate;
    S.msnsamples = S.nsamples;
    segarray = wfdbx.seginfo(S.segments);
    ns = 0;
    for i = 1:S.segments
        while true
            line = hh.getline();
            if isempty(line)
                wfdbx.internal.wfdb_error(['init: unexpected EOF in header ' ...
                    'file for record %s\n'], record);
                S.segarray = [];
                S.segments = 0;
                nsig = -2;
                return;
            end
            t = tokens(line, sep, 2);
            p = t{1};
            if ischar(p) && p(1) ~= '#'
                break;
            end
        end
        if p(1) == '+'
            wfdbx.internal.wfdb_error(['init: `%s'' is not a valid segment ' ...
                'name in record %s\n'], p, record);
            S.segarray = [];
            S.segments = 0;
            nsig = -2;
            return;
        end
        if numel(p) > 50        % WFDB_MAXRNL
            wfdbx.internal.wfdb_error(['init: `%s'' is too long for a ' ...
                'segment name in record %s\n'], p, record);
            S.segarray = [];
            S.segments = 0;
            nsig = -2;
            return;
        end
        segarray(i).recname = p;
        p = t{2};
        if ischar(p)
            segarray(i).nsamp = tol(p);
        end
        if ~ischar(p) || segarray(i).nsamp < 0
            wfdbx.internal.wfdb_error(['init: length must be specified for ' ...
                'segment %s in record %s\n'], segarray(i).recname, record);
            S.segarray = [];
            S.segments = 0;
            nsig = -2;
            return;
        end
        segarray(i).samp0 = ns;
        ns = ns + segarray(i).nsamp;
    end
    S.segarray = segarray;
    S.segend = numel(segarray) - 1;
    S.segp = 0;
    if S.msnsamples == 0
        S.msnsamples = ns;
    elseif ns ~= S.msnsamples
        wfdbx.internal.wfdb_error(['warning (init): in record %s, stated ' ...
            'record length (%d)\n'], record, S.msnsamples);
        wfdbx.internal.wfdb_error(' does not match sum of segment lengths (%d)\n', ns);
    end
    nsig = 0;
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
fmtlist = [0 8 16 61 80 160 212 310 311 24 32 508 516 524];
s = 0;
while s < nsig
    hs = hsd(s + 1);
    while true
        line = hh.getline();
        if isempty(line)
            S.hsd = hsd;
            wfdbx.internal.wfdb_error(['init: unexpected EOF in header file ' ...
                'for record %s\n'], record);
            nsig = -2;
            return;
        end
        [t, rest] = tokens(line, sep, 8);
        p = t{1};
        if ischar(p) && p(1) ~= '#'
            break;
        end
    end
    info = hs.info;
    if s == 0 || ~strcmp(p, hsd(s).info.fname)
        if s == 0
            info.group = 0;
        else
            info.group = hsd(s).info.group + 1;
        end
        info.fname = p;
    else
        info.group = hsd(s).info.group;
        info.fname = hsd(s).info.fname;
    end
    p = t{2};
    if ischar(p)
        info.fmt = cint32(tol(p));
    end
    if ~ischar(p) || ~any(info.fmt == fmtlist)
        S.hsd = hsd;
        wfdbx.internal.wfdb_error( ...
            'init: illegal format for signal %d, record %s\n', s, record);
        nsig = -2;
        return;
    end
    info.spf = 1;
    hs.skew = 0;
    hs.start = 0;
    % Parse the optional "xSPF", ":SKEW" and "+START" suffixes (0-based k).
    k = 0;
    n = numel(p);
    q = p(2:end);
    while any(q == 'x' | q == ':' | q == '+')
        k = k + 1;
        if k >= n
            break;
        end
        if p(k + 1) == 'x'
            k = k + 1;
            if k < n
                info.spf = wfdbx.internal.cint32( ...
                    wfdbx.internal.strtol(p, 10, k + 1));
                if info.spf < 1
                    info.spf = 1;
                end
            end
        end
        if k < n && p(k + 1) == ':'
            k = k + 1;
            if k < n
                hs.skew = wfdbx.internal.cint32(wfdbx.internal.strtol(p, 10, k + 1));
                if hs.skew < 0
                    hs.skew = 0;
                end
            end
        end
        if k < n && p(k + 1) == '+'
            k = k + 1;
            if k < n
                hs.start = wfdbx.internal.strtol(p, 10, k + 1);
                if hs.start < 0
                    hs.start = 0;
                end
            end
        end
        if k >= n
            break;
        end
    end
    if info.spf > S.spfmax
        S.spfmax = info.spf;
    end
    hs.skew = fix(hs.skew / info.spf + 0.5);
    p = t{3};
    if ischar(p)
        info.gain = tod(p);
    else
        info.gain = 0;
    end
    nobaseline = true;
    units = [];
    if ischar(p)
        n = numel(p);
        k = find(p == '(' | p == '/', 1) - 1;
        if isempty(k)
            k = n;
        end
        if k < n && p(k + 1) == '('
            k = k + 1;
            info.baseline = wfdbx.internal.cint32( ...
                wfdbx.internal.strtol(p, 10, k + 1));
            nobaseline = false;
        end
        % (after the first '/' that is not the last character)
        j = find(p(k + 1:n - 1) == '/', 1);
        if isempty(j)
            k = n;
        else
            k = k + j;
        end
        if k < n
            units = p(k + 1:min(n, k + 50));    % WFDB_MAXUSL
        end
    end
    info.units = units;
    p = t{4};
    if ischar(p)
        i = tol(p);
    else
        % WFDB-x: a missing ADC resolution is unspecified (0); the C
        % library inferred it from the format or assumed WFDB_DEFRES (12),
        % as legacy mode does.
        i = 0;
        if S.legacy_mode
            switch info.fmt
                case 80
                    i = 8;
                case 160
                    i = 16;
                case 212
                    i = 12;
                case {310, 311}
                    i = 10;
                otherwise
                    i = 12;     % WFDB_DEFRES
            end
        end
    end
    info.adcres = cint32(i);
    p = t{5};
    if ischar(p)
        info.adczero = cint32(tol(p));
    else
        info.adczero = 0;
    end
    if nobaseline
        info.baseline = info.adczero;
    end
    p = t{6};
    if ischar(p)
        info.initval = cint32(tol(p));
    else
        info.initval = info.adczero;
    end
    p = t{7};
    if ischar(p)
        info.cksum = cint32(tol(p));
        info.nsamp = ns;
    else
        info.cksum = 0;
        info.nsamp = 0;
    end
    p = t{8};
    if ischar(p)
        info.bsize = cint32(tol(p));
    else
        info.bsize = 0;
    end
    if s > 0 && info.group == hsd(s).info.group && ...
            (info.fmt ~= hsd(s).info.fmt || info.bsize ~= hsd(s).info.bsize)
        hs.info = info;
        hsd(s + 1) = hs;
        S.hsd = hsd;
        wfdbx.internal.wfdb_error( ...
            'init: error in specification of signal %d or %d\n', s - 1, s);
        nsig = -2;
        return;
    end
    p = line_rest(line, rest);
    if ischar(p)
        info.desc = p(1:min(end, 100));      % WFDB_MAXDSL
    else
        info.desc = sprintf('record %s, signal %d', record, s);
    end
    hs.info = info;
    hsd(s + 1) = hs;
    s = s + 1;
end
S.hsd = hsd;
wfdbx.setgvmode(S.gvmode);
nsig = s;
end

function f = open_header(S, s, record)
% Open the header (of type s: 'hea', or [] for a file name) of a record,
% or of a segment named in the header of the current multi-segment record
% (WFDB-x: in that header's directory), and note its directory.
if wfdbx.wfdbx_get_legacy()
    f = wfdbx.internal.wfdb_open(s, record, 0);     % WFDB_READ
    return;
end
if ~S.in_msrec
    S.msrec_dir = [];
    S.msrec_name = [];
end
if S.in_msrec && ischar(S.msrec_name) && ~S.user_segments
    f = wfdbx.internal.open_in(S.msrec_dir, s, record, S.msrec_name);
else
    f = wfdbx.internal.wfdb_open(s, record, 0);     % WFDB_READ
end
S.hdr_dir = [];
if ~isempty(f) && ~f.is_std
    S.hdr_dir = wfdbx.internal.wfdb_dirname(wfdbx.wfdbfile([], []));
end
end

function [t, pos] = tokens(s, isd, k)
% The first K tokens of the line S (strtok(s, d), then K - 1 calls of
% strtok(NULL, d), the delimiters d being the characters c with
% ISD(c + 1)): a cell row with [] for the missing ones.  POS: the index of
% the next character to scan (as Strtok), 0 when the line is exhausted.
t = cell(1, k);
m = isd(double(s) + 1);
d = diff([true, m, true]);
first = find(d == -1);
last = find(d == 1) - 1;
for q = 1:min(k, numel(first))
    t{q} = s(first(q):last(q));
end
if numel(first) >= k && last(k) < numel(s)
    pos = last(k) + 2;      % (after the delimiter ending token K)
else
    pos = 0;
end
end

function p = line_rest(s, pos)
% strtok(NULL, "\n\r") from the index POS of the line S (as Strtok).
p = [];
if pos == 0 || pos > numel(s)
    return;
end
m = s(pos:end) == 10 | s(pos:end) == 13;
i = find(~m, 1);
if isempty(i)
    return;
end
j = find(m(i:end), 1);
if isempty(j)
    p = s(pos + i - 1:end);
else
    p = s(pos + i - 1:pos + i + j - 3);
end
end

function v = tol(p)
% strtol(p, NULL, 10) for a token P (decimal digits read directly).
d = double(p) - 48;
neg = d(1) == -3;           % '-'
if neg || d(1) == -5        % '+'
    d = d(2:end);
end
if ~isempty(d) && numel(d) <= 15 && all(d >= 0 & d <= 9)
    v = d * 10 .^ (numel(d) - 1:-1:0)';
    if neg
        v = -v;
    end
else
    v = wfdbx.internal.strtol(p);
end
end

function v = tod(p)
% strtod(p, NULL) for a token P (an integer ending at '/', '(' or the end
% read directly).
d = double(p) - 48;
k = find(d < 0 | d > 9, 1);
if isempty(k)
    k = numel(d) + 1;
end
if k > 1 && k <= 16 && (k > numel(d) || p(k) == '/' || p(k) == '(')
    v = d(1:k - 1) * 10 .^ (k - 2:-1:0)';
else
    v = wfdbx.internal.strtod(p);
end
end

function y = cint32(x)
% (int) x
y = mod(x + 2147483648, 4294967296) - 2147483648;
end
