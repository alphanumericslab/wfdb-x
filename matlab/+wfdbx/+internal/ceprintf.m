function ceprintf(fmt, varargin)
%CEPRINTF C fprintf(stderr, ...): formatted output to the standard error.
%   wfdbx.internal.ceprintf(FMT, A1, A2, ...) is the same as
%   wfdbx.internal.cerr(wfdbx.internal.csprintf(FMT, A1, A2, ...)).
%
%   See also wfdbx.internal.csprintf, wfdbx.internal.cerr.
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

wfdbx.internal.cerr(wfdbx.internal.csprintf(fmt, varargin{:}));
end
