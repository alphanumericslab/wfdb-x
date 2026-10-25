function write_record(record, signals, fs, varargin)
%WRITE_RECORD Write a matrix of samples as a WFDB record.
%   wfdbx.write_record(RECORD, SIGNALS, FS) writes the NSAMPLES-by-NSIG
%   matrix SIGNALS (integer samples in ADC units) as record RECORD: the
%   signal file RECORD.dat and the header
%   RECORD.hea, with sampling frequency FS (Hz, > 0).  Each column is one
%   signal (a single signal is a column vector).  The gains, the ADC
%   resolutions and the units of the calibrated signals are required
%   (options 'gains', 'adcres' and 'units').  wfdb-x never assumes a
%   sampling frequency, a gain, an ADC resolution or units (C: 250 Hz,
%   200 adu/mV, a resolution based on the format, millivolts); see
%   docs/DIVERGENCES.md.
%
%   Options (name-value pairs; a scalar applies to all signals, a vector
%   or cell gives one value per signal):
%     'fmt'         storage format (default 16; 8, 16, 61, 80, 160, 212,
%                   310, 311, 24, 32, 508, 516, 524); all signals must
%                   have the same format
%     'gains'       ADC units per physical unit (required; 0 means
%                   uncalibrated, allowed only if SIGNALS are in ADC
%                   units)
%     'baselines'   ADC values corresponding to 0 physical units
%                   (default: the ADC zeros)
%     'adczeros'    ADC output for zero input (default 0)
%     'adcres'      ADC resolution in bits (required, >= 1)
%     'units'       physical units (char, or cell; required for each
%                   signal whose gain is not 0; [] or '' = unspecified)
%     'names'       signal descriptions (char, or cell; default '')
%     'base_time'   base time (and date), e.g. '12:00:00 01/02/2003'
%     'comments'    cell of info strings, written as header comments
%     'physical'    true if SIGNALS are in physical units: they are then
%                   converted with the gains and baselines (rounding as
%                   wfdbx.physadu does; NaN becomes an invalid sample)
%     'samps_per_frame'  samples per frame of each signal, to write a
%                   multi-frequency record: SIGNALS then has
%                   sum(samps_per_frame) columns, frame by frame (the spf
%                   samples of signal 0, then those of signal 1, ...)
%     'dir'         the directory (which must exist) in which the files
%                   are created (default: the current directory, or the
%                   directory part of RECORD); the header then names the
%                   record and its signal file without the directory, so
%                   that the record opens from that directory under its
%                   plain name (RECORD must not contain a directory)
%     'legacy'      true to behave as the original package (default
%                   false): the library's legacy mode
%                   (wfdbx.wfdbx_set_legacy) is on during the call, and
%                   the gains default to 200, the ADC resolutions to a
%                   value based on the format (8 for formats 80 and 508,
%                   10 for 310 and 311, 12 for 212, 24 for 24 and 524, 32
%                   for 32, otherwise 16), the units are not required (a
%                   gain of 0 is taken as 200 with 'physical'), and FS is
%                   not checked.  For compatibility only: the values it
%                   assumes are exactly the silent defaults wfdb-x
%                   removed, so results produced with it carry the same
%                   risks.
%
%   An error is thrown if the gains are not given, if FS is not > 0, if
%   the ADC resolutions are not given or are < 1, if the units of a
%   signal whose gain is not 0 are not given, if
%   'physical' is true and a gain is 0 (uncalibrated signal), if 'dir' is
%   given and does not exist or RECORD contains a directory, or if the
%   files cannot be written.
%
%   The samples are written with wfdbx.putframes, which encodes them with
%   vector operations, byte for byte as wfdbx.putvec would.
%
%   The function calls wfdbx.wfdbquit before and after its work, so any
%   signals or annotators opened with the low-level functions
%   (wfdbx.isigopen, wfdbx.annopen, ...) are closed.
%
%   Example:
%       x = round(1000 * sin(2 * pi * (0:999)' / 100));
%       wfdbx.write_record('sine', [x, -x], 250, 'fmt', 212, ...
%           'gains', 200, 'adcres', 12, 'units', 'mV', ...
%           'names', {'sin', '-sin'});
%       rec = wfdbx.read_record('sine');
%
%       % physical units (mV), with 360 Hz sampling and a start time
%       t = (0:3599)' / 360;
%       wfdbx.write_record('phys', [sin(2*pi*t), cos(2*pi*t)], 360, ...
%           'physical', true, 'gains', 200, 'adcres', 16, 'units', 'mV', ...
%           'base_time', '12:00:00 01/02/2003');
%
%   See also wfdbx.read_record, wfdbx.putframes, wfdbx.osigfopen.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% The original behavior remains available with --legacy (see
% docs/DIVERGENCES.md).
% Design decision (Reza Sameni, after a code review, Oct 2026): the
% writers take a 'dir' option (the files are created in that directory,
% and the record opens from there under its plain name).
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

record = wfdbx.internal.strarg(record);
% wfdb-x: the gains are required (C's default was WFDB_DEFGAIN)
opt = struct('fmt', 16, 'gains', [], 'baselines', [], 'adczeros', 0, ...
    'adcres', [], 'units', [], 'names', [], 'base_time', [], ...
    'comments', [], 'physical', false, 'samps_per_frame', [], ...
    'dir', [], 'legacy', false);
opt = wfdbx.internal.hl_options(opt, varargin, 'write_record');
% wfdb-x: the 'dir' option (the library's output directory, for this
% call), checked before the other arguments
restore_dir = wfdbx.internal.hl_outdir(opt.dir, record, 'write_record'); %#ok<NASGU>
restore = wfdbx.internal.hl_legacy(opt.legacy, 'write_record'); %#ok<NASGU>
% the library's legacy mode also applies (wfdbx.wfdbx_set_legacy)
legacy = opt.legacy || wfdbx.wfdbx_get_legacy() ~= 0;
if isempty(opt.gains)
    if ~legacy
        error('wfdbx:write_record', 'gains must be specified');
    end
    opt.gains = 200;        % WFDB_DEFGAIN (wfdb-x: legacy mode)
end
% wfdb-x: no default sampling frequency (C assumed 250 Hz)
if ~legacy && (~isnumeric(fs) || ~isscalar(fs) || ~(fs > 0))
    error('wfdbx:write_record', 'the sampling frequency (fs) must be > 0');
end
x = double(signals);
if isempty(opt.samps_per_frame)
    nsig = size(x, 2);
    spf = ones(1, nsig);
else
    spf = reshape(double(opt.samps_per_frame), 1, []);
    nsig = numel(spf);
    if size(x, 2) ~= sum(spf)
        error('wfdbx:write_record', ...
            'signals must have sum(samps_per_frame) = %d columns', sum(spf));
    end
end
fmts = per(opt.fmt, nsig, 'fmt');
gains = per(opt.gains, nsig, 'gains');
zeros_ = per(opt.adczeros, nsig, 'adczeros');
if isempty(opt.baselines)
    bases = zeros_;
else
    bases = per(opt.baselines, nsig, 'baselines');
end
% wfdb-x: the ADC resolutions are required (C inferred them from the format)
if isempty(opt.adcres) && legacy
    res = legacy_adcres(fmts);  % wfdb-x: legacy mode
else
    if isempty(opt.adcres)
        error('wfdbx:write_record', 'ADC resolution(s) must be specified');
    end
    res = per(opt.adcres, nsig, 'adcres');
    if ~legacy && any(~(res >= 1))
        error('wfdbx:write_record', 'ADC resolution(s) must be specified');
    end
end
units = per_str(opt.units, nsig, 'units');
names = per_str(opt.names, nsig, 'names');
% wfdb-x: the units of calibrated signals are required (C assumed mV)
for k = 1:nsig
    if ~legacy && gains(k) ~= 0 && (~ischar(units{k}) || isempty(units{k}))
        error('wfdbx:write_record', 'units must be specified');
    end
end
if opt.physical
    c = 0;
    k = find(gains == 0, 1);
    if ~isempty(k) && ~legacy
        error('wfdbx:write_record', 'signal %d is uncalibrated', k - 1);
    end
    for k = 1:nsig
        g = gains(k);
        if g == 0
            g = 200;        % WFDB_DEFGAIN (wfdb-x: legacy mode)
        end
        for j = 1:spf(k)
            c = c + 1;
            v = x(:, c) * g;
            r = fix(v + 0.5);
            r(v < 0) = fix(v(v < 0) - 0.5);
            r = r + bases(k);
            r(isnan(v)) = -32768;   % WFDB_INVALID_SAMPLE
            x(:, c) = r;
        end
    end
end
si = wfdbx.siginfo(nsig);
for k = 1:nsig
    si(k).fname = [record '.dat'];
    if ischar(names{k})
        si(k).desc = names{k};
    else
        si(k).desc = '';
    end
    si(k).units = units{k};
    si(k).gain = gains(k);
    si(k).initval = 0;
    si(k).group = 0;
    si(k).fmt = fmts(k);
    si(k).spf = spf(k);
    si(k).bsize = 0;
    si(k).adcres = res(k);
    si(k).adczero = zeros_(k);
    si(k).baseline = bases(k);
end
if nsig > 1 && any(fmts ~= fmts(1))
    error('wfdbx:write_record', ['all signals of a record written by ' ...
        'write_record must have the same format']);
end
wfdbx.wfdbquit();
if wfdbx.osigfopen(si, nsig) ~= nsig
    wfdbx.wfdbquit();
    error('wfdbx:write_record', 'can''t create signal file for record %s', record);
end
wfdbx.setsampfreq(fs);
% The counter frequency and base count survive wfdbquit() (as in the C
% library); a new record written here has neither.
wfdbx.setcfreq(0);
wfdbx.setbasecount(0);
if ischar(opt.base_time)
    wfdbx.setbasetime(opt.base_time);
end
wfdbx.putframes(x);
if wfdbx.newheader(record) < 0
    wfdbx.wfdbquit();
    error('wfdbx:write_record', 'can''t create header for record %s', record);
end
comments = opt.comments;
if ischar(comments)
    comments = {comments};
end
for k = 1:numel(comments)
    wfdbx.putinfo(comments{k});
end
wfdbx.wfdbquit();
end

function v = per(v, n, what)
v = reshape(double(v), 1, []);
if numel(v) == 1
    v = repmat(v, 1, n);
elseif numel(v) ~= n
    error('wfdbx:write_record', '%s: one value, or one per signal (%d)', what, n);
end
end

function c = per_str(v, n, what)
if iscell(v)
    if numel(v) ~= n
        error('wfdbx:write_record', '%s: one value, or one per signal (%d)', what, n);
    end
    c = reshape(v, 1, []);
else
    c = repmat({v}, 1, n);
end
end

function res = legacy_adcres(fmts)
% wfdb-x: legacy mode: the ADC resolution that write_record inferred from
% the format before the redesign
res = 16 * ones(size(fmts));
res(fmts == 80 | fmts == 508) = 8;
res(fmts == 212) = 12;
res(fmts == 310 | fmts == 311) = 10;
res(fmts == 24 | fmts == 524) = 24;
res(fmts == 32) = 32;
end
