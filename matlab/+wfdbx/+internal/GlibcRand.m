classdef GlibcRand < handle
%GLIBCRAND Exact emulation of glibc srand()/rand().
%   R = wfdbx.internal.GlibcRand(SEED) creates a generator in the state of
%   glibc after srand(SEED) (default seed 1; srand(0) is the same as
%   srand(1), as in glibc).  X = R.rand() returns the next value of rand()
%   (0 to RAND_MAX = 2147483647), and X = R.rand(N) the next N values as a
%   row vector (the same as N calls, computed in a vectorized way).
%   R.srand(SEED) reseeds the generator.
%
%   This is glibc's TYPE_3 additive feedback generator, used by wrsamp -d
%   and xform -d for dithering (after srand(0)).
%
%   Example:
%       r = wfdbx.internal.GlibcRand(0);
%       r.rand(3)       % [1804289383 846930886 1681692777]
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

    properties (Constant)
        RAND_MAX = 2147483647
    end

    properties
        r       % the last 34 values of the state sequence (uint32 as double)
    end

    methods
        function obj = GlibcRand(seed)
            if nargin < 1
                seed = 1;
            end
            obj.srand(seed);
        end

        function srand(obj, seed)
            %SRAND Reseed the generator (glibc srand()).
            seed = mod(seed, 4294967296);
            if seed == 0
                seed = 1;
            end
            r = zeros(1, 34);
            if seed >= 2147483648
                r(1) = seed - 4294967296;
            else
                r(1) = seed;
            end
            % r(i) = 16807 * r(i-1) mod (2^31 - 1), by Schrage's method
            % (127773 = (2^31 - 1) div 16807, 2836 = (2^31 - 1) mod 16807)
            for i = 2:31
                hi = fix(r(i-1) / 127773);
                lo = rem(r(i-1), 127773);
                word = 16807 * lo - 2836 * hi;
                if word < 0
                    word = word + 2147483647;
                end
                r(i) = word;
            end
            r(32:34) = r(1:3);
            obj.r = mod(r, 4294967296);
            obj.rand(310);      % glibc discards the first 310 outputs
        end

        function x = rand(obj, n)
            %RAND Next value(s) of glibc rand().
            if nargin < 2
                n = 1;
            end
            % buf(k) = buf(k-31) + buf(k-3) (mod 2^32): computed 3 at a
            % time, then (expanding buf(k-3) ten times) 30 at a time as
            % buf(k) = buf(k-30) + sum of buf(k-31-3i), i = 0..9 (sums of
            % 11 values below 2^32 are exact).
            buf = [obj.r zeros(1, n)];
            k = 35;
            last = 34 + n;
            while k <= min(last, 61)    % (the expansion needs k - 27 >= 35)
                k2 = min(k + 2, last);
                buf(k:k2) = mod(buf(k-31:k2-31) + buf(k-3:k2-3), 4294967296);
                k = k2 + 1;
            end
            if k <= last
                lags = [30, 31:3:58]';
                off = repmat(0:29, numel(lags), 1) - repmat(lags, 1, 30);
                while k + 29 <= last
                    buf(k:k+29) = mod(sum(buf(k + off), 1), 4294967296);
                    k = k + 30;
                end
                while k <= last
                    k2 = min(k + 2, last);
                    buf(k:k2) = mod(buf(k-31:k2-31) + buf(k-3:k2-3), 4294967296);
                    k = k2 + 1;
                end
            end
            obj.r = buf(end-33:end);
            x = floor(buf(35:end) / 2);
        end
    end
end
