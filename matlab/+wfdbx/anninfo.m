function ai = anninfo(name, stat)
%ANNINFO A WFDB_Anninfo structure (annotator name and file mode).
%   AI = wfdbx.anninfo(NAME, STAT) returns a structure with the fields
%   name (a char vector, e.g. 'atr', or [] for NULL) and stat (the file
%   mode: wfdbx.WFDB_READ() = 0, WFDB_WRITE = 1, WFDB_AHA_READ = 2,
%   WFDB_AHA_WRITE = 3).  The defaults are [] and WFDB_READ.
%
%   Example:
%       ai = [wfdbx.anninfo('atr', 0), wfdbx.anninfo('qrs', 0)];
%
%   See also wfdbx.annopen.

% Copyright (C) 1983-2013 George B. Moody (original C header, lib/wfdb.h, which
% defines the structure; revised 2010-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if nargin >= 1 && isa(name, 'string')   % MATLAB string
    name = char(name);
end
if nargin < 1
    name = [];
end
if nargin < 2
    stat = 0;
end
ai = struct('name', [], 'stat', stat);
ai.name = name;
end
