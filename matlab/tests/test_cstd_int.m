function test_cstd_int()
%TEST_CSTD_INT Tests of the C integer arithmetic helpers.

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
