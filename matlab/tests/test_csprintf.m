function test_csprintf()
%TEST_CSPRINTF Tests of wfdbx.internal.csprintf against glibc printf.
%   The expected strings were produced by glibc printf() on x86-64 Linux.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It tests wfdb-x; it has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

% NaNs with a known sign bit (the sign of the constant NaN, of -NaN and of
% 0/0 depends on the interpreter and the processor)
pnan = nan_bits(32760);     % bits 0x7FF8000000000000
nnan = nan_bits(65528);     % bits 0xFFF8000000000000
cases = {
    {'42', '%d', 42};
    {'-7', '%d', -7};
    {'   42|-42  |-0042', '%5d|%-5d|%05d', 42, -42, -42};
    {'+5  5 +0', '%+d % d %+d', 5, 5, 0};
    {'-005|     007', '%.3d|%8.3d', -5, 7};
    {'1152921504606846976 -3 123456789012', '%ld %lld %li', 2^60, -3, 123456789012};
    {'4294967295 7', '%u %u', -1, 7};
    {'18446744073709551615', '%lu', -1};
    {'ff FF 0xff 10 010', '%x %X %#x %o %#o', 255, 255, 255, 8, 8};
    {'ffffffff fffffffe', '%x %08x', -1, -2};
    {'4464 65535 -56', '%hd %hu %hhd', 70000, -1, 200};
    {'AbA', '%c%c%c', 65, 'b', 321};
    {'[  x|y  ]', '[%3c|%-3c]', 'x', 'y'};
    {'abc|       abc|abc       |ab|    a', '%s|%10s|%-10s|%.2s|%5.1s', 'abc', 'abc', 'abc', 'abc', 'abc'};
    {'[]', '[%s]', ''};
    {'0.0001 1e-05 123456 1.23457e+06 -0', '%g %g %g %g %g', 0.0001, 0.00001, 123456, 1234567, -0};
    {'100000 1e+15 0.3', '%g %g %g', 100000, 1e15, 0.1+0.2};
    {'0.1 0.333333333333333 0.10000000000000001', '%.12g %.15g %.17g', 0.1, 1/3, 0.1};
    {'1.00000 2.00 1E-10', '%#g %#.3g %G', 1, 2, 1e-10};
    {'1.500000 0 2 2 0.1', '%f %.0f %.0f %.0f %.1f', 1.5, 0.5, 1.5, 2.5, 0.05};
    {'2.001 1.00    -3.1416 2.50      |', '%.3f %.2f %10.4f %-10.2f|', 2.0005, 1.005, -3.14159, 2.5};
    {'1.234568e+04 1.23e-04 1.000000E+100 2e+10', '%e %.2e %E %.0e', 12345.678, 0.000123456, 1e100, 2.5e10};
    {'1000000000000000052504760255204420248704468581108159154915854115511802457988908195786371375080447864043704443832883878176942523235360430575644792184786706982848387200926575803737830233794788090059368953234970799945081119038967640880074652742780142494579258788820056842838115669472196386865459400540160.000000 4.940656e-324 1.79769e+308', '%f %e %g', 1e300, 5e-324, 1.7976931348623157e308};
    {'+1.000  1.000 -001.500', '%+.3f % .3f %08.3f', 1, 1, -1.5};
    {'    42|42    |3.14|   2.500', '%*d|%-*d|%.*f|%*.*f', 6, 42, 6, 42, 2, 3.14159, 8, 3, 2.5};
    {'42    |', '%*d|', -6, 42};
    {'100% 5%', '100%% %d%%', 5};
    {['tab' char(9) 'here' char(10)], 'tab\there\n'};
    {['99.50%' char(9) 'x' char(10)], '%5.2f%%\t%s\n', 99.5, 'x'};
    {'360 0.002777777778', '%.10g %.10g', 360, 1/360};
    {'1.235 -0.000000', '%.3lf %lf', 1.23456, -0};
    {'nan', '%g', pnan};
    {'-nan', '%g', nnan};
    {'-nan|nan', '%f|%f', nnan, pnan};
    {'inf', '%f', Inf};
    {'-inf', '%f', -Inf};
    {'  inf|', '%5.2f|', Inf};
    {'-inf  |', '%-6g|', -Inf};
    {'+inf', '%+g', Inf};
    {' nan', '% g', pnan};
    {'-nan', '% g', nnan};
    {'+nan', '%+g', pnan};
    {'INF', '%E', Inf};
    {'NAN', '%G', pnan};
    {'-NAN', '%E', nnan};
    {'     inf', '%08.3f', Inf};
    {'INF', '%F', Inf};
    {'1.500000', '%F', 1.5};
    {'2', '%d', 2.7};
    {'-2', '%d', -2.7};
    {'-2147483648', '%d', pnan};
    {'-2147483648', '%d', nnan};
    {'(null)', '%s', []};
    {'[]', '[%.3s]', []};
    {'1', '%d', true};
    {'-5', '%d', int32(-5)};
    {'200', '%u', uint8(200)};
    {'x', '%c', 'xyz'};
    {'ab''', '%s', 'ab'''};
    {'9223372036854775808', '%llu', 2^63}
    };
for k = 1:numel(cases)
    c = cases{k};
    for rep = 1:2       % the second call uses the cached format
        got = wfdbx.internal.csprintf(c{2:end});
        assert_eq(got, c{1}, sprintf('csprintf(''%s'') case %d', c{2}, k));
    end
end

% The general path gives the same results as the fast path.
f = '%d|%5s|%g|%x|%c\n';
assert_eq(wfdbx.internal.csprintf(f, 12, 'ab', 0.5, 255, 'q'), ...
    sprintf('12|   ab|0.5|ff|q\n'), 'fast path');
assert_eq(wfdbx.internal.csprintf(f, 12, 'ab', 0.5, 255, 113), ...
    sprintf('12|   ab|0.5|ff|q\n'), 'general path (numeric %c)');
assert_eq(wfdbx.internal.csprintf(f, 12, '', pnan, -1, 'q'), ...
    sprintf('12|     |nan|ffffffff|q\n'), 'general path');

% printf output and the standard streams
assert_eq(wfdbx.internal.csprintf('no conversions'), 'no conversions', ...
    'plain text');
assert_eq(wfdbx.internal.csprintf(''), '', 'empty format');
end

function x = nan_bits(hi)
% the NaN whose 16 high bits are HI and the others zero
x = typecast(bitshift(uint64(hi), 48), 'double');
assert(isnan(x) && isequal(typecast(x, 'uint64'), bitshift(uint64(hi), 48)), ...
    'NaN bit pattern');
end
