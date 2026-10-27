function wfdb_setirec(p)
%WFDB_SETIREC Save the current record name (for %r in the WFDB path).
%   wfdbx.internal.wfdb_setirec(P) saves the last component of the record
%   name P (unless it is '-'), truncated to WFDB_MAXRNL (50) characters.
%
%   Translation of the C function wfdb_setirec() (lib/wfdbio.c, WFDB
%   10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/wfdbio.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

k = find(p == '/', 1, 'last');
if ~isempty(k)
    p = p(k+1:end);
end
if ~strcmp(p, '-')
    st = wfdbx.internal.io_state();
    st.irec = p(1:min(end, 50));        % WFDB_MAXRNL
end
end
