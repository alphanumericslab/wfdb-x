function [stat, si] = setheader(record, si, nsig)
%SETHEADER Create or rewrite a header file.
%   STAT = wfdbx.setheader(RECORD, SI) writes the header file RECORD.hea
%   for the signals described by the wfdbx.siginfo struct array SI (NSIG
%   = numel(SI), or the first NSIG of them with
%   wfdbx.setheader(RECORD, SI, NSIG)), with the current sampling
%   frequency, counter frequency, base counter value and base time.
%   Returns 0, or -1 on error.
%
%   [STAT, SI] = wfdbx.setheader(...) also returns SI as C leaves it: the
%   units and desc strings are truncated by strtok (at the first blank
%   and the first newline respectively).
%
%   See also wfdbx.newheader, wfdbx.setmsheader, wfdbx.putinfo.

% Copyright (C) 1989-2013 George B. Moody (original C implementation,
% lib/signal.c; revised 2011-2022 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

if isa(record, 'string')   % MATLAB string
    record = char(record);
end
S = wfdbx.internal.sig_state();
if nargin < 3
    nsig = numel(si);
end
if ~isempty(S.oheader)
    S.oheader.close();
    if S.outinfo_hdr
        S.outinfo = [];
        S.outinfo_hdr = false;
    end
    S.oheader = [];
end
record = wfdbx.internal.wfdb_striphea(record);
if wfdbx.internal.wfdb_checkname(record, 'record')
    stat = -1;
    return;
end
S.oheader = wfdbx.internal.wfdb_open('hea', record, 1);    % WFDB_WRITE
if isempty(S.oheader)
    wfdbx.internal.wfdb_error('newheader: can''t create header for record %s\n', record);
    stat = -1;
    return;
end
g12 = @(x) wfdbx.internal.csprintf('%.12g', x);
out = sprintf('%s %d %s', record, nsig, g12(S.ffreq));
if (S.cfreq > 0 && S.cfreq ~= S.ffreq) || S.bcount ~= 0
    out = [out '/' g12(S.cfreq)];
    if S.bcount ~= 0
        out = [out '(' g12(S.bcount) ')'];
    end
end
if nsig > 0
    out = [out sprintf(' %d', si(1).nsamp)];
else
    out = [out ' 0'];
end
if S.btime ~= 0 || S.bdate ~= 0
    if S.btime == 0
        out = [out ' 0:00'];
    elseif mod(S.btime, 1000) == 0
        out = [out ' ' wfdbx.internal.ftimstr(S.btime, 1000)];
    else
        out = [out ' ' wfdbx.internal.fmstimstr(S.btime, 1000)];
    end
end
if S.bdate
    out = [out wfdbx.datstr(S.bdate)];
end
crlf = sprintf('\r\n');
out = [out crlf];
nosd = numel(S.osd);
for s = 1:nsig
    x = si(s);
    out = [out sprintf('%s %d', cstr(x.fname), x.fmt)]; %#ok<AGROW>
    if x.spf > 1
        out = [out sprintf('x%d', x.spf)]; %#ok<AGROW>
    end
    if nosd > 0 && s <= nosd && S.osd(s).skew
        out = [out sprintf(':%d', S.osd(s).skew * x.spf)]; %#ok<AGROW>
    end
    if ~isempty(S.ogd) && s <= nosd && S.ogd{S.osd(s).info.group + 1}.start
        out = [out sprintf('+%d', S.ogd{S.osd(s).info.group + 1}.start)]; %#ok<AGROW>
    elseif S.prolog_bytes
        out = [out sprintf('+%d', S.prolog_bytes)]; %#ok<AGROW>
    end
    out = [out ' ' g12(x.gain)]; %#ok<AGROW>
    if x.baseline ~= x.adczero
        out = [out sprintf('(%d)', x.baseline)]; %#ok<AGROW>
    end
    if ischar(x.units) && ~isempty(x.units)
        [p, si(s).units] = strtok_inplace(x.units, sprintf(' \t\n\r'));
        if ischar(p)
            out = [out '/' p]; %#ok<AGROW>
        end
    end
    ck = mod(x.cksum, 65536);
    if ck >= 32768
        ck = ck - 65536;
    end
    out = [out sprintf(' %d %d %d %d %d', x.adcres, x.adczero, x.initval, ...
        ck, x.bsize)]; %#ok<AGROW>
    if ischar(x.desc) && ~isempty(x.desc)
        [p, si(s).desc] = strtok_inplace(x.desc, sprintf('\n\r'));
        if ischar(p)
            out = [out ' ' p]; %#ok<AGROW>
        end
    end
    out = [out crlf]; %#ok<AGROW>
end
S.oheader.write(out);
S.prolog_bytes = 0;
S.oheader.flush();
stat = 0;
end

function s = cstr(s)
if ~ischar(s)
    s = '(null)';
end
end

function [tok, s] = strtok_inplace(s, delims)
% The first strtok() token of S, and S as strtok leaves it.
n = numel(s);
i = 1;
while i <= n && any(s(i) == delims)
    i = i + 1;
end
if i > n
    tok = [];
    return;
end
j = i;
while j <= n && ~any(s(j) == delims)
    j = j + 1;
end
tok = s(i:j - 1);
s = s(1:j - 1);
end
