function status = xform(args)
%XFORM Sampling frequency, amplitude, and format conversion of WFDB records.
%   STATUS = wfdbx.apps.xform(ARGS) runs the xform tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       xform -i IREC [OPTIONS ...]
%   where IREC is the record to be converted, and OPTIONS may include:
%       -a ANNOTATOR [ANNOTATOR ...]  copy annotations of the ANNOTATORs
%       -c          clip output (default: wrap around if out-of-range)
%       -d          add dither to the input if changing frequency or gain
%       -f TIME     begin at specified time
%       -h          print a usage summary
%       -H          open the input record in high resolution mode
%       -M          process a multifrequency record without changing
%                   frequencies
%       -n NREC     create a header file for record NREC (signal
%                   descriptions from IREC)
%       -N NREC     as for -n, but copy signal descriptions from OREC
%       -o OREC     produce output signal file(s) as specified by the
%                   header of record OREC
%       -s SIGNAL [SIGNAL ...]  write only the specified signal(s)
%       -S SCRIPT   take answers to prompts from SCRIPT (a text file)
%       -t TIME     stop at specified time
%       -u          adjust annotation times if needed to make them unique
%   Without -o, the output specifications are asked for (on /dev/tty, or
%   the standard input, or read from SCRIPT).
%
%   wfdb-x: the input and output records must specify their sampling
%   frequencies, an uncalibrated input signal cannot be rescaled to a
%   specified gain, and rescaling by ADC resolution (no output gain) needs
%   the input and output resolutions (the C program assumed 250 Hz and
%   200 adu/mV, and guessed resolutions from the formats).  The ADC
%   resolution prompt offers a value only if it comes from the input (or
%   the previous output signal) and suits the output format; otherwise
%   the resolution must be given.  Unspecified units are shown as "nd";
%   see docs/DIVERGENCES.md.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, and fmt212, a test record in format 212 whose header gives the
%   output signal specifications, are included with WFDB-x in the folder
%   tests/data of a copy of the repository; the example writes the signal
%   file fmt212.dat and the header new.hea in the current folder):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.xform({'-i', '100s', '-o', 'fmt212', '-n', 'new'})
%
%   See also wfdbx.apps.snip.
%
%   Translation of the C program xform (app/xform.c, WFDB 10.7.0): same
%   options and output. Differences: no sampling frequency, gain or ADC
%   resolution is assumed; see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/xform.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in sampling frequency, gain, ADC
% resolution or units: the input record must give its sampling frequency, and
% an output frequency of 0 is refused; rescaling an uncalibrated signal to a
% given gain, and rescaling by ADC resolution when a resolution is unspecified,
% are refused; an ADC resolution is offered only if it comes from the input (or
% the previous output signal) and suits the output format; unspecified units
% are shown as "nd" (the original assumed 250 Hz, 200 adu/mV, a resolution
% based on the format, and millivolts); when an output signal file would be one
% of the input files, the message says so; --legacy, as the first argument,
% restores the original behavior. Each change is marked "wfdb-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
%
% Original C program: app/xform.c, WFDB Software Package 10.7.0.
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
status = wfdbx.internal.app_run(@main, [{'xform'}, args]);
end

function help(pname)
h = {'where IREC is the name of the record to be converted, and OPTIONS may', ...
    ' include any of:', ...
    ' -a ANNOTATOR [ANNOTATOR ...]  copy annotations for the specified ANNOTATOR', ...
    '              from IREC;  two or more ANNOTATORs may follow -a', ...
    ' -c          clip output (default: wrap around if out-of-range)', ...
    ' -d          add dither to the input if changing sampling frequency or gain', ...
    ' -f TIME     begin at specified time', ...
    ' -h          print this usage summary', ...
    ' -H          open the input record in `high resolution'' mode', ...
    ' -M          process multifrequency record without changing frequencies', ...
    ' -n NREC     create a header file, using record name NREC and signal', ...
    '              descriptions from IREC', ...
    ' -N NREC     as for -n, but copy signal descriptions from OREC', ...
    ' -o OREC     produce output signal file(s) as specified by the header file', ...
    '              for record OREC', ...
    ' -s SIGNAL [SIGNAL ...]  write only the specified signal(s)', ...
    ' -S SCRIPT   take answers to prompts from SCRIPT (a text file)', ...
    ' -t TIME     stop at specified time', ...
    ' -u          adjust annotation times if needed to make them unique', ...
    'Unless you use `-o'' to specify an *existing* header that describes the', ...
    'desired signal files, you will be asked for output specifications.  Use', ...
    '`-n'' to name the record to be created.  Use `-s'' to select a subset of the', ...
    'input signals, or to re-order them in the output file;  arguments that', ...
    'follow `-s'' are *input* signal numbers (0,1,2,...) or names.'};
