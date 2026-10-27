function p = output_file(name)
%OUTPUT_FILE The local file that an output file name designates.
%   P = wfdbx.internal.output_file(NAME) (WFDB-x) returns the name of the
%   local file that wfdb_open(NAME, [], WFDB_WRITE) creates in normal mode
%   (under the output directory, for a relative name), or [] if it creates
%   none (NAME empty, '-' for the standard output, or a URL).
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: this function is a WFDB-x addition: the local
% file that an output name designates, under the output directory.
%
% Original C code: lib/wfdbio.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

p = [];
if ~ischar(name) || isempty(name) || strcmp(name, '-')
    return;
end
r = wfdbx.internal.expand_record(name);
if wfdbx.internal.is_url(r)
    return;
end
p = wfdbx.internal.resolve_name(r, true);
end
