function status = rdsamp(args)
%RDSAMP Print samples of the signals of a WFDB record.
%   STATUS = wfdbx.apps.rdsamp(ARGS) runs the rdsamp tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       rdsamp -r RECORD [OPTIONS ...]
%   where OPTIONS may include:
%       -c          use CSV (comma-separated value) output format
%       -f TIME     begin at specified time
%       -h          print a usage summary
%       -H          read multifrequency signals in high resolution mode
%       -l INTERVAL truncate output after the specified time interval
%       -p          print times and samples in physical units
%       -P          same as -p, but with greater precision
%                   (-pd, -pe, -ph, -pm, -ps, -pS choose the time format)
%       -s SIGNAL [SIGNAL ...]  print only the specified signal(s)
%       -S SIGNAL   begin at the first valid sample of SIGNAL
%       -t TIME     stop at specified time
%       -v          print column headings
%       -X          output in WFDB-XML format
%
%   WFDB-x: no sampling frequency or gain is assumed (C: 250 Hz, 200
%   adu/mV).  The sampling frequency is needed for time arguments (other
%   than sample numbers 'sN'), time columns and -X, and the gains of the
%   selected signals for -p/-P.  Unspecified units are shown as "nd" in
%   the column headings (C: "mV"); see docs/DIVERGENCES.md.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.rdsamp({'-r', '100s', '-t', 's10'})
%
%   See also wfdbx.apps.wrsamp, wfdbx.apps.wfdbdesc, wfdbx.read_record.
%
%   Translation of the C program rdsamp (app/rdsamp.c, WFDB 10.7.0): same
%   options and output. Differences: no sampling frequency or gain is
%   assumed; see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/rdsamp.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in sampling frequency or gain: the
% sampling frequency is required for time arguments, time columns and XML
% output (-X), and the gain of each selected signal for physical units (-p, -P)
% (the original assumed 250 Hz and 200 adu/mV); unspecified units are shown as
% "nd" (the original showed "mV"); --legacy, as the first argument, restores
% the original behavior. Each change is marked "WFDB-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
%
% Original C program: app/rdsamp.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1983-2010 George B. Moody; revised 2017-2020 by
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
status = wfdbx.internal.app_run(@main, [{'rdsamp'}, args]);
end

function help(pname)
h = {' -c          use CSV (comma-separated value) output format', ...
    ' -f TIME     begin at specified time', ...
    ' -h          print this usage summary', ...
    ' -H          read multifrequency signals in high resolution mode', ...
    ' -l INTERVAL truncate output after the specified time interval (hh:mm:ss)', ...
    ' -p          print times and samples in physical units (default: raw units)', ...
    ' -P          same as -p, but with greater precision', ...
    '              -p and -P may be followed by a character to choose a time', ...
    '              format;  choices are:', ...
    '  -pd (or -Pd)  print time of day and date if known', ...
    '  -pe (or -Pe)  print elapsed time as <hours>:<minutes>:<seconds>', ...
    '  -ph (or -Ph)  print elapsed time in hours', ...
    '  -pm (or -Pm)  print elapsed time in minutes', ...
    '  -ps (or -Ps)  print elapsed time in seconds', ...
    '  -pS (or -PS)  print elapsed time in sample intervals', ...
    ' -s SIGNAL [SIGNAL ...]  print only the specified signal(s)', ...
    ' -S SIGNAL   search for a valid sample of the specified SIGNAL at or after', ...
    [char(9) char(9) 'the time specified with -f, and begin printing then'], ...
    ' -t TIME     stop at specified time', ...
    ' -v          print column headings', ...
    ' -X          output in WFDB-XML format'};
