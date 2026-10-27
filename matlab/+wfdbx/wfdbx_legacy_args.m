function [r, argv] = wfdbx_legacy_args(argv)
%WFDBX_LEGACY_ARGS Recognize --legacy as the first argument of a tool.
%   [R, ARGV] = wfdbx.wfdbx_legacy_args(ARGV), where ARGV is a tool's
%   argument list as a cell row of char vectors with the program name
%   first (C's argv), checks whether the first argument after the program
%   name, ARGV{2}, is exactly '--legacy'.  If so, it removes it from ARGV
%   (the program name stays first), turns legacy mode on (see
%   wfdbx.wfdbx_set_legacy) and returns R = 1; the tool then behaves
%   exactly as the original one.  Otherwise ARGV is returned unchanged and
%   R = 0.  Only the first argument is recognized.  Every tool calls this
%   function (through wfdbx.internal.app_run) before anything else.  This
%   function is a WFDB-x addition.
%
%   Example (only the arguments are examined; no record is read):
%       [r, argv] = wfdbx.wfdbx_legacy_args({'rdsamp', '--legacy', '-r', '100s'})
%       % r = 1, argv = {'rdsamp', '-r', '100s'}
%
%   See also wfdbx.wfdbx_set_legacy, wfdbx.wfdbx_get_legacy.
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

r = 0;
if numel(argv) < 2 || ~ischar(argv{2}) || ~strcmp(argv{2}, '--legacy')
    return;
end
argv(2) = [];
wfdbx.wfdbx_set_legacy(1);
r = 1;
end
