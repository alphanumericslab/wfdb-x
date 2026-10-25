function segs = getseginfo()
%GETSEGINFO Segments of the open multi-segment record.
%   SEGS = wfdbx.getseginfo() returns a wfdbx.seginfo struct array (fields
%   recname, nsamp, samp0) describing the segments of the open
%   multi-segment record (empty if the record is not a multi-segment
%   record).
%
%   See also wfdbx.seginfo, wfdbx.setmsheader.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

S = wfdbx.internal.sig_state();
if isempty(S.segarray)
    segs = wfdbx.seginfo(0);
else
    segs = S.segarray;
end
end
