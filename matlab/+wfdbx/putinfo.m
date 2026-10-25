function stat = putinfo(s)
%PUTINFO Write an info string.
%   STAT = wfdbx.putinfo(S) writes the info string S (as "#S" on a line of
%   its own) to the .info file opened by setinfo, or else to the header
%   file written last by setheader/newheader.  Returns 0, or -1 if there
%   is no such file.
%
%   See also wfdbx.getinfo, wfdbx.setinfo.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if isa(s, 'string')   % MATLAB string
    s = char(s);
end
S = wfdbx.internal.sig_state();
if isempty(S.outinfo)
    if ~isempty(S.oheader)
        S.outinfo = S.oheader;
        S.outinfo_hdr = true;
    else
        wfdbx.internal.wfdb_error('putinfo: caller has not specified a record name\n');
        stat = -1;
        return;
    end
end
S.outinfo.write(['#' s sprintf('\r\n')]);
S.outinfo.flush();
stat = 0;
end
