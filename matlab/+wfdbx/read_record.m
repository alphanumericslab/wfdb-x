function rec = read_record(record, varargin)
%READ_RECORD Read the signals of a record into a matrix.
%   REC = wfdbx.read_record(RECORD) reads all samples of all signals of the
%   record RECORD and returns them in a structure.  RECORD is a record name
%   read from the input directory, or a full path, a ~ path or a URL (see
%   wfdbx.wfdbx_set_input_dir).
%
%   REC = wfdbx.read_record(RECORD, NAME, VALUE, ...) takes these options:
%
%     'channels'  signals to read: signal numbers (starting at 0), or a cell
%                 array of numbers and names (by name, as in names; default:
%                 all signals)
%     'sampfrom'  first sample: a sample number, or a time string such as
%                 '0:10' (10 seconds) or 's3600' (sample 3600); default 0
%     'sampto'    the sample after the last one: a sample number or a time
%                 string (default: the end of the record)
%     'physical'  true to return physical units instead of ADC units
%                 (default false)
%     'highres'   true to read a multi-frequency record at its highest
%                 sampling frequency (default false)
%     'pad'       true to replace invalid samples by the previous valid
%                 one (default false)
%     'checksum_warning'  false to turn off the warning given when the data
%                 do not match the header's checksums (default true)
%     'input_dir' input directory for this call only (default: the current
%                 setting)
%     'network'   true to allow network access for this call only (default:
%                 the current setting)
%     'legacy'    true to behave as the original WFDB package (default
%                 false; see wfdbx.wfdbx_set_legacy)
%
%   REC has these fields:
%
%     signals     matrix of doubles, one row per sample and one column per
%                 signal, in ADC units, or in physical units with
%                 'physical'.  Invalid samples are wfdbx.WFDB_INVALID_SAMPLE()
%                 (-32768), or NaN in physical units.
%     fs          sampling frequency in Hz (0 if the header gives none)
%     names       cell array of the signal descriptions, such as 'MLII',
%                 without the white space that a header may put at either
%                 end of it
%     units       cell array of the physical units ([] if the header gives
%                 none)
%     gains       ADC units per physical unit of each signal (0 means
%                 uncalibrated)
%     baselines   baseline of each signal, in ADC units
%     siginfo     the full signal specifications (wfdbx.siginfo structures;
%                 desc without white space at either end)
%     name        the record name
%     sampfrom    the number of the first sample returned
%     base_time   start time and date as text, to the second, such as
%                 '[14:00:03 21/06/2024]', or []
%     base_time_ms  start time in milliseconds after midnight (50403500 for
%                 14:00:03.500), or []
%     base_date   start date as [year month day], or []
%     comments    the info strings of the header (a cell column)
%     checksum_ok false if the data do not match the header's checksums
%
%   Errors: an error (identifier 'wfdbx:read_record') is thrown if the
%   record cannot be read, if a signal file is shorter than its header says
%   ("can't read signal data of record REC (getvec status -3)"), if a
%   requested signal does not exist, if a time string needs the sampling
%   frequency and the header gives none, or if 'physical' is true and a
%   selected signal is uncalibrated.  If the data do not match the header's
%   checksums, all the data are returned with the warning 'wfdbx:checksum'.
%   Checksums are only checked when a read reaches the end of the record.
%
%   The function calls wfdbx.wfdbquit, which closes anything opened with the
%   WFDB library functions.
%
%   Examples (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       rec = wfdbx.read_record('100s', 'sampto', 1000, 'physical', true);
%       size(rec.signals)       % [1000 2]
%       plot((0:999) / rec.fs, rec.signals(:, 1));
%
%       % signal V5, from 30 to 40 seconds
%       rec = wfdbx.read_record('100s', 'channels', {'V5'}, ...
%                               'sampfrom', '0:30', 'sampto', '0:40');
%
%   See also wfdbx.read_header, wfdbx.write_record, wfdbx.read_annotations.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package. Like the rest of WFDB-x, it
% never assumes a sampling frequency or gain, finds files only where they
% are named, and opens URLs only if network access is allowed; a checksum
% error is a warning, not an error (see docs/DIVERGENCES.md).
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

record = wfdbx.internal.strarg(record);
opt = struct('channels', [], 'sampfrom', 0, 'sampto', [], ...
    'physical', false, 'highres', false, 'pad', false, 'input_dir', [], ...
    'network', [], 'legacy', false, 'checksum_warning', true);
opt = wfdbx.internal.hl_options(opt, varargin, 'read_record');
legacy = wfdbx.internal.hl_legacy(opt.legacy, 'read_record'); %#ok<NASGU>
% wfdb-x: the input directory and network access for this call
restore_input = wfdbx.internal.hl_input(opt.input_dir, opt.network, 'read_record'); %#ok<NASGU>
% the library's legacy mode also applies (wfdbx.wfdbx_set_legacy)
opt.legacy = opt.legacy || wfdbx.wfdbx_get_legacy() ~= 0;
wfdbx.wfdbquit();
nsig = wfdbx.isigopen(record, 0);
if nsig <= 0
    wfdbx.wfdbquit();
    error('wfdbx:read_record', 'can''t read record %s', record);
end
[nsig, si] = wfdbx.isigopen(record, nsig);
if nsig <= 0
    wfdbx.wfdbquit();
    error('wfdbx:read_record', 'can''t open signals of record %s', record);
end
mode = 0;
if opt.highres
    mode = 1;           % WFDB_HIGHRES
end
if opt.pad
    mode = mode + 2;    % WFDB_GVPAD
end
wfdbx.setgvmode(mode);
fs = wfdbx.sampfreq([]);
% wfdb-x: no default sampling frequency (C assumed 250 Hz)
[from, ok1] = wfdbx.internal.hl_time(opt.sampfrom, fs);
[to, ok2] = wfdbx.internal.hl_time(opt.sampto, fs);
if ~ok1 || ~ok2
    wfdbx.wfdbquit();
    error('wfdbx:read_record', ...
        'sampling frequency of record %s is not specified', record);
end
if isempty(from)
    from = 0;
end
% wfdb-x: the signal names without the white space at their ends
si = wfdbx.internal.strip_desc(si);
if isempty(opt.channels)
    cols = 0:nsig - 1;
else
    ch = opt.channels;
    if ischar(ch)
        ch = {ch};
    elseif isnumeric(ch)
        ch = num2cell(ch);
    end
    cols = zeros(1, numel(ch));
    names = {si.desc};
    for k = 1:numel(ch)
        c = ch{k};
        if ischar(c)
            % (among the names without white space first)
            j = find(strcmp(wfdbx.internal.strip_desc(c), names), 1) - 1;
            if isempty(j)
                j = wfdbx.findsig(c);
            end
        else
            j = c;
        end
        if ~isscalar(j) || j < 0 || j >= nsig || j ~= fix(j)
            wfdbx.wfdbquit();
            if ischar(c)
                error('wfdbx:read_record', 'record %s has no signal %s', record, c);
            end
            error('wfdbx:read_record', 'record %s has no signal %g', record, c);
        end
        cols(k) = j;
    end
end
[base_time, base_time_ms, base_date] = wfdbx.internal.hl_basetime(fs);
if opt.physical && ~opt.legacy
    % wfdb-x: no default gain (C assumed 200 adu/mV, as legacy mode does)
    k = find([si(cols + 1).gain] == 0, 1);
    if ~isempty(k)
        wfdbx.wfdbquit();
        error('wfdbx:read_record', 'signal %d of record %s is uncalibrated', ...
            cols(k), record);
    end
end
if wfdbx.isigsettime(from) < 0
    wfdbx.wfdbquit();
    error('wfdbx:read_record', 'can''t seek to sample %d of record %s', from, record);
end
if isempty(to)
    remaining = Inf;
else
    remaining = max(to - from, 0);
end
% The output is allocated once, for the number of frames requested or (to
% the end) those the header gives (strtim('e')), up to 2^25 samples (a
% header may claim more than its files hold); it grows (doubling) only if
% more are read.  Frames are read in chunks of about 2^22 samples (whole
% frames, a multiple of 6 of them, so that formats 212, 310 and 311 end
% each chunk on a whole packed unit: the frames are then read in blocks).
CHUNK = max(65536, floor(4194304 / nsig));
S = wfdbx.internal.sig_state();
if opt.highres
    unit = 6 * max(S.ispfmax, 1);
else
    unit = 6;
end
CHUNK = CHUNK - mod(CHUNK, unit);
if isfinite(remaining)
    cap = remaining;
else
    cap = max(wfdbx.strtim('e') - from, 0);
end
data = zeros(min(cap, max(65536, floor(33554432 / nsig))), nsig);
nrows = 0;
cksum_error = false;
S.cksum_quiet = true;       % (getvec's checksum message: see below)
quiet = onCleanup(@() set_cksum_quiet(S, false)); %#ok<NASGU>
while remaining > 0
    n = min(CHUNK, remaining);
    [x, stat, last] = wfdbx.getframes(n);
    % wfdb-x: -4, a checksum error: the samples are valid (the vector for
    % which getvec returned -4 included), only their sum does not match
    % the header: a warning (see below), not an error.  In high-resolution
    % mode getvec returns -4 for each sample vector of the frame at which
    % the checksums are verified, so the reading continues to -1.
    if stat == -4
        x = [x; last]; %#ok<AGROW>
        cksum_error = true;
    end
    k = size(x, 1);
    if k > 0
        if nrows + k > size(data, 1)
            data = [data(1:nrows, :); zeros(max(nrows, k), nsig)]; %#ok<AGROW>
        end
        data(nrows + 1:nrows + k, :) = x;
        nrows = nrows + k;
    end
    remaining = remaining - size(x, 1);
    if stat == -4
        continue;
    end
    if size(x, 1) < n
        % wfdb-x: a status below -1 (e.g. -3, unexpected EOF: a signal
        % file shorter than its header says, or a decoder or I/O error) is
        % an error, not the end of the data (-1)
        if stat < -1
            wfdbx.wfdbquit();
            error('wfdbx:read_record', ...
                'can''t read signal data of record %s (getvec status %d)', ...
                record, stat);
        end
        break;
    end
end
S.cksum_quiet = false;
if cksum_error && opt.checksum_warning
    warning('wfdbx:checksum', ['checksum error in record %s: the signal ' ...
        'data do not match the checksums in its header'], record);
end
if nrows < size(data, 1)
    data = data(1:nrows, :);
end
if ~isequal(cols, 0:nsig - 1)
    data = data(:, cols + 1);
end
sel = si(cols + 1);
comments = cell(0, 1);
c = wfdbx.getinfo(record);
while ischar(c)
    comments{end + 1, 1} = c; %#ok<AGROW>
    c = wfdbx.getinfo([]);
end
gains = [sel.gain];
baselines = [sel.baseline];
if opt.physical
    g = gains;
    if opt.legacy
        g(g == 0) = 200;    % WFDB_DEFGAIN (wfdb-x: legacy mode)
    end
    inv = data == -32768;   % WFDB_INVALID_SAMPLE
    data = (data - baselines) ./ g;
    data(inv) = NaN;
end
rec.name = record;
rec.fs = fs;
rec.signals = data;
rec.siginfo = sel;
rec.names = {sel.desc};
rec.units = {sel.units};
rec.gains = gains;
rec.baselines = baselines;
rec.base_time = base_time;
rec.base_time_ms = base_time_ms;
rec.base_date = base_date;
rec.sampfrom = from;
rec.comments = comments;
rec.checksum_ok = ~cksum_error;
wfdbx.wfdbquit();
end

function set_cksum_quiet(S, on)
S.cksum_quiet = on;
end
