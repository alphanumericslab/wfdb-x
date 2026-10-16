function s = seginfo(n)
%SEGINFO A WFDB_Seginfo structure (segment of a multi-segment record).
%   S = wfdbx.seginfo() returns a structure with the fields recname (''),
%   nsamp (0, the number of samples in the segment) and samp0 (0, the
%   sample number of its first sample).  S = wfdbx.seginfo(N) returns a
%   1-by-N array of such structures.
%
%   See also wfdbx.getseginfo.

% Copyright (C) 1983-2013 George B. Moody (original C header, lib/wfdb.h, which
% defines the structure; revised 2010-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if nargin < 1
    n = 1;
end
s = repmat(struct('recname', '', 'nsamp', 0, 'samp0', 0), 1, n);
end
