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

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU General Public License, version 2 or later (see LICENSE).

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
