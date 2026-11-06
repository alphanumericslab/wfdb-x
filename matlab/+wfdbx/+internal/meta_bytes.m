function data = meta_bytes(H)
%META_BYTES The bytes of a header parsed by wfdbx.internal.meta_parse.
%   DATA = wfdbx.internal.meta_bytes(H) joins the content and line ending
%   of each line of H (a char row; '' for a header without lines).
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

parts = [H.content; H.eol];
data = ['' parts{:}];
end
