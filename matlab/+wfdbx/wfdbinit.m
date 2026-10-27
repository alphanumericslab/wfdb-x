function [stat, si] = wfdbinit(record, aiarray, nann, nsig)
%WFDBINIT Open the annotation files and input signals of a record.
%   [STAT, SI] = wfdbx.wfdbinit(RECORD, AIARRAY, NANN, NSIG) calls
%   wfdbx.annopen(RECORD, AIARRAY, NANN) and, if it succeeds,
%   [STAT, SI] = wfdbx.isigopen(RECORD, NSIG).
%
%   See also wfdbx.annopen, wfdbx.isigopen, wfdbx.wfdbquit.
%
%   Translation of the C function wfdbinit() (lib/wfdbinit.c, WFDB 10.7.0):
%   same arguments and results. Differences: those of annopen() and isigopen();
%   see docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbinit.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/wfdbinit.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1983-2012 George B. Moody; revised 2012-2019 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

si = wfdbx.siginfo(0);
stat = wfdbx.annopen(record, aiarray, nann);
if stat == 0
    [stat, si] = wfdbx.isigopen(record, nsig);
end
end
