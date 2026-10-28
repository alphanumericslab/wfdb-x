function status = snip(args)
%SNIP Copy an excerpt of a WFDB record.
%   STATUS = wfdbx.apps.snip(ARGS) runs the snip tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       snip -i IREC -n NREC [OPTIONS ...]
%   where IREC is the record to be copied, NREC the new record, and
%   OPTIONS may include:
%       -a ANNOTATOR [ANNOTATOR ...]  copy annotations of the ANNOTATORs
%       -f TIME     begin at specified time
%       -h          print a usage summary
%       -l DURATION snip only DURATION (overrides -t)
%       -m          preserve segments of multi-segment input, if possible
%       -O FORMAT   output format (default: best fit to ADC resolution)
%       -s          suppress output of info strings in header
%       -t TIME     stop at specified time
%
%   WFDB-x: the input record must specify its sampling frequency (the C
%   program assumed 250 Hz); see docs/DIVERGENCES.md.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository; the example writes the record excerpt in the current
%   folder):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.snip({'-i', '100s', '-n', 'excerpt', ...
%                        '-f', '10', '-t', '20'})
%
%   See also wfdbx.apps.xform.
%
%   Translation of the C program snip (app/snip.c, WFDB 10.7.0): same
%   options and output. Differences: no sampling frequency is assumed; see
%   docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/snip.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in sampling frequency: the input record
% must give it, for the header of the excerpt (the original assumed 250 Hz);
% --legacy, as the first argument, restores the original behavior. Each change
% is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the reasons.
%
% Original C program: app/snip.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2021 by
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
status = wfdbx.internal.app_run(@main, [{'snip'}, args]);
end

function help(pname)
h = {'where IREC is the name of the record to be converted, NREC is the name to', ...
    'be given to the record to be generated, and OPTIONS may include any of:', ...
    ' -a ANNOTATOR [ANNOTATOR ...]  copy annotations for the specified ANNOTATOR', ...
    '              from IREC;  two or more ANNOTATORs may follow -a', ...
    ' -f TIME     begin at specified time', ...
    ' -h          print this usage summary', ...
    ' -l DURATION snip only DURATION (hh:mm:ss or sNNNN; overrides -t)', ...
    ' -m          preserve segments of multsegment input, if possible', ...
    ' -O FORMAT   save output in the specified FORMAT (default: use best fit', ...
    '              to ADC resolution)', ...
    ' -s          suppress output of info strings in header', ...
    ' -t TIME     stop at specified time', ...
    'To change the sampling frequency, zero level, or gain, to select a', ...
    'subset of signals, or to re-order signals, use `xform''.'};
