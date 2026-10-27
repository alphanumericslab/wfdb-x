function status = wrsamp(args)
%WRSAMP Write WFDB signal (and header) files from a text file of samples.
%   STATUS = wfdbx.apps.wrsamp(ARGS) runs the wrsamp tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       wrsamp [OPTIONS ...] [COLUMN ...]
%   where COLUMN selects a field to be copied (leftmost field is column
%   0), and OPTIONS may include:
%       -c          check that each input line has the same number of fields
%       -d          add dither to the input
%       -f N        start copying with line N (default: 0)
%       -F FREQ     sampling frequency for the header (required with -o)
%       -G GAIN     gain(s) for the header (required with -o; 0 means
%                   uncalibrated)
%       -h          print a usage summary
%       -i FILE     read input from FILE (default: standard input)
%       -o RECORD   save output in RECORD.dat, and write RECORD.hea
%       -O FORMAT   output format (default: 16)
%       -r RSEP     input line separator (default: linefeed)
%       -R BITS     ADC resolution(s) in bits (required with -o)
%       -s FSEP     input field separators (default: space, tab, CR, comma)
%       -t N        stop copying at line N
%       -U UNITS    units (required with -o for calibrated signals, unless
%                   the input gives them)
%       -x SCALE    multiply inputs by SCALE factor(s) (default: 1)
%       -z          don't copy column 0 unless explicitly specified
%
%   -G, -R and -U take a quoted list of values, one per output signal
%   (the last one applies to the remaining signals).
%
%   wfdb-x: -F, -G and -R are required with -o, and -U for calibrated
%   signals unless the input gives their units (the C program assumed
%   250 Hz, 200 adu/mV, a resolution based on the format, and
%   millivolts); see docs/DIVERGENCES.md.  To reproduce the C program's
%   output, use -F 250 -G 200 -R 16 -U mV (for format 16).
%
%   Example (data.txt stands for a text file of samples in the current
%   folder; the example writes the record rec there):
%       wfdbx.apps.wrsamp({'-i', 'data.txt', '-o', 'rec', '-F', '360', ...
%           '-G', '200', '-R', '16', '-U', 'mV'})
%
%   See also wfdbx.apps.rdsamp, wfdbx.write_record.
%
%   Translation of the C program wrsamp (app/wrsamp.c, WFDB 10.7.0): same
%   options and output. Differences: -R and -U are new, and the signal
%   parameters are required with -o; see docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/wrsamp.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in sampling frequency, gain, ADC
% resolution or units: when a record is written (-o), -F, -G and the new option
% -R BITS are required, and the new option -U UNITS for calibrated signals
% unless the input gives the units (the original assumed 250 Hz, 200 adu/mV, a
% resolution based on the format, and millivolts); -G 0 declares the signals
% uncalibrated; -G, -R and -U take one value per signal; --legacy, as the first
% argument, restores the original behavior. Each change is marked "wfdb-x:" in
% the code; docs/DIVERGENCES.md gives the reasons.
%
% Original C program: app/wrsamp.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1993-2014 George B. Moody; revised 2020 by Benjamin Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'wrsamp'}, args]);
end

