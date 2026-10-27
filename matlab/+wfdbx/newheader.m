function stat = newheader(record)
%NEWHEADER Create a header file for the open output signals.
%   STAT = wfdbx.newheader(RECORD) writes RECORD.hea, describing the
%   output signals opened by osigopen/osigfopen and the samples written
%   so far (number of samples, checksums, initial values), with the
%   sampling frequency set by setsampfreq and the base time set by
%   setbasetime.  Returns 0, or -1 on error.
%
%   See also wfdbx.setheader, wfdbx.osigfopen, wfdbx.putinfo.
%
%   Translation of the C function newheader() (lib/signal.c, WFDB 10.7.0): same
%   arguments and results. Differences: a header written under a path names the
%   record and its signal files relative to its own directory, and only the
%   record's own name (the last component) is checked; see docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
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
record = wfdbx.internal.wfdb_striphea(record);
if S.nosig > 0
    osi = [S.osd(1:S.nosig).info];
else
    osi = wfdbx.siginfo(0);
end
stat = wfdbx.setheader(record, osi, S.nosig);
end
