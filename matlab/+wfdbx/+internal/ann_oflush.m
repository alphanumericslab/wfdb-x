function oa = ann_oflush(oa)
%ANN_OFLUSH Write the buffered bytes of an output annotator to its file.
%   OA = wfdbx.internal.ann_oflush(OA) writes the bytes buffered by
%   wfdbx.putann for the output annotator structure OA (fields obuf,
%   olen) with OA.file.write, and empties the buffer.
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

if oa.olen > 0
    oa.file.write(oa.obuf(1:oa.olen));
    oa.olen = 0;
end
end
