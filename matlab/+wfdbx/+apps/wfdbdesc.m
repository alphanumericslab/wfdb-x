function status = wfdbdesc(args)
%WFDBDESC Describe the signals of a WFDB record.
%   STATUS = wfdbx.apps.wfdbdesc(ARGS) runs the wfdbdesc tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       wfdbdesc RECORD [-readable]
%
%   The record's starting time, length, sampling frequency, info strings
%   and the specifications of each signal are printed.  With -readable,
%   only the signals whose files can be read are described.
%
%   WFDB-x: if the header does not specify the sampling frequency, it is
%   printed as "not specified" and lengths are given in sample intervals
%   only; an uncalibrated signal's gain is printed as "uncalibrated",
%   unspecified units as "nd" and an unspecified ADC resolution as "not
%   specified" (the C program assumed 250 Hz, 200 adu/mV, millivolts and
%   12 bits); see docs/DIVERGENCES.md.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.apps.wfdbdesc({'100s'})
%
%   See also wfdbx.apps.sampfreq, wfdbx.read_header.
%
%   Translation of the C program wfdbdesc (app/wfdbdesc.c, WFDB 10.7.0):
%   same options and output. Differences: unspecified values are printed as
%   such, not assumed; see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of app/wfdbdesc.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original program, but it is new code, not the original C
% code.
%
% Changes from the original: no built-in sampling frequency, gain, ADC
% resolution or units: an unspecified sampling frequency or ADC resolution is
% shown as "not specified" (lengths are then given in sample intervals only), a
% gain of 0 as "uncalibrated" (the original: "uncalibrated; assume 200"), and
% unspecified units as "adu/nd" (the original assumed 250 Hz, 12 bits and
% millivolts); --legacy, as the first argument, restores the original behavior.
% Each change is marked "WFDB-x:" in the code; docs/DIVERGENCES.md gives the
% reasons.
%
% Original C program: app/wfdbdesc.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2012 George B. Moody; revised 2018-2020 by
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
status = wfdbx.internal.app_run(@main, [{'wfdbdesc'}, args]);
end

function status = main(argv)
pname = argv{1};
argc = numel(argv);
out = @wfdbx.internal.cout;
csp = @wfdbx.internal.csprintf;
msrec = 0;
if argc < 2
    wfdbx.internal.ceprintf('usage: %s RECORD [-readable]\n', pname);
    status = 1;
    return;
end
rec = argv{2};
nsig = wfdbx.isigopen(rec, 0);
if nsig < 0
    status = 2;
    return;
end
s = wfdbx.siginfo(0);
if nsig > 0 && argc > 2 && strncmp('-readable', argv{3}, numel(argv{3}))
    [nsig, s] = wfdbx.isigopen(rec, nsig);
elseif nsig > 0
    [nsig, s] = wfdbx.isigopen(rec, -nsig);
end
out(sprintf('Record %s', rec));
wfdbx.setgvmode(0);     % WFDB_LOWRES
t = wfdbx.strtim('e');
if nsig > 0 && (s(1).fmt == 0 || s(1).nsamp ~= 0) && s(1).nsamp ~= t
    msrec = 1;
    if s(1).nsamp == 0
        out(sprintf(' (a variable-layout multi-segment record)\n'));
    else
        out(sprintf(' (a fixed-layout multi-segment record)\n'));
        out(sprintf('----------------------------------------------\n'));
        out(sprintf('The following data apply to the entire record:\n'));
        out('----------------------------------------------');
    end
end
info = wfdbx.getinfo(rec);
if ischar(info)
    out(sprintf('\nNotes\n=====\n'));
    while ischar(info)
        out([info char(10)]);
        info = wfdbx.getinfo([]);
    end
    out(sprintf('=====\n'));
end
% WFDB-x: if the sampling frequency is not specified, times are not shown
% (the C program assumed 250 Hz).
freq = wfdbx.sampfreq([]);
legacy = wfdbx.wfdbx_get_legacy();
% WFDB-x: times are shown only if the frequency is known (legacy mode: in
% any case, as in the C program)
showtimes = freq > 0 || legacy;
if showtimes
    p = wfdbx.mstimstr(0);
else
    p = '';
end
if ~isempty(p) && p(1) == '['
    out(sprintf('\nStarting time: %s\n', p));
else
    out(sprintf('\nStarting time: not specified\n'));
end
out('Length: ');
done = false;
if ~showtimes && (nsig < 1 || t > 0)
    out(sprintf('%d sample intervals\n', t));
    done = true;
elseif nsig < 1 || t > 0
    if t > 0
        out(sprintf('%s (%d sample intervals)\n', wfdbx.mstimstr(t), t));
    else
        out(sprintf('0 (%d sample intervals)\n', t));
    end
    done = true;
