function status = sigamp(args)
%SIGAMP Measure signal amplitudes of a WFDB record.
%   STATUS = wfdbx.apps.sigamp(ARGS) runs the sigamp tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       sigamp -r RECORD [OPTIONS ...]
%   where OPTIONS may include:
%       -a ANN      measure peak-to-peak amplitudes near QRS annotations
%       -d DT1 DT2  measurement window relative to QRS annotations
%       -f TIME     begin at specified time
%       -h          print a usage summary
%       -H          read multifrequency signals in high resolution mode
%       -n NMAX     make up to NMAX measurements per signal (default: 300)
%       -p          print results in physical units (-pd, -pe, -ph, -pm,
%                   -ps, -pS choose the time format)
%       -q          quick mode: print individual measurements only
%       -t TIME     stop at specified time
%       -v          verbose mode: print measurements and trimmed means
%       -w DTW      RMS amplitude measurement window (default: 1 second)
%
%   WFDB-x: the record must specify its sampling frequency, and with -p
%   the gains of its signals (the C program assumed 250 Hz and 200
%   adu/mV); see docs/DIVERGENCES.md.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.sigamp({'-r', '100s', '-v'})
%
%   See also wfdbx.apps.rdsamp.
%
%   Translation of the C program sigamp (app/sigamp.c, WFDB 10.7.0): same
%   options and output. Differences: no sampling frequency or gain is
%   assumed; see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/sigamp.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in sampling frequency or gain: the record
% must give the sampling frequency (the measurement windows are in seconds),
% and with -p the gain of each signal (the original assumed 250 Hz and 200
% adu/mV); --legacy, as the first argument, restores the original behavior.
% Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the
% reasons.
%
% Original C program: app/sigamp.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1991-2009 George B. Moody; revised 2018 by Benjamin Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'sigamp'}, args]);
end

function help(pname)
h = {'where OPTIONS may include any of:', ...
    ' -a ANN      specify annotator, measure amplitudes near QRS annotations', ...
    ' -d DT1 DT2  set measurement window relative to QRS annotations', ...
    '              defaults: DT1 = 0.05 (seconds before annotation);', ...
    '              DT2 = 0.05 (seconds after annotation)', ...
    ' -f TIME     begin at specified time', ...
    ' -h          print this usage summary', ...
    ' -H          read multifrequency signals in high resolution mode', ...
    ' -n NMAX     make up to NMAX measurements per signal (default: NMAX = 300)', ...
    ' -p          print results in physical units (default: ADC units)', ...
    '              -p may be followed by a character to choose a time format:', ...
    '  -pd         print time of day and date if known', ...
    '  -pe         print elapsed time as <hours>:<minutes>:<seconds>', ...
    '  -ph         print elapsed time in hours', ...
    '  -pm         print elapsed time in minutes', ...
    '  -ps         print elapsed time in seconds (default)', ...
    '  -pS         print elapsed time in sample intervals', ...
    ' -q          quick mode: print individual measurements only', ...
    ' -t TIME     stop at specified time', ...
    ' -v          verbose mode: print individual measurements and trimmed means', ...
    ' -w DTW      set RMS amplitude measurement window', ...
    '              default: DTW = 1 (second)'};
