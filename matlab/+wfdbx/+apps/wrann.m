function status = wrann(args)
%WRANN Translate an ASCII annotation file (as made by rdann) to binary.
%   STATUS = wfdbx.apps.wrann(ARGS) runs the wrann tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       wrann -r RECORD -a ANNOTATOR <TEXT-FILE
%   TEXT-FILE (the standard input) should be in the format produced by
%   rdann.
%
%   Example (from the shell):
%       rdann -r 100s -a atr | wrann -r 100s -a cpy
%
%   See also wfdbx.apps.rdann, wfdbx.write_annotations.

% Copyright (C) 1983-2010 George B. Moody (original C program, app/wrann.c;
% revised 2018 by Benjamin Moody).
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU General Public License, version 2 or later (see LICENSE).

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'wrann'}, args]);
end

function help(pname)
wfdbx.internal.ceprintf('usage: %s -r RECORD -a ANNOTATOR <TEXT-FILE\n', pname);
wfdbx.internal.ceprintf('TEXT-FILE should be in the format produced by `rdann''.\n');
end

function status = main(argv)
pname = argv{1};
argc = numel(argv);
ep = @wfdbx.internal.ceprintf;
record = [];
ainame = [];
i = 1;
while i < argc
    a = argv{i+1};
    if ~isempty(a) && a(1) == '-'
        if numel(a) >= 2
            c = a(2);
        else
            c = '';
        end
        switch c
            case 'a'
                i = i + 1;
                if i >= argc
                    ep('%s: annotator must follow -a\n', pname);
                    status = 1;
                    return;
                end
                ainame = argv{i+1};
            case 'h'
                help(pname);
                status = 0;
                return;
            case 'r'
                i = i + 1;
                if i >= argc
                    ep('%s: input record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i+1};
            otherwise
                ep('%s: unrecognized option %s\n', pname, a);
                status = 1;
                return;
        end
    else
        ep('%s: unrecognized argument %s\n', pname, a);
        status = 1;
        return;
    end
    i = i + 1;
end
if ~ischar(record) || ~ischar(ainame)
    help(pname);
    status = 1;
    return;
end
wfdbx.setafreq(wfdbx.sampfreq(record));
if wfdbx.annopen(record, wfdbx.anninfo(ainame, 1), 1) < 0
    status = 2;
    return;
end
annot = wfdbx.annotation();
tab = char(9);
lines = wfdbx.internal.fgets_lines(wfdbx.internal.stdin_bytes(), 400);   % char line[400] in C
nl = numel(lines);
% Fast path: the lines that do not begin with '[' and whose 5 fields are
% all converted by sscanf (%lld%s%d%d%d) are parsed with regular
% expressions; they do not depend on the values left by earlier lines.
% The other lines are parsed one by one below, as in C.
ws = '[ \t\n\v\f\r]*';
pat = ['^' ws '([+-]?\d{1,15})(?!\d)' ws '([^ \t\n\v\f\r]++)' ws ...
    '([+-]?\d{1,9})(?!\d)' ws '([+-]?\d{1,9})(?!\d)' ws '([+-]?\d{1,9})(?!\d)'];
% Octave's regexp works on UTF-8 text (and rejects invalid UTF-8), MATLAB's
% on characters: the regular expressions are applied to copies of the
% lines (la, rests_a) in which the bytes above 127 are replaced by DEL
% (127), which no pattern tells apart from them; strings are taken from
% the original lines.
la = lines;
alld = [lines{:}];
hl = [];
if any(alld > 127)
    owner = zeros(1, numel(alld));
    ends = cumsum(cellfun('length', lines));
    owner(ends(1:end-1) + 1) = 1;
    owner = cumsum(owner) + 1;          % the line of each byte
    hl = unique(owner(alld > 127));
    for k = hl
        la{k}(la{k} > 127) = char(127);
    end
end
isbr = ~cellfun('isempty', regexp(la, '^\[', 'once'));
rt = regexp(la, '^.{9}[^ ]* (.*)$', 'tokens', 'once');
rests_a = repmat({''}, 1, nl);
m = ~cellfun('isempty', rt);
rests_a(m) = [rt{m}];
rests = rests_a;
for k = hl
    rests{k} = lines{k}(end - numel(rests_a{k}) + 1:end);
end
R = regexp(rests_a, pat, 'tokens', 'once');
reg = ~isbr & ~cellfun('isempty', R);
ireg = find(reg);
T = reshape([R{reg}], 5, []);
hk = hl(reg(hl));
if ~isempty(hk)
    % the mnemonics of these lines, from the original bytes
    X = regexp(rests_a(hk), pat, 'tokenExtents', 'once');
    [~, col] = ismember(hk, ireg);
    for j = 1:numel(hk)
        T{2, col(j)} = rests{hk(j)}(X{j}(2, 1):X{j}(2, 2));
    end
end
rtm = zeros(1, nl);
rsub = zeros(1, nl);
rch = zeros(1, nl);
rnm = zeros(1, nl);
rtyp = zeros(1, nl);
rmn = cell(1, nl);
if ~isempty(ireg)
    rtm(ireg) = str2double(T(1, :));
    rsub(ireg) = str2double(T(3, :));
    rch(ireg) = str2double(T(4, :));
    rnm(ireg) = str2double(T(5, :));
    rmn(ireg) = T(2, :);
    [u, ~, jj] = unique(T(2, :));
    cu = zeros(1, numel(u));
    for k = 1:numel(u)
        cu(k) = wfdbx.strann(u{k});
    end
    rtyp(ireg) = cu(jj);
end
tabpos = regexp(rests_a, '\t', 'once');
% outputs, by line
otime = rtm;
otyp = rtyp;
otyp(reg & rtyp == 0) = 22;             % NOTE
osub = mod(rsub + 128, 256) - 128;
och = mod(rch, 256);
onum = mod(rnm + 128, 256) - 128;
oaux = cell(1, nl);
written = reg;
for li = find(reg & (rtyp == 0 | ~cellfun('isempty', tabpos)))
    if rtyp(li) == 0
        astr = rmn{li};
    else
        astr = '';
    end
    oaux{li} = auxof(astr, rests{li}, tabpos{li});
end
% These variables keep their values from line to line, as in the C
% version (sscanf leaves them unchanged when a conversion fails).
tm = 0; sub = 0; ch = 0; nm = 0;
mnem = '';
for li = find(~reg)
    if li > 1 && reg(li - 1)
        q = li - 1;
        tm = rtm(q);
        sub = rsub(q);
        ch = rch(q);
        nm = rnm(q);
        if rtyp(q) == 0
            mnem = rmn{q};
        else
            mnem = '';
        end
    end
    line = lines{li};
    n = numel(line);
    p = 10;                             % 1-based (C: line + 9)
    br = isbr(li);
    if br
        while p <= n && line(p) ~= ']'
            p = p + 1;
        end
    end
    while p <= n && line(p) ~= ' '
        p = p + 1;
    end
    rest = line(min(p + 1, n + 1):end);
    [cnt, vals] = wfdbx.internal.csscanf(rest, '%lld%s%d%d%d');
    for k = 1:cnt
        v = vals{k};
        switch k
            case 1
                tm = v;
            case 2
                mnem = v;
            case 3
                sub = wfdbx.internal.cint32(v);
            case 4
                ch = wfdbx.internal.cint32(v);
            case 5
                nm = wfdbx.internal.cint32(v);
        end
    end
    annot.anntyp = wfdbx.strann(mnem);
    if br
        annot.time = -wfdbx.strtim(line);
        if annot.time < 0
            continue;
        end
    else
        annot.time = tm;
    end
    if annot.anntyp == 0
        annot.anntyp = 22;              % NOTE
        astr = mnem;
    else
        % C empties its mnemonic buffer here, so a later line without a
        % mnemonic writes a NOTE annotation.
        mnem = '';
        astr = '';
    end
    written(li) = true;
    otime(li) = annot.time;
    otyp(li) = annot.anntyp;
    osub(li) = mod(sub + 128, 256) - 128;
    och(li) = mod(ch, 256);
    onum(li) = mod(nm + 128, 256) - 128;
    oaux{li} = auxof(astr, rest, find(rest == tab, 1));
end
A.time = otime(written);
A.anntyp = otyp(written);
A.subtyp = osub(written);
A.chan = och(written);
A.num = onum(written);
A.aux = oaux(written);
wfdbx.internal.putann_bulk(0, A);     % putann(0, &annot) for each line
wfdbx.wfdbquit();
status = 0;
end

function aux = auxof(astr, rest, k)
% The aux string of an annotation: the mnemonic of a NOTE and the text
% after the first tab of the line (without its last character).
if ~isempty(k)
    ap = rest(k:end);
    if numel(astr) + numel(ap) + 2 > 256
        e = 256 - numel(astr) - 3;      % (as a Python slice, as in wfdb-x)
        if e < 0
            e = numel(ap) + e;
        end
        ap = ap(1:min(max(e, 0), numel(ap)));
    else
        ap = ap(1:end-1);
    end
    hasap = true;
else
    hasap = false;
end
if ~isempty(astr) || hasap
    if ~isempty(astr) && hasap
        s = [astr, ' ', ap(2:end)];
    elseif ~isempty(astr)
        s = astr;
    else
        s = ap(2:end);
    end
    aux = uint8([mod(numel(s), 256), double(s)]);
else
    aux = [];
end
end
