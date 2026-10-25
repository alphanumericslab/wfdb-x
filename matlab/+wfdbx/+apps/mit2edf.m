function status = mit2edf(args)
%MIT2EDF Convert a WFDB (MIT-format) record to an EDF file.
%   STATUS = wfdbx.apps.mit2edf(ARGS) runs the mit2edf tool with the
%   command-line arguments ARGS (a cell row of char vectors, without the
%   program name) and returns its exit status.
%
%   Usage (as for the C program):
%       mit2edf -r RECORD [OPTIONS ...]
%   where OPTIONS may include:
%       -h          print a usage summary
%       -o EDFILE   write the specified EDF file (default: RECORD.edf)
%       -p          write the output as an EDF+ file
%       -v          select verbose mode
%
%   wfdb-x: the record must specify its sampling frequency, and the gain
%   and the ADC resolution of each signal (the C program assumed 250 Hz
%   and 200 adu/mV, and guessed the resolution from the format);
%   unspecified units are written as "nd" (C: "mV"); see
%   docs/DIVERGENCES.md.
%
%   Example:
%       wfdbx.apps.mit2edf({'-r', '100s', '-o', '100s.edf'})
%
%   See also wfdbx.apps.edf2mit.

% Copyright (C) 2002-2014 George B. Moody (original C program,
% convert/mit2edf.c; revised 2020 by Benjamin Moody).
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
status = wfdbx.internal.app_run(@main, [{'mit2edf'}, args]);
end

function help(pname)
h = {'where RECORD is the name of the input record, and OPTIONS may include:', ...
    ' -h          print this usage summary', ...
    ' -o EDFILE   write the specified European Data Format file (default:', ...
    '              RECORD.edf)', ...
    ' -p          write the output as an EDF+ file', ...
    ' -v          select verbose mode', ...
    'This program reads MIT-format signal and header files and writes an EDF', ...
    'file containing the same data.'};
wfdbx.internal.ceprintf('usage: %s -r RECORD [OPTIONS ...]\n', pname);
for k = 1:numel(h)
    wfdbx.internal.ceprintf('%s\n', h{k});
end
end

function V = read_frames(nf, nsig, tspf)
% NF calls of getframe: one row per frame; frames for which getframe does
% not return NSIG are rows of WFDB_INVALID_SAMPLE.
V = zeros(nf, tspf, 'int32');
got = 0;
v = zeros(1, tspf);
bulk = tspf == nsig;    % then getvec (and its bulk path) is getframe
while got < nf
    if bulk
        [blk, ok] = wfdbx.internal.bulk_frames(nf - got);
        if ok && ~isempty(blk)
            m = size(blk, 1);
            V(got + 1:got + m, :) = blk(:, 1:tspf);
            got = got + m;
            continue;
        end
    end
    [stat, v] = wfdbx.getframe(v);
    if stat ~= nsig
        V(got + 1, :) = -32768;
        if at_end()
            V(got + 2:end, :) = -32768;
            return;
        end
    else
        V(got + 1, :) = v(1:tspf);
    end
    got = got + 1;
end
end

function tf = at_end()
% True if every later getframe call is certain to fail without any
% visible effect: all signal files are at their end (each group's stat
% is <= 0, so each later read finds the end again), no segment follows,
% and no signal has samples left to count (so no "unexpected EOF" or
% checksum message can be printed).
S = wfdbx.internal.sig_state();
tf = false;
if S.in_msrec
    return;
end
for g = 1:S.nigroup
    if S.igd{g}.stat > 0
        return;
    end
end
isd = S.isd;
for s = 1:S.nisig
    if isd(s).info.nsamp > 0
        return;
    end
end
tf = true;
end

function [header, pos] = put(header, pos, text, advance)
b = uint8(text);
hlen = numel(header);
e = min(pos + numel(b), hlen);
if e > pos
    header(pos + 1:e) = b(1:e - pos);
end
if nargin >= 4
    pos = pos + advance;
end
end

function s = pad8(s)
% strncpy(p, s, 8): at most 8 bytes, padded with NULs.
s = s(1:min(8, numel(s)));
s = [s, char(zeros(1, 8 - numel(s)))];
end

function status = main(argv)
EDFMAXBLOCK = 61440;   % largest EDF data record (bytes), as in C
MONTHS = {'JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', ...
    'OCT', 'NOV', 'DEC'};
