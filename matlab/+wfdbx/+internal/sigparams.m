function [P, ok] = sigparams(pname, P, which)
%SIGPARAMS Signal parameters of the converters (-F, -G, -R, -U).
%   P = wfdbx.internal.sigparams() returns the structure of unspecified
%   parameters (F = 0, G = 0, Gset = 0, R = 0, U = []) that
%   wfdbx.internal.opt_sigparam fills.
%
%   [P, OK] = wfdbx.internal.sigparams(PNAME, P, WHICH) checks that the
%   parameters named in WHICH (a char vector of option letters, in the
%   order of the checks: e.g. 'FGRU' for ad2m and ahaecg2mit, 'GU' for
%   wav2mit) were given.  For the first one missing, it prints
%       PNAME: the sampling frequency must be specified (-F)
%       PNAME: the gain must be specified (-G)
%       PNAME: the ADC resolution must be specified (-R)
%       PNAME: the units must be specified (-U)
%   and returns OK = false (the tool then exits with status 1).  The units
%   are required only if the gain is not 0.  wfdb-x has no built-in signal
%   parameters (see docs/DIVERGENCES.md).
%
%   See also wfdbx.internal.opt_sigparam.
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

if nargin == 0
    P = struct('F', 0, 'G', 0, 'Gset', 0, 'R', 0, 'U', []);
    ok = true;
    return;
end
ok = false;
for c = reshape(which, 1, [])
    switch c
        case 'F'
            if P.F <= 0
                wfdbx.internal.ceprintf( ...
                    '%s: the sampling frequency must be specified (-F)\n', pname);
                return;
            end
        case 'G'
            if ~P.Gset
                wfdbx.internal.ceprintf( ...
                    '%s: the gain must be specified (-G)\n', pname);
                return;
            end
        case 'R'
            if P.R < 1
                wfdbx.internal.ceprintf( ...
                    '%s: the ADC resolution must be specified (-R)\n', pname);
                return;
            end
        case 'U'
            if P.G ~= 0 && ~ischar(P.U)
                wfdbx.internal.ceprintf( ...
                    '%s: the units must be specified (-U)\n', pname);
                return;
            end
    end
end
ok = true;
end
