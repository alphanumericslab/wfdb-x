function c = hl_legacy(on, fname)
%HL_LEGACY Set the library's legacy mode for one high-level call.
%   C = wfdbx.internal.hl_legacy(ON, FNAME), where ON is the 'legacy'
%   option of the high-level function FNAME (a logical scalar; an error is
%   thrown otherwise): if ON is true, it turns the library's legacy mode
%   (wfdbx.wfdbx_set_legacy) on and returns an onCleanup object that
%   restores the previous setting when it is cleared, i.e. when the
%   calling function returns or throws an error.  If ON is false, the
%   library's setting is left as it is (C = []); if that setting is on,
%   the high-level functions behave as with ON true.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if ~((islogical(on) || isnumeric(on)) && isscalar(on))
    error(['wfdbx:' fname], '%s: legacy must be true or false', fname);
end
c = [];
if on
    previous = wfdbx.wfdbx_set_legacy(1);
    c = onCleanup(@() wfdbx.wfdbx_set_legacy(previous));
end
end
