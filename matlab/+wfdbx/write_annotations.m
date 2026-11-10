function write_annotations(record, annotator, samples, varargin)
%WRITE_ANNOTATIONS Write an annotation file from arrays.
%   wfdbx.write_annotations(RECORD, ANNOTATOR, SAMPLES, NAME, VALUE, ...)
%   writes the annotation file RECORD.ANNOTATOR, with one annotation at each
%   of the sample numbers SAMPLES (a vector: a 1-D array of integers from
%   -2^63 + 1 to 2^63 - 2, the smallest and largest 64-bit integers being
%   reserved by the file format; as doubles, exact up to 2^53, or as int64
%   values).  RECORD is the record name, without the
%   .hea extension (a trailing '.hea' is also accepted): a plain name or a
%   relative path ('data/100s') is created in the output directory if one
%   is set (see wfdbx.wfdbx_set_output_dir), otherwise in the current
%   folder; a full path, absolute or in the home directory
%   ('~/Documents/100s'), is used as given.  The file is RECORD.ANNOTATOR
%   at that place ('data/100s.qrs').  A URL cannot be written.  The other
%   fields are given as options:
%
%     'symbols'   cell array of mnemonics ('N', 'V', ...), or a char vector
%                 of one-character mnemonics ('NNV'), one per annotation
%                 (or one for all); or
%     'codes'     annotation codes (wfdbx.NORMAL(), ...; 0 to 58, as 59
%                 to 63 are the control codes of the file format).  One of
%                 the two is
%                 required (unless SAMPLES is empty).  If both are given (as wfdbx.read_annotations
%                 returns them), each symbol must be that of its code (an
%                 empty symbol is not checked), and the codes are written.
%     'subtypes', 'chans', 'nums'   one value for all annotations, or one
%                 per annotation (default 0).  As in C, they are stored in
%                 one byte each, and other values wrap around (subtypes and
%                 nums to -128..127, chans to 0..255).
%     'aux'       cell array of auxiliary texts, one per annotation ([] for
%                 none), or one char vector for all
%     'fs'        time resolution to record in the file, in ticks per second
%                 (finite, > 0)
%     'dir'       directory (which must exist) in which to create the file,
%                 for this call only (default: the output directory).
%                 RECORD must then be a plain name, without a directory:
%                 the file is DIR/RECORD.ANNOTATOR.
%     'sort'      true to always sort the file, false to keep the order given
%                 (without the library's advice to run sortann; default []:
%                 the environment variable WFDBANNSORT decides)
%     'legacy'    true to behave as the original WFDB package (default
%                 false; see wfdbx.wfdbx_set_legacy)
%
%   If the annotations are not in time order, the file is sorted when it is
%   written, unless 'sort' is false, or 'sort' is not given and WFDBANNSORT
%   is 0.  An existing file is replaced: the new file is written to a
%   temporary file in the same folder ('.NAME.XXXXXXXX.tmp', created with
%   the permissions of the file it replaces), which replaces it only when
%   it is complete (and sorted), so that an error leaves it as it was.
%
%   Errors: an error (identifier 'wfdbx:write_annotations') is thrown if
%   neither 'symbols' nor 'codes' is given for one annotation or more
%   ("symbols or codes must be given"; with no annotations, an empty file
%   is written), if both are given and disagree
%   ("symbols and codes disagree at annotation K", K counting from 0), if
%   SAMPLES is a matrix or an array of more dimensions ("samples must be a
%   1-D array"; the same for 'codes', 'subtypes', 'chans', 'nums', and for
%   'symbols' given with 'codes'), if a per-annotation option ('symbols',
%   'codes', 'subtypes', 'chans', 'nums', 'aux') given as a list does not
%   have one value per annotation ("... must have one value per
%   annotation"), if a time in SAMPLES is not an integer within the range
%   of a 64-bit integer (NaN, infinite values and fractions included), if
%   a code, subtype, chan or num is NaN or infinite, if 'fs' is not finite
%   and > 0, if a time is -2^63 (or, as an int64, 2^63 - 1: "annotation
%   time T cannot be written (annotation times must be integers from
%   -9223372036854775807 to 9223372036854775806)"), if a code is not from
%   0 to 58 ("annotation code C is reserved (59 to 63 are the control codes
%   of the annotation file format)", "annotation code C is out of range (0
%   to 58)"), if an aux text has a character beyond 255 ("aux text 'X' has
%   a character that is not Latin-1 (one byte per character)"; possible in
%   MATLAB only, whose characters are 16-bit), if 'dir' does not exist, if
%   the file cannot be created, or if it cannot be written completely, or
%   the library reports an error while writing it, for example when the
%   disk is full ("write error on annotator ANNOTATOR for record RECORD",
%   after the library's message; in legacy mode too).  The arguments are
%   checked, in that order, before the file is created or changed.
%
%   The function calls wfdbx.wfdbquit, which closes anything opened with the
%   WFDB library functions; it also closes the annotator when it fails,
%   and leaves no temporary file.  The getvec mode (wfdbx.getgvmode) and the time
%   resolution of output annotators (wfdbx.getafreq) are left as they were ('fs'
%   applies to this file only).
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with WFDB-x in the folder tests/data of a copy of
%   the repository; the example writes the annotation file 100s.test in the
%   current folder):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       wfdbx.write_annotations('100s', 'test', [100 460], ...
%           'symbols', {'N', 'V'});
%       ann = wfdbx.read_annotations('100s', 'test', 'input_dir', '.', ...
%           'fs', 360);
%
%   See also wfdbx.read_annotations, wfdbx.write_record.
%
%   Part of WFDB-x; not in the original WFDB package.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package. Its 'sort' option decides,
% for one call, whether an out-of-order file is rearranged, instead of the
% process-wide WFDBANNSORT environment variable.
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU Lesser General Public License as published by
% the Free Software Foundation, either version 2.1 of the License, or (at
% your option) any later version. See LICENSE.

record = wfdbx.internal.strarg(record);
% WFDB-x: the getvec mode and the time resolution of output annotators are
% restored when the function returns (also on errors; opening an EDF record
% sets both)
keep_settings = wfdbx.internal.hl_settings(); %#ok<NASGU>
annotator = wfdbx.internal.strarg(annotator);
opt = struct('symbols', [], 'codes', [], 'subtypes', 0, 'chans', 0, ...
    'nums', 0, 'aux', [], 'fs', [], 'dir', [], 'sort', [], 'legacy', false);
opt = wfdbx.internal.hl_options(opt, varargin, 'write_annotations');
% WFDB-x: the 'dir' option (the library's output directory, for this
% call), checked before the other arguments
restore_dir = wfdbx.internal.hl_outdir(opt.dir, record, ...
    'write_annotations'); %#ok<NASGU>
legacy = wfdbx.internal.hl_legacy(opt.legacy, 'write_annotations'); %#ok<NASGU>
if ~(isempty(opt.sort) || ((islogical(opt.sort) || isnumeric(opt.sort)) && ...
        isscalar(opt.sort)))
    error('wfdbx:write_annotations', ...
        'write_annotations: sort must be true, false or []');
end
if ischar(opt.symbols)
    opt.symbols = num2cell(opt.symbols);
elseif isa(opt.symbols, 'string')
    opt.symbols = cellstr(opt.symbols);
end
if ischar(opt.aux)
    opt.aux = repmat({opt.aux}, 1, numel(samples));
elseif isa(opt.aux, 'string')
    opt.aux = cellstr(opt.aux);
end
% WFDB-x: every argument is checked before the file is touched
if ~is_1d(samples)
    error('wfdbx:write_annotations', 'samples must be a 1-D array');
end
both = ~isempty(opt.codes) && ~isempty(opt.symbols);
seq = {'codes', 'subtypes', 'chans', 'nums'};
if both
    seq = [{'symbols'}, seq];
end
for k = 1:numel(seq)
    if ~is_1d(opt.(seq{k}))
        error('wfdbx:write_annotations', '%s must be a 1-D array', seq{k});
    end
end
t64 = samples;
samples = reshape(double(samples), 1, []);
n = numel(samples);
if isempty(opt.codes) && isempty(opt.symbols) && n > 0
    error('wfdbx:write_annotations', 'symbols or codes must be given');
end
if ~isempty(opt.symbols) && numel(opt.symbols) == 1     % (one for all)
    opt.symbols = repmat(reshape(opt.symbols, 1, 1), 1, n);
end
if both || isempty(opt.codes)
    check(opt.symbols, n, 'symbols');
end
A.time = samples;
if isempty(opt.codes)
    A.anntyp = zeros(1, n);     % (from the symbols, below)
else
    A.anntyp = per(opt.codes, n, 'codes');
end
A.subtyp = per(opt.subtypes, n, 'subtypes');
A.chan = per(opt.chans, n, 'chans');
A.num = per(opt.nums, n, 'nums');
% WFDB-x: the times are integers within the range of WFDB_Time
if ~all(isfinite(samples) & samples == fix(samples))
    error('wfdbx:write_annotations', 'annotation times must be integers');
end
if isa(t64, 'int64')
    in_range = true;
elseif isa(t64, 'uint64')
    in_range = all(t64(:) <= uint64(intmax('int64')));
else
    in_range = all(samples >= -2^63 & samples < 2^63);
end
if ~in_range
    error('wfdbx:write_annotations', ['annotation times must be integers ' ...
        'within the range of a 64-bit integer']);
end
if ~isempty(opt.fs) && ~(isnumeric(opt.fs) && isscalar(opt.fs) && ...
        isreal(opt.fs) && isfinite(opt.fs) && opt.fs > 0)
    error('wfdbx:write_annotations', 'fs must be finite and > 0');
end
if isempty(opt.codes)
    % (wfdbx.strann once for each distinct mnemonic; anything but text is
    % code 0, as for strann)
    sym = reshape(opt.symbols(1:n), 1, []);
    if ~iscell(sym)
        sym = num2cell(sym);
    end
    sym(~cellfun('isclass', sym, 'char')) = {''};
    [u, ~, j] = unique(sym);
    uc = zeros(1, numel(u));
    for k = 1:numel(u)
        uc(k) = wfdbx.strann(u{k});
    end
    A.anntyp = reshape(uc(j), 1, []);
end
% WFDB-x: NaN (or an infinite value) is an error
fields = {'anntyp', 'codes'; 'subtyp', 'subtypes'; 'chan', 'chans'; 'num', 'nums'};
for k = 1:size(fields, 1)
    if ~all(isfinite(A.(fields{k, 1})))
        error('wfdbx:write_annotations', '%s must not be NaN or infinite', ...
            fields{k, 2});
    end
end
% WFDB-x: the times that the MIT format can store: the smallest and the
% largest 64-bit integers are reserved (putann refuses them, "time
% overflow", and the annotation was dropped); any other time is stored
% (with SKIPs for intervals beyond 1023 samples).  (2^63 - 1 is not a
% double: as a double, it is 2^63, beyond the range checked above.)
if isa(t64, 'int64')
    bad = find(t64 == intmin('int64') | t64 == intmax('int64'), 1);
    if ~isempty(bad)
        bad_time(t64(bad));
    end
elseif isa(t64, 'uint64')
    bad = find(t64 == uint64(intmax('int64')), 1);
    if ~isempty(bad)
        bad_time(t64(bad));
    end
else
    bad = find(samples == -2^63, 1);
    if ~isempty(bad)
        bad_time(int64(samples(bad)));
    end
end
% WFDB-x: the annotation codes are 0 to 58 (ACMAX is 49, and 50 to 58 are
% free); 59 to 63 are the control codes of the MIT format (SKIP, NUM, SUB,
% CHN, AUX), which corrupt the file, and other values do not fit in its 6
% bits
MAXCODE = 58;
k = find(A.anntyp < 0 | A.anntyp > MAXCODE, 1);
if ~isempty(k)
    c = A.anntyp(k);
    if c > MAXCODE && c <= 63
        error('wfdbx:write_annotations', ['annotation code %d is reserved ' ...
            '(59 to 63 are the control codes of the annotation file format)'], c);
    end
    error('wfdbx:write_annotations', ...
        'annotation code %s is out of range (0 to %d)', num2str(c), MAXCODE);
end
if both
    % WFDB-x: symbols and codes may both be given (as read_annotations
    % returns them) if they agree: each symbol is that of its code (an
    % empty symbol agrees with any code)
    sym = reshape(opt.symbols(1:n), 1, []);
    if ~iscell(sym)
        sym = num2cell(sym);
    end
    for k = 1:n
        if ischar(sym{k}) && ~isempty(sym{k}) && ...
                wfdbx.strann(sym{k}) ~= A.anntyp(k)
            error('wfdbx:write_annotations', ...
                'symbols and codes disagree at annotation %d', k - 1);
        end
    end
end
A.aux = cell(1, n);
if ~isempty(opt.aux)
    if ~iscell(opt.aux)
        error('wfdbx:write_annotations', ...
            'aux must be a cell array of strings, or one string');
    end
    check(opt.aux, n, 'aux');
    % (each distinct string is encoded once)
    aux = reshape(opt.aux(1:n), 1, []);
    idx = find(cellfun('isclass', aux, 'char'));
    if ~isempty(idx)
        [u, ~, j] = unique(aux(idx));
        enc = cell(1, numel(u));
        for k = 1:numel(u)
            % WFDB-x: aux texts are one byte per character (a character
            % beyond 255, possible in MATLAB, would be written as another
            % byte)
            if any(double(u{k}) > 255)
                error('wfdbx:write_annotations', ['aux text ''%s'' has a ' ...
                    'character that is not Latin-1 (one byte per ' ...
                    'character)'], u{k});
            end
            b = double(u{k}(1:min(end, 255)));
            enc{k} = uint8([numel(b), b]);
        end
        A.aux(idx) = enc(j);
    end
end
wfdbx.wfdbquit();
errors = wfdbx.wfdbx_write_errors();
st = wfdbx.internal.ann_state();
% WFDB-x: the file is written to a temporary file in the directory of its
% destination, which is renamed over it when it is complete (and, if
% needed, sorted); after a failure, it is removed, and the existing file is
% left as it was (see wfdbx.internal.staging_begin)
wfdbx.internal.staging_begin();
unstage = onCleanup(@() wfdbx.internal.staging_end(false)); %#ok<NASGU>
% (the annotator is closed however this ends)
try
    if ~isempty(opt.fs)
        wfdbx.setafreq(opt.fs);
    end
    if wfdbx.annopen(record, wfdbx.anninfo(annotator, 1), 1) < 0
        error('wfdbx:write_annotations', ...
            'can''t create annotator %s for record %s', annotator, record);
    end
    % WFDB-x: an error that putann reports is an error
    put_failed = wfdbx.internal.putann_bulk(0, A) < 0;
    % WFDB-x: the 'sort' option, for the closing of this file only
    if ~isempty(opt.sort)
        st.sort_override = logical(opt.sort);
    end
    wfdbx.wfdbquit();
catch err
    st.sort_override = [];
    wfdbx.wfdbquit();
    wfdbx.internal.staging_end(false);
    rethrow(err);
end
st.sort_override = [];
% (WFDB-x: the previous time resolution is restored by keep_settings)
complete = ~put_failed && wfdbx.wfdbx_write_errors() == errors;
if ~wfdbx.internal.staging_end(complete)
    error('wfdbx:write_annotations', ...
        'write error on annotator %s for record %s', annotator, record);
end
end

function bad_time(t)
% WFDB-x: the error for a reserved annotation time T (an int64)
error('wfdbx:write_annotations', ['annotation time %d cannot be written ' ...
    '(annotation times must be integers from %d to %d)'], t, ...
    intmin('int64') + 1, intmax('int64') - 1);
end

function tf = is_1d(v)
% True if V is a vector (a row or a column), a scalar or empty: not a
% matrix nor an array of more dimensions
tf = isempty(v) || (ndims(v) == 2 && min(size(v)) == 1); %#ok<ISMAT>
end

function v = per(v, n, what)
% one value for all annotations, or one per annotation
v = reshape(double(v), 1, []);
if numel(v) == 1
    v = repmat(v, 1, n);
else
    check(v, n, what);
end
end

function check(v, n, what)
% WFDB-x: a list of values must have one value per annotation
if numel(v) ~= n
    error('wfdbx:write_annotations', ...
        '%s must have one value per annotation', what);
end
end