pname = argv{1};
argc = numel(argv);
ofname = [];
record = [];
edfplusflag = 0;
vflag = 0;
i = 1;
while i < argc
    a = argv{i + 1};
    if strncmp(a, '-', 1)
        if numel(a) >= 2
            c = a(2);
        else
            c = char(0);
        end
        switch c
            case 'h'
                help(pname);
                status = 0;
                return;
            case 'o'
                i = i + 1;
                if i < argc
                    ofname = argv{i + 1};
                else
                    wfdbx.internal.ceprintf('%s: output file name must follow -o\n', pname);
                    status = 1;
                    return;
                end
            case 'p'
                edfplusflag = 1;
            case 'r'
                i = i + 1;
                if i < argc
                    record = argv{i + 1};
                else
                    wfdbx.internal.ceprintf('%s: record name must follow -r\n', pname);
                    status = 1;
                    return;
                end
            case 'v'
                vflag = 1;
        end
    end
    i = i + 1;
end
if ~ischar(record)
    help(pname);
    status = 1;
    return;
end
if ~ischar(ofname)
    k = find(record == '/', 1, 'last');
    if isempty(k)
        k = 0;
    end
    b = record(k + 1:end);
    ofname = [b(1:min(numel(b), 50)) '.edf'];     % WFDB_MAXRNL
elseif edfplusflag
    if numel(ofname) < 4 || ~(strcmp(ofname(end - 3:end), '.edf') || ...
            strcmp(ofname(end - 3:end), '.EDF'))
        wfdbx.internal.ceprintf('%s: ''%s'' is not a valid EDF+ file name\n', pname, ofname);
        wfdbx.internal.ceprintf(' EDF+ file names must end with ''.edf'' or ''.EDF'')\n');
        status = 1;
        return;
    end
end
nsig = wfdbx.isigopen(record, 0);
if nsig <= 0
    status = 2;
    return;
end
[nsig, si] = wfdbx.isigopen(record, nsig);
if nsig <= 0
    status = 3;
    return;
end
% wfdb-x: an EDF file needs the sampling frequency, and the gain and the ADC
% resolution of each signal (the C program assumed 250 Hz and 200 adu/mV if
% the header did not specify them, and guessed the resolution from the
% format).
legacy = wfdbx.wfdbx_get_legacy();
if ~legacy && wfdbx.sampfreq([]) <= 0
    wfdbx.internal.ceprintf( ...
        '%s: sampling frequency of record %s is not specified\n', pname, record);
    status = 3;
    return;
end
if ~legacy          % (no checks in legacy mode)
    for k = 1:nsig
        if si(k).gain == 0
            wfdbx.internal.ceprintf('%s: signal %d of record %s is uncalibrated\n', ...
                pname, k - 1, record);
            status = 3;
            return;
        end
        if si(k).adcres < 1     % the EDF digital range needs it
            wfdbx.internal.ceprintf( ...
                '%s: ADC resolution of signal %d of record %s is not specified\n', ...
                pname, k - 1, record);
            status = 3;
            return;
        end
    end
end
ofile = fopen(ofname, 'wb');
if ofile < 0
    wfdbx.internal.ceprintf('%s: can''t create %s\n', pname, ofname);
    status = 4;
    return;
end
p = wfdbx.timstr(0);
start_date_recorded = 1;
if ~strncmp(p, '[', 1)
    wfdbx.setbasetime([]);
    p = wfdbx.timstr(0);
    start_date_recorded = 0;
end
[n, v] = wfdbx.internal.csscanf(p, '[%d:%d:%d %d/%d/%d');
tv = zeros(1, 6);
for q = 1:max(n, 0)
    tv(q) = wfdbx.internal.cint32(v{q});
end
hour = tv(1); minute = tv(2); second = tv(3);
day = tv(4); month = tv(5); year = tv(6);
if n ~= 6
    start_date_recorded = 0;
    day = 1;
    month = 1;
    year = 1985;   % (the date of 'Startdate not recorded', as in C)
end
spfs = [si.spf];
samples_per_frame = sum(spfs);
frames_per_second = wfdbx.strtim('1:0') / 60.0;
frames_per_block = fix(10 * frames_per_second + 0.5);
bytes_per_block = 2 * samples_per_frame * frames_per_block;
while bytes_per_block > EDFMAXBLOCK
    frames_per_block = wfdbx.internal.cdiv(frames_per_block, 10);
    bytes_per_block = samples_per_frame * 2 * frames_per_block;
end
seconds_per_block = frames_per_block / frames_per_second;
if frames_per_block < 1 && bytes_per_block < floor(EDFMAXBLOCK / 60)
    frames_per_block = wfdbx.strtim('1:0');
    bytes_per_block = 2 * samples_per_frame * frames_per_block;
    seconds_per_block = 60.0;
