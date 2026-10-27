function n = wfdbx_write_errors()
%WFDBX_WRITE_ERRORS Number of write errors since the program started.
%   N = wfdbx.wfdbx_write_errors() returns the number of output files that
%   the library could not write, flush or close (found when they are
%   closed, as by wfdbx.wfdbquit), the standard output among them when it
%   is written as a WFDB file ('-'), plus the errors reported with
%   wfdbx.wfdbx_note_write_error.  Counting has no other effect.  The
%   high-level writers (wfdbx.write_record, wfdbx.write_annotations) raise
%   an error when they meet one, and the command-line tools then exit with
%   status 1.
%
%   Example:
%       n = wfdbx.wfdbx_write_errors();
%       % ... write a record ...
%       wfdbx.wfdbquit();
%       if wfdbx.wfdbx_write_errors() > n, error('not written'); end
%
%   See also wfdbx.wfdbx_note_write_error, wfdbx.wfdbquit.
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

% wfdb-x: write errors.  Decided by Reza Sameni, Oct 2026: a program must not
% report success when its output was not written.
st = wfdbx.internal.io_state();
n = st.write_errors;
end
