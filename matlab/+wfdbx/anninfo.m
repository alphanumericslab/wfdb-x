function ai = anninfo(name, stat)
%ANNINFO A WFDB_Anninfo structure (annotator name and file mode).
%   AI = wfdbx.anninfo(NAME, STAT) returns a structure with the fields
%   name (a char vector, e.g. 'atr', or [] for NULL) and stat (the file
%   mode: wfdbx.WFDB_READ() = 0, WFDB_WRITE = 1, WFDB_AHA_READ = 2,
%   WFDB_AHA_WRITE = 3).  The defaults are [] and WFDB_READ.
%
%   Example:
%       ai = [wfdbx.anninfo('atr', 0), wfdbx.anninfo('qrs', 0)];
%
%   See also wfdbx.annopen.
%
%   Translation of the C structure WFDB_Anninfo (lib/wfdb.h, WFDB 10.7.0):
%   same fields.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdb.h from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/wfdb.h, WFDB Software Package 10.7.0.
%   Copyright (C) 1983-2013 George B. Moody; revised 2010-2020 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin >= 1 && isa(name, 'string')   % MATLAB string
    name = char(name);
end
if nargin < 1
    name = [];
end
if nargin < 2
    stat = 0;
end
ai = struct('name', [], 'stat', stat);
ai.name = name;
end
