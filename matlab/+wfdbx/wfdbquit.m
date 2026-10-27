function wfdbquit()
%WFDBQUIT Close all WFDB files and reset the library.
%   wfdbx.wfdbquit() closes all annotation and signal files (writing any
%   buffered output and completing output files), and resets the library
%   state.  The input and output directories are left as they are
%   (WFDB-x; in legacy mode, the WFDB path is reset to its initial value,
%   as by wfdbx.resetwfdb).  Programs that
%   write files must call it (or wfdbx.wfdbflush) before they end.
%
%   See also wfdbx.wfdbflush, wfdbx.wfdbinit.
%
%   Translation of the C function wfdbquit() (lib/wfdbinit.c, WFDB 10.7.0):
%   same arguments and results. Differences: the input and output directories
%   are kept (the WFDB path is restored only in legacy mode); see
%   docs/DIVERGENCES.md.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbinit.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: the input and output directories are left as
% they are (resetwfdb is called only in legacy mode). Each change is marked
% "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
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

if wfdbx.internal.pkg_has('internal.wfdb_anclose')
    wfdbx.internal.wfdb_anclose();
end
wfdbx.internal.wfdb_oinfoclose();
wfdbx.internal.wfdb_sigclose();
if wfdbx.wfdbx_get_legacy()     % wfdb-x: only in legacy mode
    wfdbx.resetwfdb();
end
wfdbx.internal.wfdb_sampquit();
wfdbx.internal.wfdb_freeinfo();
end
