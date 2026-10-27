function msg = wfdberror()
%WFDBERROR The most recent WFDB library error message.
%   MSG = wfdbx.wfdberror() returns the last error message of the library
%   (ending with a newline), or, if no error has occurred, a message giving
%   the version of the library ('WFDB library version 10.7.0 (Jun 10
%   2022).').
%
%   See also wfdbx.wfdbquiet, wfdbx.wfdbversion.
%
%   Translation of the C function wfdberror() (lib/wfdbio.c, WFDB 10.7.0):
%   same arguments and results.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/wfdbio.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: none, apart from the language.
%
% Original C code: lib/wfdbio.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1988-2013 George B. Moody; revised 2010-2022 by Benjamin
%   Moody.
% MATLAB/Octave translation and changes: Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

st = wfdbx.internal.io_state();
if ~st.error_flag
    st.error_message = sprintf('WFDB library version %s (%s).\n', ...
        wfdbx.wfdbversion(), 'Jun 10 2022');
end
msg = st.error_message;
end
