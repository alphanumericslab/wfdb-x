function s = getinfo(record)
%GETINFO Read the info strings of a record.
%   S = wfdbx.getinfo(RECORD) returns the first info string of RECORD
%   (the comment lines of its header after the signal descriptions, and
%   the lines of RECORD.info that begin with '#', without the '#').
%   S = wfdbx.getinfo([]) returns the next one.  S is [] when there are
%   no more.
%
%   See also wfdbx.putinfo, wfdbx.setinfo.
%
%   Translation of the C function getinfo() (lib/signal.c, WFDB 10.7.0): same
%   arguments and results.

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

if nargin >= 1 && isa(record, 'string')   % MATLAB string
    record = char(record);
end
if nargin < 1
    record = [];
end
S = wfdbx.internal.sig_state();
if ischar(record)
    wfdbx.internal.wfdb_freeinfo();
end
if ~S.has_pinfo
    if ~ischar(record)
        record = wfdbx.internal.wfdb_getirec();
        if ~ischar(record)
            wfdbx.internal.wfdb_error('getinfo: caller did not specify record name\n');
            s = [];
            return;
        end
    end
    S.ninfo = 0;
    S.info_i = 0;
    pinfo = {};
    if ~S.isedf
        record = wfdbx.internal.wfdb_striphea(record);
        ifile = wfdbx.internal.wfdb_open('hea', record, 0);
        if ~isempty(ifile)
            % As in wfdb_getline(), the buffer keeps its previous contents
            % when the end of the file is reached.
            buf = '';
            while true
                line = ifile.getline();
                if isempty(line)
                    break;
                end
                buf = line;
                if buf(1) ~= '#'
                    break;
                end
            end
            while true
                line = ifile.getline();
                if isempty(line)
                    break;
                end
                buf = line;
                if buf(1) == '#'
                    break;
                end
            end
            while ~isempty(buf)
                if buf(1) == '#'
                    pinfo{end + 1} = strip_info(buf); %#ok<AGROW>
                end
                line = ifile.getline();
                if isempty(line)
                    break;
                end
                buf = line;
            end
            ifile.close();
        end
    end
    ifile = wfdbx.internal.wfdb_open('info', record, 0);
    if ~isempty(ifile)
        while true
            buf = ifile.getline();
            if isempty(buf)
                break;
            end
            if buf(1) == '#'
                pinfo{end + 1} = strip_info(buf); %#ok<AGROW>
            end
        end
        ifile.close();
    end
    S.pinfo = pinfo;
    S.has_pinfo = true;
    S.ninfo = numel(pinfo);
end
if S.info_i < S.ninfo
    S.info_i = S.info_i + 1;
    s = S.pinfo{S.info_i};
else
    s = [];
end
end

function buf = strip_info(buf)
n = numel(buf);
if n > 0 && buf(n) == char(10)
    n = n - 1;
    if n > 0 && buf(n) == char(13)
        n = n - 1;
    end
elseif n > 0 && buf(n) == char(13)
    n = n - 1;
end
buf = buf(2:n);
end
