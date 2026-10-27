function [P, i, ok] = opt_sigparam(argv, i, P)
%OPT_SIGPARAM Parse a -F, -G, -R or -U option of the signal converters.
%   [P, I, OK] = wfdbx.internal.opt_sigparam(ARGV, I, P) parses the
%   option ARGV{I+1} (ARGV{K+1} is C's argv[K]; one of -F, -G, -R, -U)
%   and the argument that follows it, as ad2m, ahaecg2mit and wav2mit do,
%   and stores the value in the structure P (fields F, G, Gset, R, U, as
%   made by wfdbx.internal.sigparams):
%       -F FREQ   sampling frequency, > 0 ("sampling frequency (> 0) must
%                 follow -F")
%       -G GAIN   gain in adu per physical unit, >= 0 ("gain (>= 0) must
%                 follow -G"); sets P.Gset
%       -R BITS   ADC resolution, 1-32 ("ADC resolution (1-32 bits) must
%                 follow -R")
%       -U UNITS  units ("units must follow -U")
%   I is advanced past the argument.  If it is missing or invalid, the
%   message "PNAME: ..." is printed and OK is false (the tool then exits
%   with status 1).  These options are wfdb-x additions: there are no
%   built-in signal parameters (see docs/DIVERGENCES.md).
%
%   See also wfdbx.internal.sigparams, wfdbx.internal.opt_ffreq.
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

c = argv{i + 1}(2);
pname = argv{1};
ok = false;
i = i + 1;
have = i < numel(argv);
switch c
    case 'F'
        if have
            [n, v] = wfdbx.internal.csscanf(argv{i + 1}, '%lf');
            if n == 1
                P.F = v{1};
                ok = ~(P.F <= 0);
            end
        end
        if ~ok
            wfdbx.internal.ceprintf( ...
                '%s: sampling frequency (> 0) must follow -F\n', pname);
        end
    case 'G'
        if have
            [n, v] = wfdbx.internal.csscanf(argv{i + 1}, '%lf');
            if n == 1
                P.G = v{1};
                ok = ~(P.G < 0);
            end
        end
        if ~ok
            wfdbx.internal.ceprintf('%s: gain (>= 0) must follow -G\n', pname);
        end
        P.Gset = 1;
    case 'R'
        if have
            [n, v] = wfdbx.internal.csscanf(argv{i + 1}, '%d');
            if n == 1
                P.R = wfdbx.internal.cint32(v{1});
                ok = P.R >= 1 && P.R <= 32;
            end
        end
        if ~ok
            wfdbx.internal.ceprintf( ...
                '%s: ADC resolution (1-32 bits) must follow -R\n', pname);
        end
    otherwise   % 'U'
        if have
            P.U = argv{i + 1};
            ok = true;
        else
            wfdbx.internal.ceprintf('%s: units must follow -U\n', pname);
        end
end
end