end
if bytes_per_block > EDFMAXBLOCK
    wfdbx.internal.ceprintf('%s: can''t convert record %s to EDF\n', pname, record);
    wfdbx.internal.ceprintf(' EDF blocks cannot be larger than %d bytes, but each input frame requires\n', ...
        EDFMAXBLOCK);
    wfdbx.internal.ceprintf([' %d bytes.  Use ''snip'' to select a subset of the input signals, or use\n' ...
        ' ''xform'' to reduce the sampling frequency.\n'], samples_per_frame * 2);
    fclose(ofile);
    status = 5;
    return;
end
nblocks = wfdbx.internal.cdiv(wfdbx.strtim('e'), frames_per_block) + 1;
hlen = (nsig + 1) * 256;
header = repmat(uint8(32), 1, hlen);
if vflag
    if edfplusflag == 1
        mode = 'EDF+';
    else
        mode = 'EDF';
    end
    wfdbx.internal.cout(sprintf('Converting record %s to %s (%s mode)\n', record, ofname, mode));
end
dmax = zeros(1, nsig);
dmin = zeros(1, nsig);
pmax = zeros(1, nsig);
pmin = zeros(1, nsig);
for k = 1:nsig
    % (wfdb-x: the ADC resolution was checked above; the C program guessed
    % it from the storage format if the header did not give it, as legacy
    % mode does.)
    if legacy && si(k).adcres < 1
        si(k).adcres = legacy_adcres(si(k).fmt);
    end
    dmax(k) = wfdbx.internal.cint32(si(k).adczero + 2 ^ (si(k).adcres - 1) - 1);
    dmin(k) = wfdbx.internal.cint32(si(k).adczero - 2 ^ (si(k).adcres - 1));
    pmax(k) = wfdbx.aduphys(k - 1, dmax(k));
    pmin(k) = wfdbx.aduphys(k - 1, dmin(k));
end
pos = 0;
[header, pos] = put(header, pos, '0', 8);
if numel(record) > 80
    record = record(1:79);
end
[header, pos] = put(header, pos, record, 80);
if start_date_recorded
    buf = sprintf('Startdate %02d-%s-%d', day, MONTHS{month}, year);
else
    buf = 'Startdate not recorded';
    if edfplusflag
        wfdbx.internal.ceprintf('WARNING (%s): EDF+ requires start date (not specified)\n', pname);
    end
end
[header, pos] = put(header, pos, buf, 80);
[header, pos] = put(header, pos, pad8(sprintf('%02d.%02d.%02d', day, month, ...
    wfdbx.internal.cmod(year, 100))), 8);
[header, pos] = put(header, pos, pad8(sprintf('%02d.%02d.%02d', hour, minute, second)), 8);
[header, pos] = put(header, pos, sprintf('%d', hlen), 8);
if edfplusflag
    header = put(header, pos, 'EDF+C');
end
pos = pos + 44;   % reserved field (44 bytes)
[header, pos] = put(header, pos, sprintf('%d', nblocks), 8);
buf = wfdbx.internal.csprintf('%g', seconds_per_block);
[header, pos] = put(header, pos, buf(1:min(8, numel(buf))), 8);
[header, pos] = put(header, pos, sprintf('%d', nsig), 4);
for k = 1:nsig
    d = si(k).desc;
    if ~ischar(d)
        d = '';
    end
    if numel(d) > 16
        d = d(1:16);
    end
    si(k).desc = d;
    [header, pos] = put(header, pos, d, 16);
end
for k = 1:nsig
    [header, pos] = put(header, pos, 'transducer type not recorded', 80);
end
for k = 1:nsig
    if ~ischar(si(k).units)
        % wfdb-x: unspecified units are shown as "nd" (C, legacy mode: mV)
        if legacy
            si(k).units = 'mV';
        else
            si(k).units = 'nd';
        end
    elseif numel(si(k).units) > 8
        si(k).units = si(k).units(1:8);
    end
    [header, pos] = put(header, pos, si(k).units, 8);
end
for k = 1:nsig
    [header, pos] = put(header, pos, wfdbx.internal.csprintf('%g', pmin(k)), 8);
end
for k = 1:nsig
    [header, pos] = put(header, pos, wfdbx.internal.csprintf('%g', pmax(k)), 8);
end
for k = 1:nsig
    [header, pos] = put(header, pos, sprintf('%d', dmin(k)), 8);
end
for k = 1:nsig
    [header, pos] = put(header, pos, sprintf('%d', dmax(k)), 8);
