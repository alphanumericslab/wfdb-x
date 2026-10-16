function status = ahaecg2mit(args)
%AHAECG2MIT Convert AHA DB files (from the AHA DVD) to WFDB format.
%   STATUS = wfdbx.apps.ahaecg2mit(ARGS) runs the ahaecg2mit tool with
%   the command-line arguments ARGS (a cell row of char vectors, without
%   the program name) and returns its exit status.
%
%   Usage (as for the C program):
%       ahaecg2mit [-s] -F FREQ -G GAIN -R BITS -U UNITS RECORD.XXX ...
%   where RECORD.XXX is the name of an AHA DVD input file ('RECORD' is one
%   of the 4-digit AHA DB record names, and 'XXX' is 'ecg' or 'txt').  The
%   output files are RECORD.hea, RECORD.atr and RECORD.dat.  With -s,
%   short-format (35-minute) records are made from long-format (2.5 hour)
%   input files (the first 145 minutes, at the frequency given by -F, are
%   skipped), and the second digit of the record name is incremented by
%   2.  -F, -G, -R and -U give the sampling frequency (Hz), gain (adu per
%   physical unit), ADC resolution (bits) and units of the signals.  The
%   options precede the input files, in any order.
%
%   wfdb-x: -F, -G, -R and -U are new and required (-U unless the gain is
%   0); the C program assumed the parameters of the AHA database (250 Hz,
%   400 adu/mV, 12 bits, millivolts): use -F 250 -G 400 -R 12 -U mV for
%   the AHA DVD files; see docs/DIVERGENCES.md.
%
%   Example:
%       wfdbx.apps.ahaecg2mit({'-F', '250', '-G', '400', '-R', '12', ...
%           '-U', 'mV', '1001.ecg'})
%
%   See also wfdbx.apps.a2m, wfdbx.apps.ad2m.

% Original C program, convert/ahaecg2mit.c, by George B. Moody (2008; revised
% 2017 by Benjamin Moody); the C source has no copyright or license notice.
% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% GNU General Public License, version 2 or later (see LICENSE).

if nargin < 1
    args = {};
end
status = wfdbx.internal.app_run(@main, [{'ahaecg2mit'}, args]);
end

function status = main(argv)
ep = @wfdbx.internal.ceprintf;
argc = numel(argv);
legacy = wfdbx.wfdbx_get_legacy();
if argc < 2 || strcmp(argv{2}, '-h')
    if legacy   % wfdb-x: the usage of the C program
        ep('usage: %s [-s] RECORD.XXX [RECORD.XXX]...\n', argv{1});
    else
        ep(['usage: %s [-s] -F FREQ -G GAIN -R BITS -U UNITS RECORD.XXX ' ...
            '[RECORD.XXX]...\n'], argv{1});
    end
    ep('%s', [' where RECORD.XXX is the name of the AHA DVD input file to' ...
        ' be converted' char(10) ...
        ' (''RECORD'' is one of the 4-digit AHA DB record names, and' ...
        ' ''XXX'' may be either' char(10) ' ''ecg'' or ''txt'', depending on the' ...
        ' version of the AHA DVD.)' char(10) ...
        ' Output files are RECORD.hea (text), RECORD.atr (binary),' ...
        ' RECORD.dat (binary).' char(10) ...
        ' Two or more input files may be converted in a single run.' char(10) ...
        ' Use -s to make short-format (35-minute) records from' ...
        ' long-format (2.5 hour)' char(10) ' input files.  When using -s, the' ...
        ' second digit in the output record name is' char(10) ...
        ' incremented by 2.' char(10)]);
    if ~legacy
        ep('%s', [' -F, -G, -R and -U give the sampling frequency (Hz), gain' ...
            ' (adu per physical' char(10) ' unit), ADC resolution (bits) and units' ...
            ' of the signals; for the AHA DVD' char(10) ' files, use -F 250' ...
            ' -G 400 -R 12 -U mV.' char(10)]);
    end
    status = 1;
    return;
end
SKIP_MINUTES = 145;     % the part of a long-format record not in the short one
FRAME_BYTES = 5;        % bytes per sample frame of a binary (.ecg) file
% wfdb-x: options (-s and the signal parameters) precede the input files,
% in any order.
P = wfdbx.internal.sigparams();
sflag = 0;
i = 1;
if legacy
    % wfdb-x: in legacy mode, the option of the C program (-s only, as the
    % first argument), and the parameters of the AHA database that it set
    % (250 Hz, 400 adu/mV, 12 bits, millivolts).
    if strcmp(argv{2}, '-s')
        sflag = 1;      % produce short-format (35-minute) records
        i = 2;
    end
    P.F = 250;
    P.G = 400;
    P.Gset = 1;
    P.R = 12;
    P.U = 'mV';
