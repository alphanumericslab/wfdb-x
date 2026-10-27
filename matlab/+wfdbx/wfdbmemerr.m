function wfdbmemerr(behavior)
%WFDBMEMERR Set the behavior of the library on memory allocation errors.
%   wfdbx.wfdbmemerr(BEHAVIOR) is accepted for compatibility with C (where
%   BEHAVIOR 0 makes allocation errors return instead of aborting); memory
%   errors are MATLAB errors in WFDB-x.
%
%   See also wfdbx.wfdberror.
%
%   Translation of the C function wfdbmemerr() (lib/wfdbio.c, WFDB 10.7.0):
%   same arguments and results. Differences: it has no effect (memory errors
%   are MATLAB errors); see docs/DIVERGENCES.md.

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

st = wfdbx.internal.io_state();
st.mem_behavior = behavior;
end
