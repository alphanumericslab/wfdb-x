function [nsig, si] = isigopen(record, nsig)
%ISIGOPEN Open the input signals of a record.
%   [N, SI] = wfdbx.isigopen(RECORD, NSIG) opens up to NSIG signals of the
%   record RECORD (closing any input signals open before, unless RECORD
%   begins with '+', in which case the signals are added to those already
%   open).  N is the number of signals opened and SI a 1-by-N struct array
%   of wfdbx.siginfo structures describing them.
%
%   If NSIG <= 0, no signals are opened: N is the number of signals of the
%   record, and SI describes the first min(N, -NSIG) of them (so
%   wfdbx.isigopen(RECORD, 0) only reads the header, and
%   wfdbx.isigopen(RECORD, -N) returns the description of the signals).
%
%   N is negative on error: -1 if the header cannot be read, -2 if it is
%   invalid, -3 if the signals cannot be opened.  (Messages are printed
%   unless wfdbx.wfdbquiet() was called.)
%
%   RECORD may name a header file ('100s.hea'), and may be an EDF file
%   name ('rec.edf').  Multi-segment records are opened segment by segment
%   as they are read.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       n = wfdbx.isigopen('100s', 0);         % number of signals
%       [n, si] = wfdbx.isigopen('100s', n);   % open them
%       [stat, v] = wfdbx.getvec();             % read a sample of each
%
%   See also wfdbx.getvec, wfdbx.getframes, wfdbx.isigsettime,
%   wfdbx.siginfo, wfdbx.wfdbquit.
%
%   Translation of the C function isigopen() (lib/signal.c, WFDB 10.7.0): same
%   arguments and results. Differences: the signal files and segments named in
%   the header are read only from the header's directory, and no sampling
%   frequency, gain, ADC resolution or units are assumed; see
%   docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: the signal files are read from the directory of
% the header, not searched for. Each change is marked "WFDB-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
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

if isa(record, 'string')   % MATLAB string
    record = char(record);
end
if nargin < 2
    nsig = 0;
end
S = wfdbx.internal.sig_state();
si = wfdbx.siginfo(0);
first_segment = 0;
if ~isempty(record) && record(1) == '+'
    record = record(2:end);
else
    wfdbx.internal.isigclose();
end
record = wfdbx.internal.wfdb_striphea(record);
if ~S.in_msrec
    wfdbx.internal.wfdb_setirec(record);
end
navail = wfdbx.internal.readheader(record);
if navail <= 0
    if navail == 0 && S.segments
        S.in_msrec = 1;
        first_segment = 1;
        if ~isempty(S.segarray)
            navail = wfdbx.internal.readheader(S.segarray(S.segp + 1).recname);
            if navail >= 0
                if S.msbtime == 0
                    S.msbtime = S.btime;
                end
                if S.msbdate == 0
                    S.msbdate = S.bdate;
                end
            end
        end
        if nsig <= 0
            S.in_msrec = 0;
        end
    end
    if navail == 0 && nsig
        wfdbx.internal.wfdb_error('isigopen: record %s has no signals\n', record);
    end
    if navail <= 0
        nsig = navail;
        return;
    end
end
hsd = S.hsd;
if nsig <= 0
    nsig = -nsig;
    if navail < nsig
        nsig = navail;
    end
    if nsig > 0
        si = [hsd(1:nsig).info];
    end
    S.in_msrec = 0;
    nsig = navail;
    return;
end
if nsig > navail
    nsig = navail;
end
if S.ibsize <= 0
    S.ibsize = 8192;    % BUFSIZ
end
nisig0 = S.nisig;
nigroup0 = S.nigroup;
% (the input groups C allocates (allocigroup), whether they are opened or
% not: isgsetframe reads them)
nn = nigroup0 + hsd(navail).info.group + 1;
if nn > nigroup0 + nsig
    nn = nigroup0 + nsig;
