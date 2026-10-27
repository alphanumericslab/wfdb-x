function stat = putinfo(s)
%PUTINFO Write an info string.
%   STAT = wfdbx.putinfo(S) writes the info string S (as "#S" on a line of
%   its own) to the .info file opened by setinfo, or else to the header
%   file written last by setheader/newheader.  Returns 0, or -1 if there
%   is no such file.
%
%   See also wfdbx.getinfo, wfdbx.setinfo.
%
%   Translation of the C function putinfo() (lib/signal.c, WFDB 10.7.0):
%   same arguments and results.

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

if isa(s, 'string')   % MATLAB string
    s = char(s);
end
S = wfdbx.internal.sig_state();
if isempty(S.outinfo)
    if ~isempty(S.oheader)
        S.outinfo = S.oheader;
        S.outinfo_hdr = true;
    else
        wfdbx.internal.wfdb_error('putinfo: caller has not specified a record name\n');
        stat = -1;
        return;
    end
end
S.outinfo.write(['#' s sprintf('\r\n')]);
S.outinfo.flush();
stat = 0;
end
