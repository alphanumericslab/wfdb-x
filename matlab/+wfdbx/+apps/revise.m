function status = revise(args)
%REVISE Convert an obsolete-format header file into a current one.
%   STATUS = wfdbx.apps.revise(ARGS) runs the revise tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       revise RECORD
%   reads the old-style header of RECORD and writes RECORD.hea.
%
%   wfdb-x: a missing ADC resolution stays unspecified (0; the C program
%   assumed WFDB_DEFRES, 12 bits); see docs/DIVERGENCES.md.
%
%   Example:
%       wfdbx.apps.revise({'old'})
%
%   See also wfdbx.apps.wfdbdesc, wfdbx.setheader.

% Copyright (C) 1999 George B. Moody (original C program, convert/revise.c;
% revised 2018 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU General Public License, version 2 or later (see LICENSE).

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'revise'}, args]);
end

function [t, p] = nexttok(lines, li, sep)
% Tokenizer of the next line (and its first token), [] at the end.
if li > numel(lines)
    t = [];
    p = [];
    return;
end
t = wfdbx.internal.Strtok(lines{li});
p = t.next(sep);
end

function [nsig, si] = readoldheader(record)
WFDB_MAXSIG = 32;
sep = sprintf(' \t\n');
si = wfdbx.siginfo(0);
nsig = -2;
f = wfdbx.internal.wfdb_open('header', record, 0);     % WFDB_READ
if isempty(f)
    wfdbx.internal.wfdb_error('init: can''t open header for record %s\n', record);
    nsig = -1;
    return;
end
is_std = f.is_std;
lines = wfdbx.internal.fgets_lines(f.readall(), 256);
f.close();
li = 0;
while true
    li = li + 1;
    if li > numel(lines)
        wfdbx.internal.wfdb_error('init: can''t find record name in record %s header\n', record);
        return;
    end
    tok = wfdbx.internal.Strtok(lines{li});
    p = tok.next(sep);
    if ischar(p) && ~strncmp(p, '#', 1)
        break;
    end
end
if ~is_std && ~strcmp(p, record)
    wfdbx.internal.wfdb_error('init: record name in record %s header is incorrect\n', record);
    return;
end
if ischar(tok.next(sep))
    wfdbx.internal.ceprintf('The header for record %s appears not to be an old-style header.\n', record);
    return;
end
li = li + 1;
[~, p] = nexttok(lines, li, sep);
if ~ischar(p)
    wfdbx.internal.wfdb_error('init: incorrect format in record %s header\n', record);
    return;
end
ng = wfdbx.internal.atoi(p);
nsamples = 0;
s = 0;
g = 0;
while g < ng
    cur = wfdbx.siginfo();
    cur.group = g;
    li = li + 1;
    [~, p] = nexttok(lines, li, sep);
    if ~ischar(p)
        wfdbx.internal.wfdb_error('init: incorrect format in record %s header\n', record);
        return;
    end
    cur.fname = p;
    li = li + 1;
    [~, p] = nexttok(lines, li, sep);
    if ~ischar(p)
        wfdbx.internal.wfdb_error('init: incorrect format in record %s header\n', record);
        return;
    end
    cur.gain = wfdbx.internal.atof(p);
    li = li + 1;
    [~, p] = nexttok(lines, li, sep);
    if ~ischar(p) || wfdbx.internal.atof(p) <= 0
        wfdbx.internal.wfdb_error('init: incorrect format in record %s header\n', record);
        return;
    end
    wfdbx.setsampfreq(wfdbx.internal.atof(p));
    li = li + 1;
    [t, p] = nexttok(lines, li, sep);
    if ~ischar(p)
        wfdbx.internal.wfdb_error('init: incorrect format in record %s header\n', record);
        return;
    end
    i = wfdbx.internal.cuint32(wfdbx.internal.atoi(p));
    p = t.next(sep);
    if ischar(p)
        mpx = wfdbx.internal.atoi(p);
    else
        mpx = 1;
    end
    if mpx == 0
        mpx = 1;
    end
    if i ~= 8 && i ~= 16
        cur.bsize = i;
        if mpx < 0
            mpx = -mpx;
            cur.fmt = 8;
        else
            cur.fmt = 16;
        end
    else
        cur.fmt = i;
        cur.bsize = 0;
    end
    p = t.next(sep);
    if ischar(p)
        cur.adcres = wfdbx.internal.atoi(p);
    else
        cur.adcres = 0;     % wfdb-x: C (and legacy mode) assumed WFDB_DEFRES
        if wfdbx.wfdbx_get_legacy()
            cur.adcres = 12;    % WFDB_DEFRES
        end
    end
    p = t.next(sep);
    if ischar(p)
        cur.adczero = wfdbx.internal.atoi(p);
    else
        cur.adczero = 0;
    end
    li = li + 1;
    [t, p] = nexttok(lines, li, sep);
    if ~ischar(p)
        wfdbx.internal.wfdb_error('init: incorrect format in record %s header\n', record);
        return;
    end
    cur.initval = wfdbx.internal.atoi(p);
    p = t.next(sep);
    if ischar(p)
        ns = wfdbx.internal.strtol(p);
    else
        ns = 0;
    end
    if ns < 0
        wfdbx.internal.wfdb_error('init: incorrect format in record %s header\n', record);
        return;
    end
    if nsamples == 0
        nsamples = ns;
    elseif ns > 0 && ns ~= nsamples
        wfdbx.internal.wfdb_error('warning (init):\n');
        wfdbx.internal.wfdb_error(' record %s durations are inconsistent\n', record);
        if nsamples > ns
            nsamples = ns;
        end
    end
    p = t.next(sep);
    if ischar(p)
        cur.cksum = wfdbx.internal.atoi(p);
        cur.nsamp = ns;
    else
        cur.cksum = 0;
        cur.nsamp = 0;
    end
    si(end + 1) = cur; %#ok<AGROW>
    % while (++s < WFDB_MAXSIG && --mpx > 0): when s reaches WFDB_MAXSIG,
    % mpx is not decremented, so a record with exactly WFDB_MAXSIG
    % signals is rejected below (as in C).
    while true
        s = s + 1;
        if s >= WFDB_MAXSIG
            break;
        end
        mpx = mpx - 1;
        if mpx <= 0
            break;
        end
        si(end + 1) = si(end); %#ok<AGROW>
    end
    if s == WFDB_MAXSIG && (mpx > 0 || g < ng - 1)
        wfdbx.internal.wfdb_error('init: too many signals in record %s\n', record);
        return;
    end
    g = g + 1;
end
for k = 1:s
    si(k).desc = sprintf('record %s, signal %d', record, k - 1);
end
nsig = s;
end

function status = main(argv)
if numel(argv) < 2
    wfdbx.internal.ceprintf('usage: %s record\n', argv{1});
    wfdbx.internal.ceprintf(' This program converts obsolete-format header files into new ones.\n');
    status = 1;
    return;
end
record = argv{2};
if strncmp(record, 'header.', 7)
    record = record(8:end);
end
[nsig, si] = readoldheader(record);
if nsig < 0
    status = 2;
    return;
end
wfdbx.setheader(record, si, nsig);
status = 0;
end
