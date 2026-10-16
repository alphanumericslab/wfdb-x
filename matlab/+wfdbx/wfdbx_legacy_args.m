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
%   function is a wfdb-x addition.
%
%   Example:
%       [r, argv] = wfdbx.wfdbx_legacy_args({'rdsamp', '--legacy', '-r', '100s'})
%       % r = 1, argv = {'rdsamp', '-r', '100s'}
%
%   See also wfdbx.wfdbx_set_legacy, wfdbx.wfdbx_get_legacy.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

r = 0;
if numel(argv) < 2 || ~ischar(argv{2}) || ~strcmp(argv{2}, '--legacy')
    return;
end
argv(2) = [];
wfdbx.wfdbx_set_legacy(1);
r = 1;
end
