function status = a2m(args)
%A2M Convert an AHA-format annotation file to MIT format.
%   STATUS = wfdbx.apps.a2m(ARGS) runs the a2m tool with the command-line
%   arguments ARGS (a cell row of char vectors, without the program name)
%   and returns its exit status.
%
%   Usage (as for the C program):
%       a2m -i AHAFILE [OPTIONS ...]
%   where AHAFILE is the name of the AHA-format input annotation file, and
%   OPTIONS may include:
%       -a ANNOTATOR  output annotator name (default: 'atr')
%       -F FREQ       sampling frequency, if the record header does not
%                     specify one (AHA database: 250)
%       -h            print a usage summary
%       -r RECORD     output record name (default: the input file name,
%                     less path and extension)
%       -s TIME       shift annotations by TIME
%       -t TYPE       type of input file (0: written by WFDB applications,
%                     1: short-format tape, 2: long-format tape,
%                     3: compressed file from AHA DB CD-ROMs or diskettes;
%                     default 3 if AHAFILE ends in .ANO or .ano, else 0)
%
%   wfdb-x: if the record header does not give the sampling frequency, -F
%   must give it (the C program assumed the rate of the AHA database,
%   250 Hz, if a header without a frequency existed, and 1 sample per
%   second if there was no header).  Annotation times in milliseconds (types
%   1, 2 and 3) are converted at the record's sampling frequency (the C
%   program assumed 4 ms per sample, i.e., 250 Hz); see
%   docs/DIVERGENCES.md.
%
%   Example:
%       wfdbx.apps.a2m({'-i', '100s.aha', '-r', '100s', '-a', 'cpy'})
%       wfdbx.apps.a2m({'-i', '1201.ANO', '-F', '250'})
%
%   See also wfdbx.apps.m2a, wfdbx.apps.ahaecg2mit.

% Copyright (C) 1983-2010 George B. Moody (original C program, convert/a2m.c).
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
status = wfdbx.internal.app_run(@main, [{'a2m'}, args]);
end

function help(pname)
h = {'where AHAFILE is the name of the AHA-format input annotation file,', ...
    'and OPTIONS may include:', ...
    ' -a ANNOTATOR  specify the output annotator name (default: ''atr'')', ...
    ' -F FREQ       sampling frequency, if the record header does not specify', ...
    '                one (AHA database: 250)', ...
    ' -h            print this usage summary', ...
    ' -r RECORD     specify the name of the output RECORD (default: use the', ...
    '                input file name, less path info and extension, as RECORD)', ...
    ' -s TIME       shift annotations by TIME', ...
    '                (defaults: 0 for TYPE 0,', ...
    '                      5:0 for TYPE 1, (or TYPE 3 if RECORD=x2xx or x3xx)', ...
    '                   2:30:0 for TYPE 2, (or TYPE 3 if RECORD=x0xx or x1xx)', ...
    ' -t TYPE       specify type of file to be converted:', ...
    '                0 for files produced by WFDB applications in AHA format,', ...
    '                1 for short-format tape files,', ...
    '                2 for long-format tape files, or', ...
    '                3 for compressed files from AHA DB CD-ROMs or diskettes', ...
    '                (defaults: 3 if AHAFILE ends in .ANO or .ano, else 0)'};
if wfdbx.wfdbx_get_legacy()  % wfdb-x: legacy mode: the original help text
    h(4:5) = [];                % (without -F)
