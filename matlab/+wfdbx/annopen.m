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
%   Example:
%       wfdbx.annopen('100s', wfdbx.anninfo('atr', wfdbx.WFDB_READ()));
%       [stat, a] = wfdbx.getann(0);
%
%   See also wfdbx.getann, wfdbx.putann, wfdbx.anninfo.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if isa(record, 'string')   % MATLAB string
    record = char(record);
end
AUXBUFLEN = 771;    % size of the aux string buffer of an input annotator
OBUFLEN = 4096;     % initial size of the output buffer (bytes)
NOTQRS = 0;         % lib/ecgcodes.h
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
st = wfdbx.internal.annstate();
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
        % The format is guessed from the first 16-bit word (read as C's
        % 16-bit getc() pair: a missing byte reads as EOF, 0xff): an AHA
        % file starts with a null byte followed by an AHA code other
        % than '[' or ']'.
        D = f.readall();
        if numel(D) >= 2
            w = double(D(1)) + 256 * double(D(2));
        elseif numel(D) == 1
            w = double(D(1)) + 256 * 255;
        else
            w = 65535;
        end
        a = floor(w / 256);
        if mod(w, 256) ~= 0 || wfdbx.ammap(a) == NOTQRS || a == '[' || a == ']'
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
        ia = new_ia(f, ai.name, istat, ...
            wfdbx.internal.ann_parse(D, istat == WFDB_AHA_READ), AUXBUFLEN);
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
        oa.file = f;
        oa.name = ai.name;
        oa.stat = ai.stat;
        oa.rname = record;
        oa.ann = wfdbx.annotation();
        oa.afreq = 0;
        oa.seqno = 0;
        oa.out_of_order = 0;
        oa.table_written = 0;
        oa.obuf = zeros(1, OBUFLEN, 'uint8');
        oa.olen = 0;
        st.oad{end+1} = oa;
    end
end
stat = 0;
end

function ia = new_ia(f, name, istat, P, auxbuflen)
% A new input annotator structure (C's struct iadata).
ia.file = f;
ia.name = name;
ia.stat = istat;
ia.P = P;
ia.k = 0;
ia.ateof = 0;
ia.tmul = 0;
ia.afreq = 0;
ia.ann = wfdbx.annotation();
ia.ann_tt = 0;
ia.pann = wfdbx.annotation();
ia.pann_tt = 0;
ia.prev_tt = 0;
ia.prev_time = 0;
ia.buf = zeros(1, auxbuflen);
ia.index = 0;
ia.auxpos = -1;
end
