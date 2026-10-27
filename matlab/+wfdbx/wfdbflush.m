function wfdbflush()
%WFDBFLUSH Write all buffered output annotations and samples.
%   wfdbx.wfdbflush() writes any buffered output annotations and samples
%   to their files (the files remain open).
%
%   See also wfdbx.wfdbquit.
%
%   Translation of the C function wfdbflush() (lib/wfdbinit.c, WFDB 10.7.0):
%   same arguments and results.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
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

if wfdbx.internal.pkg_has('internal.wfdb_oaflush')
    wfdbx.internal.wfdb_oaflush();
end
wfdbx.internal.wfdb_osflush();
end
