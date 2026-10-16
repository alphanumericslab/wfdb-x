function nfail = run_tests(pattern)
%RUN_TESTS Run the wfdb-x unit tests (MATLAB and GNU Octave).
%   run_tests runs every test function test_*.m in this directory.  A test
%   function takes no arguments and throws an error on failure; each test
%   file may call local check functions.  A line "ok   NAME" or
%   "FAIL NAME: MESSAGE" is printed for each test, then a summary.
%
%   run_tests(PATTERN) runs only the tests whose names match the regular
%   expression PATTERN.  NFAIL = run_tests(...) returns the number of
%   failures.  When run non-interactively (octave --eval, or matlab -batch)
%   and called without an output argument, it exits with status 1 if a test
%   failed.
%
%   Usage:
%       octave-cli --no-gui --norc -q --eval "cd matlab/tests; run_tests"
%       matlab -batch "cd matlab/tests; run_tests"

% Part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if nargin < 1
    pattern = '';
end
here = fileparts(mfilename('fullpath'));
addpath(fileparts(here));
addpath(here);
d = dir(fullfile(here, 'test_*.m'));
names = sort(cellfun(@(x) x(1:end-2), {d.name}, 'UniformOutput', false));
nfail = 0;
nrun = 0;
for k = 1:numel(names)
    name = names{k};
    if ~isempty(pattern) && isempty(regexp(name, pattern, 'once'))
        continue;
    end
    nrun = nrun + 1;
    try
        feval(name);
        fprintf('ok   %s\n', name);
    catch err
        nfail = nfail + 1;
        where = '';
        if ~isempty(err.stack)
            where = sprintf(' (%s line %d)', err.stack(1).name, ...
                err.stack(1).line);
        end
        fprintf('FAIL %s: %s%s\n', name, err.message, where);
    end
end
fprintf('%d of %d tests passed\n', nrun - nfail, nrun);
if nargout == 0
    if nfail > 0 && batch_mode()
        exit(1);
    end
    clear nfail
end
end

function tf = batch_mode()
if exist('OCTAVE_VERSION', 'builtin')
    % octave --eval "...", or octave SCRIPT.m
    a = argv();
    tf = ~isguirunning() && (any(strcmp(a, '--eval')) || ...
        any(cellfun(@(x) numel(x) > 2 && strcmp(x(end-1:end), '.m'), a)));
else
    tf = exist('batchStartupOptionUsed', 'file') && batchStartupOptionUsed;
end
end