wfdbx.internal.ceprintf('usage: %s -r RECORD [OPTIONS ...]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function status = main(argv)
NMAX = 300;   % the largest number of measurements (as in C)
SECONDS = 1; MINUTES = 2; HOURS = 3; TIMSTR = 4; HHMMSS = 7; SAMPLES = 8;
pname = argv{1};
argc = numel(argv);
ainame = [];
record = [];
dt1 = 0; dt2 = 0; dtw = 0;
from = 0; to = 0;
gvmode = 0;
nmax = NMAX;
pflag = 0; qflag = 0; vflag = 0;
timeunits = SECONDS;
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
                    wfdbx.internal.ceprintf('%s: annotator name must follow -a\n', pname);
                    status = 1;
                    return;
                end
                ainame = argv{i + 1};
            case 'd'
                i = i + 1;
                if i >= argc - 1
                    wfdbx.internal.ceprintf('%s: DT1 and DT2 must follow -d\n', pname);
                    status = 1;
                    return;
                end
                dt1 = i;
                i = i + 1;
            case 'f'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: start time must follow -f\n', pname);
                    status = 1;
                    return;
                end
                from = i;
            case 'h'
                help(pname);
                status = 0;
                return;
            case 'H'
                gvmode = 1;     % WFDB_HIGHRES
            case 'n'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: number of measurements must follow -n\n', pname);
                    status = 1;
                    return;
                end
                nmax = wfdbx.internal.atoi(argv{i + 1});
                if nmax < 1
                    nmax = NMAX;
                end
            case 'p'
                pflag = 1;
                if numel(a) >= 3
                    d = a(3);
                else
                    d = char(0);
                end
                switch d
                    case 'd'
                        timeunits = TIMSTR;
                    case 'e'
                        timeunits = HHMMSS;
                    case 'h'
                        timeunits = HOURS;
                    case 'm'
                        timeunits = MINUTES;
                    case 'S'
                        timeunits = SAMPLES;
                    otherwise
                        timeunits = SECONDS;
                end
            case 'q'
                qflag = 1;
            case 'r'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i + 1};
            case 't'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: stop time must follow -t\n', pname);
                    status = 1;
                    return;
                end
                to = i;
            case 'v'
                vflag = 1;
            case 'w'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: window size must follow -w\n', pname);
                    status = 1;
                    return;
                end
                dtw = i;
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
if gvmode == 0
    p = wfdbx.internal.cgetenv('WFDBGVMODE');
    if ischar(p)
        gvmode = wfdbx.internal.atoi(p);
    end
end
wfdbx.setgvmode(bitor(gvmode, 2));      % WFDB_GVPAD
nsig = wfdbx.isigopen(record, 0);
if nsig <= 0
    status = 2;
    return;
end
[n, si] = wfdbx.isigopen(record, nsig);
if n ~= nsig
    status = 2;
    return;
end
gain = [si.gain];
% WFDB-x: no default gain (the C program assumed 200 adu/mV for
% uncalibrated signals, as legacy mode does).
legacy = wfdbx.wfdbx_get_legacy();
k = find(gain == 0, 1);
if legacy
    gain(gain == 0) = 200;      % WFDB_DEFGAIN
elseif pflag && ~isempty(k)
    wfdbx.internal.ceprintf('%s: signal %d of record %s is uncalibrated\n', ...
        pname, k - 1, record);
    status = 2;
    return;
end
amp = zeros(nsig, nmax);
% WFDB-x: no default sampling frequency (the C program assumed 250 Hz); the
% measurement windows are defined in seconds.  Legacy mode: as in C.
sfreq = wfdbx.sampfreq([]);
if sfreq <= 0 && legacy
    sfreq = 250;            % WFDB_DEFFREQ
elseif sfreq <= 0
    wfdbx.internal.ceprintf( ...
        '%s: sampling frequency of record %s is not specified\n', pname, record);
    status = 2;
    return;
end
if timeunits == TIMSTR || timeunits == HHMMSS
    p = wfdbx.timstr(0);
    if ~strncmp(p, '[', 1)
        timeunits = HHMMSS;
    end
end
if timeunits == HOURS
    sfreq = sfreq * 3600;
elseif timeunits == MINUTES
    sfreq = sfreq * 60;
end
if from > 0
    from = wfdbx.strtim(argv{from + 1});
end
if to > 0
    to = wfdbx.strtim(argv{to + 1});
end
if from < 0
    from = -from;
end
if to < 0
    to = -to;
end
if from >= to
    to = wfdbx.strtim('e');
end
namp = 0;
csp = @wfdbx.internal.csprintf;
out = @wfdbx.internal.cout;

    function printamp(t)
        switch timeunits
            case TIMSTR
                s = wfdbx.mstimstr(-t);
            case HHMMSS
                s = wfdbx.mstimstr(t);
            case SAMPLES
                s = sprintf('%d', t);
            otherwise
                s = csp('%f', t / sfreq);
        end
        x = amp(:, namp + 1).';
        if pflag
            x = x ./ gain;
        end
        x = num2cell(x);
        out([s, csp(repmat('\t%g', 1, nsig), x{:}), char(10)]);
    end

