function wfdb_error(fmt, varargin)
%WFDB_ERROR Report an error as the WFDB library does (printf-style).
%   wfdbx.wfdb_error(FMT, A1, A2, ...) formats the message as C printf
%   does, saves it (it is then returned by wfdbx.wfdberror) and writes it
%   to the standard error output unless wfdbx.wfdbquiet() is in effect.
%   FMT is a C format: '\n' stands for a newline, as in C string literals.
%
%   Example:
%       wfdbx.wfdb_error('myapp: can''t read record %s\n', '100s');
%
%   See also wfdbx.wfdberror, wfdbx.wfdbquiet, wfdbx.wfdbverbose.
%
%   Translation of the C function wfdb_error() (lib/wfdbio.c, WFDB 10.7.0):
%   same arguments and results.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
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

fmt = wfdbx.internal.strarg(fmt);
for k = 1:numel(varargin)
    if isa(varargin{k}, 'string')
        varargin{k} = char(varargin{k});
    end
end
wfdbx.internal.wfdb_error(fmt, varargin{:});
end
