function [prefix, ptype] = path_components(p)
%PATH_COMPONENTS Split a WFDB path string into its components.
%   [PREFIX, PTYPE] = wfdbx.internal.path_components(P) splits P as the C
%   library splits the WFDB path (components separated by white space or
%   ';', or by ':' other than in URLs) and returns the components (a cell
%   row of char, empty ones included) and their types (0 = WFDB_LOCAL, 1 =
%   WFDB_NET).  (wfdb-x: the scanner of wfdb_parse_path, which setwfdb
%   uses too.)
%
%   Part of the translation of lib/wfdbio.c (WFDB 10.7.0).

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: the scanner of wfdb_parse_path(), taken out so
% that setwfdb can use it. Each change is marked "wfdb-x:" in the code;
% docs/DIVERGENCES.md gives the reasons.
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

prefix = cell(1, 0);
ptype = zeros(1, 0);
if ischar(p)
    n = numel(p);
    q = 1;
    while q <= n
        while q <= n && any(p(q) == [' ' char([9 10 13])])   % space, \t \n \r
            q = q + 1;
        end
        start = q;
        q = q - 1;
        current_type = 0;
        slashes = 0;
        while true
            q = q + 1;
            if q <= n
                c = p(q);
            else
                c = char(0);
            end
            if c == ':'
                if q + 2 <= n && p(q+1) == '/' && p(q+2) == '/'
                    current_type = 1;
                elseif current_type ~= 1 || slashes > 2
                    break;
                end
            elseif any(c == [';' ' ' char([9 10 13 0])])   % separators, as in C
                break;
            elseif c == '/'
                slashes = slashes + 1;
            end
        end
        prefix{end+1} = p(start:q-1); %#ok<AGROW>
        ptype(end+1) = current_type; %#ok<AGROW>
        if q <= n
            q = q + 1;
        end
    end
end
end
