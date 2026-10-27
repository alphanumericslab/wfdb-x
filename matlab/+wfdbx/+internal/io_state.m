function st = io_state()
%IO_STATE The global state of the WFDB I/O layer (a wfdbx.internal.IOState).
%   ST = wfdbx.internal.io_state() returns the handle object that holds the
%   WFDB path, the error reporting state and the name of the last file
%   opened.  It is created on the first call.
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

persistent s
if isempty(s)
    s = wfdbx.internal.IOState();
end
st = s;
end
