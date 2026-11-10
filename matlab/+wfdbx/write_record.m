function write_record(record, signals, fs, varargin)
%WRITE_RECORD Write a matrix of samples as a WFDB record.
%   wfdbx.write_record(RECORD, SIGNALS, FS, NAME, VALUE, ...) writes the
%   header RECORD.hea and the signal file RECORD.dat.  SIGNALS has one row
%   per sample and one column per signal (a matrix: a 2-D array), in ADC
%   units (or in physical units with 'physical').  FS is the sampling
%   frequency in Hz.  Existing files with these names are replaced: both
%   files are written to temporary files in the destination folder
%   ('.NAME.XXXXXXXX.tmp', created with the permissions of the files they
%   replace), which replace the existing files only when both are
%   complete, so that an error leaves the existing files as they were.
%
%   RECORD is the record name, without the .hea extension (a trailing
%   '.hea' is removed, as by the readers): a plain name
%   ('rec') or a relative path ('data/rec'), created in the output directory
%   if one is set (see wfdbx.wfdbx_set_output_dir), otherwise in the
%   current folder, missing directories included; or a full path, absolute
%   or in the home directory ('~/Documents/rec'), used as given.  With a
%   path, the files are created in that directory, and the header names
%   the record and its signal file without the path ('rec', 'rec.dat'), so
%   that the record opens under any path that leads to it (in legacy mode,
%   as in the original, the header gives the name with its path).  A URL
%   cannot be written.
%
%   The gain and ADC resolution of each signal, and the units of each
%   calibrated signal, must be given; there are no defaults.  Per-signal options
%   take one value for all signals, or a vector or cell array with one value
%   per signal.
%
%     'fmt'         storage format: 8, 16, 61, 80, 160, 212, 310, 311, 24,
%                   32, 508, 516 or 524 (default 16, the same for all
%                   signals)
%     'gains'       ADC units per physical unit (required); 0 marks a signal
%                   as uncalibrated, which is only allowed for samples in ADC
%                   units
%     'adcres'      ADC resolution in bits (required; whole numbers >= 1)
%     'units'       physical units (required for each signal whose gain is
%                   not 0)
%     'baselines'   baselines, in ADC units (default: the ADC zeros)
%     'adczeros'    ADC zeros (default 0)
%                   ('adcres', 'adczeros' and 'baselines' are whole numbers
%                   within the range of a 32-bit integer; a cell array may
%                   hold [] for a missing value: an ADC zero of 0, a
%                   baseline equal to the ADC zero)
%     'names'       signal descriptions (default: none)
%     'base_time'   start time and date, such as '12:00:00 01/02/2003'
%     'comments'    cell array of info strings
%                   (the record name, names, units and comments are text of
%                   one byte per character: characters 0 to 255, Latin-1)
%     'metadata'    "Key: value" entries to write to the header, after the
%                   comments, as "# Key: value" ("# Key:" for an empty
%                   value): an N-by-2 cell array with one entry per row,
%                   {KEY, VALUE}.  The keys and values follow the rules of
%                   wfdbx.set_metadata; no two keys may be equal without
%                   regard to letter case, nor be the key of an entry in
%                   'comments', and a value must not be [].  Default: none.
%     'physical'    true if SIGNALS are in physical units; they are converted
%                   with the gains and baselines, and NaN becomes an invalid
%                   sample; infinite values, and values beyond the range of
%                   32-bit ADC units, are errors (default false)
%     'samps_per_frame'  samples per frame of each signal, for a
%                   multi-frequency record.  Each row of SIGNALS then holds
%                   one frame: the samples of signal 0, then those of
%                   signal 1, and so on.
%     'dir'         directory (which must exist) in which to create the
%                   files, for this call only (default: the output
%                   directory).  RECORD must then be a plain name, without
%                   a directory, and the record opens from that directory
%                   under its plain name.
%     'legacy'      true to behave as the original WFDB package (default
%                   false; see wfdbx.wfdbx_set_legacy)
%
%   Errors: an error (identifier 'wfdbx:write_record') is thrown if a
%   'samps_per_frame' value is not an integer >= 1 ("samps_per_frame must
%   hold integers >= 1") or the number of columns of SIGNALS is not their
%   sum ("signals has N columns, but samps_per_frame adds up to M"; these
%   are checked first, before any file is created), if FS is not greater
%   than 0 or not finite, if RECORD is empty, if SIGNALS has more than two
%   dimensions ("signals must be a 1-D or 2-D array"), if SIGNALS has no
%   signals ("at least one signal is required"), if a gain is not finite,
%   if 'base_time' cannot be parsed by wfdbx.setbasetime, if the gains, ADC
%   resolutions or required units are not given, if an ADC resolution, ADC
%   zero or baseline is not a whole number within the range of a 32-bit
%   integer ("adcres must be whole numbers within the range of a 32-bit
%   integer", and the same for adczeros and baselines), if the record
%   name, a signal name, the units or a comment has a character beyond
%   255 ("signal name 'X' has a character that is not Latin-1 (one byte
%   per character)"; possible in MATLAB only, whose characters are 16-bit),
%   if a per-signal option does not have one value or one value per
%   signal, if samples in ADC units are not integers or lie outside the
%   range of a 32-bit integer, if samples in physical units are infinite or
%   their ADC values lie outside that range, if 'physical' is true and a
%   gain is 0, if an entry of 'metadata' is not valid, if 'dir' does not
%   exist, if the files cannot be created, or
%   if they cannot be written completely, for example when the disk is full
%   ("write error on record RECORD", after the library's messages; in
%   legacy mode too).  The arguments are checked, in that order, before
%   any file is created or changed.  A record is never written over one of
%   the files being read ("osigfopen: output file NAME is also an input
%   file").
%
%   The function calls wfdbx.wfdbquit, which closes anything opened with the
%   WFDB library functions; it also closes the output signals when it
%   fails, and leaves no temporary file.  The getvec mode
%   (wfdbx.getgvmode) and the time resolution of output annotators
%   (wfdbx.getafreq) are left as they were.
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
%   See also wfdbx.read_record, wfdbx.write_annotations, wfdbx.set_metadata.
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
% under the terms of the GNU Lesser General Public License as published by
% the Free Software Foundation, either version 2.1 of the License, or (at
% your option) any later version. See LICENSE.

record = wfdbx.internal.strarg(record);
% WFDB-x: a trailing '.hea' is removed, as by the readers (1.2.2)
record = wfdbx.internal.wfdb_striphea(record);
% WFDB-x: the getvec mode and the time resolution of output annotators are
% restored when the function returns (also on errors; opening an EDF record
% sets both)
keep_settings = wfdbx.internal.hl_settings(); %#ok<NASGU>
% WFDB-x: every argument is checked before any file is touched
if ~ischar(record) || isempty(record)
    error('wfdbx:write_record', 'the record name must not be empty');
end
check_latin1(record, 'record name');
% WFDB-x: the gains are required (C's default was WFDB_DEFGAIN)
opt = struct('fmt', 16, 'gains', [], 'baselines', [], 'adczeros', 0, ...
    'adcres', [], 'units', [], 'names', [], 'base_time', [], ...
    'comments', [], 'physical', false, 'samps_per_frame', [], ...
    'metadata', [], 'dir', [], 'legacy', false);
opt = wfdbx.internal.hl_options(opt, varargin, 'write_record');
% WFDB-x: the 'dir' option (the library's output directory, for this
% call), checked before the other arguments
restore_dir = wfdbx.internal.hl_outdir(opt.dir, record, 'write_record'); %#ok<NASGU>
restore = wfdbx.internal.hl_legacy(opt.legacy, 'write_record'); %#ok<NASGU>
INT32_MIN = -2147483648;
INT32_MAX = 2147483647;
if ndims(signals) > 2 %#ok<ISMAT>
    error('wfdbx:write_record', 'signals must be a 1-D or 2-D array');
end
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
if nsig == 0
    error('wfdbx:write_record', 'at least one signal is required');
end
% the library's legacy mode also applies (wfdbx.wfdbx_set_legacy)
legacy = opt.legacy || wfdbx.wfdbx_get_legacy() ~= 0;
fmts = per(opt.fmt, nsig, 'fmt');
if isempty(opt.gains)
    if ~legacy
        error('wfdbx:write_record', 'gains must be specified');
    end
    opt.gains = 200;        % WFDB_DEFGAIN (WFDB-x: legacy mode)
end
gains = per(opt.gains, nsig, 'gains');
if isempty(opt.adczeros)
    opt.adczeros = 0;
end
[zeros_, zmiss, zbad] = per_num(opt.adczeros, nsig, 'adczeros');
if isempty(opt.baselines)
    bases = zeros(1, nsig);
    bmiss = true(1, nsig);
    bbad = false(1, nsig);
else
    [bases, bmiss, bbad] = per_num(opt.baselines, nsig, 'baselines');
end
units = per_str(opt.units, nsig, 'units');
names = per_str(opt.names, nsig, 'names');
% WFDB-x: the ADC resolutions are required (C inferred them from the
% format); whole numbers within the range of an int (a fraction was
% truncated, NaN or text failed after the signal file was written)
if isempty(opt.adcres)
    [res, rmiss, rbad] = deal(zeros(1, nsig), true(1, nsig), false(1, nsig));
else
    [res, rmiss, rbad] = per_num(opt.adcres, nsig, 'adcres');
end
if ~legacy
    if any(rmiss)
        error('wfdbx:write_record', 'ADC resolution(s) must be specified');
    end
    check_whole(res, rbad, 'adcres');
    if any(res < 1)
        error('wfdbx:write_record', 'ADC resolution(s) must be specified');
    end
end
if ~all(cellfun(@(u) is_text(u) || isempty(u), [units, names]))
    error('wfdbx:write_record', 'units and names must be strings');
end
% WFDB-x: the units of calibrated signals are required (C assumed mV)
for k = 1:nsig
    if ~legacy && gains(k) ~= 0 && (~is_text(units{k}) || isempty(units{k}))
        error('wfdbx:write_record', 'units must be specified');
    end
end
k = find(gains == 0, 1);
if opt.physical && ~isempty(k) && ~legacy
    error('wfdbx:write_record', 'signal %d is uncalibrated', k - 1);
end
% WFDB-x: no default sampling frequency (C assumed 250 Hz); a finite
% frequency > 0, in legacy mode too
if ~isnumeric(fs) || ~isscalar(fs) || ~isreal(fs) || ~(fs > 0) || ~isfinite(fs)
    error('wfdbx:write_record', 'the sampling frequency (fs) must be finite and > 0');
end
if ~all(isfinite(gains))
    error('wfdbx:write_record', 'gains must be finite');
end
base_time = wfdbx.internal.strarg(opt.base_time);
if ~(isnumeric(base_time) && isempty(base_time))
    check_base_time(base_time);
end
% WFDB-x: the ADC resolutions (in legacy mode, missing ones from the
% format, as the original), ADC zeros (0 if missing) and baselines (the
% ADC zero if missing) are whole numbers within the range of an int, in
% both modes
if legacy
    dres = legacy_adcres(fmts);  % WFDB-x: legacy mode
    res(rmiss) = dres(rmiss);
    rmiss(:) = false;
end
check_whole(res, rbad, 'adcres');
zeros_(zmiss) = 0;
check_whole(zeros_, zbad, 'adczeros');
bases(bmiss) = zeros_(bmiss);
check_whole(bases, bbad, 'baselines');
% WFDB-x: the text written to the header is one byte per character
for k = 1:nsig
    check_latin1(names{k}, 'signal name');
    check_latin1(units{k}, 'units');
end
if opt.physical
    c = 0;
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
if nsig > 1 && any(fmts ~= fmts(1))
    error('wfdbx:write_record', ['all signals of a record written by ' ...
        'write_record must have the same format']);
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
for k = 1:numel(comments)
    check_latin1(comments{k}, 'comment');
end
% WFDB-x: the metadata entries, written after the comments (checked before
% any file is created)
if ~(isa(opt.metadata, 'double') && isempty(opt.metadata))
    comments = [reshape(comments, 1, []), wfdbx.internal.meta_info_lines( ...
        opt.metadata, comments, wfdbx.internal.meta_id('write_record'))];
end
si = wfdbx.siginfo(nsig);
for k = 1:nsig
    si(k).fname = [record '.dat'];
    if is_text(names{k})
        si(k).desc = char(names{k});
    else
        si(k).desc = '';
    end
    if is_text(units{k})
        si(k).units = char(units{k});
    else
        si(k).units = units{k};
    end
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
wfdbx.wfdbquit();
errors = wfdbx.wfdbx_write_errors();
% WFDB-x: the signal file and the header are written to temporary files in
% the directories of their destinations, which are renamed over them when
% both are complete; after a failure, they are removed, and the existing
% files are left as they were (see wfdbx.internal.staging_begin).  (The
% staging also ends if the function is interrupted.)
wfdbx.internal.staging_begin();
unstage = onCleanup(@() wfdbx.internal.staging_end(false)); %#ok<NASGU>
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
    if ischar(base_time)
        wfdbx.setbasetime(base_time);
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
    wfdbx.internal.staging_end(false);
    rethrow(err);
end
wfdbx.wfdbquit();
complete = wfdbx.wfdbx_write_errors() == errors;
if ~wfdbx.internal.staging_end(complete)
    error('wfdbx:write_record', 'write error on record %s', record);
end
end

function check_base_time(t)
% WFDB-x: an error if wfdbx.setbasetime cannot parse T (checked before any
% file is created); the library's base time and its messages are left as
% they were.
if ~ischar(t)
    error('wfdbx:write_record', 'base_time must be a string');
end
S = wfdbx.internal.sig_state();
saved = {S.btime, S.bdate, S.pdays, S.date_string, S.time_string};
io = wfdbx.internal.io_state();
msg = {io.error_print, io.error_flag, io.error_message};
io.error_print = false;
try
    ok = wfdbx.setbasetime(t) >= 0;
catch err
    restore_base_time(S, io, saved, msg);
    rethrow(err);
end
restore_base_time(S, io, saved, msg);
if ~ok
    error('wfdbx:write_record', 'invalid base_time ''%s''', t);
end
end

function restore_base_time(S, io, saved, msg)
% (the state saved by check_base_time)
S.btime = saved{1};
S.bdate = saved{2};
S.pdays = saved{3};
S.date_string = saved{4};
S.time_string = saved{5};
io.error_print = msg{1};
io.error_flag = msg{2};
io.error_message = msg{3};
end

function tf = is_text(s)
tf = ischar(s) || isa(s, 'string');
end

function check_latin1(s, what)
% WFDB-x: text written to the header is one byte per character (codes 0 to
% 255, Latin-1); a character beyond that (possible in MATLAB, whose
% characters are 16-bit) would be written as another byte.
if is_text(s)
    s = char(s);
    if any(double(s(:)) > 255)
        error('wfdbx:write_record', ['%s ''%s'' has a character that is ' ...
            'not Latin-1 (one byte per character)'], what, s);
    end
end
end

function [v, missing, bad] = per_num(v, n, what)
% Per-signal whole numbers (adcres, adczeros, baselines): one value, or one
% per signal, as a numeric (or logical) array or a cell array whose
% entries are numbers or [] (missing).  V is a 1-by-N double row; MISSING
% marks the entries [], BAD those that are not real numbers (text, ...).
if iscell(v)
    c = reshape(v, 1, []);
    if numel(c) == 1
        c = repmat(c, 1, n);
    elseif numel(c) ~= n
        error('wfdbx:write_record', '%s: one value, or one per signal (%d)', what, n);
    end
    v = zeros(1, n);
    missing = false(1, n);
    bad = false(1, n);
    for k = 1:n
        e = c{k};
        if isnumeric(e) && isempty(e)
            missing(k) = true;
        elseif (isnumeric(e) || islogical(e)) && isscalar(e) && isreal(e)
            v(k) = double(e);
        else
            bad(k) = true;
        end
    end
elseif (isnumeric(v) || islogical(v)) && isreal(v)
    v = per(v, n, what);
    missing = false(1, n);
    bad = false(1, n);
else
    if numel(v) ~= 1 && numel(v) ~= n && ~ischar(v)
        error('wfdbx:write_record', '%s: one value, or one per signal (%d)', what, n);
    end
    v = zeros(1, n);
    missing = false(1, n);
    bad = true(1, n);
end
end

function check_whole(v, bad, what)
% WFDB-x: the fields of a signal specification are C ints: whole numbers
% within the range of a 32-bit integer (a fraction was truncated, and NaN,
% text or a value beyond that range failed while the files were written)
if any(bad | ~isfinite(v) | v ~= fix(v) | v < -2147483648 | v > 2147483647)
    error('wfdbx:write_record', ['%s must be whole numbers within the ' ...
        'range of a 32-bit integer'], what);
end
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
