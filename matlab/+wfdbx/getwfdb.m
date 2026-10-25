function p = getwfdb()
%GETWFDB The WFDB path.
%   P = wfdbx.getwfdb() returns the WFDB path: the list of directories (and
%   URL prefixes) searched for WFDB files, separated by spaces or
%   semicolons.  On the first call it is taken from the environment variable
%   WFDB, or is the default '. /usr/local/database
%   http://physionet.org/physiobank/database' if WFDB is not set.  A path
%   of the form @FILE is replaced by the contents of FILE (up to 10 levels).
%   URL components (http://, https://) are accepted in the path but are
%   not searched: wfdb-x reads local files only.
%
%   See also wfdbx.setwfdb, wfdbx.resetwfdb, wfdbx.wfdbfile.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

st = wfdbx.internal.io_state();
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
