function write_annotations(record, annotator, samples, varargin)
%WRITE_ANNOTATIONS Write an annotation file from arrays.
%   wfdbx.write_annotations(RECORD, ANNOTATOR, SAMPLES, NAME, VALUE, ...)
%   writes the annotation file RECORD.ANNOTATOR (in the current
%   directory), as wrann does, with one annotation at each of the sample
%   numbers SAMPLES.  The other fields are given as name-value pairs:
%
%     'symbols'   cell of mnemonics ('N', 'V', ...; wfdbx.strann), or a
%                 char vector of one-character mnemonics ('NNVN'), or
%     'codes'     annotation codes (one of the two is required)
%     'subtypes', 'chans', 'nums'   values (scalars apply to all; default 0)
%     'aux'       cell of auxiliary strings (char, [] for none; at most
%                 255 bytes are written), or one char vector for all
%     'fs'        time resolution to record in the file (ticks per second)
%     'legacy'    true to run with the library's legacy mode
%                 (wfdbx.wfdbx_set_legacy) on during the call (default
%                 false; writing annotations does not depend on it)
%
%   SAMPLES and the other values may be row or column vectors.
%
%   Annotations that are not in canonical order are sorted when the file
%   is closed (as by the C library).  An error is thrown if the file
%   cannot be created.
%
%   The function calls wfdbx.wfdbquit before and after its work, so any
%   signals or annotators opened with the low-level functions
%   (wfdbx.isigopen, wfdbx.annopen, ...) are closed.
%
%   Example:
%       wfdbx.write_annotations('100s', 'test', [100 460], ...
%           'symbols', {'N', 'V'});
%       ann = wfdbx.read_annotations('100s', 'test');
%
%   See also wfdbx.read_annotations, wfdbx.annopen, wfdbx.putann.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

record = wfdbx.internal.strarg(record);
annotator = wfdbx.internal.strarg(annotator);
opt = struct('symbols', [], 'codes', [], 'subtypes', 0, 'chans', 0, ...
    'nums', 0, 'aux', [], 'fs', [], 'legacy', false);
opt = wfdbx.internal.hl_options(opt, varargin, 'write_annotations');
legacy = wfdbx.internal.hl_legacy(opt.legacy, 'write_annotations'); %#ok<NASGU>
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
    codes = zeros(1, n);
    for k = 1:n
        codes(k) = wfdbx.strann(opt.symbols{k});
    end
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
    for k = 1:n
        s = opt.aux{k};
        if ischar(s)
            b = double(s(1:min(end, 255)));
            A.aux{k} = uint8([numel(b), b]);
        end
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
wfdbx.wfdbquit();
if ~isempty(opt.fs)
    wfdbx.setafreq(0);
end
end

function v = per(v, n)
v = reshape(double(v), 1, []);
if numel(v) == 1
    v = repmat(v, 1, n);
end
end