wfdbx.internal.ceprintf('usage: %s -i IREC [OPTIONS ...]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function x = gcd_approx(x, y)
% Approximate greatest common divisor (as in xform.c).
if x > y
    tol = 0.001 * y;   % relative tolerance (as in C)
else
    tol = 0.001 * x;
end
while true
    if x > y && x - y > tol
        x = x - y;
    elseif y > x && y - x > tol
        y = y - x;
    else
        return;
    end
end
end

function [s, R] = rfgets(R, size)
% C fgets(buf, size, fp) on the prompt input ([] at the end).
if R.fid >= 0
    % byte by byte (fgets would transcode the characters in MATLAB)
    b = zeros(1, 0);
    while numel(b) < size - 1
        c = fread(R.fid, 1, 'uint8=>double');
        if isempty(c)
            break;
        end
        b(end + 1) = c; %#ok<AGROW>
        if c == 10
            break;
        end
    end
    if isempty(b)
        s = [];
    else
        s = char(b);
    end
    return;
end
n = numel(R.data);
if R.pos > n
    s = [];
    return;
end
lim = min(n, R.pos + size - 2);
k = find(R.data(R.pos:lim) == char(10), 1);
if isempty(k)
    e = lim;
else
    e = R.pos + k - 1;
end
s = R.data(R.pos:e);
R.pos = e + 1;
end

function [s, R] = script_fgets(R, size)
[s, R] = rfgets(R, size);
if ~ischar(s)
    if ischar(R.script)
        wfdbx.internal.ceprintf('\n%s: unexpected end of file in %s\n', ...
            R.pname, R.script);
        wfdbx.internal.cexit(1);
    end
    s = char(10);
end
end

function d = dither(rng, cnt)
% CNT values of the dither (two rand() calls each, in order).
if cnt == 0
    d = zeros(1, 0);
    return;
end
r = rng.rand(2 * cnt);
d = (r(1:2:end) + r(2:2:end)) / wfdbx.internal.GlibcRand.RAND_MAX - 1;
end

function y = cround(vd)
% d2i(vd + 0.5) if vd >= 0, else d2i(vd - 0.5)
y = vd;
p = vd >= 0;
y(p) = wfdbx.internal.d2i(vd(p) + 0.5);
y(~p) = wfdbx.internal.d2i(vd(~p) - 0.5);
end

function [x, msgs, X] = check_rows(x, X, ok)
% Range checks of the rows of x (rows-by-nosig): returns the values (as
% clipped), and the messages as rows [row, k, value] in output order.
% X.vmax, X.vmin are updated as in C.  OK (same size as x) says which
% values are checked: those computed from valid inputs (a computed value
% may equal WFDB_INVALID_SAMPLE, and is then checked as in C).
INV = -32768;
if nargin < 3
    ok = x ~= INV;
end
nosig = size(x, 2);
msgs = zeros(0, 3);
if isempty(x)
    return;
end
for k = 1:nosig
    c = x(:, k);
    valid = ok(:, k);
    if X.clip
        hi = valid & c > X.vmax(k);
        lo = valid & ~hi & c < X.vmin(k);
        r = find(hi | lo);
        if ~isempty(r)
            msgs = [msgs; r, repmat(k - 1, numel(r), 1), c(r)]; %#ok<AGROW>
            c(hi) = X.vmax(k);
            c(lo) = X.vmin(k);
            x(:, k) = c;
        end
    else
        ch = c;
        ch(~valid) = -Inf;
        cl = c;
        cl(~valid) = Inf;
        if any(ch > X.vmax(k)) || any(cl < X.vmin(k))
            pm = cummax([X.vmax(k); ch]);
            hi = ch > pm(1:end - 1);
            pn = cummin([X.vmin(k); cl]);
            lo = ~hi & cl < pn(1:end - 1);
            r = find(hi | lo);
            msgs = [msgs; r, repmat(k - 1, numel(r), 1), c(r)]; %#ok<AGROW>
            X.vmax(k) = pm(end);
            X.vmin(k) = pn(end);
        end
    end
end
if size(msgs, 1) > 1
    msgs = sortrows(msgs, [1 2]);
end
end

function X = report(X, nframes, msgs, msgframe)
% Write the progress dots (one per minute of input, after NFRAMES more
% input frames) and the range messages (MSGS, emitted while processing
% input frame MSGFRAME(j) of this block, 1-based) to the standard error,
% in the order of C.
P = max(X.spm, 1);
first = P - X.nsm;              % first frame of the block with a dot
dots = first:P:nframes;
X.nsm = mod(X.nsm + nframes, P);
if isempty(dots) && isempty(msgs)
    return;
end
% events: [frame, type (0 dot, 1 message), index]
ev = [dots(:), zeros(numel(dots), 1), (1:numel(dots)).'; ...
    msgframe(:), ones(size(msgs, 1), 1), (1:size(msgs, 1)).'];
ev = sortrows(ev, [1 2 3]);
parts = cell(1, size(ev, 1));
isdot = ev(:, 2) == 0;
if any(~isdot)
    m = msgs(ev(~isdot, 3), :);
    txt = sprintf('v[%d] = %d (out of range)\n', [m(:, 2), m(:, 3)].');
    parts(~isdot) = regexp(txt, '[^\n]*\n', 'match');
end
for j = find(isdot).'
    X.nminutes = X.nminutes + 1;
    if X.nminutes >= 60
        X.nminutes = 0;
        parts{j} = sprintf('.\n');
    else
        parts{j} = '.';
    end
end
wfdbx.internal.cerr([parts{:}]);
end

function [y, X] = xf_input(V, X)
% Transform input samples (rows of V, columns as in X.cols) as C does
% in the loops of main() (without range checks).
INV = -32768;
x = V(:, X.cols);
inv = x == INV;
if X.gflag
    vd = x .* X.gain + X.deltav;
    if X.dflag
        vt = vd.';
        idx = find(~inv.');
        vt(idx) = reshape(vt(idx), [], 1) + dither(X.rng, numel(idx)).';
        vd = vt.';
    end
    y = cround(vd);
else
    y = wfdbx.internal.cint32(x + X.deltav);
end
y(inv) = INV;
end

function status = main(argv)
INV = -32768;           % WFDB_INVALID_SAMPLE
CHUNK = 65536;          % frames read and written at a time
WFDB_MAXRNL = 50;       % longest record name (lib/wfdb.h)
WFDB_MAXUSL = 50;       % longest units string
WFDB_MAXDSL = 100;      % longest signal description
pname = argv{1};
argc = numel(argv);
irec = []; orec = []; nrec = [];
startp = '0:0';
script = [];
rng = [];
ofreq = 0;
clip = 0; dflag = 0; fflag = 0; gflag = 0; Hflag = 0; Mflag = 0;
nann = 0; nosig = 0; reopen = 0; sflag = 0; uflag = 0;
use_irec_desc = 1;
siglist_args = [];
from = 0; to = 0;
nsamp = -1;
ainames = {};
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
                j = 0;
                while true
                    i = i + 1;
                    if ~(i < argc && (j == 0 || ~strncmp(argv{i + 1}, '-', 1)))
                        break;
                    end
                    j = j + 1;
                end
                if j == 0
                    wfdbx.internal.ceprintf('%s: annotator(s) must follow -a\n', pname);
                    status = 1;
                    return;
                end
                i = i - j;
                j = 0;
                while i < argc && (j == 0 || ~strncmp(argv{i + 1}, '-', 1))
                    ainames{end + 1} = argv{i + 1}; %#ok<AGROW>
                    nann = nann + 1;
                    i = i + 1;
                    j = j + 1;
                end
                i = i - 1;
            case 'c'
                clip = 1;
            case 'd'
                dflag = 1;
                rng = wfdbx.internal.GlibcRand(0);
            case 'f'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: time must follow -f\n', pname);
                    status = 1;
                    return;
                end
                from = i;
            case 'h'
                help(pname);
                status = 0;
                return;
            case 'H'
                Hflag = 1;
            case 'i'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: input record name must follow -i\n', pname);
                    status = 1;
                    return;
                end
                irec = argv{i + 1};
            case 'M'
                Mflag = 1;
            case {'n', 'N'}
                if c == 'N'
                    use_irec_desc = 0;
                end
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: new record name must follow -%c\n', pname, c);
                    status = 1;
                    return;
                end
                nrec = argv{i + 1};
            case 'o'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: output record name must follow -o\n', pname);
                    status = 1;
                    return;
                end
                orec = argv{i + 1};
            case 's'
                sflag = 1;
                j = 0;
                while true
                    i = i + 1;
                    if ~(i < argc && ~strncmp(argv{i + 1}, '-', 1))
                        break;
                    end
                    j = j + 1;
                end
                if j == 0
                    wfdbx.internal.ceprintf('%s: signal list must follow -s\n', pname);
                    status = 1;
                    return;
                end
                i = i - j;
                while i < argc && ~strncmp(argv{i + 1}, '-', 1)
                    siglist_args(end + 1) = i; %#ok<AGROW>
                    nosig = nosig + 1;
                    i = i + 1;
                end
                i = i - 1;
            case 'S'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: script name must follow -S\n', pname);
                    status = 1;
                    return;
                end
                script = argv{i + 1};
            case 't'
                i = i + 1;
                if i >= argc
                    wfdbx.internal.ceprintf('%s: time must follow -t\n', pname);
                    status = 1;
                    return;
                end
                to = i;
            case 'u'
                uflag = 1;
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
if ~ischar(irec)
    help(pname);
    status = 1;
    return;
end
if ischar(nrec) && ischar(orec) && strcmp(nrec, orec)
    wfdbx.internal.ceprintf('%s: arguments of -n (or -N) and -o cannot be identical\n', pname);
    status = 1;
    return;
end
nisig = wfdbx.isigopen(irec, 0);
if nisig < 0
    status = 2;
    return;
end
dfin = wfdbx.siginfo(0);
dfout = wfdbx.siginfo(0);
siglist = [];
if nisig == 0
    nosig = 0;
else
    [n, dfin] = wfdbx.isigopen(irec, nisig);
    if n ~= nisig
        status = 2;
        return;
    end
    if sflag
        siglist = zeros(1, 0);
        for k = 1:nosig
            s = argv{siglist_args(k) + 1};
            j = wfdbx.findsig(s);
            if j < 0
                wfdbx.internal.ceprintf( ...
                    '%s: warning: record %s doesn''t have a signal ''%s''\n', ...
                    pname, irec, s);
            else
                siglist(end + 1) = j; %#ok<AGROW>
            end
        end
        nosig = numel(siglist);
        if nosig == 0
            sflag = 0;
        end
    end
    if sflag == 0
        nosig = nisig;
        siglist = 0:nosig - 1;
    end
end
if Mflag
    wfdbx.setgvmode(0);     % WFDB_LOWRES
elseif Hflag
    wfdbx.setgvmode(1);     % WFDB_HIGHRES
end
ifreq = wfdbx.sampfreq([]);
% wfdb-x: no default sampling frequency (the C program assumed 250 Hz if the
% input header did not specify one, as legacy mode does).
legacy = wfdbx.wfdbx_get_legacy();
if ifreq <= 0 && ~legacy
    wfdbx.internal.ceprintf( ...
        '%s: sampling frequency of record %s is not specified\n', pname, irec);
    wfdbx.wfdbquit();
    status = 2;
    return;
end
spf = wfdbx.getspf();
if Mflag
    iframelen = sum([dfin(1:nisig).spf]);
    oframelen = sum([dfin(siglist + 1).spf]);
else
    iframelen = nisig;
    oframelen = nosig;
end
fmt = 0;
if ischar(orec)
    if ischar(nrec) && wfdbx.newheader(nrec) < 0
        status = 2;
        return;
    end
    ofreq = wfdbx.sampfreq(orec);
    if ofreq == 0 && ~legacy    % wfdb-x: no default sampling frequency
        wfdbx.internal.ceprintf( ...
            '%s: sampling frequency of record %s is not specified\n', ...
            pname, orec);
        wfdbx.wfdbquit();
        status = 2;
        return;
    end
    wfdbx.setsampfreq(ifreq / spf);
    if ifreq ~= ofreq && Mflag ~= 0
        wfdbx.internal.ceprintf(['%s: -M option may not be used if sampling ' ...
            'frequency is to be changed\n'], pname);
        wfdbx.wfdbquit();
        status = 1;
        return;
    end
else
    % the answers to the prompts: from SCRIPT, /dev/tty or the standard input
    R = struct('fid', -1, 'data', '', 'pos', 1, 'script', script, 'pname', pname);
    if ischar(script)
        fid = fopen(script, 'rb');
        if fid >= 0
            R.data = char(fread(fid, Inf, 'uint8=>uint8').');
            fclose(fid);
        end
    else
        fid = fopen('/dev/tty', 'rb');
        if fid >= 0
            R.fid = fid;
        end
    end
    if fid < 0
        R.data = char(wfdbx.internal.stdin_bytes());
    end
    if ~ischar(nrec)
        while true
            wfdbx.internal.ceprintf( ...
                'Choose a name for the output record (up to %d characters): ', ...
                WFDB_MAXRNL);
            [record, R] = script_fgets(R, WFDB_MAXRNL + 2);
            record = record(1:end - 1);
            if ~isempty(record) && wfdbx.newheader(record) >= 0
                break;
            end
        end
        nrec = record;
    end
    if sflag == 0
        while true
            nosig = nisig;
            wfdbx.internal.ceprintf('Number of signals to be written (1-%d) [%d]: ', ...
                nisig, nosig);
            [answer, R] = script_fgets(R, 32);
            [n, v] = wfdbx.internal.csscanf(answer, '%d');
            if n == 1
                nosig = wfdbx.internal.cint32(v{1});
            end
            if nosig == 0
                wfdbx.internal.ceprintf('No signals will be written.  Are you sure? [n]: ');
                [answer, R] = script_fgets(R, 32);
                if ~(strncmp(answer, 'y', 1) || strncmp(answer, 'Y', 1))
                    nosig = -1;
                end
            end
            if ~(nosig < 0 || nosig > nisig)
                break;
            end
        end
    end
    if Mflag
        ofreq = ifreq;
        wfdbx.internal.ceprintf('Sampling frequency (%g frames/sec) will be unchanged\n', ofreq);
    else
        while true
            ofreq = ifreq;
            wfdbx.internal.ceprintf('Output sampling frequency (Hz per signal, > 0) [%g]: ', ofreq);
            [answer, R] = script_fgets(R, 32);
            [n, v] = wfdbx.internal.csscanf(answer, '%lf');
            if n == 1
                ofreq = v{1};
            end
            if ~(ofreq < 0)
                break;
            end
        end
    end
    if ofreq == 0 && legacy
        ofreq = 250;    % WFDB_DEFFREQ (wfdb-x: legacy mode, as in C)
    elseif ofreq == 0   % wfdb-x: the C program assumed 250 Hz
        wfdbx.internal.ceprintf( ...
            '%s: the output sampling frequency must be > 0\n', pname);
        if R.fid >= 0
            fclose(R.fid);
        end
        wfdbx.wfdbquit();
        status = 1;
        return;
    end
    if nosig > 0
        cerr = @wfdbx.internal.cerr;
        cerr(sprintf('Specify the name of the directory in which the output\n'));
        cerr(sprintf(' signals should be written, or press <return> to write\n'));
        cerr(' them in the current directory: ');
        [directory, R] = script_fgets(R, 31);
        if strncmp(directory, char(10), 1)
            directory = '';
        else
            directory = [directory(1:end - 1) '/'];
        end
        cerr(sprintf(['Any of these output formats may be used:\n' ...
            '    8   8-bit first differences\n' ...
            '   16   16-bit two''s complement amplitudes (LSB first)\n' ...
            '   61   16-bit two''s complement amplitudes (MSB first)\n' ...
            '   80   8-bit offset binary amplitudes\n' ...
            '  160   16-bit offset binary amplitudes\n' ...
            '  212   2 12-bit amplitudes bit-packed in 3 bytes\n' ...
            '  310   3 10-bit amplitudes bit-packed in 15 LS bits of each of 2 words\n' ...
            '  311   3 10-bit amplitudes bit-packed in 30 LS bits of 4 bytes\n' ...
            '   24   24-bit two''s complement amplitudes (LSB first)\n' ...
            '   32   32-bit two''s complement amplitudes (LSB first)\n' ...
            '  508  8-bit amplitudes with FLAC compression\n' ...
            '  516  16-bit amplitudes with FLAC compression\n' ...
            '  524  24-bit amplitudes with FLAC compression\n']));
        formats = [8, 16, 61, 80, 160, 212, 310, 311, 24, 32, 508, 516, 524];
        while true
            fmt = dfin(1).fmt;
            wfdbx.internal.ceprintf('Choose an output format from the list above [%d]: ', fmt);
            [answer, R] = script_fgets(R, 32);
            [n, v] = wfdbx.internal.csscanf(answer, '%d');
            if n == 1
                fmt = wfdbx.internal.cint32(v{1});
            end
            if any(formats == fmt)
                break;
            end
        end
        if nosig > 1
            cerr('Save all signals in one file? [y]: ');
            [answer, R] = script_fgets(R, 32);
        end
        dfout = dfin(siglist(1:nosig) + 1);
        if nosig <= 1 || ~(strncmp(answer, 'n', 1) || strncmp(answer, 'N', 1))
            fn = sprintf('%s%s.dat', directory, nrec);
            for k = 1:nosig
                dfout(k).fname = fn;
                dfout(k).group = 0;
            end
        else
            for k = 1:nosig
                dfout(k).fname = sprintf('%s%s.d%d', directory, nrec, k - 1);
                dfout(k).group = k - 1;
            end
        end
    end
    for k = 1:nosig
        d = dfout(k);
        d.fmt = fmt;
        if Mflag == 0
            d.spf = 1;
        end
        d.bsize = 0;
        if ~use_irec_desc
            wfdbx.internal.ceprintf('Signal %d description (up to %d characters): ', ...
                k - 1, WFDB_MAXDSL);
            [desc, R] = script_fgets(R, WFDB_MAXDSL + 2);
            d.desc = desc(1:end - 1);
            wfdbx.internal.ceprintf('Signal %d units (up to %d characters): ', ...
                k - 1, WFDB_MAXUSL);
            [units, R] = script_fgets(R, WFDB_MAXUSL + 2);
            e = find(units == char(10), 1);
            if ~isempty(e)
                units = units(1:e - 1);
            end
            units(units == ' ' | units == char(9)) = '_';
            if isempty(units)
                d.units = [];
            else
                d.units = units;
            end
        end
        if ischar(d.units)
            u = d.units;
        else
            u = 'nd';   % wfdb-x: C (and legacy mode) showed "mV"
            if legacy
                u = 'mV';
            end
        end
        wfdbx.internal.ceprintf(' Signal %d gain (adu/%s) [%g]: ', k - 1, u, d.gain);
        [answer, R] = script_fgets(R, 32);
        [n, v] = wfdbx.internal.csscanf(answer, '%lf');
        if n == 1
            d.gain = v{1};
        end
        % wfdb-x: a resolution is offered only if it comes from the input
        % (or the previous output signal) and suits the output format; the C
        % program otherwise offered one based on the format (12 bits for
        % 16-bit formats).  Without one, the user must give it.
        while true
            if k > 1
                d.adcres = dfout(k - 1).adcres;
            end
            switch d.fmt
                case {80, 508}
                    maxres = 8;
                case 212
                    maxres = 12;
                case 310
                    maxres = 10;
                case {24, 524}
                    maxres = 24;
                case 32
                    maxres = 32;
                otherwise
                    maxres = 16;
            end
            if legacy   % wfdb-x: legacy mode: as in the C program
                if maxres == 8
                    d.adcres = 8;
                elseif d.adcres < 8 || d.adcres > maxres
                    d.adcres = maxres;
                    if maxres == 16
                        d.adcres = 12;      % WFDB_DEFRES
                    end
                end
            end
            if d.adcres >= 8 && d.adcres <= maxres
                wfdbx.internal.ceprintf(' Signal %d ADC resolution in bits (8-32) [%d]: ', ...
                    k - 1, d.adcres);
            else
                wfdbx.internal.ceprintf(' Signal %d ADC resolution in bits (8-32): ', ...
                    k - 1);
                d.adcres = 0;
            end
            [answer, R] = script_fgets(R, 32);
            [n, v] = wfdbx.internal.csscanf(answer, '%d');
            if n == 1
                d.adcres = wfdbx.internal.cint32(v{1});
            end
            if d.adcres == 0 && ~legacy
                wfdbx.internal.ceprintf( ...
                    '%s: the ADC resolution of signal %d must be specified\n', ...
                    pname, k - 1);
                if R.fid >= 0
                    fclose(R.fid);
                end
                wfdbx.wfdbquit();
                status = 1;
                return;
            end
            if ~(d.adcres < 8 || d.adcres > 32)
                break;
            end
        end
        wfdbx.internal.ceprintf(' Signal %d ADC zero level (adu) [%d]: ', k - 1, d.adczero);
        [answer, R] = script_fgets(R, 32);
        [n, v] = wfdbx.internal.csscanf(answer, '%d');
        if n == 1
            d.adczero = wfdbx.internal.cint32(v{1});
        end
        dfout(k) = d;
    end
    if R.fid >= 0
        fclose(R.fid);
    end
end
siglist = siglist(1:max(nosig, 0));
if from
    startp = argv{from + 1};
end
from = wfdbx.strtim(startp);
if from < 0
    from = -from;
end
btstring = wfdbx.mstimstr(-from);
if to
    to = wfdbx.strtim(argv{to + 1});
    if to < 0
        to = -to;
    end
    if to > 0
        nsamp = to - from;
        if nsamp <= 0
            wfdbx.internal.ceprintf('%s: ''to'' time must be later than ''from'' time\n', pname);
            status = 1;
            return;
        end
    end
end
spm = wfdbx.strtim('1:0');
if Mflag
    wfdbx.setgvmode(1);     % WFDB_HIGHRES
    spf = wfdbx.getspf();
    from = from * spf;
    to = to * spf;
    wfdbx.setafreq(ofreq * spf);
else
    wfdbx.setafreq(0);
end
if nann > 0
    ai = repmat(wfdbx.anninfo(ainames{1}, 0), 1, nann);     % WFDB_READ
    for k = 1:nann
        ai(k).name = ainames{k};
    end
    if wfdbx.annopen(irec, ai, nann) < 0 || wfdbx.iannsettime(from) < -1
        status = 2;
        return;
    end
    if ischar(nrec)
        p0 = nrec;
    else
        p0 = orec;
    end
    ao = ai;
    for k = 1:nann
        ao(k).stat = 1;                                     % WFDB_WRITE
    end
    if wfdbx.annopen(['+' p0], ao, nann) < 0
        status = 2;
        return;
    end
    C = wfdbx.ecgcodes();
    for k = 0:nann - 1
        % read until the first annotation after 'to'
        [stat, A] = wfdbx.internal.getann_bulk(k, inf, false, true);
        last = numel(A.time);
        if to ~= 0
            e = find(A.time > to, 1);
            if ~isempty(e)
                last = e - 1;
            end
        end
        if stat == 1 && last == numel(A.time)
            wfdbx.getann(k);        % the call that fails, as in C
        end
        keep = false(1, numel(A.time));
        keep(1:last) = true;
        keep = keep & ~(A.time == 0 & A.subtyp == 0 & A.chan == 0 & ...
            A.num == 0 & (A.anntyp == C.NOTQRS | A.anntyp == C.NOTE));
        A.time = fix((A.time(keep) - from) * ofreq / ifreq);
        A.anntyp = A.anntyp(keep);
        A.subtyp = A.subtyp(keep);
        A.chan = A.chan(keep);
        A.num = A.num(keep);
        A.aux = A.aux(keep);
        if uflag
            tt = 0;
            cc = -129;   % below any chan (as in C)
            t = A.time;
            ch = A.chan;
            for j = 1:numel(t)
                if t(j) < tt || (t(j) == tt && ch(j) <= cc)
                    tt = tt + 1;
                    t(j) = tt;
                else
                    tt = t(j);
                end
                cc = ch(j);
            end
            A.time = t;
        end
        wfdbx.internal.putann_bulk(k, A);
    end
    for k = nann - 1:-1:0
        wfdbx.iannclose(k);
        wfdbx.oannclose(k);
    end
end
if nosig == 0
    status = 0;
    return;
end
wfdbx.internal.cerr('Checking input signals ...');
if wfdbx.isigsettime(from) < 0
    status = 2;
    return;
end
wfdbx.internal.cerr(sprintf(' done\n'));
wfdbx.wfdbquiet();
if ischar(orec)
    [n, dfout] = wfdbx.osigopen(orec, nosig);
    if n ~= nosig
        % wfdb-x: say why if an output file is one of the input files (the
        % library's message, quieted above, is the last error)
        e = wfdbx.wfdberror();
        tail = ' is also an input file';
        tail(end + 1) = char(10);
        if ~legacy && strncmp(e, 'osigopen: output file ', 22) && ...
                numel(e) > 22 + 23 && strcmp(e(end-22:end), tail)
            wfdbx.internal.ceprintf('%s: can''t write output signals (%s)\n', ...
                pname, e(1:end-1));
        else
            wfdbx.internal.ceprintf('%s: can''t write output signals\n', pname);
        end
        status = 2;
        return;
    end
end
wfdbx.wfdbverbose();
for k = 1:nosig
    if dfout(k).fmt == 0
        wfdbx.internal.ceprintf('%s: signal %d format cannot be 0 (changing to format 16)\n', ...
            pname, k - 1);
        dfout(k).fmt = 16;
        reopen = 1;
    end
end
% Without -M, the output frames hold one sample of each signal (as for
% output signals specified interactively), so signals of the -o record with
% more than one sample per frame are (re)opened with one.  (C reads past
% the end of its output array; see "Undefined behaviors" in
% docs/KNOWN_C_BEHAVIORS.md.)
if Mflag == 0
    for k = 1:nosig
        if dfout(k).spf > 1
            dfout(k).spf = 1;
            reopen = 1;
        end
    end
end
if ischar(nrec) && use_irec_desc
    for k = 1:nosig
        dfout(k).desc = dfin(siglist(k) + 1).desc;
    end
    reopen = 1;
end
gain = zeros(1, nosig);
deltav = zeros(1, nosig);
for k = 1:nosig
    j = siglist(k) + 1;
    di = dfin(j);
    dk = dfout(k);
    if dk.gain == 0
        % wfdb-x: rescaling by ADC resolution needs both resolutions (the C
        % program guessed an unspecified input resolution from the format,
        % assuming WFDB_DEFRES for 16-bit formats).
        if legacy
            if di.adcres == 0   % wfdb-x: legacy mode: the C program's guess
                di.adcres = legacy_inres(di.fmt);
                dfin(j) = di;
            end
        elseif di.adcres == 0 || dk.adcres == 0
            if di.adcres == 0
                sn = j - 1;
                rn = irec;
            else
                sn = k - 1;
                if ischar(orec)
                    rn = orec;
                else
                    rn = nrec;
                end
            end
            wfdbx.internal.ceprintf( ...
                '%s: ADC resolution of signal %d of record %s is not specified\n', ...
                pname, sn, rn);
            wfdbx.wfdbquit();
            status = 2;
            return;
        end
        gain(k) = 2^dk.adcres / 2^di.adcres;
    elseif di.gain == 0 && legacy
        gain(k) = dk.gain / 200;        % WFDB_DEFGAIN (wfdb-x: legacy mode)
    elseif di.gain == 0
        % output gain specified, but the input signal is uncalibrated
        % (wfdb-x: the C program assumed an input gain of WFDB_DEFGAIN)
        wfdbx.internal.ceprintf(['%s: signal %d of record %s is ' ...
            'uncalibrated; it cannot be rescaled to the specified gain\n'], ...
            pname, j - 1, irec);
        wfdbx.wfdbquit();
        status = 2;
        return;
    else
        gain(k) = dk.gain / di.gain;
    end
    if gain(k) ~= 1
        gflag = 1;
    end
    deltav(k) = wfdbx.internal.d2i(dk.adczero - gain(k) * di.adczero);
    if dk.gain ~= di.gain * gain(k) || dk.baseline ~= di.baseline * gain(k)
        dk.gain = di.gain * gain(k);
        dk.baseline = wfdbx.internal.d2i(di.baseline * gain(k));
        reopen = 1;
    end
    dfout(k) = dk;
end
if reopen
    if wfdbx.osigfopen(dfout, nosig) ~= nosig
        status = 2;
        return;
    end
end
X = struct();
X.clip = clip;
X.vmax = wfdbx.internal.cint32([dfout(1:nosig).adczero] + 2 .^ ([dfout(1:nosig).adcres] - 1) - 1);
X.vmin = wfdbx.internal.cint32([dfout(1:nosig).adczero] - 2 .^ ([dfout(1:nosig).adcres] - 1));
X.spm = spm;
X.nsm = 0;
X.nminutes = 0;
X.gflag = gflag;
X.dflag = dflag;
X.rng = rng;
X.gain = gain;
X.deltav = deltav;
X.cols = siglist + 1;
vin = zeros(1, max(iframelen, 1));
m = 0; n = 0;
vv = zeros(1, nosig);
if ifreq ~= ofreq
    f = gcd_approx(ifreq, ofreq);
    fflag = 1;
    m = fix(ifreq / f);
    n = fix(ofreq / f);
    [st, vin] = wfdbx.getvec(vin); %#ok<ASGLU>
    x = vin(siglist + 1);
    vv = wfdbx.internal.d2i(x .* gain + deltav);
    vv(x == INV) = INV;
end
if Mflag
    % one frame at a time (getframe)
    msiglist = zeros(1, nosig);
    for k = 1:nosig
        msiglist(k) = sum([dfin(1:siglist(k)).spf]);
    end
    ospf = [dfout(1:nosig).spf];
    vout = zeros(1, max(oframelen, 1));
    while true
        [st, vin] = wfdbx.getframe(vin);
        if st < nisig
            break;
        end
        if nsamp ~= -1
            more = nsamp > 0;
            nsamp = nsamp - 1;
            if ~more
                break;
            end
        end
        jx = 0;
        rows = zeros(0, 3);
        for k = 1:nosig
            for kk = 1:ospf(k)
                vt = vin(msiglist(k) + kk);
                if vt == INV
                    vout(jx + 1) = vt;
                else
                    if gflag
                        vd = vt * gain(k) + deltav(k);
                        if dflag
                            vd = vd + dither(rng, 1);
                        end
                        y = cround(vd);
                    else
                        y = wfdbx.internal.cint32(vt + deltav(k));
                    end
                    [y, msgs, X] = check_one(y, k, X);
                    rows = [rows; msgs]; %#ok<AGROW>
                    vout(jx + 1) = y;
                end
                jx = jx + 1;
            end
        end
        X = report(X, 1, rows, ones(size(rows, 1), 1));
        if wfdbx.putvec(vout) < 0
            break;
        end
    end
elseif fflag == 0
    remaining = nsamp;
    while true
        if remaining == 0
            wfdbx.getvec(vin);      % C reads one more vector
            break;
        end
        if remaining < 0
            k = CHUNK;
        else
            k = min(CHUNK, remaining);
        end
        V = wfdbx.getframes(k, nisig);   % (getvec(vin) >= nisig)
        L = size(V, 1);
        y = xf_input(V, X);
        [y, msgs, X] = check_rows(y, X, V(:, X.cols) ~= INV);
        X = report(X, L, msgs, msgs(:, 1));
        if wfdbx.putframes(y) < 0 || L < k
            break;
        end
        if remaining > 0
            remaining = remaining - L;
        end
    end
else
    % resampling: output frame q (0, 1, ...) is computed while input frame
    % i(q) = ceil(q*m/n) + 1 is processed (1 is the first frame after the
    % one read above), from input frames i(q) - 1 and i(q)
    remaining = nsamp;
    i0 = 0;             % input frames processed
    q0 = 0;             % output frames written
    while true
        if remaining == 0
            wfdbx.getvec(vin);      % C reads one more vector
            break;
        end
        if remaining < 0
            k = CHUNK;
        else
            k = min(CHUNK, remaining);
        end
        V = wfdbx.getframes(k, nisig);   % (getvec(vin) >= nisig)
        L = size(V, 1);
        if L == 0
            X = report(X, 0, zeros(0, 3), zeros(0, 1));
            break;
        end
        q1 = floor((i0 + L - 1) * n / m);       % last output of this block
        q = (q0:q1).';
        iq = ceil(q * m / n) + 1 - i0;          % input frame (in the block)
        r = q * m;
        r = r - floor(r / n) * n;               % ot % n
        x = r / n;
        x(r == 0) = 1;
        if dflag && gflag
            % rand() calls interleaved, in C order: the input samples of a
            % frame, then the outputs computed while processing it.  An
            % output is dithered if both of its (dithered and rounded)
            % inputs are valid, so this is done one frame at a time (a
            % rounded input may equal WFDB_INVALID_SAMPLE).
            xin = V(:, X.cols);
            vdin = xin .* gain + deltav;
            y = zeros(L, nosig);
            nq = numel(q);
            dout = zeros(nq, nosig);
            prev = vv;
            jq = 1;
            for j = 1:L
                for kk = 1:nosig
                    if xin(j, kk) == INV
                        y(j, kk) = INV;
                    else
                        y(j, kk) = cround(vdin(j, kk) + dither(rng, 1));
                    end
                end
                % the outputs computed while frame j is processed
                while jq <= nq && iq(jq) == j
                    for kk = 1:nosig
                        if prev(kk) ~= INV && y(j, kk) ~= INV
                            dout(jq, kk) = dither(rng, 1);
                        end
                    end
                    jq = jq + 1;
                end
                prev = y(j, :);
            end
        else
            y = xf_input(V, X);
            dout = [];
        end
        Y = [vv; y];
        a = Y(iq, :);
        b = Y(iq + 1, :);
        vd = a + x .* wfdbx.internal.cint32(b - a);    % (an int difference in C)
        if dflag
            if isempty(dout)
                vt = vd.';
                idx = find((a ~= INV & b ~= INV).');
                vt(idx) = reshape(vt(idx), [], 1) + dither(rng, numel(idx)).';
                vd = vt.';
            else
                vd = vd + dout;
            end
        end
        out = cround(vd);
        bad = a == INV | b == INV;
        out(bad) = INV;
        [out, msgs, X] = check_rows(out, X, ~bad);
        X = report(X, L, msgs, iq(msgs(:, 1)));
        if wfdbx.putframes(out) < 0 || L < k
            break;
        end
        vv = y(end, :);
        i0 = i0 + L;
        q0 = q1 + 1;
        if remaining > 0
            remaining = remaining - L;
        end
    end
end
if X.nminutes > 0
    wfdbx.internal.cerr(char(10));
end
if ischar(nrec)
    wfdbx.setsampfreq(ofreq);
    if strncmp(btstring, '[', 1)
        wfdbx.setbasetime(btstring(2:end - 1));
    end
    wfdbx.newheader(nrec);
    wfdbx.wfdbquiet();
    info = wfdbx.getinfo(irec);
    while ischar(info)
        wfdbx.putinfo(info);
        info = wfdbx.getinfo([]);
    end
    wfdbx.putinfo(sprintf('Produced by %s from record %s, beginning at %s', ...
        pname, irec, startp));
    for k = 1:nosig
        if siglist(k) ~= k - 1
            xinfo = sprintf('record %s, signal %d <- record %s, signal %d', ...
                nrec, k - 1, irec, siglist(k));
            if gain(k) ~= 1
                xinfo = [xinfo wfdbx.internal.csprintf(' * %g', gain(k))]; %#ok<AGROW>
            end
            if deltav(k) ~= 0
                if deltav(k) > 0
                    sg = '+';
                else
                    sg = '-';
                end
                xinfo = [xinfo sprintf(' %s %d', sg, abs(deltav(k)))]; %#ok<AGROW>
            end
            wfdbx.putinfo(xinfo);
        end
    end
    wfdbx.wfdbverbose();
end
wfdbx.wfdbquit();
status = 0;
end

function [y, msgs, X] = check_one(y, k, X)
% check() of one sample of signal k (1-based)
msgs = zeros(0, 3);
if y > X.vmax(k)
    msgs = [1, k - 1, y];
    if X.clip
        y = X.vmax(k);
    else
        X.vmax(k) = y;
    end
elseif y < X.vmin(k)
    msgs = [1, k - 1, y];
    if X.clip
        y = X.vmin(k);
    else
        X.vmin(k) = y;
    end
end
end

function r = legacy_inres(fmt)
% wfdb-x: legacy mode: the C program's guess of an unspecified input ADC
% resolution (WFDB_DEFRES for 16-bit formats, for historical compatibility)
switch fmt
    case {80, 508}
        r = 8;
    case 212
        r = 12;
    case 310
        r = 10;
    case {24, 524}
        r = 24;
    case 32
        r = 32;
    otherwise
        r = 12;     % WFDB_DEFRES
end
end
