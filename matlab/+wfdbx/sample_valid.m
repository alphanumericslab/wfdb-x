function f = sample_valid()
%SAMPLE_VALID Status of the last call of wfdbx.sample.
%   F = wfdbx.sample_valid() returns 1 if the last sample returned by
%   wfdbx.sample was valid, -1 if it was invalid (or the signal number was
%   out of range), 0 if it was beyond the end of the record.
%
%   See also wfdbx.sample.
%
%   Translation of the C function sample_valid() (lib/signal.c, WFDB
%   10.7.0): same arguments and results.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/signal.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/signal.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2011-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

S = wfdbx.internal.sig_state();
f = S.sample_vflag;
end