end
while ~legacy && i < argc
    a = argv{i+1};
    if numel(a) ~= 2 || a(1) ~= '-' || ~any(a(2) == 'sFGRU')
        break;
    end
    if a(2) == 's'
        sflag = 1;      % produce short-format (35-minute) records
    else
        [P, i, ok] = wfdbx.internal.opt_sigparam(argv, i, P);
        if ~ok
            status = 1;
            return;
        end
    end
    i = i + 1;
end
% wfdb-x: the signal parameters must be given explicitly (see
% docs/DIVERGENCES.md); in legacy mode, these checks pass.
[P, ok] = wfdbx.internal.sigparams(argv{1}, P, 'FGRU');
if ~ok
    status = 1;
    return;
end
nskip = 0;
if sflag    % the first 145 minutes, in samples
    nskip = fix(SKIP_MINUTES * 60 * P.F);
end
while i < argc
    name = argv{i+1};
    ext = name(max(1, end-3):end);
    if any(strcmp(ext, {'.ecg', '.ECG'}))
        fmt = 1;
    elseif any(strcmp(ext, {'.txt', '.TXT'}))
        fmt = 2;
    else
        ep('%s: ignoring ''%s''\n', argv{1}, name);
        i = i + 1;
        continue;
    end
    fid = fopen(name, 'rb');
    if fid < 0
        ep('%s: can''t open ''%s''\n', argv{1}, argv{2});
        i = i + 1;
        continue;
    end
    data = fread(fid, Inf, 'uint8=>uint8')';
    fclose(fid);
    stem = name(1:end-4);
    argv{i+1} = stem;       % (*p = '\0' strips the extension)
    record = stem(max(1, end-3):end);
    if fmt == 1
        [V, A] = readbin(data, nskip * FRAME_BYTES);    % fseek
    else
        [V, A] = readtxt(data, nskip);
    end
    if sflag && numel(record) > 1
        % (a record name shorter than 2 characters is left unchanged)
        record(2) = char(mod(double(record(2)) + 2, 256));
    end
    process(record, V, A, P);
    i = i + 1;
end
status = 0;
end

function process(record, V, A, P)
wfdbx.setsampfreq(P.F);   % wfdb-x: -F (the C program set 250 Hz)
ofname = [record '.dat'];
si = wfdbx.siginfo(2);
for k = 1:2
    si(k).fname = ofname;
    si(k).desc = sprintf('ECG%d', k - 1);
    si(k).units = P.U;
    si(k).gain = P.G;
    si(k).fmt = 212;
    si(k).adcres = P.R;
    si(k).spf = 0;
end
if wfdbx.osigfopen(si, 2) ~= 2 || ...
        wfdbx.annopen(record, wfdbx.anninfo('atr', 1), 1) < 0  % WFDB_WRITE
    wfdbx.wfdbquit();
    return;
end
if ~isempty(V)
    wfdbx.putframes(V);
end
if ~isempty(A.time)
    wfdbx.internal.putann_bulk(0, A);
end
wfdbx.newheader(record);
wfdbx.wfdbquit();
wfdbx.internal.ceprintf('wrote %s.atr, %s.dat, and %s.hea\n', record, record, record);
end