end
S.nigalloc = max(S.nigalloc, nn);
new_isd = repmat(wfdbx.internal.isdata(), 1, 0);
new_igd = {};
si_ = 0;        % 0-based index in hsd
s = 0;
while si_ < navail && s < nsig
    hs = hsd(si_ + 1);
    sj = si_ + 1;
    while sj < navail && hsd(sj + 1).info.group == hs.info.group
        sj = sj + 1;
    end
    if sj - si_ > nsig - s
        si_ = sj;
        continue;
    end
    ig = wfdbx.internal.IGData();
    if hs.info.bsize < 0
        hs.info.bsize = -hs.info.bsize;
        hsd(si_ + 1).info.bsize = hs.info.bsize;
        ig.bsize = hs.info.bsize;
        ig.seek = 0;
    else
        ig.bsize = hs.info.bsize;
        if ig.bsize == 0
            ig.bsize = S.ibsize;
        end
        ig.seek = 1;
    end
    if hs.info.fmt == 0
        ig.fp = [];
    else
        if S.legacy_mode
            ig.fp = wfdbx.internal.wfdb_open(hs.info.fname, [], 0); % WFDB_READ
        else    % WFDB-x: in the directory of the header
            ig.fp = wfdbx.internal.open_in(S.hdr_dir, [], hs.info.fname, ...
                record);
        end
        if isempty(ig.fp)
            si_ = sj;
            continue;
        end
    end
    if hs.info.fmt >= 500 && hs.info.fmt <= 532     % FLAC formats
        S.hsd = hsd;
        if ~wfdbx.internal.pkg_has('internal.flac_isopen')
            wfdbx.internal.wfdb_error('isigopen: FLAC formats are not supported\n');
            ig.fp.close();
            si_ = sj;
            continue;
        end
        if wfdbx.internal.flac_isopen(ig, hsd(si_ + 1:sj), sj - si_) < 0
            ig.fp.close();
            si_ = sj;
            continue;
        end
    end
    ig.bp = 0;
    ig.be = 0;
    ig.start = hs.start;
    ig.initial_skip = double(ig.start > 0);
    ig.stat = 1;
    gnum = nigroup0 + numel(new_igd);
    while si_ < sj && s < nsig
        d = wfdbx.internal.isdata();
        d.info = hs.info;
        d.info.group = gnum;
        d.skew = hs.skew;
        new_isd(end + 1) = d; %#ok<AGROW>
        s = s + 1;
        si_ = si_ + 1;
        if si_ < sj
            hs = hsd(si_ + 1);
        end
    end
    new_igd{end + 1} = ig; %#ok<AGROW>
    si_ = sj;
end
S.hsd = hsd;
if s == 0 && nsig
    wfdbx.internal.wfdb_error( ...
        'isigopen: none of the signals for record %s is readable\n', record);
end
INT_MAX = 2147483647;
spflimit = INT_MAX - S.framelen;
for k = 1:numel(new_isd)
    spflimit = spflimit - new_isd(k).info.spf;
    if spflimit < 0
        wfdbx.internal.wfdb_error( ...
            'isigopen: total frame size too large in record %s\n', record);
        wfdbx.internal.isigclose();
        nsig = -3;
        return;
    end
end
for k = 1:numel(new_isd)
    new_isd(k).samp = new_isd(k).info.initval;
    if S.ispfmax < new_isd(k).info.spf
        S.ispfmax = new_isd(k).info.spf;
    end
    if S.skewmax < new_isd(k).skew
        S.skewmax = new_isd(k).skew;
    end
end
if isempty(new_isd)
    si = wfdbx.siginfo(0);
else
    si = [new_isd.info];
end
old = S.isd;
if nisig0 > 0
    S.isd = [old(1:nisig0), new_isd];
else
    S.isd = new_isd;
end
oldg = S.igd;
S.igd = [oldg(1:nigroup0), new_igd];
S.nisig = S.nisig + s;
S.nigroup = S.nigroup + numel(new_igd);
S.plan = [];
for k = 1:numel(new_igd)
    if new_igd{k}.initial_skip
        S.skip_pending = true;
    end
end
if wfdbx.internal.sigmap_init(first_segment) < 0
    wfdbx.internal.isigclose();
    nsig = -3;
    return;
end
S.spfmax = S.ispfmax;
wfdbx.setgvmode(S.gvmode);
S.gvc = S.ispfmax;
framelen = 0;
isd = S.isd;
gspf = zeros(1, S.nigroup);     % samples per frame of each signal group
for i = 1:S.nisig
    info = isd(i).info;
    framelen = framelen + info.spf;
    if info.fmt ~= 0
        if info.group >= numel(gspf)
            gspf(info.group + 1) = 0;
        end
        gspf(info.group + 1) = gspf(info.group + 1) + info.spf;
    end
end
S.framelen = framelen;
% WFDB-x: a signal group whose frames hold no samples (an EDF file can give
% 0 samples per data record) is at the end of its data at once
S.empty_group = false;
for i = 1:S.nisig
    info = isd(i).info;
    if info.fmt ~= 0 && gspf(info.group + 1) == 0
        S.empty_group = true;
    end
end
if S.tspf > S.tuvlen
    S.tvector = zeros(1, S.tspf);
    S.uvector = zeros(1, S.tspf);
    S.vvector = zeros(1, S.tspf);
    S.tuvlen = S.tspf;
end
if S.skewmax ~= 0 && (~S.in_msrec || ~S.has_dsbuf)
    if S.tspf > fix(INT_MAX / (S.skewmax + 1))
        wfdbx.internal.wfdb_error( ...
            'isigopen: maximum skew too large in record %s\n', record);
        wfdbx.internal.isigclose();
        nsig = -3;
        return;
    end
    S.dsbi = -1;
    S.dsblen = S.tspf * (S.skewmax + 1);
    S.dsbuf = zeros(1, S.dsblen);
    S.has_dsbuf = true;
end
nsig = s;
end
