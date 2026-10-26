function write_annotations(record, annotator, samples, varargin)
%WRITE_ANNOTATIONS Write an annotation file from arrays.
%   wfdbx.write_annotations(RECORD, ANNOTATOR, SAMPLES, NAME, VALUE, ...)
%   writes the annotation file RECORD.ANNOTATOR, as wrann does, with one
%   annotation at each of the sample numbers SAMPLES.  The other fields
%   are given as name-value pairs:
%
%     'symbols'   cell of mnemonics ('N', 'V', ...; wfdbx.strann), or a
%                 char vector of one-character mnemonics ('NNVN'), or
%     'codes'     annotation codes (one of the two is required)
%     'subtypes', 'chans', 'nums'   values (scalars apply to all; default 0)
%     'aux'       cell of auxiliary strings (char, [] for none; at most
%                 255 bytes are written), or one char vector for all
%     'fs'        time resolution to record in the file (ticks per second)
%     'dir'       the directory (which must exist) in which the file is
%                 created (default: the current directory, or the
%                 directory part of RECORD; RECORD must not contain a
%                 directory when 'dir' is given)
%     'sort'      true to rearrange an out-of-order file in canonical
%                 order when it is closed, false to leave it in the order
%                 given, for this call only, whatever the environment
%                 variable WFDBANNSORT says (in legacy mode too: true
%                 runs sortann as legacy mode does); default [] (unset):
%                 WFDBANNSORT decides (see below).  The environment is
%                 not changed.
%     'legacy'    true to run with the library's legacy mode
%                 (wfdbx.wfdbx_set_legacy) on during the call (default
%                 false; writing annotations does not depend on it)
%
%   SAMPLES and the other values may be row or column vectors.
%
%   Annotations that are not in canonical order are rearranged when the
%   file is closed, unless 'sort' is false, or 'sort' is unset and the
%   environment variable WFDBANNSORT is 0 (as
%   the sortann tool does; wfdb-x: in this process, whereas the C library,
%   as legacy mode, runs sortann; see wfdbx.oannclose).  An error is
%   thrown if the file cannot be created, or if 'dir' is given and does
%   not exist or RECORD contains a directory.
%
%   The function calls wfdbx.wfdbquit before and after its work, so any
%   signals or annotators opened with the low-level functions
%   (wfdbx.isigopen, wfdbx.annopen, ...) are closed.
%
%   Example:
%       wfdbx.write_annotations('100s', 'test', [100 460], ...
%           'symbols', {'N', 'V'});
%       ann = wfdbx.read_annotations('100s', 'test');
%       wfdbx.write_annotations('100s', 'test', [100 460], ...
%           'symbols', 'NV', 'dir', 'out');     % creates out/100s.test
%
%   See also wfdbx.read_annotations, wfdbx.annopen, wfdbx.putann.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, after a code review, Oct 2026): the
% writers take a 'dir' option (the files are created in that directory,
% and the record opens from there under its plain name), and an
% out-of-order file is rearranged in this process (see wfdbx.oannclose).
% Design decision (Reza Sameni, Oct 2026): the 'sort' option decides, for
% one call, whether an out-of-order file is rearranged, instead of the
% process-wide WFDBANNSORT environment variable.
% The original behavior remains available with --legacy (see
% docs/DIVERGENCES.md).
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

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