end
for k = 1:nsig
    [header, pos] = put(header, pos, 'prefiltering not recorded', 80);
end
for k = 1:nsig
    [header, pos] = put(header, pos, sprintf('%d', frames_per_block * si(k).spf), 8);
end
fwrite(ofile, header, 'uint8');
bad = find(header < 32 | header > 126);   % EDF headers are printable ASCII
for q = 1:numel(bad)
    c = double(header(bad(q)));
    if c > 127
        c = c - 256;
    end
    wfdbx.internal.ceprintf('WARNING (%s): output contains an invalid character, %d, at byte %d\n', ...
        pname, c, bad(q) - 1);
end
blocks_per_minute = 0;
blocks_per_hour = 0;
if vflag
    wfdbx.internal.cout(sprintf(' Header block size: %d bytes\n', hlen));
    if seconds_per_block == 1.0
        s1 = '';
    else
        s1 = 's';
    end
    if frames_per_block == 1
        s2 = '';
    else
        s2 = 's';
    end
    wfdbx.internal.cout(wfdbx.internal.csprintf( ...
        ' Data block size: %g second%s (%d frame%s or %d bytes)\n', ...
        seconds_per_block, s1, frames_per_block, s2, bytes_per_block));
    p = wfdbx.timstr(wfdbx.strtim('e'));
    k = find(p ~= ' ', 1);
    if isempty(k)
        p = '';
    else
        p = p(k:end);
    end
    wfdbx.internal.cout(sprintf(' Recording length: %s (%d data blocks, %d frames, %d bytes)\n', ...
        p, nblocks, nblocks * frames_per_block, nblocks * bytes_per_block));
    wfdbx.internal.cout(sprintf(' Total length of file to be written: %d bytes\n', ...
        hlen + nblocks * bytes_per_block));
    blocks_per_minute = fix(60 / seconds_per_block);
    blocks_per_hour = 60 * blocks_per_minute;
end
% All the frames (one row each), then the blocks: in each block, the
% samples of signal 0 for all its frames, then those of signal 1, ...
nfr = nblocks * frames_per_block;
if nblocks > 0 && frames_per_block > 0
    V = read_frames(nfr, nsig, samples_per_frame);
    parts = cell(nsig, 1);
    c0 = 0;
    for k = 1:nsig
        x = V(:, c0 + 1:c0 + spfs(k)).';
        parts{k} = reshape(x, spfs(k) * frames_per_block, nblocks);
        c0 = c0 + spfs(k);
    end
    % the low 16 bits of each sample, in little-endian byte order
    fwrite(ofile, mod(vertcat(parts{:}), 65536), 'uint16', 0, 'ieee-le');
end
fclose(ofile);
if vflag
    dots = cell(1, nblocks);
    for nb = 1:nblocks
        s = '';
        if blocks_per_minute ~= 0 && mod(nb, blocks_per_minute) == 0
            s = '.';
        end
        if blocks_per_hour ~= 0 && mod(nb, blocks_per_hour) == 0
            s = [s char(10)]; %#ok<AGROW>
        end
        dots{nb} = s;
    end
    wfdbx.internal.cout([dots{:}]);
end
wfdbx.internal.cout(char(10));
if edfplusflag
    wfdbx.internal.ceprintf(['\nWARNING (%s): EDF+ requires the subject''s gender, birthdate, and name, as\n' ...
        ' well as additional information about the recording that is not usually\n' ...
        ' available.  This information is not saved in the output file even if\n' ...
        ' available.  EDF+ also requires the use of standard names for signals and\n' ...
        ' for physical units;  these requirements are not enforced by this program.\n' ...
        ' To make the output file fully EDF+ compliant, its header must be edited\n' ...
        ' manually.\n'], pname);
    if ~any(strcmp({si.desc}, 'EDF-Annotations'))
        wfdbx.internal.ceprintf(['\nWARNING:  The output file does not include EDF annotations, which are\n' ...
            ' required for EDF+.\n']);
    end
end
wfdbx.wfdbquit();
status = 0;
end

function r = legacy_adcres(f)
% wfdb-x: legacy mode: the C program's guess of the ADC resolution from the
% storage format
switch f
    case {524, 24}
        r = 24;
    case 32
        r = 32;
    case {508, 80}
        r = 8;
    case 212
        r = 12;
    case {310, 311}
        r = 10;
    case {516, 16, 61, 160}
        r = 16;
    otherwise
        if f >= 100 && mod(f, 100) > 0 && mod(f, 100) <= 32
            r = mod(f, 100);
        else
            r = 16;
        end
end
end
