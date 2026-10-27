function p = getwfdb()
%GETWFDB The input directory (in legacy mode, the WFDB path).
%   P = wfdbx.getwfdb() returns the input directory (see
%   wfdbx.wfdbx_set_input_dir), or '.' if none is set.  wfdb-x: files are
%   not searched for.
%
%   In legacy mode, it returns the WFDB path: the list of directories (and
%   URL prefixes) searched for WFDB files, separated by spaces or
%   semicolons.  On the first call it is taken from the environment
%   variable WFDB, or is the default '. /usr/local/database
%   http://physionet.org/physiobank/database' if WFDB is not set.  A path
%   of the form @FILE is replaced by the contents of FILE (up to 10
%   levels).  URL components (http://, https://) are accepted in the path
%   but are not searched (legacy mode reads local files only).
%
%   See also wfdbx.setwfdb, wfdbx.resetwfdb, wfdbx.wfdbfile,
%   wfdbx.wfdbx_set_input_dir.
%
%   Translation of the C function getwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
%   arguments and results. Differences: it returns the input directory (the
%   WFDB path in legacy mode); see docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: it returns the input directory; files are not
% searched for (the WFDB path only in legacy mode). Each change is marked
% "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
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
if ~wfdbx.wfdbx_get_legacy()    % wfdb-x: the input directory
    wfdbx.internal.init_input_dir(st);
    p = st.input_dir;
    if ~ischar(p) || isempty(p)
        p = '.';
    end
    return;
end
if ~ischar(st.wfdbpath)
    p = wfdbx.internal.cgetenv('WFDB');
    if ~ischar(p)
        p = wfdbx.wfdbdefwfdb();
    end
    p = wfdbx.internal.getiwfdb(p);
    st.wfdbpath = p;
    st.wfdbpath_init = p;
    wfdbx.internal.wfdb_parse_path(p);
end
p = st.wfdbpath;
end
