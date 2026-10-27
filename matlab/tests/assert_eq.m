function assert_eq(actual, expected, what)
%ASSERT_EQ Throw an error unless ACTUAL and EXPECTED are equal.
%   assert_eq(ACTUAL, EXPECTED, WHAT) compares with isequal (class aside:
%   chars are compared as chars, numbers as doubles) and reports WHAT and
%   both values on failure.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It tests WFDB-x; it has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

if nargin < 3
    what = 'value';
end
if ischar(expected) || ischar(actual)
    ok = ischar(actual) && ischar(expected) && ...
        isequal(double(actual(:)'), double(expected(:)'));
elseif iscell(expected)
    ok = iscell(actual) && numel(actual) == numel(expected);
    for k = 1:numel(expected)
        if ~ok, break; end
        try
            assert_eq(actual{k}, expected{k});
        catch
            ok = false;
        end
    end
elseif isempty(expected) && isempty(actual)
    ok = true;
else
    ok = isequal(double(actual), double(expected)) || ...
        (isnumeric(actual) && all(isnan(double(actual(:)))) && ...
        all(isnan(double(expected(:)))) && numel(actual) == numel(expected));
end
if ~ok
    error('wfdbx:test', '%s: got %s, expected %s', what, show(actual), ...
        show(expected));
end
end

function s = show(x)
if ischar(x)
    s = ['''' strrep(strrep(x, char(10), '\n'), char(0), '\0') ''''];
elseif iscell(x)
    s = '{';
    for k = 1:numel(x)
        s = [s show(x{k}) ' ']; %#ok<AGROW>
    end
    s = [s '}'];
elseif isempty(x)
    s = '[]';
else
    s = mat2str(double(x), 17);
end
end
