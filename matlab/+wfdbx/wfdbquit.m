function wfdbquit()
%WFDBQUIT Close all WFDB files and reset the library.
%   wfdbx.wfdbquit() closes all annotation and signal files (writing any
%   buffered output and completing output files), and resets the library
%   state (the WFDB path is reset to its initial value).  Programs that
%   write files must call it (or wfdbx.wfdbflush) before they end.
%
%   See also wfdbx.wfdbflush, wfdbx.wfdbinit.

% Copyright (C) 1983-2012 George B. Moody (original C implementation,
% lib/wfdbinit.c; revised 2012-2019 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if wfdbx.internal.pkg_has('internal.wfdb_anclose')
    wfdbx.internal.wfdb_anclose();
end
wfdbx.internal.wfdb_oinfoclose();
wfdbx.internal.wfdb_sigclose();
wfdbx.resetwfdb();
wfdbx.internal.wfdb_sampquit();
wfdbx.internal.wfdb_freeinfo();
end
