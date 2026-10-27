function cexit(status)
%CEXIT C exit(): terminate the running tool with an exit status.
%   wfdbx.internal.cexit(STATUS) ends the tool being run by
%   wfdbx.internal.app_run (which returns STATUS), by throwing an error
%   with the identifier 'wfdbx:exit'.  Use it where the C source calls
%   exit(); a tool's main function may also simply return its status.
%
%   See also wfdbx.internal.app_run.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

error('wfdbx:exit', '%d', status);
end
