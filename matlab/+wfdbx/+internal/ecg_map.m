function m = ecg_map()
%ECG_MAP The annotation mapping tables (a wfdbx.internal.EcgMap object).
%   M = wfdbx.internal.ecg_map() returns the handle object holding the
%   tables used by wfdbx.isqrs, wfdbx.map1, wfdbx.map2 and wfdbx.annpos.
%   For speed in loops, read the table once, e.g. q = m.qrs; then
%   q(code + 1) for valid codes (1 to 49).

% Copyright (C) 1999 George B. Moody (original C header, lib/ecgmap.h).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

persistent s
if isempty(s)
    s = wfdbx.internal.EcgMap();
end
m = s;
end
