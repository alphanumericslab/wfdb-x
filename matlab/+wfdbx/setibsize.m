function n = setibsize(n)
%SETIBSIZE Set the size of the input buffers.
%   N = wfdbx.setibsize(N) sets the default input buffer size (bytes; 0
%   for the default, 8192).  Must be called before isigopen.  Returns the
%   size set, or -1 (signals already open) or -2 (N < 0).
%
%   See also wfdbx.setobsize, wfdbx.isigopen.
%
%   Translation of the C function setibsize() (lib/signal.c, WFDB 10.7.0):
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
if S.nisig
    wfdbx.internal.wfdb_error('setibsize: can''t change buffer size after isigopen\n');
    n = -1;
    return;
end
if n < 0
    wfdbx.internal.wfdb_error('setibsize: illegal buffer size %d\n', n);
    n = -2;
    return;
end
if n == 0
    n = 8192;
end
S.ibsize = n;
end
