function status = rdedfann(args)
%RDEDFANN Print the annotations of an EDF+ record as text for wrann.
%   STATUS = wfdbx.apps.rdedfann(ARGS) runs the rdedfann tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       rdedfann -r RECORD [OPTIONS ...]
%   where RECORD is an EDF+ record, and OPTIONS may include:
%       -F FREQ     set the sampling frequency to FREQ Hz
%       -h          print a usage summary
%       -v          print column headings
%       -x          print EDF+ annotation text in aux (default: in anntyp)
%
%   Example (rec.edf stands for an EDF+ file with annotations in the current
%   folder):
%       wfdbx.apps.rdedfann({'-r', 'rec.edf'})
%
%   See also wfdbx.apps.edf2mit, wfdbx.apps.wrann.
%
%   Translation of the C program rdedfann (convert/rdedfann.c, WFDB 10.7.0):
%   same options and output.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of convert/rdedfann.c from the WFDB
% Software Package 10.7.0, by George B. Moody. The translation follows the
% logic and behavior of the original program, but it is new code, not the
% original C code.
%
% Changes from the original: none, apart from the language and the --legacy
% option (as the first argument, it restores the original behavior).
%
% Original C program: convert/rdedfann.c, WFDB Software Package 10.7.0.
%   Copyright (C) 2008-2014 George B. Moody; bug fix and -x option contributed
%   by Luca Citi, 2014.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'rdedfann'}, args]);
end

function help(pname)
h = {'where RECORD is the name of the input EDF+ record, and OPTIONS may include:', ...
    sprintf(' -F FREQ     set the sampling frequency to FREQ Hz\n'), ...
    ' -h          print this usage summary', ...
    ' -v          print column headings', ...
    ' -x          print EDF+ annotation text in aux (default: print in anntyp)'};
wfdbx.internal.ceprintf('usage: %s -r RECORD [OPTIONS ...]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function s = cstr(b)
k = find(b == 0, 1);
if isempty(k)
    s = char(b);
else
    s = char(b(1:k - 1));
end
end

function status = main(argv)
pname = argv{1};
argc = numel(argv);
record = [];
sfreq = 0;
vflag = 0;
xflag = 0;
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
            case 'F'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: sampling frequency must follow -F\n', pname);
                    status = 1;
                    return;
                end
                [n, v] = wfdbx.internal.csscanf(argv{i + 1}, '%lf');
                if n == 1
                    sfreq = v{1};
                end
                if sfreq <= 0
                    sfreq = 1;
                end
            case 'h'
                help(pname);
                status = 0;
                return;
            case 'r'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i + 1};
            case 'v'
                vflag = 1;
            case 'x'
                xflag = 1;
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
if ~ischar(record)
    help(pname);
    status = 1;
    return;
end
wfdbx.setgvmode(1);     % WFDB_HIGHRES
nsig = wfdbx.isigopen(record, 0);
if nsig <= 0
    status = 2;
    return;
end
[nsig, si] = wfdbx.isigopen(record, nsig);
if nsig <= 0
    status = 2;
    return;
end
aindex = 0;
alen = 0;
framelen = 0;
for k = 1:nsig
    if strcmp(si(k).desc, 'EDF Annotations')
        aindex = framelen;
        alen = si(k).spf;
    end
    framelen = framelen + si(k).spf;
end
if alen == 0
    wfdbx.internal.ceprintf('%s: record %s has no EDF annotations\n', pname, record);
    wfdbx.wfdbquit();
    status = 3;
    return;
end
frame = zeros(1, framelen);
if sfreq > 0
    wfdbx.setgvmode(0);     % WFDB_LOWRES
    wfdbx.setsampfreq(sfreq);
else
    sfreq = wfdbx.sampfreq([]);
end
if vflag
    wfdbx.internal.cout(sprintf('      Time   Sample #  Type  Sub Chan  Num\tAux\n'));
end
% the state of the TAL parser (static buffers of the C program)
state = 0;
onset = zeros(1, 1024);
duration = zeros(1, 1024);
text = zeros(1, 1024);
op = 0; dp = 0; tp = 0;
while true
    [stat, frame] = wfdbx.getframe(frame);
    if stat <= 0
        break;
    end
    % Parse the TALs (time-stamped annotation lists) of EDF+: '+onset',
    % optionally char(21) and a duration, char(20), texts each ended by
    % char(20), and a null byte.
    state = 0;
    xs = frame(aindex + 1:aindex + alen);
    for k = 1:alen
        xk = xs(k);
        if ~(xk || state)
            break;
        end
        bytes = [mod(xk, 256), mod(floor(xk / 256), 256)];
        for q = 1:2
            x = bytes(q);
            switch state
                case 0
                    if x == 0
                        continue;
                    end
                    if x ~= '+'
                        wfdbx.internal.ceprintf('%s: unexpected character ''%c'' in input\n', ...
                            pname, char(x));
                    else
                        state = 1;
                        op = 0; dp = 0; tp = 0;
                        text(1) = 0;
                    end
                case 1
                    if x == 21
                        x = 0;
                        state = 2;
                    elseif x == 20
                        x = 0;
                        state = 3;
                    end
                    op = op + 1;
                    onset(op) = x;
                case 2
                    if x == 20
                        x = 0;
                        state = 3;
                    end
                    dp = dp + 1;
                    duration(dp) = x;
                case 3
                    if x == 20
                        x = 0;
                        state = 4;
                    end
                    tp = tp + 1;
                    text(tp) = x;
                case 4
                    if text(1)
                        t = fix(wfdbx.internal.atof(cstr(onset)) * sfreq + 0.5);
                        txt = cstr(text);
                        txt(txt == ' ' | txt == char(9)) = '_';
                        text(1:numel(txt)) = double(txt);
                        if t
                            ts = wfdbx.mstimstr(t);
                        else
                            ts = '    0:00.000';
                        end
                        if xflag
                            a1 = '"';
                            a2 = txt;
                        else
                            a1 = txt;
                            a2 = '';
                        end
                        s = sprintf('%s  %7d %5s%5d%5d%5d\t%s', ts, t, a1, 0, 0, 0, a2);
                        if duration(1)
                            if xflag
                                sep = ' ';
                            else
                                sep = char(9);
                            end
                            s = [s sep 'duration: ' cstr(duration)]; %#ok<AGROW>
                        end
                        wfdbx.internal.cout([s char(10)]);
                    end
                    if x
                        text(1) = x;
                        tp = 1;
                        state = 3;
                    else
                        state = 0;
                    end
            end
        end
    end
end
wfdbx.wfdbquit();
status = 0;
end