wfdbx.internal.ceprintf('usage: %s -i IREC -n NREC [OPTIONS ...]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function copy_ann(pname, nrec, irec, from, to, annotators)
n = numel(annotators);
ai = wfdbx.anninfo(annotators{1}, 0);       % WFDB_READ
ai = repmat(ai, 1, n);
ao = ai;
for k = 1:n
    ai(k).name = annotators{k};
    ao(k).name = annotators{k};
    ao(k).stat = 1;                         % WFDB_WRITE
end
if wfdbx.annopen(irec, ai, n) < 0
    wfdbx.internal.ceprintf('%s: error opening input annotators\n', pname);
    wfdbx.internal.cexit(2);
end
if wfdbx.annopen(['+' nrec], ao, n) < 0
    wfdbx.internal.ceprintf('%s: error opening output annotators\n', pname);
    wfdbx.internal.cexit(2);
end
for i = 0:n - 1
    [stat, A] = wfdbx.internal.getann_bulk(i, inf); %#ok<ASGLU>
    keep = A.time >= from & (to == 0 | A.time < to);
    A.time = A.time(keep) - from;
    A.anntyp = A.anntyp(keep);
    A.subtyp = A.subtyp(keep);
    A.chan = A.chan(keep);
    A.num = A.num(keep);
    A.aux = A.aux(keep);
    wfdbx.internal.putann_bulk(i, A);
end
wfdbx.wfdbquit();
end

function opt = copy_sig(opt, nrec, irec, from, to, recurse)
pname = opt.pname;
wfdbx.wfdbquit();
nsig = wfdbx.isigopen(irec, 0);
if nsig < 0
    wfdbx.internal.ceprintf('%s: error opening header for %s\n', pname, irec);
    wfdbx.internal.cexit(2);
end
[n, si] = wfdbx.isigopen(irec, nsig);
if n ~= nsig
    wfdbx.internal.ceprintf('%s: error opening signals for %s\n', pname, irec);
    wfdbx.internal.cexit(2);
end
tstring = [];
p = wfdbx.mstimstr(-from);
if strncmp(p, '[', 1)
    tstring = p(2:end);
    k = find(tstring == ']', 1);
    if ~isempty(k)
        tstring = tstring(1:k - 1);
    end
    k = find(tstring == ' ', 1);
    if ~isempty(k) && ~any(tstring(k:end) == '/')
        tstring = tstring(1:k - 1);
    end
end
seginfo = wfdbx.getseginfo();
maxseg = numel(seginfo);
if recurse && maxseg > 0
    sfreq = wfdbx.sampfreq([]);
    ohfile = wfdbx.internal.OutputFile([nrec '.hea'], pname);
    if ohfile.fid < 0
        wfdbx.internal.ceprintf('%s: can''t create master header\n', pname);
        wfdbx.internal.cexit(2);
    end
    if seginfo(1).nsamp == 0
        olrecname = [nrec '_layout'];
        for k = 1:nsig
            si(k).fname = '~';
            si(k).fmt = 0;
            si(k).nsamp = 0;
            si(k).cksum = 0;
        end
        if ischar(tstring)
            wfdbx.setbasetime(tstring);
        end
        if wfdbx.setheader(olrecname, si, nsig) < 0
            wfdbx.internal.ceprintf('%s: can''t create layout header\n', pname);
            fclose(ohfile.fid);
            wfdbx.internal.cexit(2);
        end
        if opt.sflag == 0
            wfdbx.wfdbquiet();
            info = wfdbx.getinfo(irec);
            while ischar(info)
                wfdbx.putinfo(info);
                info = wfdbx.getinfo([]);
            end
            wfdbx.wfdbverbose();
            opt.sflag = 1;
        end
    end
    first_seg = 0;
    last_seg = maxseg - 1;
    for i = 0:maxseg - 1
        t = seginfo(i + 1).samp0;
        tf = seginfo(i + 1).samp0 + seginfo(i + 1).nsamp;
        if t <= from && from < tf
            first_seg = i;
        end
        if t <= to && to <= tf
            last_seg = i;
            break;
        end
    end
    nseg = last_seg - first_seg + 1;
    if seginfo(1).nsamp == 0
        nseg = nseg + 1;
    end
    tf = seginfo(last_seg + 1).samp0 + seginfo(last_seg + 1).nsamp;
    if to > tf
        to = tf;
    end
    hdr = wfdbx.internal.csprintf('%s/%d %d %.12g %d', nrec, nseg, nsig, ...
        sfreq, to - from);
    if ischar(tstring)
        hdr = [hdr ' ' tstring];
    end
    hdr = [hdr sprintf('\r\n')];
    if seginfo(1).nsamp == 0
        hdr = [hdr nrec sprintf('_layout 0\r\n')];
    end
    ohfile.write(uint8(hdr));
    i = 0;
    for j = first_seg:last_seg
        t = seginfo(j + 1).samp0;
        tf = seginfo(j + 1).samp0 + seginfo(j + 1).nsamp;
        if to < tf
            tf = to;
        end
        if from > t
            start = from - t;
            len = tf - from;
        else
            start = 0;
            len = tf - t;
        end
        if strcmp(seginfo(j + 1).recname, '~')
            orseg = '~';
        else
            i = i + 1;
            orseg = sprintf('%s_%04d', nrec, i);
            opt = copy_sig(opt, orseg, seginfo(j + 1).recname, start, ...
                start + len, 0);
        end
        ohfile.write(uint8([orseg wfdbx.internal.csprintf(' %d', len) ...
            sprintf('\r\n')]));
    end
    ohfile.close();     % WFDB-x: reports a write error
    return;
end
if opt.fmt <= 0
    maxres = si(1).adcres;
    fmt = si(1).fmt;
    for i = 2:nsig
        if si(i).adcres > maxres
            maxres = si(i).adcres;
        end
        if si(i).fmt ~= fmt
            fmt = 0;
        end
    end
    if fmt == 0
        if maxres > 24
            fmt = 32;
        elseif maxres > 16
            fmt = 24;
        elseif maxres > 12
            fmt = 16;
        elseif maxres > 10
            fmt = 212;
        elseif maxres > 8
            fmt = 310;
        else
            fmt = 80;
        end
    end
    opt.fmt = fmt;
end
ofname = [nrec '.dat'];
for k = 1:nsig
    si(k).fname = ofname;
    si(k).group = 0;
    si(k).fmt = opt.fmt;
    si(k).spf = 1;
end
if wfdbx.osigfopen(si, nsig) ~= nsig
    wfdbx.internal.cexit(2);
end
if wfdbx.isigsettime(from) < 0
    wfdbx.internal.cexit(2);
end
wfdbx.wfdbquiet();
CHUNK = 65536;
v = zeros(1, max(nsig, 1));
if to == 0
    % copy to the end
    while true
        x = wfdbx.getframes(CHUNK);
        wfdbx.putframes(x);
        if size(x, 1) < CHUNK
            break;
        end
    end
else
    % copy to - from vectors; the last one is written even if it could
    % not be read (as in C)
    remaining = to - from;
    failed = false;
    while remaining > 1
        k = min(CHUNK, remaining - 1);
        x = wfdbx.getframes(k);
        wfdbx.putframes(x);
        remaining = remaining - size(x, 1);
        if size(x, 1) < k
            failed = true;
            break;
        end
        v = x(end, :);
    end
    if ~failed && remaining == 1
        [stat, v] = wfdbx.getvec(v); %#ok<ASGLU>
        wfdbx.putvec(v);
    end
end
wfdbx.wfdbverbose();
wfdbx.setsampfreq(wfdbx.sampfreq([]));
if ischar(tstring)
    wfdbx.setbasetime(tstring);
end
wfdbx.newheader(nrec);
end

function copy_info(pname, irec, startp)
wfdbx.wfdbquiet();
info = wfdbx.getinfo(irec);
while ischar(info)
    wfdbx.putinfo(info);
    info = wfdbx.getinfo([]);
end
wfdbx.putinfo(sprintf('Produced by %s from record %s, beginning at %s', ...
    pname, irec, startp));
wfdbx.wfdbverbose();
end

function status = main(argv)
pname = argv{1};
argc = numel(argv);
opt = struct('pname', pname, 'fmt', 0, 'sflag', 0);
mflag = 0;
nrec = []; irec = []; startp = []; endp = []; len = [];
ann_first = 0;
nann = 0;
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
            case 'a'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: annotator(s) must follow -a\n', pname);
                    status = 1;
                    return;
                end
                % As in C, the count of annotators is not reset if -a is
                % given more than once, and the names are those that
                % follow the last -a (see "Undefined behaviors" in
                % docs/KNOWN_C_BEHAVIORS.md).
                ann_first = i;
                while true
                    nann = nann + 1;
                    i = i + 1;
                    if ~(i < argc && ~strncmp(argv{i + 1}, '-', 1))
                        break;
                    end
                end
                if i < argc
                    i = i - 1;
                end
            case 'f'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: time must follow -f\n', pname);
                    status = 1;
                    return;
                end
                startp = argv{i + 1};
            case 'h'
                help(pname);
                status = 0;
                return;
            case {'i', 'r'}
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: input record name must follow -i\n', pname);
                    status = 1;
                    return;
                end
                irec = argv{i + 1};
            case 'l'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: duration must follow -l\n', pname);
                    status = 1;
                    return;
                end
                len = argv{i + 1};
            case 'm'
                mflag = 1;
            case 'n'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: new record name must follow -n\n', pname);
                    status = 1;
                    return;
                end
                nrec = argv{i + 1};
            case 'O'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: output format must follow -O\n', pname);
                    status = 1;
                    return;
                end
                opt.fmt = wfdbx.internal.cint32(wfdbx.internal.strtol(argv{i + 1}));
            case 's'
                opt.sflag = 1;
            case 't'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: time must follow -t\n', pname);
                    status = 1;
                    return;
                end
                endp = argv{i + 1};
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
if ~ischar(irec) || ~ischar(nrec)
    help(pname);
    status = 1;
    return;
end
if ~ischar(startp)
    startp = '0';
end
if ~ischar(endp)
    endp = 'e';
end
if wfdbx.newheader(nrec) < 0
    wfdbx.internal.ceprintf('%s: can''t create output header\n', pname);
    status = 2;
    return;
end
nsig = wfdbx.isigopen(irec, 0);
if nsig < 0
    wfdbx.internal.ceprintf('%s: error reading input header\n', pname);
    status = 2;
    return;
end
% WFDB-x: the output header needs the sampling frequency (the C program
% assumed 250 Hz if the input header did not specify one).
if ~wfdbx.wfdbx_get_legacy() && wfdbx.sampfreq([]) <= 0  % (WFDB-x)
    wfdbx.internal.ceprintf( ...
        '%s: sampling frequency of record %s is not specified\n', pname, irec);
    wfdbx.wfdbquit();
    status = 2;
    return;
end
from = wfdbx.strtim(startp);
if from < 0
    from = -from;
end
if ischar(len)
    to = from + wfdbx.strtim(len);
else
    to = wfdbx.strtim(endp);
    if to < 0
        to = -to;
    end
end
endt = wfdbx.strtim('e');
if (endt > 0 && endt < from) || (to > 0 && to < from)
    wfdbx.internal.ceprintf('%s: improper interval selected\n', pname);
    wfdbx.wfdbquit();
    status = 1;
    return;
end
% (names beyond the last argument, which C reads past the end of argv, are
% ignored)
annotators = {};
if nann > 0
    annotators = argv(ann_first + 1:min(ann_first + nann - 1, argc - 1) + 1);
end
if ~isempty(annotators)
    copy_ann(pname, nrec, irec, from, to, annotators);
end
if nsig > 0
    opt = copy_sig(opt, nrec, irec, from, to, mflag);
end
if ~opt.sflag
    copy_info(pname, irec, startp);
end
wfdbx.wfdbquit();
status = 0;
end
