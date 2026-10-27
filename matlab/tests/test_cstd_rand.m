function test_cstd_rand()
%TEST_CSTD_RAND Tests of the glibc rand() emulation.

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

r = wfdbx.internal.GlibcRand(0);
assert_eq([r.rand() r.rand() r.rand()], [1804289383 846930886 1681692777], ...
    'rand after srand(0)');
r.srand(0);
x = r.rand(1000);
r.srand(1);
y = zeros(1, 1000);
for k = 1:1000
    y(k) = r.rand();
end
assert_eq(x, y, 'vectorized rand = scalar rand; srand(0) = srand(1)');
r = wfdbx.internal.GlibcRand(42);
assert_eq(r.rand(2), [71876166 708592740], 'rand after srand(42)');
assert(wfdbx.internal.GlibcRand.RAND_MAX == 2147483647, 'RAND_MAX');
end
