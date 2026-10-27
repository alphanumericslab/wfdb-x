function opt = hl_options(opt, args, fname)
%HL_OPTIONS Parse name-value pairs (high-level API).
%   OPT = wfdbx.internal.hl_options(OPT, ARGS, FNAME) sets the fields of
%   the structure OPT (the defaults) from the name-value pairs of the cell
%   ARGS (names are case-insensitive and must be fields of OPT).  MATLAB
%   strings are converted to char (wfdbx.internal.strarg).  Errors
%   mention FNAME.
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

if mod(numel(args), 2) ~= 0
    error(['wfdbx:' fname], '%s: options must be name-value pairs', fname);
end
for k = 1:2:numel(args)
    name = wfdbx.internal.strarg(args{k});
    if ~ischar(name) || ~isfield(opt, lower(name))
        if ischar(name)
            error(['wfdbx:' fname], '%s: unknown option ''%s''', fname, name);
        end
        error(['wfdbx:' fname], '%s: option names must be strings', fname);
    end
    opt.(lower(name)) = wfdbx.internal.strarg(args{k + 1});
end
end
