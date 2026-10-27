function stat = annopen(record, aiarray, nann)
%ANNOPEN Open annotation files of a record.
%   STAT = wfdbx.annopen(RECORD, AIARRAY) opens the annotators described
%   by the struct array AIARRAY (see wfdbx.anninfo: fields name and stat,
%   wfdbx.WFDB_READ() or WFDB_AHA_READ for input, WFDB_WRITE or
%   WFDB_AHA_WRITE for output).  Input annotators are numbered 0, 1, ...
%   in the order they are opened (for wfdbx.getann), as are output
%   annotators (for wfdbx.putann).  Unless RECORD begins with '+', the
%   annotators already open are closed first.
%
%   STAT = wfdbx.annopen(RECORD, AIARRAY, NANN) opens the first NANN.
%
%   STAT is 0 on success, or a negative value: -3 if an input annotator
%   cannot be read, -4 if an output annotator cannot be created, -5 for an
%   illegal stat, or (when NANN is 0) the error code of the annotators
%   closed (-6, -7).
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with wfdb-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.annopen('100s', wfdbx.anninfo('atr', wfdbx.WFDB_READ()));
%       [stat, a] = wfdbx.getann(0);
%
%   See also wfdbx.getann, wfdbx.putann, wfdbx.anninfo.
%
%   Translation of the C function annopen() (lib/annot.c, WFDB 10.7.0): same
%   arguments and results. Differences: the annotation files are found only
%   where they are named, not by a search of the WFDB path; see
%   docs/DIVERGENCES.md.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
%
% It is a MATLAB/Octave translation of lib/annot.c from the WFDB Software
% Package 10.7.0, by George B. Moody. The translation follows the logic and
% behavior of the original code, but it is new code, not the original C
% code.
%
% Changes from the original: the name of an output annotation file is kept,
% so that the file can be sorted when it is closed. Each change is marked
% "wfdb-x:" in the code; docs/DIVERGENCES.md gives the reasons.
%
% Original C code: lib/annot.c, WFDB Software Package 10.7.0.
%   Copyright (C) 1989-2013 George B. Moody; revised 2015-2020 by Benjamin
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
WFDB_READ = 0;      % file modes (lib/wfdb.h)
WFDB_WRITE = 1;
WFDB_AHA_READ = 2;
WFDB_AHA_WRITE = 3;

if nargin < 2
    aiarray = [];
end
if nargin < 3
    nann = numel(aiarray);
end
st = wfdbx.internal.ann_state();
st.annclose_error = 0;
if ~isempty(record) && record(1) == '+'
    record = record(2:end);
else
    wfdbx.internal.wfdb_anclose();
end
if nann == 0
    stat = st.annclose_error;
    return;
end
record = wfdbx.internal.wfdb_striphea(record);
for i = 1:nann
    s = aiarray(i).stat;
    if ~(s == WFDB_READ || s == WFDB_AHA_READ || s == WFDB_WRITE || ...
            s == WFDB_AHA_WRITE)
        wfdbx.internal.wfdb_error( ...
            'annopen: illegal stat %d for annotator %s, record %s\n', ...
            s, aiarray(i).name, record);
        stat = -5;
        return;
    end
end
for i = 1:nann
    ai = aiarray(i);
    if ai.stat == WFDB_READ || ai.stat == WFDB_AHA_READ
        wfdbx.internal.wfdb_setirec(record);
        f = wfdbx.internal.wfdb_open(ai.name, record, WFDB_READ);
        if isempty(f)
            wfdbx.internal.wfdb_error( ...
                'annopen: can''t read annotator %s for record %s\n', ...
                ai.name, record);
            stat = -3;
            return;
        end
        D = f.readall();
        if wfdbx.internal.ann_format(D) == WFDB_READ
            if ai.stat ~= WFDB_READ
                wfdbx.internal.wfdb_error( ...
                    'warning (annopen, annotator %s, record %s):\n', ...
                    ai.name, record);
                wfdbx.internal.wfdb_error( ...
                    ' file appears to be in MIT format\n');
                wfdbx.internal.wfdb_error( ...
                    ' ... continuing under that assumption\n');
            end
            istat = WFDB_READ;
        else
            if ai.stat ~= WFDB_AHA_READ
                wfdbx.internal.wfdb_error( ...
                    'warning (annopen, annotator %s, record %s):\n', ...
                    ai.name, record);
                wfdbx.internal.wfdb_error( ...
                    ' file appears to be in AHA format\n');
                wfdbx.internal.wfdb_error( ...
                    ' ... continuing under that assumption\n');
            end
            istat = WFDB_AHA_READ;
        end
        ia = wfdbx.internal.ann_iadata(f, ai.name, istat, ...
            wfdbx.internal.ann_parse(D, istat == WFDB_AHA_READ));
        st.iad{end+1} = ia;
        wfdbx.internal.ann_gettable(numel(st.iad) - 1);
    else
        if wfdbx.internal.wfdb_checkname(ai.name, 'annotator')
            stat = -4;
            return;
        end
        f = wfdbx.internal.wfdb_open(ai.name, record, WFDB_WRITE);
        if isempty(f)
            wfdbx.internal.wfdb_error( ...
                'annopen: can''t write annotator %s for record %s\n', ...
                ai.name, record);
            stat = -4;
            return;
        end
        oa = wfdbx.internal.ann_oadata(f, ai.name, ai.stat);
        oa.rname = record;
        oa.fname = wfdbx.wfdbfile([], []);  % wfdb-x: the file, for sorting
        st.oad{end+1} = oa;
    end
end
stat = 0;
end
