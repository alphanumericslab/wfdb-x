function stat = wfdb_oinfoclose()
%WFDB_OINFOCLOSE Close the .info file opened by setinfo (wfdb_oinfoclose).
%   STAT = wfdbx.internal.wfdb_oinfoclose() returns 0, or -2 on a write
%   error.
%
%   Translation of the C function wfdb_oinfoclose() (lib/signal.c, WFDB
%   10.7.0).

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

S = wfdbx.internal.sig_state();
stat = 0;
if ~isempty(S.outinfo) && ~S.outinfo_hdr
    errflag = S.outinfo.ferror();
    if S.outinfo.close()
        errflag = true;
    end
    if errflag
        wfdbx.internal.wfdb_error('setinfo: write error in info file\n');
        stat = -2;
    end
end
S.outinfo = [];
S.outinfo_hdr = false;
end
