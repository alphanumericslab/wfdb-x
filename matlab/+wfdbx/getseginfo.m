function segs = getseginfo()
%GETSEGINFO Segments of the open multi-segment record.
%   SEGS = wfdbx.getseginfo() returns a wfdbx.seginfo struct array (fields
%   recname, nsamp, samp0) describing the segments of the open
%   multi-segment record (empty if the record is not a multi-segment
%   record).
%
%   See also wfdbx.seginfo, wfdbx.setmsheader.
%
%   Translation of the C function getseginfo() (lib/signal.c, WFDB 10.7.0):
%   same arguments and results.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
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

S = wfdbx.internal.sig_state();
if isempty(S.segarray)
    segs = wfdbx.seginfo(0);
else
    segs = S.segarray;
end
end
