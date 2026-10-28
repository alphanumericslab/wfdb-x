% bench.m: benchmark driver for the MATLAB/Octave implementation of WFDB-x.
%
%     octave-cli --no-gui --norc -q benchmarks/matlab/bench.m OP DATADIR REPS
%
% Adds matlab/ to the path and runs wfdbx_bench(OP, DATADIR, REPS), which
% prints one JSON line (see benchmarks/README.md); exits with its status.
% In MATLAB, call wfdbx_bench directly.
%
% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

% (no command history: Octave would save it under the home directory)
history_save(false);
here = fileparts(mfilename('fullpath'));
addpath(here);
addpath(fullfile(fileparts(fileparts(here)), 'matlab'));
args = argv();
if numel(args) ~= 3
    fprintf(2, 'usage: bench.m OP DATADIR REPS\n');
    exit(2);
end
exit(wfdbx_bench(args{1}, args{2}, str2double(args{3})));
