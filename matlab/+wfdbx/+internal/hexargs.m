function args = hexargs(hex)
%HEXARGS Decode command-line arguments passed as hexadecimal strings.
%   ARGS = wfdbx.internal.hexargs(HEX) converts a cell array of strings of
%   hexadecimal digits (two per byte, as written by `od -tx1`) into a cell
%   row of char vectors with those bytes.  bin/wfdbx_matlab.sh passes the
%   arguments of a tool to MATLAB this way, so that any bytes (quotes,
%   non-ASCII characters) arrive unchanged.
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

args = cell(1, numel(hex));
for k = 1:numel(hex)
    h = hex{k};
    if isempty(h)
        args{k} = '';
    else
        args{k} = char(hex2dec(reshape(h, 2, [])')');
    end
end
end
