function stat = setmsheader(record, segment_name, nsegments)
%SETMSHEADER Create the header of a multi-segment record.
%   STAT = wfdbx.setmsheader(RECORD, SEGNAMES) writes RECORD.hea, the
%   header of a multi-segment record made of the records named in the
%   cell array SEGNAMES (whose headers must exist and have the same
%   number of signals and sampling frequency).  STAT = 0 on success, or a
%   negative value on error.  wfdbx.setmsheader(RECORD, SEGNAMES, N) uses
%   the first N segments.
%
%   See also wfdbx.setheader, wfdbx.getseginfo.
%
%   Translation of the C function setmsheader() (lib/signal.c, WFDB 10.7.0):
%   same arguments and results. Differences: a header written under a path
%   names the record and its segments relative to its own directory, and only
%   the record's own name (the last component) is checked; see
%   docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: the names written into the header are relative
% to the header's directory, and the segments are read as named by the
% caller. Each change is marked "wfdb-x:" in the code; docs/DIVERGENCES.md
% gives the reasons.
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
segment_name = wfdbx.internal.strarg(segment_name);
S = wfdbx.internal.sig_state();
if nargin < 3
    nsegments = numel(segment_name);
end
msfreq = 0;
mscfreq = 0;
msbcount = 0;
nsig = 0;
old_in_msrec = S.in_msrec;
wfdbx.internal.isigclose();
if ~isempty(S.oheader)
    S.oheader.close();
    if S.outinfo_hdr
        S.outinfo = [];
        S.outinfo_hdr = false;
    end
    S.oheader = [];
end
record = wfdbx.internal.wfdb_striphea(record);
if wfdbx.internal.wfdb_checkname(record, 'record')
    stat = -1;
    return;
end
if nsegments < 1
    wfdbx.internal.wfdb_error('setmsheader: record must contain at least one segment\n');
    stat = -1;
    return;
end
ns = zeros(1, nsegments);
for i = 1:nsegments
    name = segment_name{i};
    if numel(name) > 50                 % WFDB_MAXRNL
        wfdbx.internal.wfdb_error(['setmsheader: `%s'' is too long for a ' ...
            'segment name in record %s\n'], name, record);
        stat = -2;
        return;
    end
    S.in_msrec = 1;
    S.nsamples = 0;
    S.user_segments = true;     % wfdb-x: names given by the caller
    n = wfdbx.internal.readheader(name);
    S.user_segments = false;
    S.in_msrec = old_in_msrec;
    if n < 0
        wfdbx.internal.wfdb_error('setmsheader: can''t read segment %s header\n', name);
        stat = -3;
        return;
    end
    ns(i) = S.nsamples;
    if ns(i) <= 0
        wfdbx.internal.wfdb_error( ...
            'setmsheader: length of segment %s must be specified\n', name);
        stat = -4;
        return;
    end
    if i == 1
        nsig = n;
        msfreq = S.ffreq;
        mscfreq = S.cfreq;
        msbcount = S.bcount;
        S.msbtime = S.btime;
        S.msbdate = S.bdate;
        S.msnsamples = ns(i);
    else
        if nsig ~= n
            wfdbx.internal.wfdb_error(['setmsheader: incorrect number of ' ...
                'signals in segment %s\n'], name);
            stat = -4;
            return;
        end
        if msfreq ~= S.ffreq
            wfdbx.internal.wfdb_error(['setmsheader: incorrect sampling ' ...
                'frequency in segment %s\n'], name);
            stat = -4;
            return;
        end
        S.msnsamples = S.msnsamples + ns(i);
    end
end
S.oheader = wfdbx.internal.wfdb_open('hea', record, 1);    % WFDB_WRITE
if isempty(S.oheader)
    wfdbx.internal.wfdb_error( ...
        'setmsheader: can''t create header file for record %s\n', record);
    stat = -1;
    return;
end
g12 = @(x) wfdbx.internal.csprintf('%.12g', x);
% wfdb-x: names relative to the header's directory (hea_name)
out = sprintf('%s/%d %d %s', wfdbx.internal.hea_name(record, record), ...
    nsegments, nsig, g12(msfreq));
if (mscfreq > 0 && mscfreq ~= msfreq) || msbcount ~= 0
    out = [out '/' g12(mscfreq)];
    if msbcount ~= 0
        out = [out '(' g12(msbcount) ')'];
    end
end
out = [out sprintf(' %d', S.msnsamples)];
if S.msbtime ~= 0 || S.msbdate ~= 0
    if mod(S.msbtime, 1000) == 0
        out = [out ' ' wfdbx.internal.ftimstr(S.msbtime, 1000)];
    else
        out = [out ' ' wfdbx.internal.fmstimstr(S.msbtime, 1000)];
    end
end
if S.msbdate
    out = [out wfdbx.datstr(S.msbdate)];
end
crlf = sprintf('\r\n');
out = [out crlf];
for i = 1:nsegments
    out = [out sprintf('%s %d', wfdbx.internal.hea_name(record, segment_name{i}), ns(i)) crlf]; %#ok<AGROW>
end
S.oheader.write(out);
stat = 0;
end