if ischar(ainame)
    if dtw > 0
        wfdbx.internal.ceprintf('%s: -a and -w options cannot be used together;\n', pname);
        wfdbx.internal.ceprintf('  -w option is being ignored\n');
    end
    if wfdbx.annopen(record, wfdbx.anninfo(ainame, 0), 1) < 0     % WFDB_READ
        status = 2;
        return;
    end
    if dt1 == 0
        dt2 = wfdbx.strtim('0.05');
        dt1 = -dt2;
    else
        p = argv{dt1 + 2};
        if strncmp(p, '-', 1)
            dt2 = -wfdbx.strtim(p(2:end));
        else
            dt2 = wfdbx.strtim(p);
        end
        p = argv{dt1 + 1};
        if strncmp(p, '-', 1)
            dt1 = wfdbx.strtim(p(2:end));
        else
            dt1 = -wfdbx.strtim(p);
        end
        if dt1 > dt2
            tmp = dt1;
            dt1 = dt2;
            dt2 = tmp;
        end
    end
    if dt1 == dt2
        dt2 = dt2 + 1;
    end
    if wfdbx.iannsettime(from) < 0
        status = 2;
        return;
    end
    NORMAL = wfdbx.NORMAL();
    annot = wfdbx.annotation();
    while namp < nmax
        [st, annot] = wfdbx.getann(0, annot);
        if st ~= 0 || ~(to == 0 || annot.time < to)
            break;
        end
        if wfdbx.map1(annot.anntyp) == NORMAL
            % getptp(): one vector at t + dt1, then dt2 - dt1 more
            t = annot.time;
            if wfdbx.isigsettime(t + dt1) < 0
                break;
            end
            m = 1 + max(dt2 - dt1, 0);
            [v, st] = wfdbx.getframes(m, nsig);
            if size(v, 1) < m || st < nsig
                break;
            end
            % (an int in C)
            amp(:, namp + 1) = wfdbx.internal.cint32( ...
                max(v, [], 1) - min(v, [], 1)).';
            if vflag || qflag
                printamp(t);
            end
            namp = namp + 1;
        end
    end
else
    if dt1 > 0
        wfdbx.internal.ceprintf('%s: -d option must be used with -a;\n', pname);
        wfdbx.internal.ceprintf('  -d option is being ignored\n');
    end
    if dtw ~= 0
        dtw = wfdbx.strtim(argv{dtw + 1});
    end
    if dtw <= 0
        dtw = wfdbx.strtim('1');
    end
    if from > 0 && wfdbx.isigsettime(from) < 0
        status = 2;
        return;
    end
    t = from;
    m = max(dtw, 1);
    while namp < nmax && (to == 0 || t < to)
        % getrms(): the mean of dtw vectors, then the RMS difference
        [v, st] = wfdbx.getframes(m, nsig);
        if size(v, 1) < m || st < nsig
            break;
        end
        v0 = v(1, :);
        vmean = sum(v, 1);         % (exact: sums of integers)
        if wfdbx.isigsettime(t) < 0
            break;
        end
        [v, st] = wfdbx.getframes(m, nsig);
        if size(v, 1) < m || st < nsig
            break;
        end
        vmean = vmean / dtw + v(1, :) - v0;
        d = wfdbx.internal.d2i(v - vmean);
        d = d .* d;
        if max(d(:)) * m < 2^53
            vsum = sum(d, 1);       % exact
        else
            vsum = zeros(1, nsig);
            for j = 1:m
                vsum = vsum + d(j, :);
            end
        end
        amp(:, namp + 1) = sqrt(vsum / dtw).';
        if vflag || qflag
            printamp(t);
        end
        namp = namp + 1;
        t = t + dtw;
    end
end
if qflag == 0
    jlow = floor(namp / 20);   % trimmed mean: drop 5% at each end
    jhigh = namp - jlow;
    s = '';
    if vflag
        s = 'Trimmed mean';
    end
    for k = 1:nsig
        vals = sort(amp(k, 1:namp));
        a = 0;
        for j = jlow + 1:jhigh
            a = a + vals(j);
        end
        if jhigh - jlow == 0
            a = -NaN;       % 0.0/0.0 yields a negative NaN on x86
        else
            a = a / (jhigh - jlow);
        end
        if pflag
            a = a / gain(k);
        end
        s = [s, csp('\t%g', a)]; %#ok<AGROW>
    end
    out([s, char(10)]);
end
status = 0;
end