function help(pname)
h = {'where COLUMN selects a field to be copied (leftmost field is column 0),', ...
    'and OPTIONS may include:', ...
    ' -c          check that each input line contains the same number of fields', ...
    ' -d          add dither to the input', ...
    ' -f N        start copying with line N (default: 0)', ...
    ' -F FREQ     specify frequency to be written to header file (required', ...
    '              with -o)', ...
    ' -G GAIN     specify gain(s) to be written to header file (required with', ...
    '              -o; 0 means uncalibrated)', ...
    ' -h          print this usage summary', ...
    ' -i FILE     read input from FILE (default: standard input)', ...
    ' -o RECORD   save output in RECORD.dat, and generate a header file for', ...
    '              RECORD (default: write to standard output in format 16, do', ...
    '              not generate a header file)', ...
    ' -O FORMAT   save output in the specified FORMAT (default: 16)', ...
    ' -r RSEP     interpret RSEP as the input line separator (default: linefeed)', ...
    ' -R BITS     specify ADC resolution(s) in bits (required with -o)', ...
    ' -s FSEP     interpret any character in FSEP as an input field separator', ...
    '             (default: space, tab, carriage-return, or comma)  ', ...
    ' -t N        stop copying at line N (default: end of input file)', ...
    ' -U UNITS    specify units (required with -o for calibrated signals, unless', ...
    '              the input gives them)', ...
    ' -x SCALE    multiply inputs by SCALE factor(s) (default: 1)', ...
    ' -z          don''t copy column 0 unless explicitly specified', ...
    '', ...
    'The input is a text file with a sample of each signal on each line. Samples', ...
    'can be separated by tabs, spaces, commas, or any combination of these.', ...
    'Consecutive separators are equivalent to single separators.', ...
    '', ...
    'To specify different GAIN or SCALE values for each output signal, provide', ...
    'a quoted list of values, e.g., -G "100 50" defines the gain for signal 0', ...
    'as 100, and the gain for signal 1 (and any additional signals) as 50.', ...
    '', ...
    'If the first input line contains any alphabetic characters, it is assumed', ...
    'to contain column headings, which are copied as signal descriptions into', ...
    'RECORD.hea.  If the second input line also contains alphabetic characters,', ...
    'it is assumed to specify the physical units for each column, which are', ...
    'copied as units strings into RECORD.hea.  The first line containing samples', ...
    'is line 0.', ...
    '', ...
    'If no COLUMN is specified, all fields are copied in order; column 0 can be', ...
    'omitted in this case by using the ''-z'' option.'};
if wfdbx.wfdbx_get_legacy()  % wfdb-x: legacy mode: the original help text
    h([17 21 22]) = [];         % (without -R and -U)
    h = [h(1:5), ...
        {' -F FREQ     specify frequency to be written to header file (default: 250)', ...
        ' -G GAIN     specify gain(s) to be written to header file (default: 200)'}, ...
        h(10:end)];
end
wfdbx.internal.ceprintf('usage: %s [OPTIONS ...] [COLUMN ...]\n', pname);
for i = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{i});
    if mod(i, 23) == 0   % pause every 23 lines, as in C
        wfdbx.internal.cerr('--More--');
        wfdbx.internal.cerr([char(27) '[A' char(27) '[2K']);   % VT100: cursor up, erase line
    end
end
end

function tf = line_has_alpha(line)
tf = 0;
if ~ischar(line)
    return;
end
n = numel(line);
p = 1;
while p <= n
    c = line(p);
    if c == 'e' || c == 'E'
        p = p + 1;
        if p <= n
            nc = line(p);
        else
            nc = char(0);
        end
        if nc <= '9' || nc == '-' || nc == '+'
            p = p + 1;
            continue;
        end
        c = nc;
    end
    if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
        tf = 1;
        return;
    end
    p = p + 1;
end
end

