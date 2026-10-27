function [nsig, si] = osigopen(record, nsig)
%OSIGOPEN Open output signals as specified by the header of a record.
%   [N, SI] = wfdbx.osigopen(RECORD, NSIG) opens the first NSIG output
%   signals described by the header of RECORD (the signal files named
%   there are created as output files: under the output directory, if
%   one is set).  Output signals open before are closed, unless RECORD
%   begins with '+'.  N is NSIG, or a negative value on error; SI
%   describes the signals opened.
%
%   wfdb-x: an output signal file is never one of the input files.  In
%   normal mode, if a signal file to be created is the same file as a
%   signal file of the open input record (one open for input, or one of
%   any segment of the open multi-segment record; the files are compared,
%   not their names: links and other spellings are recognized), it is
%   neither created nor truncated: the message "osigopen: output file NAME is
%   also an input file" is printed and -3 is returned, the input staying
%   open.  Legacy mode does not check (the original truncated the input).
%   This behavior is identical in all seven implementations of wfdb-x.
%
%   See also wfdbx.osigfopen, wfdbx.putvec, wfdbx.newheader.
%
%   Translation of the C function osigopen() (lib/signal.c, WFDB 10.7.0): same
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

if isa(record, 'string')   % MATLAB string
    record = char(record);
end
S = wfdbx.internal.sig_state();
si = wfdbx.siginfo(0);
if ~isempty(record) && record(1) == '+'
    record = record(2:end);
else
    wfdbx.internal.osigclose();
end
record = wfdbx.internal.wfdb_striphea(record);
n = wfdbx.internal.readheader(record);
if n < 0
    nsig = n;
    return;
end
if n < nsig
    wfdbx.internal.wfdb_error( ...
        'osigopen: record %s has fewer signals than needed\n', record);
    nsig = -3;
    return;
end
if nsig <= 0
    nsig = 0;
    return;
end
hsi = [S.hsd(1:nsig).info];
[nsig, si] = wfdbx.internal.openosig('osigopen', hsi, nsig);
end
