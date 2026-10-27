function [ffreq, i, ok] = opt_ffreq(argv, i, ffreq)
%OPT_FFREQ Parse the -F FREQ option of the annotation tools (wfdb-x).
%   [FFREQ, I, OK] = wfdbx.internal.opt_ffreq(ARGV, I, FFREQ) parses the
%   argument that follows the -F option at ARGV{I+1} (ARGV{K+1} is C's
%   argv[K]), as rdann, ann2rr, sortann, m2a and a2m do:
%       if (++i >= argc || sscanf(argv[i], "%lf", &Ffreq) != 1 ||
%           Ffreq <= 0.) error
%   I is advanced past the option.  If the frequency is missing or not
%   > 0, "PNAME: sampling frequency (> 0) must follow -F" is printed and
%   OK is false (the tool then exits with status 1).  The -F option is a
%   wfdb-x addition: there is no default sampling frequency (see
%   docs/DIVERGENCES.md).
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package. wfdb-x never assumes a
% sampling frequency, gain, ADC resolution or units (see
% docs/DIVERGENCES.md).
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

ok = false;
i = i + 1;
if i < numel(argv)
    [n, v] = wfdbx.internal.csscanf(argv{i + 1}, '%lf');
    if n == 1
        ffreq = v{1};
        ok = ~(ffreq <= 0);
    end
end
if ~ok
    wfdbx.internal.ceprintf('%s: sampling frequency (> 0) must follow -F\n', ...
        argv{1});
end
end
