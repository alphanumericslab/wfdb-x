function n = wfdbgetstart(s)
%WFDBGETSTART Byte offset of the first sample of an input signal.
%   N = wfdbx.wfdbgetstart(S) returns the number of bytes preceding
%   sample 0 (the prolog) in the signal file of input signal S.
%
%   See also wfdbx.wfdbsetstart.
%
%   Translation of the C function wfdbgetstart() (lib/signal.c, WFDB
%   10.7.0): same arguments and results.

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
if s < S.nisig
    n = S.igd{S.vsd(s + 1).info.group + 1}.start;
elseif s == 0 && ~isempty(S.hsd)
    n = S.hsd(1).start;
else
    n = 0;
end
end
