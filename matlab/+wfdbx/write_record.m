function write_record(record, signals, fs, varargin)
%WRITE_RECORD Write a matrix of samples as a WFDB record.
%   wfdbx.write_record(RECORD, SIGNALS, FS, NAME, VALUE, ...) writes the
%   header RECORD.hea and the signal file RECORD.dat.  SIGNALS has one row
%   per sample and one column per signal, in ADC units (or in physical units
%   with 'physical').  FS is the sampling frequency in Hz.
%
%   You must give the gain and ADC resolution of each signal, and the units
%   of each calibrated signal; there are no defaults.  Per-signal options
%   take one value for all signals, or a vector or cell array with one value
%   per signal.
%
%     'fmt'         storage format: 8, 16, 61, 80, 160, 212, 310, 311, 24,
%                   32, 508, 516 or 524 (default 16, the same for all
%                   signals)
%     'gains'       ADC units per physical unit (required); 0 marks a signal
%                   as uncalibrated, which is only allowed for samples in ADC
%                   units
%     'adcres'      ADC resolution in bits (required)
%     'units'       physical units (required for each signal whose gain is
%                   not 0)
%     'baselines'   baselines, in ADC units (default: the ADC zeros)
%     'adczeros'    ADC zeros (default 0)
%     'names'       signal descriptions (default: none)
%     'base_time'   start time and date, such as '12:00:00 01/02/2003'
%     'comments'    cell array of info strings
%     'physical'    true if SIGNALS are in physical units; they are converted
%                   with the gains and baselines, and NaN becomes an invalid
%                   sample; infinite values, and values beyond the range of
%                   32-bit ADC units, are errors (default false)
%     'samps_per_frame'  samples per frame of each signal, for a
%                   multi-frequency record.  Each row of SIGNALS then holds
%                   one frame: the samples of signal 0, then those of
%                   signal 1, and so on.
%     'dir'         folder in which to create the files (default: the output
%                   directory).  RECORD must then be a plain name.
%     'legacy'      true to behave as the original WFDB package (default
%                   false; see wfdbx.wfdbx_set_legacy)
%
%   Errors: an error (identifier 'wfdbx:write_record') is thrown if a
%   'samps_per_frame' value is not an integer >= 1 ("samps_per_frame must
%   hold integers >= 1") or the number of columns of SIGNALS is not their
%   sum ("signals has N columns, but samps_per_frame adds up to M"; these
%   are checked first, before any file is created), if FS is not greater
%   than 0, if the gains, ADC resolutions or required units are not given,
%   if a per-signal option does not have one value or one value per
%   signal, if samples in ADC units are not integers or lie outside the
%   range of a 32-bit integer, if samples in physical units are infinite or
%   their ADC values lie outside that range, if 'physical' is true and a
%   gain is 0, if 'dir' does not exist, if the files cannot be created, or
%   if they cannot be written completely, for example when the disk is full
%   ("write error on record RECORD", after the library's messages; in
%   legacy mode too).  The arguments are checked before any file is
%   created.  A record is never written over one of the files being read
%   ("osigfopen: output file NAME is also an input file").
%
%   The function calls wfdbx.wfdbquit, which closes anything opened with the
%   WFDB library functions; it also closes the output signals when it
%   fails.
%
%   Examples:
%       x = round(1000 * sin(2 * pi * (0:999)' / 100));
%       wfdbx.write_record('sine', [x, -x], 250, 'fmt', 212, ...
%           'gains', 200, 'adcres', 12, 'units', 'mV', ...
%           'names', {'sin', '-sin'});
%
%       % physical units (mV) at 360 Hz, with a start time
%       t = (0:3599)' / 360;
%       wfdbx.write_record('phys', [sin(2*pi*t), cos(2*pi*t)], 360, ...
%           'physical', true, 'gains', 200, 'adcres', 16, 'units', 'mV', ...
%           'base_time', '12:00:00 01/02/2003');
%
%   See also wfdbx.read_record, wfdbx.write_annotations.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package. Like the rest of WFDB-x, it
% never assumes a sampling frequency, gain, ADC resolution or units (see
% docs/DIVERGENCES.md).
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

record = wfdbx.internal.strarg(record);
% WFDB-x: the gains are required (C's default was WFDB_DEFGAIN)
opt = struct('fmt', 16, 'gains', [], 'baselines', [], 'adczeros', 0, ...
    'adcres', [], 'units', [], 'names', [], 'base_time', [], ...
    'comments', [], 'physical', false, 'samps_per_frame', [], ...
    'dir', [], 'legacy', false);
opt = wfdbx.internal.hl_options(opt, varargin, 'write_record');
% WFDB-x: the 'dir' option (the library's output directory, for this
% call), checked before the other arguments
restore_dir = wfdbx.internal.hl_outdir(opt.dir, record, 'write_record'); %#ok<NASGU>
restore = wfdbx.internal.hl_legacy(opt.legacy, 'write_record'); %#ok<NASGU>
INT32_MIN = -2147483648;
INT32_MAX = 2147483647;
% Each frame holds spf(k) >= 1 samples of signal k, and each row of
% signals is one frame.
x = double(signals);
if isempty(opt.samps_per_frame)
    nsig = size(x, 2);
    spf = ones(1, nsig);
else
    spf = reshape(double(opt.samps_per_frame), 1, []);
    nsig = numel(spf);
    if any(~(spf >= 1) | spf ~= fix(spf))
        error('wfdbx:write_record', 'samps_per_frame must hold integers >= 1');
    end
    if size(x, 2) ~= sum(spf)
        error('wfdbx:write_record', ...
            'signals has %d columns, but samps_per_frame adds up to %d', ...
            size(x, 2), sum(spf));
    end
end
% the library's legacy mode also applies (wfdbx.wfdbx_set_legacy)
legacy = opt.legacy || wfdbx.wfdbx_get_legacy() ~= 0;
if isempty(opt.gains)
    if ~legacy
        error('wfdbx:write_record', 'gains must be specified');
    end
    opt.gains = 200;        % WFDB_DEFGAIN (WFDB-x: legacy mode)
end
% WFDB-x: no default sampling frequency (C assumed 250 Hz)
if ~legacy && (~isnumeric(fs) || ~isscalar(fs) || ~(fs > 0))
    error('wfdbx:write_record', 'the sampling frequency (fs) must be > 0');
end
fmts = per(opt.fmt, nsig, 'fmt');
gains = per(opt.gains, nsig, 'gains');
zeros_ = per(opt.adczeros, nsig, 'adczeros');
if isempty(opt.baselines)
    bases = zeros_;
else
    bases = per(opt.baselines, nsig, 'baselines');
end
% WFDB-x: the ADC resolutions are required (C inferred them from the format)
if isempty(opt.adcres) && legacy
    res = legacy_adcres(fmts);  % WFDB-x: legacy mode
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
if ~all(cellfun(@(u) is_text(u) || isempty(u), [units, names]))
    error('wfdbx:write_record', 'units and names must be strings');
end
% WFDB-x: the units of calibrated signals are required (C assumed mV)
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
            g = 200;        % WFDB_DEFGAIN (WFDB-x: legacy mode)
        end
        for j = 1:spf(k)
            c = c + 1;
            v = x(:, c) * g;
            r = fix(v + 0.5);
            r(v < 0) = fix(v(v < 0) - 0.5);
            r = r + bases(k);
            % WFDB-x: NaN is an invalid sample; an infinite value, or one
            % beyond the range of a 32-bit sample, is an error
            nan = isnan(r);
            if any(~nan & ~(r >= INT32_MIN & r <= INT32_MAX))
                error('wfdbx:write_record', ['signal %d has a sample that ' ...
                    'is infinite or beyond the range of 32-bit ADC units'], k - 1);
            end
            r(nan) = -32768;        % WFDB_INVALID_SAMPLE
            x(:, c) = r;
        end
    end
else
    % WFDB-x: samples in ADC units must be integers within the range of a
    % 32-bit sample (anything else is an error, not rounded or wrapped)
    if ~all(isfinite(x(:)) & x(:) == fix(x(:)))
        error('wfdbx:write_record', 'samples in ADC units must be integers');
    end
    if ~all(x(:) >= INT32_MIN & x(:) <= INT32_MAX)
        error('wfdbx:write_record', ['samples in ADC units must be within ' ...
            'the range of a 32-bit integer']);
    end
end
comments = opt.comments;
if ischar(comments) || isa(comments, 'string')
    comments = cellstr(comments);
elseif isempty(comments)
    comments = {};
end
if ~iscell(comments) || ~all(cellfun(@is_text, comments(:)))
    error('wfdbx:write_record', 'comments must be a cell array of strings');
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
errors = wfdbx.wfdbx_write_errors();
% (the output signals are closed however this ends)
try
    if wfdbx.osigfopen(si, nsig) ~= nsig
        error('wfdbx:write_record', 'can''t create signal file for record %s', ...
            record);
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
        error('wfdbx:write_record', 'can''t create header for record %s', record);
    end
    for k = 1:numel(comments)
        wfdbx.putinfo(comments{k});
    end
catch err
    wfdbx.wfdbquit();
    rethrow(err);
end
wfdbx.wfdbquit();
if wfdbx.wfdbx_write_errors() > errors
    error('wfdbx:write_record', 'write error on record %s', record);
end
end

function tf = is_text(s)
tf = ischar(s) || isa(s, 'string');
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
% WFDB-x: legacy mode: the ADC resolution that write_record infers from
% the format
res = 16 * ones(size(fmts));
res(fmts == 80 | fmts == 508) = 8;
res(fmts == 212) = 12;
res(fmts == 310 | fmts == 311) = 10;
res(fmts == 24 | fmts == 524) = 24;
res(fmts == 32) = 32;
end