wfdbx.internal.ceprintf('usage: %s -r RECORD [OPTIONS ...]\n', pname);
wfdbx.internal.ceprintf('where RECORD is the name of the input record, and OPTIONS may include:\n');
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function s = escapify(s)
% Escape quotes and backslashes (see docs/KNOWN_C_BEHAVIORS.md).
s = strrep(strrep(s, '\', '\\'), '''', '\''');
end

function status = main(argv)
SECONDS = 1; MINUTES = 2; HOURS = 3; TIMSTR = 4; MSTIMSTR = 5;
SHORTTIMSTR = 6; HHMMSS = 7; SAMPLES = 8;
CHUNK = 65536;
pname = argv{1};
argc = numel(argv);
record = [];
search = [];
cflag = 0; highres = 0; pflag = 0; vflag = 0; xflag = 0;
nosig = 0;
isiglist = 0;
timeunits = SECONDS;
from_i = 0; maxl_i = 0; to_i = 0;
i = 1;
while i < argc
    a = argv{i + 1};
    if ~isempty(a) && a(1) == '-'
        if numel(a) >= 2
            c = a(2);
        else
            c = char(0);
        end
        switch c
            case 'c'
                cflag = 1;
            case 'f'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: time must follow -f\n', pname);
                    status = 1;
                    return;
                end
                from_i = i;
            case 'h'
                help(pname);
                status = 0;
                return;
            case 'H'
                highres = 1;
            case 'l'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: max output length must follow -l\n', pname);
                    status = 1;
                    return;
                end
                maxl_i = i;
            case {'P', 'p'}
                if c == 'P'
                    pflag = pflag + 2;
                else
                    pflag = pflag + 1;
                end
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
            case 'r'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i + 1};
            case 's'
                isiglist = i + 1;
                while i + 1 < argc && ~strncmp(argv{i + 2}, '-', 1)
                    i = i + 1;
                    nosig = nosig + 1;
                end
                if nosig == 0
                    wfdbx.internal.ceprintf('%s: signal list must follow -s\n', pname);
                    status = 1;
                    return;
                end
            case 'S'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf( ...
                        '%s: signal name or number must follow -S\n', pname);
                    status = 1;
                    return;
                end
                search = argv{i + 1};
            case 't'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: time must follow -t\n', pname);
                    status = 1;
                    return;
                end
                to_i = i;
            case 'v'
                vflag = 1;
            case 'X'
                xflag = 1;
                cflag = 1;
                vflag = 1;
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
legacy = wfdbx.wfdbx_get_legacy();
if legacy       % WFDB-x: legacy mode: the C program's default gain
    for k = 1:nsig
        if si(k).gain == 0
            si(k).gain = 200;     % WFDB_DEFGAIN
        end
    end
end
if highres
    wfdbx.setgvmode(1);   % WFDB_HIGHRES
end
freq = wfdbx.sampfreq([]);
% WFDB-x: no default sampling frequency (the C program assumed 250 Hz if
% the header did not specify one, as legacy mode does).
if ~legacy && freq <= 0 && ...
        ((from_i > 0 && wfdbx.wfdbx_time_needs_freq(argv{from_i + 1})) || ...
        (to_i > 0 && wfdbx.wfdbx_time_needs_freq(argv{to_i + 1})) || ...
        (maxl_i > 0 && wfdbx.wfdbx_time_needs_freq(argv{maxl_i + 1})) || ...
        xflag || (pflag && (timeunits ~= SAMPLES || vflag)))
    wfdbx.internal.ceprintf( ...
        '%s: sampling frequency of record %s is not specified\n', pname, record);
    status = 2;
    return;
end
from = 0;
if from_i > 0
    from = wfdbx.strtim(argv{from_i + 1});
    if from < 0
        from = -from;
    end
end
if wfdbx.isigsettime(from) < 0
    status = 2;
    return;
end
to = 0;
if to_i > 0
    to = wfdbx.strtim(argv{to_i + 1});
    if to < 0
        to = -to;
    end
end
if nosig
    sig = zeros(1, nosig);
    for k = 1:nosig
        s = wfdbx.findsig(argv{isiglist + k});
        if s < 0
            wfdbx.internal.ceprintf('%s: can''t read signal ''%s''\n', pname, ...
                argv{isiglist + k});
            status = 2;
            return;
        end
        sig(k) = s;
    end
    nsig = nosig;
else
    sig = 0:nsig - 1;
end
% WFDB-x: no default gain (the C program assumed 200 adu/mV for
% uncalibrated signals).
if pflag && ~legacy
    for k = 1:nsig
        if si(sig(k) + 1).gain == 0
            wfdbx.internal.ceprintf( ...
                '%s: signal %d of record %s is uncalibrated\n', pname, ...
                sig(k), record);
            status = 2;
            return;
        end
    end
end
if ischar(search)
    s = wfdbx.findsig(search);
    if s >= 0
        from = wfdbx.tnextvec(s, from);
    end
    if s < 0 || from < 0
        wfdbx.internal.ceprintf('%s: can''t read signal ''%s''\n', pname, search);
        status = 2;
        return;
    end
end
maxl = 0;
if maxl_i > 0
    maxl = wfdbx.strtim(argv{maxl_i + 1});
    if maxl < 0
        maxl = -maxl;
    end
end
if maxl && (to == 0 || to > from + maxl)
    to = from + maxl;
end
if timeunits == TIMSTR
    p = wfdbx.timstr(0);
    if isempty(p) || p(1) ~= '['
        timeunits = HHMMSS;
    elseif numel(p) < 16
        timeunits = SHORTTIMSTR;
    elseif freq > 1
        timeunits = MSTIMSTR;
    end
end
if timeunits == HOURS
    freq = freq * 3600;
elseif timeunits == MINUTES
    freq = freq * 60;
end
csp = @wfdbx.internal.csprintf;
tufmt = ''; tnfmt = ''; tfmt = ''; vfmt = ''; invalid = ''; snfmt = '';
if cflag
    snfmt = ',''%s''';
    if pflag
        switch timeunits
            case SAMPLES
                tnfmt = '''sample interval''';
                tufmt = csp('''%g sec''', 1 / freq);
            case SHORTTIMSTR
                tnfmt = '''Time'''; tufmt = '''hh:mm:ss.mmm''';
            case TIMSTR
                tnfmt = '''Time and date'''; tufmt = '''hh:mm:ss dd/mm/yyyy''';
            case MSTIMSTR
                tnfmt = '''Time and date'''; tufmt = '''hh:mm:ss.mmm dd/mm/yyyy''';
            case HHMMSS
                tnfmt = '''Elapsed time'''; tufmt = '''hh:mm:ss.mmm''';
            case HOURS
                tnfmt = '''Elapsed time'''; tufmt = '''hours''';
            case MINUTES
                tnfmt = '''Elapsed time'''; tufmt = '''minutes''';
            otherwise
                tnfmt = '''Elapsed time'''; tufmt = '''seconds''';
        end
        invalid = ',-';
        if pflag > 1
            vfmt = ',%.8f';
        else
            vfmt = ',%.3f';
        end
    else
        tnfmt = '''sample #''';
        tfmt = '%d';
        vfmt = ',%d';
    end
else
    if pflag
        switch timeunits
            case SAMPLES
                tnfmt = 'sample interval';
                speriod = csp('(%g', 1 / freq);
                speriod = speriod(1:min(end, 10));
                tufmt = sprintf('%10s sec)', speriod);
            case SHORTTIMSTR
                tnfmt = '     Time'; tufmt = '(hh:mm:ss.mmm)';
            case TIMSTR
                tnfmt = '   Time      Date    '; tufmt = '(hh:mm:ss dd/mm/yyyy)';
            case MSTIMSTR
                tnfmt = '      Time      Date    '; tufmt = '(hh:mm:ss.mmm dd/mm/yyyy)';
            case HHMMSS
                tnfmt = '   Elapsed time'; tufmt = '   hh:mm:ss.mmm';
            case HOURS
                tnfmt = '   Elapsed time'; tufmt = '        (hours)';
            case MINUTES
                tnfmt = '   Elapsed time'; tufmt = '      (minutes)';
            otherwise
                tnfmt = '   Elapsed time'; tufmt = '      (seconds)';
        end
        if pflag > 1
            snfmt = '\t%15s';
            invalid = [char(9) '              -'];
            vfmt = '\t%15.8f';
        else
            snfmt = '\t%7s';
            invalid = [char(9) '      -'];
            vfmt = '\t%7.3f';
        end
    else
        snfmt = '\t%7s';
        tnfmt = '       sample #';
        tfmt = '%15d';
        vfmt = '\t%7d';
    end
end
out = @wfdbx.internal.cout;
if xflag
    out(['<?xml version="1.0" encoding="UTF-8"?>' char(10) ...
        '<?xml-stylesheet type="text/xsl" href="wfdb.xsl"?>' char(10) ...
        '<!DOCTYPE wfdbsampleset PUBLIC "-//PhysioNet//DTD WFDB 1.0//EN"' ...
        ' "http://physionet.org/physiobank/database/XML/wfdb.dtd">' char(10)]);
    out([sprintf('<wfdbsampleset>\n<samplingfrequency>') csp('%g', freq) ...
        sprintf('</samplingfrequency>\n<signals>%d</signals>\n<description>', nsig)]);
end
if vflag
    out(tnfmt);
    for k = 1:nsig
        p = si(sig(k) + 1).desc;
        if ~isempty(strfind(p, ', signal '))
            p = sprintf('sig %d', sig(k));
        end
        if cflag == 0
            ln = numel(p);
            if pflag > 1
                if ln > 15
                    p = p(ln - 14:end);
                end
            elseif ln > 7
                p = p(ln - 6:end);
            end
        else
            p = escapify(p);
        end
        out(sprintf(snfmt, p));
    end
    if xflag
        out('</description>');
    end
    out(char(10));
end
if pflag
    if vflag
        if xflag
            out('<units>');
        end
        out(tufmt);
        for k = 1:nsig
            p = si(sig(k) + 1).units;
            if ~ischar(p)   % WFDB-x: unspecified units are shown as "nd"
                if legacy   % (C, legacy mode: mV)
                    p = 'mV';
                else
                    p = 'nd';
                end
            end
            if cflag == 0
                ln = numel(p);
                if pflag > 1
                    ln = min(ln, 13);
                    out(sprintf('\t%14s)', ['(' p(1:ln)]));
                else
                    ln = min(ln, 5);
                    out(sprintf('\t%6s)', ['(' p(1:ln)]));
                end
            else
                out([',''' escapify(p) '''']);
            end
        end
        if xflag
            out('</units>');
        end
        out(char(10));
    end
    if xflag
        out(sprintf('<samplevectors>\n'));
    end
    base = [si(sig + 1).baseline];
    gain = [si(sig + 1).gain];
    tsf = 0;
    if cflag == 0
        switch timeunits
            case {TIMSTR, SHORTTIMSTR, MSTIMSTR, HHMMSS}
                tsf = timeunits;
            case SAMPLES
                tfmt = '%15d';
            case MINUTES
                tfmt = '%15.5f';
            case HOURS
                tfmt = '%15.7f';
            otherwise
                tfmt = '%15.3f';
        end
    else
        switch timeunits
            case {TIMSTR, SHORTTIMSTR, MSTIMSTR, HHMMSS}
                tsf = timeunits;
            case SAMPLES
                tfmt = '%d';
            case MINUTES
                tfmt = '%.5f';
            case HOURS
                tfmt = '%.7f';
            otherwise
                tfmt = '%.3f';
        end
    end
    nanstr = sprintf(vfmt, NaN);
    if tsf == 0
        [lpre, lwidth, lprec] = line_spec(tfmt, vfmt, nsig);
    end
    while to == 0 || from < to
        if to == 0
            k = CHUNK;
        else
            k = min(CHUNK, to - from);
        end
        arr = wfdbx.getframes(k);
        m = size(arr, 1);
        if m
            sel = arr(:, sig + 1);
            phys = (sel - repmat(base, m, 1)) ./ repmat(gain, m, 1);
            inv = sel == -32768;
            phys(inv) = NaN;
            % -0.0 prints as in C; keep the sign of zero
            if tsf == 0
                if timeunits == SAMPLES
                    tv = (from:from + m - 1)';
                else
                    tv = (from:from + m - 1)' / freq;
                end
                txt = wfdbx.internal.format_rows([tv phys], lpre, lwidth, ...
                    lprec, [false(m, 1) inv]);
                if ischar(txt)
                    out(txt);
                    from = from + m;
                    if m < k
                        break;
                    end
                    continue;
                end
                txt = sprintf([tfmt repmat(vfmt, 1, nsig) '\n'], [tv phys]');
            else
                tcol = cell(m, 1);
                for r = 1:m
                    tcol{r} = timestring(tsf, from + r - 1, cflag, TIMSTR, HHMMSS);
                end
                c = [tcol num2cell(phys)]';
                txt = sprintf(['%s' repmat(vfmt, 1, nsig) '\n'], c{:});
            end
            if any(inv(:))
                txt = strrep(txt, nanstr, invalid);
            end
            out(txt);
            from = from + m;
        end
        if m < k
            break;
        end
    end
else
    if xflag
        out(sprintf('<samplevectors>\n'));
    end
    lfmt = [tfmt repmat(vfmt, 1, nsig) '\n'];
    [lpre, lwidth, lprec] = line_spec(tfmt, vfmt, nsig);
    while to == 0 || from < to
        if to == 0
            k = CHUNK;
        else
            k = min(CHUNK, to - from);
        end
        arr = wfdbx.getframes(k);
        m = size(arr, 1);
        if m
            v = [(from:from + m - 1)' arr(:, sig + 1)];
            txt = wfdbx.internal.format_rows(v, lpre, lwidth, lprec);
            if ~ischar(txt)
                txt = sprintf(lfmt, v');
            end
            out(txt);
            from = from + m;
        end
        if m < k
            break;
        end
    end
end
if xflag
    out(sprintf('</samplevectors>\n</wfdbsampleset>\n'));
end
wfdbx.wfdbquit();
status = 0;
end

function [pre, width, prec] = line_spec(tfmt, vfmt, nsig)
% The text, width and precision of each conversion of the line format
% (wfdbx.internal.format_rows); the time format is a single conversion
% (%Wd, %W.Pf), the value format text and a conversion.
fmts = [{tfmt}, repmat({vfmt}, 1, nsig)];
pre = cell(1, nsig + 1);
width = zeros(1, nsig + 1);
prec = zeros(1, nsig + 1);
for k = 1:nsig + 1
    f = fmts{k};
    j = find(f == '%', 1);
    pre{k} = sprintf(f(1:j - 1));
    c = f(j + 1:end - 1);        % width, then a point and the precision
    d = find(c == '.', 1);
    if isempty(d)
        d = numel(c) + 1;
    end
    width(k) = str2double(['0' c(1:d - 1)]);
    if f(end) == 'd'
        prec(k) = -1;
    else
        prec(k) = str2double(c(d + 1:end));
    end
end
end

function s = timestring(kind, t, cflag, TIMSTR, HHMMSS)
% The time column for the time-of-day and elapsed-time formats.
if kind == TIMSTR
    s = wfdbx.timstr(-t);
elseif kind == HHMMSS
    if t == 0
        s = '0:00.000';
    else
        s = wfdbx.mstimstr(t);
    end
else
    s = wfdbx.mstimstr(-t);
end
if cflag
    k = find(s ~= ' ', 1);
    if isempty(k)
        s = '''''';
    else
        s = ['''' s(k:end) ''''];
    end
elseif kind == HHMMSS
    s = sprintf('%15s', s);
end
end
