function [stat, vector] = getframe(vector)
%GETFRAME Read a frame of samples from the open input signals.
%   [STAT, V] = wfdbx.getframe() reads the next frame: all samples of
%   every input signal (spf samples of each signal, in signal order), and
%   returns them in the row vector V.  STAT is the number of input
%   signals, or as for wfdbx.getvec: -1 at the end of the record, -3 if
%   a file cannot be read, -4 on a checksum error.
%
%   [STAT, V] = wfdbx.getframe(V) starts from the vector V (whose
%   elements are left unchanged when no signals are open, as in C).
%
%   See also wfdbx.getvec, wfdbx.getframes.
%
%   Translation of the C function getframe() (lib/signal.c, WFDB 10.7.0):
%   same arguments and results.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
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
if nargin < 1
    vector = zeros(1, S.tspf);
end
[stat, vector] = wfdbx.internal.getframe_s(S, vector);
end
