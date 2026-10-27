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
%   Example (old stands for a record with an obsolete-format header,
%   old.hea, in the current folder):
%       wfdbx.apps.revise({'old'})
%
%   See also wfdbx.apps.wfdbdesc, wfdbx.setheader.
%
%   Translation of the C program revise (convert/revise.c, WFDB 10.7.0):
%   same options and output. Differences: a missing ADC resolution stays
%   unspecified; see docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of convert/revise.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in ADC resolution: a missing resolution
% stays unspecified (the original assumed 12 bits); --legacy, as the first
% argument, restores the original behavior. Each change is marked "wfdb-x:" in
% the code; docs/DIVERGENCES.md gives the reasons.
%
% Original C program: convert/revise.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1999 George B. Moody; revised 2018 by Benjamin Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

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
