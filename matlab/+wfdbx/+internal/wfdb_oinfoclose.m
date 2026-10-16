function stat = wfdb_oinfoclose()
%WFDB_OINFOCLOSE Close the .info file opened by setinfo (wfdb_oinfoclose).
%   STAT = wfdbx.internal.wfdb_oinfoclose() returns 0, or -2 on a write
%   error.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sigstate();
stat = 0;
if ~isempty(S.outinfo) && ~S.outinfo_hdr
    errflag = S.outinfo.ferror();
    if S.outinfo.close()
        errflag = true;
    end
    if errflag
        wfdbx.internal.wfdb_error('setinfo: write error in info file\n');
        stat = -2;
    end
end
S.outinfo = [];
S.outinfo_hdr = false;
end
