function report = check_record(record, varargin)
%CHECK_RECORD Check a record and its annotation files, and report every problem.
%   REPORT = wfdbx.check_record(RECORD) checks the header of the record
%   RECORD, its signal specifications and every sample of its signal files,
%   and reports each problem that it finds.  RECORD is a record name read
%   from the input directory, or a full path, a ~ path or a URL (as for
%   wfdbx.read_record).  Problems in the record never throw an error: they
%   are reported.
%
%   REPORT = wfdbx.check_record(RECORD, NAME, VALUE, ...) takes these
%   options:
%
%     'annotators'  annotator names to check: a cell array such as {'atr'},
%                   or one name as a char vector (default: none)
%     'input_dir'   input directory for this call only (see
%                   wfdbx.read_record)
%     'network'     true to allow network access for this call only (see
%                   wfdbx.read_record)
%
%   REPORT is a structure with these fields:
%
%     record    the record name, as given
%     ok        true if no issue has the severity 'error'
%     issues    N-by-1 structure array of the problems, in the order of the
%               checks, with the fields severity ('error', 'warning' or
%               'info'), code (a stable identifier, such as 'checksum' or
%               'gain_missing'), where ('' for the record, 'signal N',
%               'segment SEG', 'segment SEG, signal N' or 'annotator ANN')
%               and message (the description of the problem)
%     lines     the text form: a cell column with one line per issue,
%               'SEVERITY: WHERE: MESSAGE' (without 'WHERE: ' for the
%               record itself), or the single line 'no problems found'
%
%   Called without an output argument, the function displays the lines.
%
%   Severities: 'error' (the record is damaged or does not follow the WFDB
%   format: programs will read wrong data or fail), 'warning' (the record
%   can be read, but something is missing or unusual, and may give wrong
%   results) and 'info' (a fact worth knowing, such as invalid samples).
%   The checks run in normal mode, even if legacy mode is on
%   (wfdbx.wfdbx_set_legacy), and the library prints no messages during
%   the call.
%
%   Errors: an error (identifier 'wfdbx:check_record') is thrown only for
%   invalid arguments: RECORD is not a string or is empty, or an annotator
%   name is not a string.
%
%   The function calls wfdbx.wfdbquit, which closes anything opened with the
%   WFDB library functions.
%
%   It checks for problems similar to those found by Benjamin Moody's
%   wfdbcheck (https://github.com/bemoody/wfdbcheck).
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       report = wfdbx.check_record('100s', 'annotators', {'atr'});
%       fprintf('%s\n', report.lines{:});
%       %   warning: signal 0: the units are not specified
%       %   warning: signal 1: the units are not specified
%       report.ok                   % true
%
%   See also wfdbx.read_record, wfdbx.read_header, wfdbx.read_annotations.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package. The checks were designed
% for WFDB-x and are the same in the seven languages (the messages, their
% order and the formatting of numbers; python/src/wfdbx/check.py is the
% reference); no code or text of wfdbcheck was used.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

record = wfdbx.internal.strarg(record);
if ~ischar(record)
    error('wfdbx:check_record', 'check_record: record must be a string');
end
if isempty(record)
    error('wfdbx:check_record', 'check_record: record must not be empty');
end
opt = struct('annotators', {{}}, 'input_dir', [], 'network', []);
opt = wfdbx.internal.hl_options(opt, varargin, 'check_record');
annotators = opt.annotators;
if ischar(annotators)
    annotators = {annotators};      % (one name)
elseif isempty(annotators)
    annotators = {};
elseif ~iscell(annotators)
    error('wfdbx:check_record', 'check_record: annotator names must be strings');
end
for k = 1:numel(annotators)
    if ~ischar(annotators{k})
        error('wfdbx:check_record', 'check_record: annotator names must be strings');
    end
    annotators{k} = reshape(annotators{k}, 1, []);
end
% the input directory and network access for this call
restore_input = wfdbx.internal.hl_input(opt.input_dir, opt.network, ...
    'check_record'); %#ok<NASGU>
% normal mode, and no messages, for the call
io = wfdbx.internal.io_state();
printing = io.error_print;
legacy = wfdbx.wfdbx_set_legacy(0);
io.error_print = false;
restore = onCleanup(@() restore_state(io, printing, legacy)); %#ok<NASGU>
wfdbx.wfdbquit();
rep = reshape(struct('severity', {}, 'code', {}, 'where', {}, 'message', {}), 0, 1);
[rep, len] = check_record_signals(record, rep);
for k = 1:numel(annotators)
    rep = check_annotator(record, annotators{k}, len, rep);
end
wfdbx.wfdbquit();
issues = rep;
report = struct();
report.record = record;
report.ok = ~any(strcmp({issues.severity}, 'error'));
report.issues = issues;
if isempty(issues)
    report.lines = {'no problems found'};
else
    lines = cell(numel(issues), 1);
    for k = 1:numel(issues)
        x = issues(k);
        if isempty(x.where)
            lines{k} = [x.severity ': ' x.message];
        else
            lines{k} = [x.severity ': ' x.where ': ' x.message];
        end
    end
    report.lines = lines;
end
if nargout == 0
    fprintf('%s\n', report.lines{:});
    clear report
end
end

function restore_state(io, printing, legacy)
wfdbx.wfdbquit();
io.error_print = printing;
wfdbx.wfdbx_set_legacy(legacy);
end


function rep = add(rep, severity, code, where, message)
rep(end + 1, 1) = struct('severity', severity, 'code', code, ...
    'where', where, 'message', message);
end

% ---------------------------------------------------------------------------
% Text of the messages

function s = q(name)
% A name quoted for a message: in double quotes, with each byte below 32
% or above 126 shown as \xHH (lowercase hex).
if isempty(name)
    s = '""';
    return;
end
name = double(name);
bad = name < 32 | name > 126;
if ~any(bad)
    s = ['"' char(name) '"'];
    return;
end
parts = cell(1, numel(name));
for k = 1:numel(name)
    if bad(k)
        parts{k} = sprintf('\\x%02x', mod(name(k), 256));
    else
        parts{k} = char(name(k));
    end
end
s = ['"' parts{:} '"'];
end

function s = nn(k, word)
% '1 frame', '2 frames'
if k == 1
    s = sprintf('%d %s', k, word);
else
    s = sprintf('%d %ss', k, word);
end
end

function s = count_msg(k, noun, verb_one, verb_many, what, one)
% A message about k items: '1 NOUN VERB WHAT: ONE' or 'K NOUNs VERB WHAT;
% the first is ONE'.
if k == 1
    s = ['1 ' noun ' ' verb_one ' ' what ': ' one];
else
    s = sprintf('%d %ss %s %s; the first is %s', k, noun, verb_many, what, one);
end
end

function s = g(x)
s = sprintf('%g', x);
end

function x = int16v(x)
x = mod(x, 65536);
if x >= 32768
    x = x - 65536;
end
end

function tf = has_control(s)
s = double(s);
tf = any(s < 32 | s == 127);
end

function tf = is_number(s)
% True if s is only a number: an optional sign, digits with at most one
% '.', and at least one digit.
if ~isempty(s) && (s(1) == '+' || s(1) == '-')
    s = s(2:end);
end
if sum(s == '.') > 1
    tf = false;
    return;
end
d = s(s ~= '.');
tf = ~isempty(d) && all(d >= '0' & d <= '9');
end

function w = at(prefix, sub)
% 'segment s1' + 'signal 0' -> 'segment s1, signal 0'
if ~isempty(prefix) && ~isempty(sub)
    w = [prefix ', ' sub];
elseif ~isempty(prefix)
    w = prefix;
else
    w = sub;
end
end

function c = capacity(fmt)
% Bits that each storage format can store ([]: no limit; formats 8 and 0).
switch fmt
    case {80, 508}
        c = 8;
    case {310, 311}
        c = 10;
    case 212
        c = 12;
    case {16, 61, 160, 516}
        c = 16;
    case {24, 524}
        c = 24;
    case 32
        c = 32;
    otherwise
        c = [];
end
end

function s = str(x)
% a siginfo string field ([] when absent) as a char vector
if ischar(x)
    s = x;
else
    s = '';
end
end

% ---------------------------------------------------------------------------
% The header file

function hdr = header_text(name)
% The bytes of the header file that the library reads for record NAME (as
% a char row), the record name that its file name gives (the file name
% without directory and '.hea') and its path; [] if there is none (no such
% file, or a record read from another format, such as EDF).
hdr = [];
q_ = numel(name);
while q_ > 1 && ~any(name(q_) == './:\')
    q_ = q_ - 1;
end
if q_ >= 1 && name(q_) == '.'
    if ~strcmp(name(q_ + 1:end), 'hea')
        return;             % (EDF: no WFDB header)
    end
    f = wfdbx.internal.wfdb_open([], name, 0);     % WFDB_READ
else
    f = wfdbx.internal.wfdb_open('hea', name, 0);
end
if isempty(f)
    return;
end
io = wfdbx.internal.io_state();
path = io.wfdb_filename;
if ~ischar(path) || isempty(path)
    path = name;
end
text = char(f.readall());
f.close();
base = path(numel(wfdbx.internal.wfdb_dirname(path)) + 1:end);
if numel(base) >= 4 && strcmp(base(end - 3:end), '.hea')
    base = base(1:end - 4);
elseif numel(base) >= 4 && strcmp(base(1:4), 'hea.')
    base = base(5:end);
end
hdr = struct('text', text, 'base', base, 'path', path);
end

function lines = split_lines(text, drop_last)
% The lines of text (split at each LF); drop_last: no line after a final LF
lf = find(text == char(10));
starts = [1, lf + 1];
ends = [lf - 1, numel(text)];
if drop_last && starts(end) > numel(text)
    starts = starts(1:end - 1);
    ends = ends(1:end - 1);
end
lines = cell(1, numel(starts));
for k = 1:numel(starts)
    lines{k} = text(starts(k):ends(k));
end
end

function f = fields_of(line)
% The fields of a header line, separated by spaces, tabs and CRs.
sep = line == ' ' | line == char(9) | line == char(13);
d = diff([true, sep, true]);
starts = find(d == -1);
ends = find(d == 1) - 1;
f = cell(1, numel(starts));
for k = 1:numel(starts)
    f{k} = line(starts(k):ends(k));
end
end

function f = record_line(text)
% The fields of the record line of a header (the first line whose first
% field does not begin with '#'), or {}.
lines = split_lines(text, false);
for k = 1:numel(lines)
    f = fields_of(lines{k});
    if ~isempty(f) && f{1}(1) ~= '#'
        return;
    end
end
f = {};
end

function rep = check_text(hdr, where, rep)
% Checks 1.5-1.7: the lines of the header file and its record name.
lines = split_lines(hdr.text, true);
for k = 1:numel(lines)
    line = lines{k};
    if ~isempty(line) && line(end) == char(13)
        line = line(1:end - 1);
    end
    if numel(line) > 255
        rep = add(rep, 'error', 'header_line_long', where, ...
            sprintf('line %d of the header is longer than 255 characters', k));
    end
end
for k = 1:numel(lines)
    if any(double(lines{k}) > 127)
        rep = add(rep, 'warning', 'header_not_ascii', where, ...
            sprintf('line %d of the header contains non-ASCII characters', k));
        break;
    end
end
f = record_line(hdr.text);
if ~isempty(f)
    x = f{1};
    k = find(x(2:end) == '/', 1);   % (the first '/' after the first character)
    if ~isempty(k)
        x = x(1:k);
    end
    if ~strcmp(x, hdr.base)
        rep = add(rep, 'warning', 'header_name', where, ...
            ['the header names the record ' q(x) ', but its file name is ' ...
            q(hdr.base)]);
    end
end
end

function n = header_length(text)
% The length (number of samples) on the record line: 0 if not given.
f = record_line(text);
n = 0;
if numel(f) < 4
    return;
end
v = f{4};
k = find(~(v >= '0' & v <= '9'), 1);
if isempty(k)
    k = numel(v) + 1;
end
if k > 1
    n = sum((double(v(1:k - 1)) - 48) .* 10 .^ (k - 2:-1:0));
end
end

% ---------------------------------------------------------------------------
% Signal specifications (section 2)

function rep = check_specs(si, opened_as, prefix, rep, skip_null)
% Checks 2.1-2.13 of the signals si of a record opened under the name
% opened_as.  skip_null: signals of format 0 are not checked (a segment
% of a multi-segment record).
FILE_CHARS = ['abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ' ...
    '0123456789_-./'];
descs = {};                 % descriptions of the signals checked
for s = 0:numel(si) - 1
    info = si(s + 1);
    null = info.fmt == 0;
    if null && skip_null
        continue;
    end
    where = at(prefix, sprintf('signal %d', s));
    desc = str(info.desc);
    if isempty(desc) || strcmp(desc, sprintf('record %s, signal %d', opened_as, s))
        rep = add(rep, 'warning', 'desc_missing', where, ...
            'the signal has no description');
    else
        descs{end + 1} = desc; %#ok<AGROW>
        if is_number(desc)
            rep = add(rep, 'warning', 'desc_number', where, ...
                ['the description ' q(desc) ' is only a number']);
        end
        if has_control(desc)
            rep = add(rep, 'error', 'desc_control', where, ...
                ['the description ' q(desc) ' contains control characters']);
        end
    end
    if info.fmt == 8
        rep = add(rep, 'warning', 'format_difference', where, ...
            'format 8 stores first differences, which cannot follow steep slopes');
    end
    if info.gain == 0
        rep = add(rep, 'warning', 'gain_missing', where, ...
            'the signal is uncalibrated (no gain is given)');
    elseif info.gain < 0
        rep = add(rep, 'info', 'gain_negative', where, ...
            ['the gain is negative (' g(info.gain) ')']);
    end
    units = str(info.units);
    if info.gain ~= 0 && isempty(units)
        rep = add(rep, 'warning', 'units_missing', where, ...
            'the units are not specified');
    end
    if ~isempty(units) && has_control(units)
        rep = add(rep, 'error', 'units_control', where, ...
            ['the units ' q(units) ' contain control characters']);
    end
    b = info.adcres;
    if null
        cap = [];
    else
        cap = capacity(info.fmt);
    end
    if b == 0
        rep = add(rep, 'warning', 'adcres_missing', where, ...
            'the ADC resolution is not specified');
    elseif ~isempty(cap) && b > cap
        rep = add(rep, 'error', 'adcres_too_large', where, sprintf( ...
            'the ADC resolution (%d bits) exceeds what format %d can store (%d bits)', ...
            b, info.fmt, cap));
    elseif ~isempty(cap) && b >= 1
        [lo, hi] = adc_range(info);
        fmin = -2^(cap - 1);
        fmax = 2^(cap - 1) - 1;
        if lo < fmin || hi > fmax
            rep = add(rep, 'error', 'adc_range', where, sprintf( ...
                'the ADC range (%d to %d) does not fit in format %d (%d to %d)', ...
                lo, hi, info.fmt, fmin, fmax));
        end
    end
    fname = str(info.fname);
    if ~null && ~strcmp(fname, '-') && ~strcmp(fname, '~') && ...
            ~all(ismember(fname, FILE_CHARS))
        rep = add(rep, 'warning', 'filename', where, ...
            ['the signal file name ' q(fname) ' contains characters other ' ...
            'than letters, digits, ''_'', ''-'' and ''.''']);
    end
end
% descriptions shared by several signals, in the order of their first
% occurrence
done = false(1, numel(descs));
for k = 1:numel(descs)
    if done(k)
        continue;
    end
    same = strcmp(descs, descs{k});
    done = done | same;
    if sum(same) > 1
        rep = add(rep, 'warning', 'desc_duplicate', prefix, sprintf( ...
            '%d signals have the description %s', sum(same), q(descs{k})));
    end
end
end

function [lo, hi] = adc_range(info)
b = info.adcres;
lo = info.adczero - 2^(b - 1);
hi = info.adczero + 2^(b - 1) - 1;
end

% ---------------------------------------------------------------------------
% Signal data (section 3)

function rep = check_data(name, si, prefix, ns, length_missing, rep)
% Checks 3.1-3.9: read the signals of the record opened as NAME (header
% signals si, header length ns).
INVALID = -32768;           % WFDB_INVALID_SAMPLE
INT32_MAX = 2147483647;
n = numel(si);
if n == 0
    return;
end
fmts = [si.fmt];
fnames = cell(1, n);
for s = 1:n
    fnames{s} = str(si(s).fname);
end
if any(strcmp(fnames, '-') & fmts ~= 0)
    return;                 % (the standard input: not read)
end
wfdbx.wfdbquit();
[k, opened] = wfdbx.isigopen(name, n);
if k < n
    have = cell(1, numel(opened));
    for s = 1:numel(opened)
        have{s} = str(opened(s).fname);
    end
    reported = {};
    for s = 1:n
        if fmts(s) ~= 0 && ~any(strcmp(have, fnames{s})) && ...
                ~any(strcmp(reported, fnames{s}))
            reported{end + 1} = fnames{s}; %#ok<AGROW>
            rep = add(rep, 'error', 'file_unreadable', prefix, ...
                ['the signal file ' q(fnames{s}) ' cannot be read']);
        end
    end
    if isempty(reported)
        rep = add(rep, 'error', 'file_unreadable', prefix, ...
            ['the signal file ' q(fnames{1}) ' cannot be read']);
    end
    wfdbx.wfdbquit();
    return;
end
S = wfdbx.internal.sig_state();
groups = [si.group];
for gr = 1:numel(S.igd)
    size_ = file_size(S.igd{gr});
    if ~isempty(size_) && size_ > INT32_MAX
        j = find(groups == gr - 1, 1);
        rep = add(rep, 'warning', 'file_large', prefix, ...
            ['the signal file ' q(fnames{j}) ' has more than 2147483647 ' ...
            'bytes, which 32-bit applications cannot handle']);
    end
end
wfdbx.setgvmode(0);         % WFDB_LOWRES
lo = -Inf(1, n);
hi = Inf(1, n);
for s = 1:n
    b = si(s).adcres;
    if b >= 1 && b <= 32 && fmts(s) ~= 0
        [lo(s), hi(s)] = adc_range(si(s));
    end
end
n_out = zeros(1, n);
first_out = zeros(2, n);    % sample number and value
n_inv = zeros(1, n);
first_inv = zeros(1, n);
rows = max(1024, floor(2^20 / n));
m = 0;                      % frames read
stat = n;
residual = [];              % checksum residuals after ns frames
% (the checksums: not for EDF, nor for a record with skewed signals, whose
% samples the library reads ahead)
checked = ns > 0 && ~S.isedf;
for s = 0:n - 1
    if wfdbx.wfdbgetskew(s) ~= 0
        checked = false;
    end
end
S.cksum_quiet = true;
quiet = onCleanup(@() set_cksum_quiet(S, false)); %#ok<NASGU>
data_sig = find(fmts ~= 0);
while true
    want = rows;
    if checked && isempty(residual)
        want = min(rows, ns - m);
    end
    [x, stat, last] = wfdbx.getframes(want);
    if stat == -4
        x = [x; last]; %#ok<AGROW>
    end
    got = size(x, 1);
    if got > 0
        for s = data_sig
            col = x(:, s);
            bad = col == INVALID;
            if any(bad)
                if n_inv(s) == 0
                    first_inv(s) = m + find(bad, 1) - 1;
                end
                n_inv(s) = n_inv(s) + sum(bad);
            end
            out = ~bad & (col < lo(s) | col > hi(s));
            if any(out)
                if n_out(s) == 0
                    j = find(out, 1);
                    first_out(:, s) = [m + j - 1; col(j)];
                end
                n_out(s) = n_out(s) + sum(out);
            end
        end
        m = m + got;
    end
    if checked && isempty(residual) && m >= ns
        residual = zeros(1, n);
        for s = 1:n
            residual(s) = S.isd(s).info.cksum;
        end
    end
    if stat == -4
        continue;
    end
    if got < want
        break;
    end
end
S.cksum_quiet = false;
% (with skewed signals, getvec returns the frames of the files less the
% largest skew)
skew = 0;
for s = 0:n - 1
    skew = max(skew, wfdbx.wfdbgetskew(s));
end
wfdbx.wfdbquit();
if skew && m > 0
    m = m + skew;
end
for s = 1:n
    where = at(prefix, sprintf('signal %d', s - 1));
    if n_out(s)
        x = sprintf('sample %d (value %d)', first_out(1, s), first_out(2, s));
        rep = add(rep, 'error', 'sample_range', where, count_msg(n_out(s), ...
            'sample', 'is', 'are', sprintf('outside the ADC range (%d to %d)', ...
            lo(s), hi(s)), x));
    end
    if n_inv(s)
        rep = add(rep, 'info', 'invalid_samples', where, count_msg(n_inv(s), ...
            'sample', 'is', 'are', 'invalid (missing data)', ...
            sprintf('sample %d', first_inv(s))));
    end
end
if ~isempty(residual)
    for s = 1:n
        info = si(s);
        if info.nsamp > 0 && info.fmt ~= 0 && mod(residual(s), 65536) ~= 0
            rep = add(rep, 'error', 'checksum', at(prefix, sprintf('signal %d', s - 1)), ...
                sprintf('the checksum does not match: the header gives %d, the samples sum to %d', ...
                int16v(info.cksum), int16v(info.cksum - residual(s))));
        end
    end
end
end_ok = stat == -1 || stat >= 0;
short = ns > 0 && m < ns && (stat == -1 || stat == -3);
if short
    rep = add(rep, 'error', 'length_short', prefix, sprintf( ...
        'the signal files end after %s, before the %d given in the header', ...
        nn(m, 'frame'), ns));
end
if ns > 0 && m > ns
    rep = add(rep, 'warning', 'length_long', prefix, sprintf( ...
        'the signal files hold %s, more than the %d given in the header', ...
        nn(m, 'frame'), ns));
end
if length_missing && end_ok
    rep = add(rep, 'info', 'length_unspecified_frames', prefix, ...
        ['the signal files hold ' nn(m, 'frame')]);
end
if ~end_ok && ~short
    rep = add(rep, 'error', 'read_error', prefix, sprintf( ...
        'the signal data cannot be read after %s (getvec status %d)', ...
        nn(m, 'frame'), stat));
end
end

function set_cksum_quiet(S, on)
S.cksum_quiet = on;
end

function n = file_size(ig)
% The size of the local file of signal group ig, or [].
n = [];
f = ig.fp;
if isempty(f) || f.is_std || f.type ~= 0 || isempty(f.name)  % WFDB_LOCAL
    return;
end
d = dir(f.name);
if numel(d) == 1 && ~d.isdir
    n = d.bytes;
end
end

% ---------------------------------------------------------------------------
% A record (sections 1-4)

function h = open_header(name)
% Open the header of record NAME (wfdbquit first): nsig, siginfo, fs,
% nsamples and segments (names and lengths); [] if the header cannot be
% read.
wfdbx.wfdbquit();
n = wfdbx.isigopen(name, 0);
if n < 0
    wfdbx.wfdbquit();
    h = [];
    return;
end
si = wfdbx.siginfo(0);
if n > 0
    [~, si] = wfdbx.isigopen(name, -n);
end
S = wfdbx.internal.sig_state();
segs = wfdbx.getseginfo();
h.n = n;
h.si = si;
h.segnames = cell(1, numel(segs));
h.seglens = zeros(1, numel(segs));
for k = 1:numel(segs)
    h.segnames{k} = segs(k).recname;
    h.seglens(k) = double(segs(k).nsamp);
end
if S.in_msrec || ~isempty(segs)
    h.nsamples = double(S.msnsamples);
else
    h.nsamples = double(S.nsamples);
end
h.fs = wfdbx.sampfreq([]);
wfdbx.wfdbquit();
end

function [rep, length_missing] = check_single(record, h, hdr, rep)
% Sections 1.2-1.8 and 2 for a single-segment record.  length_missing is
% true if the header gives no length.
INT32_MAX = 2147483647;
if h.n == 0
    rep = add(rep, 'info', 'no_signals', '', 'the record has no signals');
end
if h.fs == 0
    rep = add(rep, 'warning', 'fs_missing', '', ...
        'the sampling frequency is not specified');
end
if h.nsamples == 0
    rep = add(rep, 'warning', 'length_missing', '', ...
        'the record length is not specified');
end
if ~isempty(hdr)
    rep = check_text(hdr, '', rep);
end
if h.nsamples > INT32_MAX
    rep = add(rep, 'info', 'length_large', '', ['the record has more than ' ...
        '2147483647 samples, which 32-bit applications cannot handle']);
end
if h.n > 0
    rep = check_specs(h.si, record, '', rep, false);
end
length_missing = h.nsamples == 0;
end

function [rep, len] = check_record_signals(record, rep)
% Sections 1-4.  len is the record length in samples for the annotation
% checks (0 if unknown), or [] if the header cannot be read.
INT32_MAX = 2147483647;
hdr = header_text(record);
h = open_header(record);
if isempty(h)
    rep = add(rep, 'error', 'header_unreadable', '', 'the header cannot be read');
    if ~isempty(hdr)
        rep = check_text(hdr, '', rep);
    end
    len = [];
    return;
end
if isempty(h.segnames)
    [rep, length_missing] = check_single(record, h, hdr, rep);
    if h.n > 0
        rep = check_data(record, h.si, '', h.nsamples, length_missing, rep);
    end
    len = h.nsamples;
    return;
end
% A multi-segment record: the master header
if h.n == 0
    rep = add(rep, 'info', 'no_signals', '', 'the record has no signals');
end
if h.fs == 0
    rep = add(rep, 'warning', 'fs_missing', '', ...
        'the sampling frequency is not specified');
end
if ~isempty(hdr)
    given = header_length(hdr.text);
else
    given = h.nsamples;
end
if given == 0
    rep = add(rep, 'warning', 'length_missing', '', ...
        'the record length is not specified');
end
if ~isempty(hdr)
    rep = check_text(hdr, '', rep);
end
if h.nsamples > INT32_MAX
    rep = add(rep, 'info', 'length_large', '', ['the record has more than ' ...
        '2147483647 samples, which 32-bit applications cannot handle']);
end
% The segments, next to the master header
if ~isempty(hdr)
    hpath = hdr.path;
else
    hpath = wfdbx.wfdbfile('hea', record);
    if ~ischar(hpath)
        hpath = '';
    end
end
d = wfdbx.internal.wfdb_dirname(hpath);
if isempty(d)
    d = [pwd() filesep()];
elseif ~wfdbx.internal.is_url(d) && ~wfdbx.internal.is_absolute_path(d)
    d = [pwd() filesep() d];
end
variable = h.seglens(1) == 0;
layout_descs = {};
done = {};
for k = 1:numel(h.segnames)
    seg = h.segnames{k};
    if strcmp(seg, '~') || any(strcmp(done, seg))
        continue;
    end
    done{end + 1} = seg; %#ok<AGROW>
    prefix = ['segment ' seg];
    is_layout = variable && k == 1;
    if ~wfdbx.internal.in_header_dir(seg)
        rep = add(rep, 'error', 'segment_unreadable', prefix, ...
            'the segment cannot be read');
        continue;
    end
    path = [d seg];
    seg_hdr = header_text(path);
    sh = open_header(path);
    if ~isempty(sh) && ~isempty(sh.segnames)
        rep = add(rep, 'error', 'nested', prefix, ...
            'the segment is itself a multi-segment record');
        continue;
    end
    if isempty(sh)
        rep = add(rep, 'error', 'segment_unreadable', prefix, ...
            'the segment cannot be read');
        continue;
    end
    if sh.fs > 0 && h.fs > 0 && sh.fs ~= h.fs
        rep = add(rep, 'error', 'segment_fs', prefix, ['the segment''s ' ...
            'sampling frequency (' g(sh.fs) ') differs from the record''s (' ...
            g(h.fs) ')']);
    end
    if sh.n == 0
        rep = add(rep, 'info', 'no_signals', prefix, 'the record has no signals');
    end
    if ~isempty(seg_hdr)
        rep = check_text(seg_hdr, prefix, rep);
    end
    if sh.nsamples > INT32_MAX
        rep = add(rep, 'info', 'length_large', prefix, ['the record has more ' ...
            'than 2147483647 samples, which 32-bit applications cannot handle']);
    end
    if sh.n > 0
        rep = check_specs(sh.si, path, prefix, rep, ~is_layout);
    end
    if is_layout
        layout_descs = {sh.si.desc};
        continue;
    end
    if variable
        for s = 1:numel(sh.si)
            x = sh.si(s);
            if x.fmt ~= 0 && ~desc_in(x.desc, layout_descs)
                rep = add(rep, 'error', 'layout_missing_signal', ...
                    at(prefix, sprintf('signal %d', s - 1)), ...
                    ['the signal ' q(str(x.desc)) ' is not in the layout']);
            end
        end
    else
        rep = check_layout(sh.si, h.si, prefix, rep);
    end
    if sh.n > 0
        rep = check_data(path, sh.si, prefix, sh.nsamples, false, rep);
    end
end
total = sum(h.seglens);
if given > 0 && total ~= given
    rep = add(rep, 'warning', 'segment_lengths', '', sprintf( ...
        'the segment lengths add up to %s, but the master header gives %d', ...
        nn(total, 'sample'), given));
end
len = total;                % (the end of the signals)
end

function tf = desc_in(desc, descs)
% true if desc ([] when absent) is one of descs
tf = false;
for k = 1:numel(descs)
    if (ischar(desc) && ischar(descs{k}) && strcmp(desc, descs{k})) || ...
            (~ischar(desc) && ~ischar(descs{k}))
        tf = true;
        return;
    end
end
end

function rep = check_layout(ssi, si, prefix, rep)
% Check 4.4: the signals of a segment of a fixed-layout record match the
% record's signals.
if numel(ssi) ~= numel(si)
    rep = add(rep, 'error', 'layout_signals', prefix, sprintf( ...
        'the segment has %s, but the record has %d', ...
        nn(numel(ssi), 'signal'), numel(si)));
end
for s = 1:min(numel(ssi), numel(si))
    a = ssi(s);
    b = si(s);
    if a.fmt == 0
        continue;
    end
    where = at(prefix, sprintf('signal %d', s - 1));
    cmp = {'description', q(str(a.desc)), q(str(b.desc)); ...
        'units', q(str(a.units)), q(str(b.units)); ...
        'gain', g(a.gain), g(b.gain); ...
        'baseline', sprintf('%d', a.baseline), sprintf('%d', b.baseline); ...
        'samples per frame', sprintf('%d', a.spf), sprintf('%d', b.spf)};
    for j = 1:size(cmp, 1)
        if ~strcmp(cmp{j, 2}, cmp{j, 3})
            rep = add(rep, 'error', 'layout_mismatch', where, sprintf( ...
                'the signal differs from the record''s signal %d in its %s (%s, expected %s)', ...
                s - 1, cmp{j, 1}, cmp{j, 2}, cmp{j, 3}));
        end
    end
end
end

% ---------------------------------------------------------------------------
% Annotators (section 5)

function rep = check_annotator(record, an, len, rep)
ACMAX = 49;
where = ['annotator ' an];
if ~isempty(an) && all(an >= '0' & an <= '9')
    rep = add(rep, 'warning', 'annotator_name', where, ...
        'the annotator name consists only of digits');
end
wfdbx.wfdbquit();
if ~isempty(len)
    wfdbx.sampfreq(record);     % (the record's frequency, for getann)
end
st = wfdbx.internal.ann_state();
astring = st.astring;
tstring = st.tstring;
modified = st.modified;
restore = onCleanup(@() restore_tables(st, astring, tstring, modified)); %#ok<NASGU>
if wfdbx.annopen(record, wfdbx.anninfo(an, 0), 1) < 0  % WFDB_READ
    rep = add(rep, 'error', 'annotations_unreadable', where, ...
        'the annotation file cannot be read');
    return;
end
[stat, A] = wfdbx.internal.getann_bulk(0, Inf, true);
t = double(A.time);
c = double(A.anntyp);
undefined = false(size(c));
codes = unique(c(c >= 1 & c <= ACMAX));
for k = 1:numel(codes)
    if strcmp(wfdbx.annstr(codes(k)), sprintf('[%d]', codes(k)))
        undefined = undefined | c == codes(k);
    end
end
wfdbx.wfdbquit();
clear restore
count = numel(t);
if stat ~= -1
    rep = add(rep, 'error', 'annotations_truncated', where, ...
        ['the annotation file ends unexpectedly after ' nn(count, 'annotation')]);
end
order = find(t(2:end) < t(1:end - 1)) + 1;
if ~isempty(order)
    x = sprintf('at sample %d, after sample %d', t(order(1)), t(order(1) - 1));
    rep = add(rep, 'error', 'annotations_order', where, count_msg(numel(order), ...
        'annotation', 'is', 'are', 'out of order', x));
end
k = find(c > ACMAX);
if ~isempty(k)
    x = sprintf('at sample %d (code %d)', t(k(1)), c(k(1)));
    rep = add(rep, 'error', 'annotation_code', where, count_msg(numel(k), ...
        'annotation', 'has', 'have', 'an invalid code', x));
end
k = find(c == 0);
if ~isempty(k)
    x = sprintf('at sample %d', t(k(1)));
    rep = add(rep, 'warning', 'annotation_null', where, count_msg(numel(k), ...
        'annotation', 'has', 'have', 'code 0 (NOTQRS)', x));
end
k = find(undefined);
if ~isempty(k)
    x = sprintf('at sample %d (code %d)', t(k(1)), c(k(1)));
    if numel(k) == 1
        msg = ['1 annotation uses a code without a mnemonic: ' x];
    else
        msg = sprintf('%d annotations use codes without a mnemonic; the first is %s', ...
            numel(k), x);
    end
    rep = add(rep, 'warning', 'annotation_undefined', where, msg);
end
if ~isempty(len) && len > 0
    k = find(t >= len);
    if ~isempty(k)
        x = sprintf('at sample %d', t(k(1)));
        rep = add(rep, 'warning', 'annotations_after_end', where, count_msg( ...
            numel(k), 'annotation', 'is', 'are', ['after the end of the record (' ...
            nn(len, 'sample') ')'], x));
    end
end
end

function restore_tables(st, astring, tstring, modified)
wfdbx.wfdbquit();
st.astring = astring;
st.tstring = tstring;
st.modified = modified;
end
