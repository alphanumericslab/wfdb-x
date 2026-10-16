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

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU General Public License, version 2 or later (see LICENSE).

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
