function stat = setinfo(record)
%SETINFO Open a .info file for info strings.
%   STAT = wfdbx.setinfo(RECORD) creates (or opens for appending)
%   RECORD.info, to which wfdbx.putinfo then writes.  wfdbx.setinfo([])
%   closes it.  Returns 0, or a negative value on error.
%
%   See also wfdbx.putinfo, wfdbx.getinfo.
%
%   Translation of the C function setinfo() (lib/signal.c, WFDB 10.7.0):
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

if isa(record, 'string')   % MATLAB string
    record = char(record);
end
S = wfdbx.internal.sig_state();
stat = wfdbx.internal.wfdb_oinfoclose();
if ~ischar(record)
    return;
end
record = wfdbx.internal.wfdb_striphea(record);
if wfdbx.internal.wfdb_checkname(record, 'record')
    stat = -1;
    return;
end
S.outinfo = wfdbx.internal.wfdb_open('info', record, 4);    % WFDB_APPEND
if isempty(S.outinfo)
    wfdbx.internal.wfdb_error('setinfo: can''t create info file for record %s\n', record);
    stat = -1;
    return;
end
stat = 0;
end
