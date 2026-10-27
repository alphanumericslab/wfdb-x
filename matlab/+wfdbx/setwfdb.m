function setwfdb(p)
%SETWFDB Set the input directory (in legacy mode, the WFDB path).
%   wfdbx.setwfdb(P) sets the input directory (a C-compatible form of
%   wfdbx.wfdbx_set_input_dir): P is split into components as the WFDB
%   path is (at spaces, semicolons, and colons other than in URLs); it
%   must contain at most one non-empty component, which becomes the input
%   directory (a directory, a ~ name or a URL, taken literally); none
%   (e.g. '', ';' or []) restores the default.  With more than one, an
%   error message is printed and nothing changes: wfdb-x reads from a
%   single input directory.  wfdbx.resetwfdb restores the value set by the
%   last setwfdb.
%
%   In legacy mode, it sets the WFDB path to the char vector P (see
%   wfdbx.getwfdb); wfdbx.setwfdb([]) restores the path given by the
%   environment variable WFDB (or the default path).  As in C, the
%   environment variable WFDB is then set to P, and WFDBCAL, WFDBANNSORT
%   and WFDBGVMODE are set to their defaults if they are not set.
%
%   See also wfdbx.getwfdb, wfdbx.resetwfdb, wfdbx.wfdbx_set_input_dir.
%
%   Translation of the C function setwfdb() (lib/wfdbio.c, WFDB 10.7.0): same
%   arguments and results. Differences: it sets a single input directory (the
%   WFDB path in legacy mode); see docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: it sets a single input directory; files are not
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

if isa(p, 'string')   % MATLAB string
    p = char(p);
end
if ~wfdbx.wfdbx_get_legacy()    % wfdb-x: a single input directory
    c = wfdbx.internal.path_components(p);
    c = c(~cellfun('isempty', c));
    if numel(c) > 1
        wfdbx.internal.wfdb_error(['setwfdb: wfdb-x reads from a single ' ...
            'input directory; use wfdbx_set_input_dir (or legacy mode for ' ...
            'the WFDB search path)\n']);
        return;
    end
    d = [];
    if ~isempty(c)
        d = c{1};
    end
    st = wfdbx.internal.io_state();
    wfdbx.internal.put_input_dir(st, d);
    st.setwfdb_input_dir = d;
    st.setwfdb_called = true;
    return;
end
if ~ischar(p)
    p = wfdbx.internal.cgetenv('WFDB');
    if ~ischar(p)
        p = wfdbx.wfdbdefwfdb();
    end
end
setenv('WFDB', p);
if ~ischar(wfdbx.internal.cgetenv('WFDBCAL'))
    setenv('WFDBCAL', wfdbx.wfdbdefwfdbcal());
end
if ~ischar(wfdbx.internal.cgetenv('WFDBANNSORT'))
    setenv('WFDBANNSORT', '1');
end
if ~ischar(wfdbx.internal.cgetenv('WFDBGVMODE'))
    setenv('WFDBGVMODE', '0');
end
p = wfdbx.internal.getiwfdb(p);
st = wfdbx.internal.io_state();
st.wfdbpath = p;
wfdbx.internal.wfdb_parse_path(p);
end
