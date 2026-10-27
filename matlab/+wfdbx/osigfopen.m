function stat = osigfopen(si, nsig)
%OSIGFOPEN Open output signals as specified by signal descriptions.
%   N = wfdbx.osigfopen(SI) opens the output signals described by the
%   wfdbx.siginfo struct array SI (fields fname, desc, units, gain,
%   group, fmt, spf, bsize, adcres, adczero, baseline; the other fields
%   are ignored), closing any output signals open before.  Signals of the
%   same group (written in the same file) must be consecutive and have
%   the same file name.  N = wfdbx.osigfopen(SI, NSIG) opens the first
%   NSIG signals of SI.  Returns the number of signals opened, or a
%   negative value on error (and 0 if SI is empty).
%
%   wfdb-x: an output signal file is never one of the input files.  In
%   normal mode, if a signal file to be created is the same file as a
%   signal file of the open input record (one open for input, or one of
%   any segment of the open multi-segment record; the files are compared,
%   not their names: links and other spellings are recognized), it is
%   neither created nor truncated: the message "osigfopen: output file NAME is
%   also an input file" is printed and -3 is returned, the input staying
%   open.  Legacy mode does not check (the original truncated the input).
%   This behavior is identical in all seven implementations of wfdb-x.
%
%   Example:
%       si = wfdbx.siginfo(2);
%       [si.fname] = deal('out.dat'); [si.fmt] = deal(16);
%       wfdbx.osigfopen(si);
%       wfdbx.putvec([1 2]);
%       wfdbx.newheader('out');
%       wfdbx.wfdbquit();
%
%   See also wfdbx.osigopen, wfdbx.putvec, wfdbx.newheader.
%
%   Translation of the C function osigfopen() (lib/signal.c, WFDB 10.7.0): same
%   arguments and results. Differences: an output signal file that is one of
%   the input files of the open record is refused; see docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: an output signal file that is one of the files
% of the open input record is refused. Each change is marked "wfdb-x:" in
% the code; docs/DIVERGENCES.md gives the reasons.
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

stat = wfdbx.internal.osigclose();
if nargin < 2
    nsig = numel(si);
end
if isempty(si) || nsig == 0
    return;
end
S = wfdbx.internal.sig_state();
if S.obsize <= 0
    S.obsize = 8192;
end
fmtlist = [0 8 16 61 80 160 212 310 311 24 32 508 516 524];
for s = 1:nsig
    x = si(s);
    lf = 0;
    if ischar(x.fname)
        lf = numel(x.fname);
    end
    ld = 0;
    if ischar(x.desc)
        ld = numel(x.desc);
    end
    if lf + ld > 200 || x.bsize < 0    % (limit as in C) || ~any(x.fmt == fmtlist)
        wfdbx.internal.wfdb_error('osigfopen: error in specification of signal %d\n', s - 1);
        stat = -2;
        return;
    end
    if ~((s == 1 && x.group == 0) || ...
            (s > 1 && x.group == si(s - 1).group && ...
            wfdbx.internal.cstreq(x.fname, si(s - 1).fname)) || ...
            (s > 1 && x.group == si(s - 1).group + 1 && ...
            ~wfdbx.internal.cstreq(x.fname, si(s - 1).fname)))
        wfdbx.internal.wfdb_error( ...
            'osigfopen: incorrect file name or group for signal %d\n', s - 1);
        stat = -2;
        return;
    end
end
stat = wfdbx.internal.openosig('osigfopen', si, nsig);
end
