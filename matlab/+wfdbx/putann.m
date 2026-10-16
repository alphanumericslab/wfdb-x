function stat = putann(an, annot)
%PUTANN Write an annotation to an output annotator.
%   STAT = wfdbx.putann(AN, ANNOT) writes the annotation ANNOT (a
%   wfdbx.annotation() structure) to output annotator AN (0 for the first
%   output annotator opened by wfdbx.annopen).  ANNOT.aux is [] or a uint8
%   (or double) row vector whose first element is the length of the data
%   that follows.  STAT is 0 on success, -1 on a write error, or -2 if AN
%   is not an open output annotator.
%
%   Annotations should be written in canonical order (by time, then num,
%   then chan); otherwise the file is sorted (by the sortann tool) when it
%   is closed.
%
%   See also wfdbx.annopen, wfdbx.getann, wfdbx.oannclose.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/annot.c; revised 2015-2020 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

% MIT format: 16-bit little-endian words, the annotation code in the top
% 6 bits and data (a time difference or a value) in the low 10 bits;
% codes 59-63 are pseudo-annotations (names as in lib/annot.c).
CODE1 = 1024;           % 1 << CS: code 1 in the code field
DATA = 1023;            % data field mask (01777)
MAXRR = DATA;           % longest interval that fits in the data field
SKIP = 59 * CODE1;      % long interval: a 32-bit value follows
NUM = 60 * CODE1;       % change of 'num'
SUB = 61 * CODE1;       % subtype
CHN = 62 * CODE1;       % change of 'chan'
AUX = 63 * CODE1;       % auxiliary data (length in the data field)
MAXSKIP = 2147483647;   % largest interval represented by one SKIP
MAX_AHA_AUX = 6;        % AUXLEN: length of the AHA aux field
OFLUSH = 65536;         % flush the output buffer beyond this many bytes
WFDB_AHA_WRITE = 3;
LONG_MIN = -9223372036854775808;
LONG_MAX = 9223372036854775807;
TWO16 = 65536;
TWO32 = 4294967296;

st = wfdbx.internal.annstate();
if an < 0 || an >= numel(st.oad) || isempty(st.oad{an+1})
    wfdbx.internal.wfdb_error('putann: can''t write annotation file %d\n', an);
    stat = -2;
    return;
end
oa = st.oad{an+1};
t = annot.time;
if ~oa.table_written
    oa.table_written = 1;
    st.oad{an+1} = oa;
    if wfdbx.internal.ann_puttable(an) < 0
        stat = -1;
        return;
    end
    oa = st.oad{an+1};
end
prev = oa.ann;
achan = mod(annot.chan, 256);                   % unsigned char
pchan = mod(prev.chan, 256);
anum = mod(annot.num + 128, 256) - 128;         % signed char
pnum = mod(prev.num + 128, 256) - 128;
pt = prev.time;
if ~(achan > pchan || anum > pnum || t > pt || (t == 0 && pt == 0))
    oa.out_of_order = 1;
end
aux = annot.aux;
if oa.stat == WFDB_AHA_WRITE
    % a 16-byte AHA record: 0, AHA code, time (two words, high first),
    % serial number, subtype, code, aux (6 bytes)
    x = mod(t, TWO32);
    hi = floor(x / TWO16);
    lo = x - hi * TWO16;
    oa.seqno = oa.seqno + 1;
    sq = mod(oa.seqno, TWO16);
    b = zeros(1, 16);
    b(2) = wfdbx.mamap(annot.anntyp, annot.subtyp);
    b(3:4) = [mod(hi, 256), floor(hi / 256)];
    b(5:6) = [mod(lo, 256), floor(lo / 256)];
    b(7:8) = [mod(sq, 256), floor(sq / 256)];
    b(9) = mod(annot.subtyp, 256);
    b(10) = mod(annot.anntyp, 256);
    if ~isempty(aux)
        ln = min(double(aux(1)), MAX_AHA_AUX);
        if ln > 0
            d = double(aux(2:min(end, ln + 1)));
            b(11:10+numel(d)) = d;
        end
    end
else
    if t == LONG_MIN || t >= LONG_MAX
        wfdbx.internal.wfdb_error( ...
            'putann: time overflow in annotation file %d\n', an);
        stat = -1;
        st.oad{an+1} = oa;
        return;
    end
    d = t - pt;
    w = [];
    if t > pt
        while d > MAXSKIP       % SKIP words: high 16 bits first
            w = [w, SKIP, floor(MAXSKIP / TWO16), mod(MAXSKIP, TWO16)]; %#ok<AGROW>
            d = d - MAXSKIP;
        end
    else
        while -d > MAXSKIP      % MINSKIP = -MAXSKIP
            w = [w, SKIP, floor(-MAXSKIP / TWO16) + TWO16, mod(-MAXSKIP, TWO16)]; %#ok<AGROW>
            d = d + MAXSKIP;
        end
    end
    typ = annot.anntyp;
    if typ == 0
        x = mod(d - 1, TWO32);
        w = [w, SKIP, floor(x / TWO16), mod(x, TWO16)];
        d = 1;
    elseif d > MAXRR || d < 0
        x = mod(d, TWO32);
        w = [w, SKIP, floor(x / TWO16), mod(x, TWO16)];
        d = 0;
    end
    w(end+1) = mod(d + typ * CODE1, TWO16);
    if annot.subtyp ~= 0
        w(end+1) = SUB + mod(annot.subtyp, DATA + 1);
    end
    if achan ~= pchan
        w(end+1) = CHN + achan;
    end
    if anum ~= pnum
        w(end+1) = NUM + mod(anum, DATA + 1);
    end
    b = zeros(1, 2 * numel(w));
    b(1:2:end) = mod(w, 256);
    b(2:2:end) = floor(w / 256);
    if ~isempty(aux) && aux(1) ~= 0
        ln = double(aux(1));
        d = zeros(1, ln + mod(ln, 2));
        x = double(aux(2:min(end, ln + 1)));
        d(1:numel(x)) = x;
        b = [b, ln, AUX / 256, d];                      % word AUX + ln
    end
end
% buffered output (written by wfdbx.internal.ann_oflush)
n = numel(b);
if oa.olen + n > numel(oa.obuf)
    oa.obuf(2 * (oa.olen + n)) = 0;
end
oa.obuf(oa.olen+1:oa.olen+n) = b;
oa.olen = oa.olen + n;
if oa.olen >= OFLUSH || oa.file.is_std
    oa = wfdbx.internal.ann_oflush(oa);
end
if oa.file.ferror()
    wfdbx.internal.wfdb_error( ...
        'putann: write error on annotation file %s\n', oa.name);
    st.oad{an+1} = oa;
    stat = -1;
    return;
end
a = wfdbx.annotation();
a.time = t;
a.anntyp = annot.anntyp;
a.subtyp = annot.subtyp;
a.chan = annot.chan;
a.num = annot.num;
a.aux = aux;
oa.ann = a;
st.oad{an+1} = oa;
stat = 0;
end