end
wfdbx.internal.ceprintf('usage: %s -i AHAFILE [ OPTIONS ... ]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function status = main(argv)
pname = argv{1};
argc = numel(argv);
ep = @wfdbx.internal.ceprintf;
ifname = [];
record = [];
oann = 'atr';
typ = -1;
offset = 0;
Ffreq = 0;      % wfdb-x: -F
legacy = wfdbx.wfdbx_get_legacy();
i = 1;
while i < argc
    a = argv{i+1};
    if ~isempty(a) && a(1) == '-'
        if numel(a) >= 2
            c = a(2);
        else
            c = '';
        end
        if legacy && strcmp(c, 'F')   % wfdb-x: legacy mode: not an option of
            c = '';                     % the original (unrecognized)
        end
        switch c
            case 'a'
                i = i + 1;
                if i >= argc
                    ep('%s: output annotator name must follow -a\n', pname);
                    status = 1;
                    return;
                end
                oann = argv{i+1};
            case 'F'    % sampling frequency follows (wfdb-x)
                [Ffreq, i, ok] = wfdbx.internal.opt_ffreq(argv, i, Ffreq);
                if ~ok
                    status = 1;
                    return;
                end
            case 'h'
                help(pname);
                status = 1;
                return;
            case 'i'
                i = i + 1;
                if i >= argc
                    ep('%s: name of AHA-format input file must follow -i\n', pname);
                    status = 1;
                    return;
                end
                ifname = argv{i+1};
                if typ < 0 && numel(ifname) > 4 && ...
                        any(strcmp(ifname(end-3:end), {'.ANO', '.ano'}))
                    typ = 3;
                end
            case 'r'
                i = i + 1;
                if i >= argc
                    ep('%s: record name must follow -a\n', pname);
                    status = 1;
                    return;
                end
                record = argv{i+1};
            case 's'
                i = i + 1;
                if i >= argc
                    ep('%s: time shift must follow -s\n', pname);
                    status = 1;
                    return;
                end
                offset = i;
            case 't'
                i = i + 1;
                if i < argc
                    typ = wfdbx.internal.atoi(argv{i+1});
                end
                if i >= argc || typ < 0 || typ > 3
                    ep('%s: file type (0-3) must follow -t\n', pname);
                    status = 1;
                    return;
                end
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
if ~ischar(ifname)
    help(pname);
    status = 1;
    return;
end
[ok, infid] = redirect_stdin(ifname);
if ~ok
    ep('%s: can''t read input file `%s''\n', pname, ifname);
    status = 2;
    return;
end
if ~ischar(record)
    record = basename_record(ifname);
end
if typ < 0
    typ = 0;
end
ai = wfdbx.anninfo(oann, 1);                    % WFDB_WRITE
if typ ~= 3
    ai(2) = wfdbx.anninfo('-', 2);              % WFDB_AHA_READ
end
if wfdbx.annopen(record, ai, numel(ai)) < 0
    status = 2;
    return;
end
% wfdb-x: if the record header does not give the sampling frequency, -F
% must give it.  (The C program assumed the rate of the AHA database,
% 250 Hz, if a header without a frequency existed, and 1 sample per second
% if there was no header.)
if legacy
    if wfdbx.sampfreq(record) == 0
        wfdbx.setsampfreq(250);   % the AHA DB is sampled at 250 Hz
    end
elseif wfdbx.sampfreq(record) <= 0
    if Ffreq > 0
        wfdbx.setsampfreq(Ffreq);
    else
        ep('%s: sampling frequency of record %s is not specified (use -F)\n', ...
            pname, record);
        status = 1;
        return;
    end
end
if offset
    offset = wfdbx.strtim(argv{offset+1});
else
    n4 = numel(record) == 4;
    if typ == 1
        offset = wfdbx.strtim('5:0');
    elseif typ == 2
        offset = wfdbx.strtim('2:30:0');
    elseif typ == 3
        if n4 && any(record(2) == '01')
            offset = wfdbx.strtim('2:30:0');
        elseif n4 && any(record(2) == '23')
            offset = wfdbx.strtim('5:0');
        end
    end
end
annot = wfdbx.annotation();
if typ == 0
    while true
        [st, annot] = wfdbx.getann(0, annot);
        if st < 0
            break;
        end
        if annot.chan
            annot.anntyp = wfdbx.internal.cint8(annot.chan);
            annot.chan = 0;
        end
        annot.time = annot.time + offset;
        if wfdbx.putann(0, annot) < 0
            break;
        end
    end
elseif typ == 1 || typ == 2
    % Times in milliseconds are converted at the sampling frequency of the
    % record (wfdb-x; the C program assumed 4 ms per sample, i.e., 250 Hz,
    % whatever the record's frequency).
    fs = wfdbx.sampfreq([]);
    while true
        [st, annot] = wfdbx.getann(0, annot);
        if st < 0
            break;
        end
        if legacy   % wfdb-x: legacy mode: 4 msec/sample
            annot.time = floor(annot.time / 4) + offset;
        else
            annot.time = fix(annot.time * fs / 1000) + offset;   % (WFDB_Time)
        end
        wfdbx.putann(0, annot);
    end
else
    fs = wfdbx.sampfreq([]);    % (milliseconds, as for types 1 and 2)
    inb = read_stdin(infid);
    b = double(inb);
    nb = numel(b);
    k = 0;
    while k + 6 <= nb
        buf = b(k+1:k+6);
        k = k + 6;
        if buf(2) == 255
            break;
        end
        c0 = buf(1);
        if c0 > 127
            c0 = c0 - 256;
        end
        annot.anntyp = wfdbx.ammap(c0);
        if annot.anntyp == 0
            break;
        end
        if buf(1) == double('U')
            annot.subtyp = -1;
        else
            annot.subtyp = 0;
        end
        t = buf(2) * 65536 + buf(3) * 256 + buf(4);
        if legacy   % wfdb-x: legacy mode: 4 msec/sample
            annot.time = floor(t / 4) + offset;
        else
            annot.time = fix(t * fs / 1000) + offset;   % (WFDB_Time)
        end
        wfdbx.putann(0, annot);
    end
end
wfdbx.wfdbquit();
status = 0;
end

function [ok, fid] = redirect_stdin(ifname)
% freopen(ifname, "rb", stdin): the file becomes the standard input (as
% a regular, seekable file).  FID is its file identifier (-1 for '-').
% (It is read only when C reads it: output files opened before may be
% the same file, truncated.)
fid = -1;
ok = true;
if strcmp(ifname, '-')
    return;
end
fid = fopen(ifname, 'rb');
if fid < 0
    ok = false;
    return;
end
st = wfdbx.internal.iostate();
st.stdin_file = wfdbx.internal.WFDBFile(fid, 0, '-', 0);
end

function data = read_stdin(fid)
% The rest of the standard input (as redirected by redirect_stdin).
if fid < 0
    data = wfdbx.internal.stdin_bytes();
else
    data = fread(fid, Inf, 'uint8=>uint8')';
end
end

function rec = basename_record(ifname)
% The input file name without its directory and extension.
k = find(ifname == '/', 1, 'last');
if isempty(k)
    rec = ifname;
else
    rec = ifname(k+1:end);
end
j = find(rec(2:end) == '.', 1);
if ~isempty(j)
    rec = rec(1:j);
end
end
