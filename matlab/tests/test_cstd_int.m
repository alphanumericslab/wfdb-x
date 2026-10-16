function test_cstd_int()
%TEST_CSTD_INT Tests of the C integer arithmetic helpers.

% Part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

I = 'wfdbx.internal.';
assert_eq(wfdbx.internal.cdiv(-7, 2), -3, 'cdiv(-7,2)');
assert_eq(wfdbx.internal.cmod(-7, 2), -1, 'cmod(-7,2)');
assert_eq(wfdbx.internal.cdiv(7, -2), -3, 'cdiv(7,-2)');
assert_eq(wfdbx.internal.cmod(7, -2), 1, 'cmod(7,-2)');
assert_eq(wfdbx.internal.cdiv([9 -9], 4), [2 -2], 'cdiv vector');
assert_eq(wfdbx.internal.cint16(32768), -32768, 'cint16(0x8000)');
assert_eq(wfdbx.internal.cint16([65535 32767 -32769]), [-1 32767 32767], 'cint16');
assert_eq(wfdbx.internal.cuint16(-1), 65535, 'cuint16(-1)');
assert_eq(wfdbx.internal.cint32(2147483648), -2147483648, 'cint32(2^31)');
assert_eq(wfdbx.internal.cint32(-2147483649), 2147483647, 'cint32(-2^31-1)');
assert_eq(wfdbx.internal.cint32(4294967296 + 5), 5, 'cint32(2^32+5)');
assert_eq(wfdbx.internal.cuint32(-1), 4294967295, 'cuint32(-1)');
assert_eq(wfdbx.internal.cint8([128 255 127 -129]), [-128 -1 127 127], 'cint8');
assert_eq(wfdbx.internal.cuint8([-1 256 300]), [255 0 44], 'cuint8');
assert_eq(wfdbx.internal.d2i([2.9 -2.9 NaN 2147483648 -2147483648.5 -2147483649]), ...
    [2 -2 -2147483648 -2147483648 -2147483648 -2147483648], 'd2i');
assert_eq(wfdbx.internal.d2i(2147483647.9), 2147483647, 'd2i max');
assert_eq(wfdbx.internal.cisspace(sprintf(' \t\n\v\f\rx')), ...
    [true true true true true true false], 'cisspace');
assert_eq(feval([I 'cint32'], 1), 1, 'feval');
end
