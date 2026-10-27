function wfdbx_note_write_error()
%WFDBX_NOTE_WRITE_ERROR Count a write error.
%   wfdbx.wfdbx_note_write_error() adds one to the count of write errors
%   (see wfdbx.wfdbx_write_errors): for an application that writes a file
%   itself and could not write or close it.
%
%   See also wfdbx.wfdbx_write_errors.
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

st = wfdbx.internal.io_state();
st.write_errors = st.write_errors + 1;
end
