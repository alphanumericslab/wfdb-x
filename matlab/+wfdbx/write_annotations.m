function write_annotations(record, annotator, samples, varargin)
%WRITE_ANNOTATIONS Write an annotation file from arrays.
%   wfdbx.write_annotations(RECORD, ANNOTATOR, SAMPLES, NAME, VALUE, ...)
%   writes the annotation file RECORD.ANNOTATOR, with one annotation at each
%   of the sample numbers SAMPLES.  The other fields are given as options:
%
%     'symbols'   cell array of mnemonics ('N', 'V', ...), or a char vector
%                 of one-character mnemonics ('NNV'); or
%     'codes'     annotation codes (wfdbx.NORMAL(), ...).  One of the two is
%                 required.
%     'subtypes', 'chans', 'nums'   one value for all annotations, or one
%                 per annotation (default 0)
%     'aux'       cell array of auxiliary texts ([] for none), or one char
%                 vector for all
%     'fs'        time resolution to record in the file, in ticks per second
%     'dir'       folder in which to create the file (default: the output
%                 directory).  RECORD must then be a plain name.
%     'sort'      true to always sort the file, false to keep the order given
%                 (without the library's advice to run sortann; default []:
%                 the environment variable WFDBANNSORT decides)
%     'legacy'    true to behave as the original WFDB package (default
%                 false; see wfdbx.wfdbx_set_legacy)
%
%   If the annotations are not in time order, the file is sorted when it is
%   written, unless 'sort' is false, or 'sort' is not given and WFDBANNSORT
%   is 0.
%
%   Errors: an error (identifier 'wfdbx:write_annotations') is thrown if
%   neither 'symbols' nor 'codes' is given, if 'dir' does not exist, if the
%   file cannot be created, or if it cannot be written completely, for
%   example when the disk is full ("write error on annotator ANNOTATOR for
%   record RECORD", after the library's message; in legacy mode too).
%
%   The function calls wfdbx.wfdbquit, which closes anything opened with the
%   WFDB library functions.
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
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

record = wfdbx.internal.strarg(record);
annotator = wfdbx.internal.strarg(annotator);
opt = struct('symbols', [], 'codes', [], 'subtypes', 0, 'chans', 0, ...
    'nums', 0, 'aux', [], 'fs', [], 'dir', [], 'sort', [], 'legacy', false);
opt = wfdbx.internal.hl_options(opt, varargin, 'write_annotations');
% wfdb-x: the 'dir' option (the library's output directory, for this
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
end
if ischar(opt.aux)
    opt.aux = repmat({opt.aux}, 1, numel(samples));
end
samples = reshape(double(samples), 1, []);
n = numel(samples);
if isempty(opt.codes)
    if isempty(opt.symbols) && n > 0
        error('wfdbx:write_annotations', 'symbols or codes must be given');
    end
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
    codes = reshape(uc(j), 1, []);
else
    codes = reshape(double(opt.codes), 1, []);
end
A.time = samples;
A.anntyp = per(codes, n);
A.subtyp = per(opt.subtypes, n);
A.chan = per(opt.chans, n);
A.num = per(opt.nums, n);
A.aux = cell(1, n);
if ~isempty(opt.aux)
    % (each distinct string is encoded once)
    aux = reshape(opt.aux(1:n), 1, []);
    idx = find(cellfun('isclass', aux, 'char'));
    if ~isempty(idx)
        [u, ~, j] = unique(aux(idx));
        enc = cell(1, numel(u));
        for k = 1:numel(u)
            b = double(u{k}(1:min(end, 255)));
            enc{k} = uint8([numel(b), b]);
        end
        A.aux(idx) = enc(j);
    end
end
wfdbx.wfdbquit();
errors = wfdbx.wfdbx_write_errors();
if ~isempty(opt.fs)
    wfdbx.setafreq(opt.fs);
end
if wfdbx.annopen(record, wfdbx.anninfo(annotator, 1), 1) < 0
    wfdbx.wfdbquit();
    error('wfdbx:write_annotations', 'can''t create annotator %s for record %s', ...
        annotator, record);
end
wfdbx.internal.putann_bulk(0, A);
% wfdb-x: the 'sort' option, for the closing of this file only
st = wfdbx.internal.ann_state();
if ~isempty(opt.sort)
    st.sort_override = logical(opt.sort);
end
unset = onCleanup(@() clear_sort(st)); %#ok<NASGU>
wfdbx.wfdbquit();
st.sort_override = [];
if ~isempty(opt.fs)
    wfdbx.setafreq(0);
end
if wfdbx.wfdbx_write_errors() > errors
    error('wfdbx:write_annotations', ...
        'write error on annotator %s for record %s', annotator, record);
end
end

function clear_sort(st)
st.sort_override = [];
end

function v = per(v, n)
v = reshape(double(v), 1, []);
if numel(v) == 1
    v = repmat(v, 1, n);
end
end
