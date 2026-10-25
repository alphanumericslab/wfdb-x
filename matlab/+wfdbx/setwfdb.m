function setwfdb(p)
%SETWFDB Change the WFDB path.
%   wfdbx.setwfdb(P) sets the WFDB path to the char vector P (see
%   wfdbx.getwfdb).  wfdbx.setwfdb([]) restores the path given by the
%   environment variable WFDB (or the default path).  As in C, the
%   environment variable WFDB is set to P, and WFDBCAL, WFDBANNSORT and
%   WFDBGVMODE are set to their defaults if they are not set.
%
%   See also wfdbx.getwfdb, wfdbx.resetwfdb.

% Copyright (C) 1988-2013 George B. Moody (original C implementation,
% lib/wfdbio.c; revised 2010-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if isa(p, 'string')   % MATLAB string
    p = char(p);
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
