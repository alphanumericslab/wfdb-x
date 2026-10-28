function f = sampfreq(record)
%SAMPFREQ Sampling frequency of a record.
%   F = wfdbx.sampfreq(RECORD) reads the header of RECORD and returns its
%   sampling frequency (in Hz); a negative value if the header cannot be
%   read, and 0 if the header does not specify it (WFDB-x: C assumed
%   250 Hz; see docs/DIVERGENCES.md).  F = wfdbx.sampfreq([]) returns the
%   sampling frequency of the currently open record (as modified by
%   setgvmode/setsampfreq).
%
%   See also wfdbx.setsampfreq, wfdbx.getifreq.
%
%   Translation of the C function sampfreq() (lib/signal.c, WFDB 10.7.0): same
%   arguments and results. Differences: it returns 0, not 250, if the header
%   gives no sampling frequency; see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: it returns 0 when the header gives no sampling
% frequency (the C library assumed 250 Hz). Each change is marked "WFDB-x:"
% in the code; docs/DIVERGENCES.md gives the reasons.
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

if nargin >= 1 && isa(record, 'string')   % MATLAB string
    record = char(record);
end
if nargin < 1
    record = [];
end
S = wfdbx.internal.sig_state();
record = wfdbx.internal.wfdb_striphea(record);
if ischar(record)
    wfdbx.internal.wfdb_setirec(record);
    wfdbx.setsampfreq(0);
    n = wfdbx.internal.readheader(record);
    if n < 0
        f = n;
        return;
    end
end
f = S.sfreq;
end
