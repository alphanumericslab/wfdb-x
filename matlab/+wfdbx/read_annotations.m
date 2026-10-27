function ann = read_annotations(record, annotator, varargin)
%READ_ANNOTATIONS Read an annotation file into arrays.
%   ANN = wfdbx.read_annotations(RECORD, ANNOTATOR) reads all annotations of
%   the record RECORD from the annotation file with the suffix ANNOTATOR:
%   wfdbx.read_annotations('100s', 'atr') reads 100s.atr.
%
%   ANN = wfdbx.read_annotations(RECORD, ANNOTATOR, NAME, VALUE, ...) takes
%   these options:
%
%     'sampfrom'  read the annotations at or after this time: a sample
%                 number or a time string (default 0)
%     'sampto'    read the annotations before this time (default: all)
%     'fs'        sampling frequency in Hz, used when the record has no
%                 header or its header gives none (default: none)
%     'input_dir', 'network', 'legacy'
%                 as in wfdbx.read_record
%
%   wfdbx.read_annotations(RECORD, ANNOTATOR, SAMPFROM, SAMPTO) is also
%   accepted.
%
%   ANN has these fields, one row per annotation, in file order:
%
%     samples     annotation times, in samples
%     codes       annotation codes (wfdbx.NORMAL(), wfdbx.PVC(), ...)
%     symbols     cell array of their mnemonics ('N', 'V', ...)
%     subtypes, chans, nums   subtype, channel and annotator number
%     aux         cell array of the auxiliary texts ([] where there is none)
%     fs          the frequency in which the times are counted (0 if
%                 unknown)
%     record, annotator   the arguments
%
%   Errors: an error (identifier 'wfdbx:read_annotations') is thrown if the
%   annotation file cannot be opened, if it ends unexpectedly or cannot be
%   read before 'sampto' ("can't read annotation file ANNOTATOR of record
%   RECORD (getann status S)"), or if a time string needs the sampling
%   frequency and none is known.
%
%   The function calls wfdbx.wfdbquit, which closes anything opened with the
%   WFDB library functions.
%
%   Example (100s, the first minute of record 100 of the MIT-BIH Arrhythmia
%   Database, is included with wfdb-x in the folder tests/data of a copy of
%   the repository):
%       wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
%       ann = wfdbx.read_annotations('100s', 'atr', 'sampto', '0:30');
%       ann.symbols(1:3)'                                   % {'+', 'N', 'N'}
%       beats = ann.samples(wfdbx.isqrs(ann.codes) == 1);   % QRS times
%       rr = diff(beats) / ann.fs;                          % RR intervals (s)
%
%   See also wfdbx.write_annotations, wfdbx.read_record.
%
%   Part of wfdb-x; not in the original WFDB package.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It has no counterpart in the original package. Like the rest of wfdb-x, it
% never assumes a sampling frequency (see docs/DIVERGENCES.md).
%
% Copyright (C) 2026 Reza Sameni.
%
% This library is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

record = wfdbx.internal.strarg(record);
annotator = wfdbx.internal.strarg(annotator);
varargin = wfdbx.internal.strarg(varargin);
opt = struct('sampfrom', 0, 'sampto', [], 'fs', [], 'input_dir', [], ...
    'network', [], 'legacy', false);
names = fieldnames(opt);
if ~isempty(varargin) && ~(ischar(varargin{1}) && ...
        any(strcmpi(varargin{1}, names)))
    % positional form (SAMPFROM, SAMPTO, name-value pairs)
    opt.sampfrom = varargin{1};
    n = 1;
    if numel(varargin) > 1 && ~(ischar(varargin{2}) && ...
            any(strcmpi(varargin{2}, names)))
        opt.sampto = varargin{2};
        n = 2;
    end
    varargin = varargin(n + 1:end);
end
opt = wfdbx.internal.hl_options(opt, varargin, 'read_annotations');
legacy = wfdbx.internal.hl_legacy(opt.legacy, 'read_annotations'); %#ok<NASGU>
% wfdb-x: the input directory and network access for this call
restore_input = wfdbx.internal.hl_input(opt.input_dir, opt.network, ...
    'read_annotations'); %#ok<NASGU>
% the library's legacy mode also applies (wfdbx.wfdbx_set_legacy)
opt.legacy = opt.legacy || wfdbx.wfdbx_get_legacy() ~= 0;
if ~isempty(opt.fs) && ~(isnumeric(opt.fs) && isscalar(opt.fs) && opt.fs > 0)
    error('wfdbx:read_annotations', 'fs must be > 0');
end
sampfrom = opt.sampfrom;
sampto = opt.sampto;
wfdbx.wfdbquit();
% wfdb-x: no default sampling frequency (C used WFDB_DEFFREQ, 250 Hz, if
% the record had no header); 'fs' gives one, as -F does for rdann.
f = wfdbx.sampfreq(record);
if f <= 0 && ~isempty(opt.fs)
    wfdbx.setsampfreq(opt.fs);
elseif f < 0 && opt.legacy
    wfdbx.setsampfreq(250);     % WFDB_DEFFREQ (wfdb-x: legacy mode)
end
if wfdbx.annopen(record, wfdbx.anninfo(annotator, 0), 1) < 0
    wfdbx.wfdbquit();
    error('wfdbx:read_annotations', 'can''t read annotator %s for record %s', ...
        annotator, record);
end
fs = wfdbx.getifreq();
[from, ok1] = wfdbx.internal.hl_time(sampfrom, fs);
[to, ok2] = wfdbx.internal.hl_time(sampto, fs);
if ~ok1 || ~ok2
    wfdbx.wfdbquit();
    error('wfdbx:read_annotations', ...
        'sampling frequency of record %s is not specified', record);
end
if ~isempty(from) && from ~= 0 && wfdbx.iannsettime(from) < 0
    wfdbx.wfdbquit();
    error('wfdbx:read_annotations', 'can''t seek in annotator %s', annotator);
end
st = wfdbx.internal.ann_state();
if ~isempty(to) && st.iad{1}.P.aha
    % (one at a time: reading an AHA annotation may print a message, and
    % C reads no annotation after the first one at or after 'to')
    A = [];
    while true
        [stat, B] = wfdbx.internal.getann_bulk(0, 1, false, true);
        if isempty(A)
            A = B;
        else
            A = cat_ann(A, B);
        end
        if stat ~= 0 || B.time(1) >= to
            break;
        end
    end
else
    [stat, A] = wfdbx.internal.getann_bulk(0, inf, false, true);
end
k = [];
if ~isempty(to)
    k = find(A.time >= to, 1);
end
if stat == 1 && isempty(k)
    stat = wfdbx.getann(0);             % the call that fails (error message)
end
% wfdb-x: a read that ends with a status other than -1 (end of the file)
% before reaching 'sampto' (e.g. -3, unexpected EOF) is an error
if isempty(k) && stat < 0 && stat ~= -1
    wfdbx.wfdbquit();
    error('wfdbx:read_annotations', ...
        'can''t read annotation file %s of record %s (getann status %d)', ...
        annotator, record, stat);
end
if ~isempty(to)
    if ~isempty(k)
        n = k - 1;
        A.time = A.time(1:n);
        A.anntyp = A.anntyp(1:n);
        A.subtyp = A.subtyp(1:n);
        A.chan = A.chan(1:n);
        A.num = A.num(1:n);
        A.aux = A.aux(1:n);
    end
end
n = numel(A.time);
aux = cell(n, 1);
for k = reshape(find(~cellfun('isempty', A.aux)), 1, [])
    x = A.aux{k};
    x = x(2:min(end, double(x(1)) + 1));
    z = find(x == 0, 1);
    if ~isempty(z)
        x = x(1:z-1);
    end
    aux{k} = char(x);
end
symbols = cell(n, 1);
for c = reshape(unique(A.anntyp), 1, [])
    symbols(A.anntyp == c) = {wfdbx.annstr(c)};
end
ann.record = record;
ann.annotator = annotator;
ann.samples = A.time(:);
ann.codes = A.anntyp(:);
ann.symbols = symbols;
ann.subtypes = A.subtyp(:);
ann.chans = A.chan(:);
ann.nums = A.num(:);
ann.aux = aux;
ann.fs = wfdbx.getiafreq(0);
wfdbx.wfdbquit();
end

function A = cat_ann(A, B)
A.time = [A.time, B.time];
A.anntyp = [A.anntyp, B.anntyp];
A.subtyp = [A.subtyp, B.subtyp];
A.chan = [A.chan, B.chan];
A.num = [A.num, B.num];
A.aux = [A.aux, B.aux];
end