function tokens = parseline(line, delim)
% Split a line into tokens as parseline() in wrsamp.c does.
isd = false(1, 256);
isd(double(delim) + 1) = true;
m = isd(double(line) + 1);
if ~any(line == '"' | line == '''' | line == '<' | line == '\')
    % fast path: tokens are the runs of non-separator characters
    d = diff([true, m, true]);
    starts = find(d == -1);
    ends = find(d == 1) - 1;
    tokens = cell(1, numel(starts));
    for k = 1:numel(starts)
        tokens{k} = line(starts(k):ends(k));
    end
    return;
end
tokens = {};
n = numel(line);
p = 1;
while p <= n
    while p <= n && m(p)
        p = p + 1;
    end
    if p > n
        break;
    end
    q = char(0);
    hasq = false;
    c = line(p);
    if c == '"' || c == ''''
        q = c;
        hasq = true;
        p = p + 1;
    elseif c == '<'
        p = p + 1;
        q = '>';
        hasq = true;
    end
    buf = '';
    while p <= n && (hasq || ~m(p))
        c = line(p);
        if c == '\'
            if p + 1 > n
                break;
            end
            buf(end + 1) = line(p + 1); %#ok<AGROW>
            p = p + 2;
            continue;
        end
        if hasq && c == q
            p = p + 1;
            hasq = false;
            break;
        end
        buf(end + 1) = c; %#ok<AGROW>
        p = p + 1;
    end
    tokens{end + 1} = buf; %#ok<AGROW>
end
end

function r = legacy_adcres(fmt)
% wfdb-x: legacy mode: the ADC resolution that the C program inferred from
% the format
switch fmt
    case {508, 80}
        r = 8;
    case {310, 311}
        r = 10;
    case 212
        r = 12;
    case {516, 16, 160, 61}
        r = 16;
    case {524, 24}
        r = 24;
    case 32
        r = 32;
    otherwise
        if fmt > 100 && mod(fmt, 100) > 0 && mod(fmt, 100) <= 32
            r = mod(fmt, 100);
        else
            r = 12;     % WFDB_DEFRES
        end
end
end

function [l, li] = read_line(data, lstart, seps, li)
% The next line (without its separator), or [] at the end of the input.
li = li + 1;
if li > numel(seps)
    l = [];
else
    l = data(lstart(li):seps(li) - 1);
end
end

function s = lstrip(s)
k = find(s ~= ' ', 1);
if isempty(k)
    s = '';
else
    s = s(k:end);
end
end

function s = pyslice(s, a, b)
% Python s[a:b] (0-based, negative indices count from the end).
n = numel(s);
if b < 0
    b = max(n + b, 0);
end
b = min(b, n);
if a >= b
    s = '';
else
    s = s(a + 1:b);
end
end

function status = main(argv)
pname = argv{1};
argc = numel(argv);
gain = '';
scale = '';
res = '';       % wfdb-x: -R
uopt = [];      % wfdb-x: -U
record = [];
rsep = char(10);
sflag = 0;
xflag = 0; zflag = 0; dflag = 0;
freq = 0;       % wfdb-x: no default frequency (C: WFDB_DEFFREQ)
legacy = wfdbx.wfdbx_get_legacy();
if legacy
    freq = 250;     % WFDB_DEFFREQ (wfdb-x: legacy mode)
end
fmt = 16;
t0 = 0; t1 = 0;
delim = sprintf(' \t\r\n,');
rng = [];
infile = [];
have_infile = false;
i = 1;
while i < argc && strncmp(argv{i + 1}, '-', 1)
    a = argv{i + 1};
    if numel(a) >= 2
        c = a(2);
    else
        c = char(0);
    end
    if legacy && any(c == 'RU')     % wfdb-x: legacy mode: not options of
        c = char(0);                % the original (unrecognized)
    end
    switch c
        case 'c'
        case 'd'
            dflag = 1;
            rng = wfdbx.internal.GlibcRand(0);
        case 'f'
            i = i + 1;
            if i < argc
                t0 = wfdbx.internal.strtol(argv{i + 1});
            end
            if i >= argc || t0 <= 0
                wfdbx.internal.ceprintf('%s: starting line # must follow -f\n', pname);
                status = 1;
                return;
            end
        case 'F'
            i = i + 1;
            if i < argc
                freq = wfdbx.internal.atof(argv{i + 1});
            end
            if i >= argc || freq <= 0
                wfdbx.internal.ceprintf('%s: sampling frequency must follow -F\n', pname);
                status = 1;
                return;
            end
        case 'G'
            i = i + 1;
            if i >= argc
                wfdbx.internal.ceprintf('%s: gain(s) must follow -G\n', pname);
                status = 1;
                return;
            end
            gain = argv{i + 1};
        case 'h'
            help(pname);
            status = 1;
            return;
        case 'R'    % wfdb-x: ADC resolution(s) in bits
            i = i + 1;
            if i >= argc
                wfdbx.internal.ceprintf('%s: ADC resolution(s) must follow -R\n', pname);
                status = 1;
                return;
            end
            res = argv{i + 1};
        case 'U'    % wfdb-x: units
            i = i + 1;
            if i >= argc
                wfdbx.internal.ceprintf('%s: units must follow -U\n', pname);
                status = 1;
                return;
            end
            uopt = argv{i + 1};
        case 'i'
            i = i + 1;
            if i >= argc
                wfdbx.internal.ceprintf('%s: input file name must follow -i\n', pname);
                status = 1;
                return;
            end
            if strcmp(argv{i + 1}, '-')
                infile = [];
                have_infile = false;
            else
                fid = fopen(argv{i + 1}, 'rb');
                if fid < 0
                    wfdbx.internal.ceprintf('%s: can''t read `%s''\n', pname, argv{i + 1});
                    status = 2;
                    return;
                end
                infile = fread(fid, Inf, 'uint8=>uint8')';
                fclose(fid);
                have_infile = true;
            end
        case 'l'
            i = i + 1;
            if i >= argc
                i = i - 1;
            end
            wfdbx.internal.ceprintf('%s: -l is obsolete, ignored\n', pname);
        case 'o'
            i = i + 1;
            if i >= argc
                wfdbx.internal.ceprintf('%s: record name must follow -o\n', pname);
                status = 1;
                return;
            end
            record = argv{i + 1};
        case 'O'
            i = i + 1;
            if i >= argc
                wfdbx.internal.ceprintf('%s: output format must follow -O\n', pname);
                status = 1;
                return;
            end
            fmt = wfdbx.internal.atoi(argv{i + 1});
        case 'r'
            i = i + 1;
            if i >= argc
                wfdbx.internal.ceprintf('%s: line separator must follow -r\n', pname);
                status = 1;
                return;
            end
            if isempty(argv{i + 1})
                rsep = char(0);
            else
                rsep = argv{i + 1}(1);
            end
        case 's'
            i = i + 1;
            if i >= argc
                wfdbx.internal.ceprintf('%s: field separator(s) must follow -s\n', pname);
                status = 1;
                return;
            end
            sflag = 1;
            delim = argv{i + 1};
        case 't'
            i = i + 1;
            if i < argc
                t1 = wfdbx.internal.strtol(argv{i + 1});
            end
            if i >= argc || t1 <= 0
                wfdbx.internal.ceprintf('%s: ending line # must follow -t\n', pname);
                status = 1;
                return;
            end
        case 'x'
            i = i + 1;
            if i >= argc
                wfdbx.internal.ceprintf('%s: scaling factor(s) must follow -x\n', pname);
                status = 1;
                return;
            end
            scale = argv{i + 1};
        case 'z'
            zflag = 1;
        otherwise
            wfdbx.internal.ceprintf('%s: unrecognized option %s\n', pname, a);
            status = 1;
            return;
    end
    i = i + 1;
end
% wfdb-x: the sampling frequency, the gains, the ADC resolutions, and the
% units (of calibrated signals) must be specified when a header is written
% (the C program assumed 250 Hz, 200 adu/mV, a resolution based on the
% format, and millivolts).
if ischar(record) && ~legacy && freq <= 0
    wfdbx.internal.ceprintf( ...
        '%s: the sampling frequency must be specified (-F)\n', pname);
    status = 1;
    return;
end
if ischar(record) && ~legacy && isempty(gain)
    wfdbx.internal.ceprintf('%s: the gain(s) must be specified (-G)\n', pname);
    status = 1;
    return;
end
if ischar(record) && ~legacy && isempty(res)
    wfdbx.internal.ceprintf( ...
        '%s: the ADC resolution(s) must be specified (-R)\n', pname);
    status = 1;
    return;
end
nosig = argc - i;
if ~have_infile
    infile = wfdbx.internal.stdin_bytes();
end
% The input lines (an unterminated last line is lost, as in C).
data = char(infile);
seps = find(data == rsep);
lstart = [1, seps(1:end - 1) + 1];
li = 0;
[line, li] = read_line(data, lstart, seps, li);
if ~ischar(line)
    if rsep ~= char(10)
        if ~ischar(record)
            wfdbx.internal.ceprintf('%s: use -o to specify the output record name', pname);
        else
            wfdbx.internal.ceprintf(['%s: no record separators in input\n' ...
                'Try specifying a different separator after the -r option.\n'], pname);
        end
    else
        wfdbx.internal.ceprintf('%s: no newlines in input\n', pname);
    end
    status = 3;
    return;
end
dstrings = [];
ustrings = [];
ncols = 0;
if strncmp(line, '<?xml ', 6)
    xflag = 1;
    zflag = 1;
    while true
        [line, li] = read_line(data, lstart, seps, li);
        if ~ischar(line)
            wfdbx.internal.ceprintf('%s: XML input, but no <wfdbsampleset> found\n', pname);
            status = 1;
            return;
        end
        if strcmp(line, '<wfdbsampleset>')
            break;
        end
    end
    while true
        [line, li] = read_line(data, lstart, seps, li);
        if ~ischar(line)
            wfdbx.internal.ceprintf('%s: empty <wfdbsampleset>\n', pname);
            status = 1;
            return;
        end
        if strncmp(line, '<samplingfrequency>', 19)
            [n, v] = wfdbx.internal.csscanf(line(20:end), '%lf');
            if n == 1
                freq = v{1};
            end
        elseif strncmp(line, '<description>', 13)
            ta = parseline(pyslice(line, 13, numel(line) - 14), delim);   % between <description> and </description>
            dstrings = ta;
            ncols = numel(ta);
        elseif strncmp(line, '<units>', 7)
            ta = parseline(pyslice(line, 7, numel(line) - 8), delim);   % between <units> and </units>
            ustrings = ta;
        end
        if strcmp(line, '<samplevectors>')
            break;
        end
    end
    [line, li] = read_line(data, lstart, seps, li);
    if ~ischar(line)
        wfdbx.internal.ceprintf('%s: empty <wfdbsampleset>\n', pname);
        status = 1;
        return;
    end
else
    if sflag == 0 && any(line == char(9))
        delim = char(9);
    end
    ta = parseline(line, delim);
    ncols = numel(ta);
    if line_has_alpha(line)
        dstrings = cellfun(@lstrip, ta, 'UniformOutput', false);
        [line, li] = read_line(data, lstart, seps, li);
        if ~ischar(line)
            wfdbx.internal.ceprintf('%s: no data\n', pname);
            status = 1;
            return;
        elseif line_has_alpha(line)
            ta = parseline(line, delim);
            ustrings = cell(1, numel(ta));
            for k = 1:numel(ta)
                t = lstrip(ta{k});
                if ~isempty(t) && t(1) == '('
                    last = t(end);
                    t = t(2:end);
                    if last == ')'
                        t = t(1:end - 1);
                    end
                end
                ustrings{k} = t;
            end
            [line, li] = read_line(data, lstart, seps, li);
            if ~ischar(line)
                wfdbx.internal.ceprintf('%s: no data\n', pname);
                status = 1;
                return;
            end
        end
    end
end
if nosig
    fv = zeros(1, nosig);
    for k = 1:nosig
        arg = argv{argc - nosig + k};
        [n, v] = wfdbx.internal.csscanf(arg, '%d');
        if n == 1
            x = wfdbx.internal.cint32(v{1});
        end
        if n ~= 1 || x < 0 || x >= ncols
            wfdbx.internal.ceprintf('%s: unrecognized argument %s\n', pname, arg);
            status = 1;
            return;
        end
        fv(k) = x;
    end
else
    nosig = ncols - zflag;
    fv = zflag:zflag + nosig - 1;
end
if ischar(record)
    ofname = [record '.dat'];
else
    ofname = '-';
end
si = wfdbx.siginfo(max(nosig, 0));
scalef = zeros(1, max(nosig, 0));
for k = 1:nosig
    si(k).fname = ofname;
    if iscell(dstrings)
        if fv(k) < numel(dstrings)
            si(k).desc = dstrings{fv(k) + 1};
        else
            si(k).desc = '';
        end
    else
        si(k).desc = sprintf('col %d', fv(k));
    end
    if ischar(uopt)     % wfdb-x: -U (the last one applies to the rest)
        uopt = lstrip(uopt);
        if ~isempty(uopt)
            j = find(uopt == ' ', 1);
            if isempty(j)
                si(k).units = uopt;
                uopt = '';
            else
                si(k).units = uopt(1:j - 1);
                uopt = uopt(j:end);
            end
        elseif k > 1
            si(k).units = si(k - 1).units;
        else
            si(k).units = '';
        end
    elseif iscell(ustrings)
        if fv(k) < numel(ustrings)
            si(k).units = ustrings{fv(k) + 1};
        else
            si(k).units = '';
        end
    else
        si(k).units = '';
    end
    si(k).group = 0;
    si(k).fmt = fmt;
    si(k).spf = 1;
    si(k).bsize = 0;
    % wfdb-x: the ADC resolutions are given by -R (the last one applies to
    % the remaining signals); the C program inferred them from the format
    % or assumed WFDB_DEFRES.
    res = lstrip(res);
    [n, v] = wfdbx.internal.csscanf(res, '%d');
    if legacy       % wfdb-x: legacy mode: as in the C program
        si(k).adcres = legacy_adcres(fmt);
    elseif n < 1
        if k == 1
            si(k).adcres = 0;
        else
            si(k).adcres = si(k - 1).adcres;
        end
    else
        si(k).adcres = v{1};
        j = find(res == ' ', 1);
        if isempty(j)
            res = '';
        else
            res = res(j:end);
        end
    end
    if ischar(record) && ~legacy && si(k).adcres < 1
        wfdbx.internal.ceprintf( ...
            '%s: the ADC resolution(s) must be specified (-R)\n', pname);
        status = 1;
        return;
    end
    si(k).adczero = 0;
    si(k).baseline = 0;
    gain = lstrip(gain);
    [n, v] = wfdbx.internal.csscanf(gain, '%lf');
    if n < 1
        if k == 1
            si(k).gain = 0;       % wfdb-x: no default (C: WFDB_DEFGAIN)
            if legacy
                si(k).gain = 200;     % WFDB_DEFGAIN (wfdb-x: legacy mode)
            end
        else
            si(k).gain = si(k - 1).gain;
        end
    else
        si(k).gain = v{1};
        j = find(gain == ' ', 1);
        if isempty(j)
            gain = '';
        else
            gain = gain(j:end);
        end
    end
    % wfdb-x: the units of a calibrated signal must be specified, by -U or
    % by the input (the C program left them out: millivolts).
    if ischar(record) && ~legacy && si(k).gain ~= 0 && isempty(si(k).units)
        wfdbx.internal.ceprintf('%s: the units must be specified (-U)\n', pname);
        status = 1;
        return;
    end
    scale = lstrip(scale);
    [n, v] = wfdbx.internal.csscanf(scale, '%lf');
    if n < 1
        if k == 1
            scalef(k) = 1;
        else
            scalef(k) = scalef(k - 1);
        end
    else
        scalef(k) = v{1};
        j = find(scale == ' ', 1);
        if isempty(j)
            scale = '';
        else
            scale = scale(j:end);
        end
    end
end
while line_has_alpha(line)
    [line, li] = read_line(data, lstart, seps, li);
end
if wfdbx.osigfopen(si, nosig) < nosig || wfdbx.setsampfreq(freq) < 0
    status = 2;
    return;
end
t = 0;
while t < t0
    [line, li] = read_line(data, lstart, seps, li);
    t = t + 1;
end
if zflag && ischar(line)
    if strncmp(line, '[', 1)
        wfdbx.setbasetime(pyslice(line, 1, 24));   % 23 characters, as in C
    elseif numel(line) >= 2 && line(2) == '['
        wfdbx.setbasetime(pyslice(line, 2, 25));   % 23 characters, as in C
    end
end
vout = zeros(1, nosig);
RAND_MAX = wfdbx.internal.GlibcRand.RAND_MAX;
while ischar(line)
    if t1 ~= 0
        tt = t;
        t = t + 1;
        if ~(tt < t1)
            break;
        end
    end
    ta = parseline(line, delim);
    for k = 1:nosig
        if fv(k) < numel(ta)
            tok = ta{fv(k) + 1};
        else
            tok = '';
        end
        [n, v] = wfdbx.internal.csscanf(tok, '%lf');
        if n == 1
            x = v{1} * scalef(k);
            if dflag
                x = x + (rng.rand() + rng.rand()) / RAND_MAX - 1;
            end
            if x >= 0
                vout(k) = wfdbx.internal.d2i(x + 0.5);
            else
                vout(k) = wfdbx.internal.d2i(x - 0.5);
            end
        else
            vout(k) = -32768;     % WFDB_INVALID_SAMPLE
        end
    end
    if wfdbx.putvec(vout) < 0
        break;
    end
    [line, li] = read_line(data, lstart, seps, li);
    if ischar(line) && xflag && strncmp(line, '</samplevectors>', 16)
        [line, li] = read_line(data, lstart, seps, li);
        if ischar(line) && ~strcmp(line, '</wfdbsampleset>')
            wfdbx.internal.ceprintf('%s: (warning) unexpected EOF in XML input\n', pname);
        end
        break;
    end
end
wfdbx.setsampfreq(freq);
if ischar(record)
    wfdbx.newheader(record);
end
wfdbx.wfdbquit();
status = 0;
end
