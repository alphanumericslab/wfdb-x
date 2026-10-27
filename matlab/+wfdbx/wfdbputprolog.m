function stat = wfdbputprolog(buf, size, s)
%WFDBPUTPROLOG Write a prolog to the signal file of an output signal.
%   STAT = wfdbx.wfdbputprolog(BUF, SIZE, S) writes the first SIZE bytes
%   of BUF (char or uint8) at the current position of the signal file of
%   output signal S, and records the prolog length for the header.
%   Returns 0, or -1 if not all bytes could be written.
%
%   See also wfdbx.wfdbsetstart.
%
%   Translation of the C function wfdbputprolog() (lib/signal.c, WFDB
%   10.7.0): same arguments and results.

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
g = S.osd(s + 1).info.group;
b = uint8(buf(1:min(end, size)));
n = S.ogd{g + 1}.fp.write(b);
wfdbx.wfdbsetstart(s, n);
if n ~= size
    wfdbx.internal.wfdb_error('wfdbputprolog: only %d of %d bytes written\n', n, size);
    stat = -1;
else
    stat = 0;
end
end
