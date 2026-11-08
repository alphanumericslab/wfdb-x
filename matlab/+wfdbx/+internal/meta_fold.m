function k = meta_fold(k)
%META_FOLD A metadata key with the letters A-Z changed to a-z.
%   K = wfdbx.internal.meta_fold(K) changes only the ASCII letters A-Z (no
%   other character: 'É' and 'é' differ), so that keys are compared
%   without regard to letter case as in the other implementations.
%   (upper and lower are not used: MATLAB's also convert Latin-1 letters.)
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU Lesser General Public License as published by
% the Free Software Foundation, either version 2.1 of the License, or (at
% your option) any later version. See LICENSE.

u = k >= 'A' & k <= 'Z';
k(u) = char(k(u) + 32);
end