function A = annots(time, code)
% Annotations at TIME with the AHA codes CODE (bytes).
n = numel(time);
typ = wfdbx.ammap(double(code(:)'));
A = struct('time', time(:)', 'anntyp', typ, 'subtyp', 0 - (code(:)' == 'U'), ...
    'chan', zeros(1, n), 'num', zeros(1, n), 'aux', {cell(1, n)});
end

function [V, A] = readbin(data, off)
% The samples and annotations of the binary format (readbindata()), from
% byte OFF of the file.
b = double(data(off+1:end));
nr = floor(numel(b) / 5);
R = reshape(b(1:5*nr), 5, nr);
V = [R(1, :) + 256 * R(2, :); R(3, :) + 256 * R(4, :)]';
k = find(R(5, :) ~= double('.'));
% t starts at -1 and is incremented after each sample
A = annots(k - 2, R(5, k));
end

function [V, A] = readtxt(data, nskip)
% The text format: the successive calls of readtxtdata() (after NSKIP
% calls with -s), until the first one that returns 0.  Each call reads up
% to 16 characters (to a CR, LF or EOF; a byte 255 reads as EOF) into a
% buffer that keeps the bytes of earlier lines and is not NUL-terminated
% (bytes beyond it are read as NUL; see KNOWN_C_BEHAVIORS.md).
ep = @wfdbx.internal.ceprintf;
b = double(data(:)');
nb = numel(b);
T = [find(b == 13 | b == 10 | b == 255), nb + 1];  % terminators
S = [1, T(1:end-1) + 1];                % segment starts
L = T - S;                              % characters before each terminator
q = floor(L / 16);                      % full (16-character) calls
K = sum(q + 1);
seg = repelem(1:numel(T), q + 1);
first = cumsum([1, q(1:end-1) + 1]);
r = (1:K) - first(seg);                 % index of the call in its segment
st = S(seg) + 16 * r;                   % first character read
m = 16 * ones(1, K);                    % characters stored
last = r == q(seg);
m(last) = L(seg(last)) - 16 * q(seg(last));
% the last character read (c), and whether the call returns at EOF
cend = zeros(1, K);
full = ~last;
cend(full) = b(st(full) + 15);
tl = T(seg(last));
atend = tl > nb;
cl = zeros(1, numel(tl));
cl(~atend) = b(tl(~atend));
cend(last) = cl;
eofc = false(1, K);
eofc(last) = atend | cl == 255;
cend(cend > 127) = cend(cend > 127) - 256;
% Results of sscanf(buf, "%d,%d,\"%c", v, v+1, &c): n, values.
nres = zeros(1, K);
v0 = zeros(1, K);
v1 = zeros(1, K);
cc = zeros(1, K);
done = false(1, K);
% Fast path: the characters stored by the call are converted completely
% (so the rest of the buffer does not matter).
consumed = m + (last & ~isreal_all(atend, last, K));
bm = b;
bm(bm > 127) = 1;           % (regexp needs valid UTF-8 in Octave)
strs = mat2cell(char(bm), 1, consumed);
[tok, e] = regexp(strs, ['^[ \t\v\f]*([+-]?\d{1,9}),[ \t\v\f]*' ...
    '([+-]?\d{1,9}),"[^\x00]'], 'tokens', 'end', 'once');
ok = ~cellfun('isempty', tok) & ~eofc;
okk = find(ok);
ee = [e{ok}];
okk = okk(ee <= m(okk));
ee = ee(ee <= m(ok));
if ~isempty(okk)
    Tk = reshape([tok{okk}], 2, []);
    nres(okk) = 3;
    v0(okk) = str2double(Tk(1, :));
    v1(okk) = str2double(Tk(2, :));
    cc(okk) = b(st(okk) + ee - 1);
    done(okk) = true;
end
% A call that stores nothing leaves the buffer as the previous call did.
z = find(m == 0 & ~eofc);
z = z(z > 1);
z = z(done(z - 1) & ~eofc(z - 1));
nres(z) = nres(z - 1);
v0(z) = v0(z - 1);
v1(z) = v1(z - 1);
cc(z) = cc(z - 1);
done(z) = true;
% Slow path: build the buffer and scan it.
slow = find(~done & ~eofc);
bufs = cell(1, K);
if ~isempty(slow)
    buf = zeros(numel(slow), 16);
    idx = 1:K;
    for j = 1:16
        lj = cummax(idx .* (m >= j));
        kk = lj(slow);
        has = kk > 0;
        buf(has, j) = b(st(kk(has)) + j - 1);
    end
    for k = 1:numel(slow)
        s = buf(k, :);
        e = find(s == 0, 1);
        if ~isempty(e)
            s = s(1:e-1);
        end
        s = char(s);
        bufs{slow(k)} = s;
        [n, vals] = wfdbx.internal.csscanf(s, '%d,%d,"%c');
        nres(slow(k)) = n;
        if numel(vals) >= 1
            v0(slow(k)) = wfdbx.internal.cint32(vals{1});
        end
        if numel(vals) >= 2
            v1(slow(k)) = wfdbx.internal.cint32(vals{2});
        end
        if numel(vals) >= 3
            cc(slow(k)) = double(vals{3});
        end
    end
end
% v[0] and v[1] keep their values when they are not assigned.
idx = 1:K;
a0 = cummax(idx .* (nres >= 1 & ~eofc));
a1 = cummax(idx .* (nres >= 2 & ~eofc));
V0 = zeros(1, K);
V1 = zeros(1, K);
V0(a0 > 0) = v0(a0(a0 > 0));
V1(a1 > 0) = v1(a1(a1 > 0));
err = ~eofc & nres < 3;
ret0 = err | eofc;
% the calls of the -s skip, then those of the conversion, up to the
% first that returns 0
k0 = min(nskip, K);
k1 = find(ret0(k0+1:end), 1) + k0;
if isempty(k1)
    k1 = K + 1;
end
for k = find(err(1:min(k1, K)))
    ep('Error: improperly formatted input!\n');
    ep(' n = %d, buf = |%s|, v[0] = %d, v[1] = %d, c = |%c|\n', ...
        nres(k), bufs{k}, V0(k), V1(k), mod(cend(k), 256));
end
ks = k0+1:k1-1;
V = [V0(ks); V1(ks)]';
c = cc(ks);
an = find(c ~= double('"'));
% t starts at -1 and is incremented before each sample
A = annots(an - 1, c(an));
end

function x = isreal_all(atend, last, K)
% True for the calls that end at the real end of the file.
x = false(1, K);
x(last) = atend;
end
