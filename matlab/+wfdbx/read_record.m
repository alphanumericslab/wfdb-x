function rec = read_record(record, varargin)
%READ_RECORD Read the signals of a record into a matrix.
%   REC = wfdbx.read_record(RECORD) reads all samples of all signals of
%   record RECORD (as rdsamp does: relative to the input directory, or a
%   full path, ~ path or URL) and returns a structure with the fields
%
%     name        the record name
%     fs          sampling frequency (Hz) of the returned samples (0 if
%                 the header does not specify it)
%     signals     NSAMPLES-by-NSIG matrix (double) of samples in ADC units
%                 (invalid samples are wfdbx.WFDB_INVALID_SAMPLE(), i.e.
%                 -32768), or in physical units with 'physical' (invalid
%                 samples are NaN)
%     siginfo     1-by-NSIG wfdbx.siginfo struct array of the signals
%     names       1-by-NSIG cell of signal descriptions
%     units       1-by-NSIG cell of physical units ([] if unspecified;
%                 never assumed to be millivolts)
%     gains       1-by-NSIG ADC units per physical unit (0: uncalibrated)
%     baselines   1-by-NSIG ADC values corresponding to 0 physical units
%     base_time   start time and date from the header, as wfdbx.timstr(0)
%                 gives it (e.g. '[08:45:00 01/01/2001]'), or [] if the
%                 header has none
%     base_time_ms  the base time in milliseconds after midnight (a
%                 double: '14:00:03.500' is 50403500), or [] exactly when
%                 base_time is []
%     base_date   the base date as a 1-by-3 double [year month day], or
%                 [] if the header gives no date
%     sampfrom    sample number of the first returned sample
%     comments    NC-by-1 cell of the info strings (header comments)
%     checksum_ok false if the samples were found not to match the
%                 checksums in the header (the case of the checksum
%                 warning, whether or not 'checksum_warning' is on), true
%                 otherwise; the checksums are verified only when a read
%                 reaches the end of the record
%
%   Options (name-value pairs):
%     'channels'  signals to read: signal numbers (0-based, as in WFDB),
%                 or a cell of numbers and names (default: all)
%     'sampfrom'  first sample: sample number, or a WFDB time string such
%                 as '0:10' or 's3600' (default 0); a time string other
%                 than a sample number ('sN') needs the sampling frequency
%     'sampto'    end (exclusive): sample number or time string
%                 (default: the end of the record)
%     'physical'  true to return physical units, (ADC - baseline) / gain
%                 (default false; all selected signals must be calibrated)
%     'highres'   true to read multi-frequency records in WFDB_HIGHRES
%                 mode (all samples of the fastest signals; default false:
%                 one sample per frame, averaged)
%     'pad'       true to replace invalid samples by the previous valid
%                 sample (WFDB_GVPAD mode; default false)
%     'input_dir' the input directory for this call (a local directory,
%                 a ~ name or a URL; '' for the default; see
%                 wfdbx.wfdbx_set_input_dir); default: the current setting
%                 (by default, the current directory)
%     'network'   true to allow reading URLs for this call (false to
%                 forbid it; see wfdbx.wfdbx_set_network); default: the
%                 current setting (by default, not allowed)
%     'legacy'    true to behave as the original package (default false):
%                 the library's legacy mode (wfdbx.wfdbx_set_legacy) is on
%                 during the call (a header without a sampling frequency
%                 means 250 Hz, a missing ADC resolution is inferred from
%                 the format), and 'physical' converts uncalibrated
%                 signals with a gain of 200.  For compatibility only: the
%                 values it assumes are exactly the silent defaults wfdb-x
%                 removed, so results produced with it carry the same
%                 risks.
%     'checksum_warning'  true (the default) to warn when the samples read
%                 to the end of the record do not match the checksums in
%                 its header (false: no warning); the data are returned
%                 either way (see below)
%
%   An error is thrown if the record cannot be read, if a requested
%   signal does not exist, if a time string needs the sampling frequency
%   and the header does not specify it, or if 'physical' is true and a
%   selected signal is uncalibrated (gain 0).  An error is also thrown,
%   'can't read signal data of record REC (getvec status S)', if reading
%   stops with a getvec status below -1 (e.g. -3 for a signal file
%   shorter than its header says, or a read or decoding error), also with
%   'legacy'; reaching the end of the record before 'sampto' is not an
%   error.  Nor is a checksum error (getvec status -4: the samples are
%   complete, their sum does not match the header's checksums): every
%   frame is returned, the last one included, with the warning
%   'wfdbx:checksum' ("checksum error in record REC: the signal data do
%   not match the checksums in its header"; option 'checksum_warning'),
%   which replaces getvec's own message; this behavior is identical in
%   all six implementations of wfdb-x.  wfdb-x never assumes a
%   sampling frequency, a gain, an ADC resolution or units (C: 250 Hz,
%   200 adu/mV, 12 bits, millivolts): an unspecified ADC resolution is
%   reported as 0 (siginfo.adcres) and unspecified units as [].  See
%   docs/DIVERGENCES.md.
%
%   The function calls wfdbx.wfdbquit before and after its work, so any
%   signals or annotators opened with the low-level functions
%   (wfdbx.isigopen, wfdbx.annopen, ...) are closed.
%
%   Examples:
%       rec = wfdbx.read_record('100s', 'sampto', 1000, 'physical', true);
%       size(rec.signals)       % [1000 2]
%       plot((0:999) / rec.fs, rec.signals(:, 1));
%       xlabel('time (s)'); ylabel(rec.names{1});
%
%       % 10 seconds of signal V5, starting 30 s into the record
%       rec = wfdbx.read_record('100s', 'channels', {'V5'}, ...
%                               'sampfrom', '0:30', 'sampto', '0:40');
%
%   See also wfdbx.write_record, wfdbx.read_header, wfdbx.getframes.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): a checksum error (getvec
% status -4: the samples are complete, their sum does not match the
% header's checksums) is not an error of read_record but a warning
% ('checksum_warning', false: none); the data are returned.
% Design decision (Reza Sameni, Oct 2026): files are found by explicit
% names (the input directory, the output directory, or a full path or
% URL), not by a search of the WFDB path, and PhysioNet (or any server) is
% accessed only if asked for ('network', true): a search can silently open
% the wrong file, fails in ways nobody notices, and sent local paths and
% record names to physionet.org.  The original behavior remains available
% with --legacy (see docs/DIVERGENCES.md).
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% The original behavior remains available with --legacy (see
% docs/DIVERGENCES.md).
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
    for k = 1:numel(ch)
        c = ch{k};
        if ischar(c)
            j = wfdbx.findsig(c);
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
% more are read.  Frames are read in chunks of about 2^22 samples.
CHUNK = max(65536, floor(4194304 / nsig));
if isfinite(remaining)
    cap = remaining;
else
    cap = max(wfdbx.strtim('e') - from, 0);
end
data = zeros(min(cap, max(65536, floor(33554432 / nsig))), nsig);
nrows = 0;
cksum_error = false;
S = wfdbx.internal.sig_state();
S.cksum_quiet = true;       % (getvec's checksum message: see below)
quiet = onCleanup(@() set_cksum_quiet(S, false)); %#ok<NASGU>
while remaining > 0
    n = min(CHUNK, remaining);
    [x, stat, last] = wfdbx.getframes(n);
    % wfdb-x: -4, a checksum error: the frames are complete (the last one,
    % for which getvec returned -4, included), only their sum does not
    % match the header: a warning (see below), not an error
    if stat == -4
        x = [x; last]; %#ok<AGROW>
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
        cksum_error = true;
        break;
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