elseif s(1).fmt
    nbytes = file_size(s(1).fname);
    if ~isempty(nbytes)
        nbytes = nbytes - wfdbx.wfdbgetstart(0);
        framesize = 0;
        for k = 1:nsig
            if s(k).group ~= 0
                break;
            end
            framesize = framesize + s(k).spf;
        end
        switch s(1).fmt
            case {8, 80}
                t = fix(nbytes / framesize);
            case {16, 61, 160}
                t = fix(nbytes / (2 * framesize));
            case 24
                t = fix(nbytes / (3 * framesize));
            case 32
                t = fix(nbytes / (4 * framesize));
            case 212
                t = fix(2 * nbytes / (3 * framesize));
            case {310, 311}
                t = fix(3 * nbytes / (4 * framesize));
            otherwise
                t = -1;
        end
        if t >= 0 && ~showtimes
            out(sprintf('%d sample intervals [from signal file size]\n', t));
        elseif t >= 0
            out(sprintf('%s (%d sample intervals) [from signal file size]\n', ...
                wfdbx.mstimstr(t), t));
        else
            out(sprintf('not specified\n'));
        end
        done = true;
    end
end
if ~done
    out(sprintf('not specified\n'));
end
if showtimes
    out(['Sampling frequency: ' csp('%.12g', freq) sprintf(' Hz\n')]);
else
    out(sprintf('Sampling frequency: not specified\n'));
end
if nsig == 1
    out(sprintf('%d signal\n', nsig));
else
    out(sprintf('%d signals\n', nsig));
end
if nsig < 1
    status = 2;
    return;
end
if msrec && s(1).nsamp ~= 0
    out(sprintf('----------------------------------------------\n'));
    out(sprintf('The following data apply to the first segment:\n'));
    out(sprintf('----------------------------------------------\n'));
    if showtimes
        out(sprintf('Segment length: %s (%d sample intervals)\n', ...
            wfdbx.mstimstr(s(1).nsamp), s(1).nsamp));
    else
        out(sprintf('Segment length: %d sample intervals\n', s(1).nsamp));
    end
end
for i = 1:nsig
    si = s(i);
    out(sprintf('Group %d, Signal %d:\n', si.group, i - 1));
    if si.fmt
        out(sprintf(' File: %s\n', si.fname));
    else
        out(sprintf(' File: [none]\n'));
    end
    out(sprintf(' Description: %s\n', cstr(si.desc)));
    out(' Gain: ');
    if legacy               % WFDB-x: legacy mode: as in the C program
        if si.gain == 0
            out(['uncalibrated; assume ' csp('%g', 200)]);   % WFDB_DEFGAIN
        else
            out(csp('%.12g', si.gain));
        end
        if ischar(si.units)
            out(sprintf(' adu/%s\n', si.units));
        else
            out(sprintf(' adu/mV\n'));
        end
    elseif si.gain == 0     % WFDB-x: no default gain
        out(sprintf('uncalibrated\n'));
    elseif ischar(si.units)
        out([csp('%.12g', si.gain) sprintf(' adu/%s\n', si.units)]);
    else
        % WFDB-x: unspecified units are shown as "nd" (C assumed mV)
        out([csp('%.12g', si.gain) sprintf(' adu/nd\n')]);
    end
    out(sprintf(' Initial value: %d\n', si.initval));
    if si.fmt ~= 0
        out(sprintf(' Storage format: %d', si.fmt));
    end
    if si.spf > 1
        out(sprintf(' (%d samples per frame)', si.spf));
    end
    if si.fmt ~= 0 || si.spf > 1
        out(char(10));
    end
    out(' I/O: ');
    if si.bsize == 0
        out(sprintf('can be unbuffered\n'));
    else
        out(sprintf('%d-byte blocks\n', si.bsize));
    end
    if si.adcres > 0 || legacy
        out(sprintf(' ADC resolution: %d bits\n', si.adcres));
    else                    % WFDB-x: no default resolution
        out(sprintf(' ADC resolution: not specified\n'));
    end
    out(sprintf(' ADC zero: %d\n', si.adczero));
    out(sprintf(' Baseline: %d\n', si.baseline));
    if si.nsamp > 0
        out(sprintf(' Checksum: %d\n', si.cksum));
    end
end
status = 0;
end

function s = cstr(s)
if ~ischar(s)
    s = '(null)';
end
end

function n = file_size(name)
% Size of the regular file NAME (relative to the current directory), or [].
n = [];
if ~ischar(name) || isempty(name) || any(name == '*') || any(name == '?')
    return;
end
if isfolder(name)
    return;
end
d = dir(name);
if numel(d) == 1 && ~d.isdir
    n = d.bytes;
end
end
