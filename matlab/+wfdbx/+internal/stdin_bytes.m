function b = stdin_bytes()
%STDIN_BYTES The complete standard input, as a uint8 row vector.
%   B = wfdbx.internal.stdin_bytes() reads the standard input to its end on
%   the first call and returns its bytes; later calls return the same bytes
%   (the standard input is read only once per session).
%
%   If the environment variable WFDBX_STDIN is set, the file it names is
%   read instead (MATLAB cannot read its standard input: the MATLAB driver
%   bin/wfdbx_matlab.sh saves the standard input to such a file).  In MATLAB
%   without WFDBX_STDIN, the standard input is empty.
%
%   See also wfdbx.internal.fgets_lines, wfdbx.internal.WFDBFile.
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

persistent data
if isempty(data)
    name = getenv('WFDBX_STDIN');
    if ~isempty(name)
        fid = fopen(name, 'rb');
        if fid >= 0
            data = fread(fid, Inf, 'uint8=>uint8')';
            fclose(fid);
        end
    elseif wfdbx.internal.is_octave()
        data = fread(0, Inf, 'uint8=>uint8')';
    end
    if isempty(data)
        data = zeros(1, 0, 'uint8');
    end
end
b = data;
end
