function s = getinfo(record)
%GETINFO Read the info strings of a record.
%   S = wfdbx.getinfo(RECORD) returns the first info string of RECORD
%   (the comment lines of its header after the signal descriptions, and
%   the lines of RECORD.info that begin with '#', without the '#').
%   S = wfdbx.getinfo([]) returns the next one.  S is [] when there are
%   no more.
%
%   See also wfdbx.putinfo, wfdbx.setinfo.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
