function previous = wfdbx_set_legacy(on)
%WFDBX_SET_LEGACY Turn legacy mode on or off.
%   PREVIOUS = wfdbx.wfdbx_set_legacy(ON) turns legacy mode on if ON is true
%   and off otherwise.  PREVIOUS is the previous setting (1: on, 0: off).
%   Legacy mode is off by default.
%
%   In legacy mode, the library behaves exactly as the original WFDB
%   library, including its assumed signal parameters and its search for
%   files.  Use it only to reproduce old results.  docs/DIVERGENCES.md
%   describes what changes in legacy mode.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository; in legacy mode, the WFDB path, set by wfdbx.setwfdb,
%   says where records are found):
%       old = wfdbx.wfdbx_set_legacy(1);
%       wfdbx.setwfdb('/path/to/wfdb-x/tests/data');
%       rec = wfdbx.read_record('100s');   % read as the original package
%       wfdbx.wfdbx_set_legacy(old);
%
%   See also wfdbx.wfdbx_get_legacy.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

S = wfdbx.internal.sig_state();
previous = S.legacy_mode;
S.legacy_mode = double(logical(on));
end
