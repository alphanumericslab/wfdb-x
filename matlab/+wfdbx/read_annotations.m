function ann = read_annotations(record, annotator, varargin)
%READ_ANNOTATIONS Read an annotation file into arrays.
%   ANN = wfdbx.read_annotations(RECORD, ANNOTATOR) reads all annotations
%   of annotator ANNOTATOR (e.g. 'atr') of record RECORD, as rdann does,
%   and returns a structure with the fields
%
%     record, annotator   the arguments
%     samples   N-by-1 annotation times (sample numbers)
%     codes     N-by-1 annotation codes (wfdbx.NORMAL(), ...)
%     symbols   N-by-1 cell of mnemonics ('N', 'V', '+', ...; wfdbx.annstr)
%     subtypes, chans, nums   N-by-1, the other fields of the annotations
%     aux       N-by-1 cell of auxiliary strings (char, up to the first
%               null byte), [] where there is none
%     fs        time resolution of the times (ticks per second; 0 if no
%               sampling frequency is known)
%
%   Options (name-value pairs):
%     'sampfrom'  read the annotations at or after this time (sample
%                 number, or a time string for wfdbx.strtim; default 0)
%     'sampto'    read the annotations before this time (default: all)
%     'fs'        sampling frequency (Hz, > 0), used if the record has no
%                 header or its header does not specify one (as the -F
%                 option of rdann); default: none
%     'legacy'    true to behave as the original package (default false):
%                 the library's legacy mode (wfdbx.wfdbx_set_legacy) is on
%                 during the call, and a record without a header (or a
%                 header without a sampling frequency) means 250 Hz.  For
%                 compatibility only: the values it assumes are exactly
%                 the silent defaults wfdb-x removed, so results produced
%                 with it carry the same risks.
%   (wfdbx.read_annotations(RECORD, ANNOTATOR, SAMPFROM, SAMPTO) is also
%   accepted, optionally followed by name-value pairs.)
%
%   An error is thrown if the annotation file cannot be read, or if a
%   time string needs the sampling frequency and none is known (wfdb-x
%   never assumes one; C assumed 250 Hz: see docs/DIVERGENCES.md).
%
%   The function calls wfdbx.wfdbquit before and after its work, so any
%   signals or annotators opened with the low-level functions
%   (wfdbx.isigopen, wfdbx.annopen, ...) are closed.
%
%   Example:
%       ann = wfdbx.read_annotations('100s', 'atr', 'sampto', '0:30');
%       ann.symbols(1:3), ann.samples(1:3)
%       beats = ann.samples(wfdbx.isqrs(ann.codes) == 1);   % QRS times
%       rr = diff(beats) / ann.fs;                          % RR (s)
%
%   See also wfdbx.write_annotations, wfdbx.annopen, wfdbx.getann.

% MATLAB/Octave implementation part of wfdb-x, Reza Sameni, Oct 2026.
% Design decision (Reza Sameni, Oct 2026): no built-in sampling frequency,
% gain, ADC resolution or units. Values that the record or the user does
% not give are never assumed (the original package assumed 250 Hz,
% 200 adu/mV, 12 bits and millivolts), because a silently assumed value
% corrupts every result derived from it. See docs/DIVERGENCES.md.
% The original behavior remains available with --legacy (see
% docs/DIVERGENCES.md).
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

record = wfdbx.internal.strarg(record);
annotator = wfdbx.internal.strarg(annotator);
varargin = wfdbx.internal.strarg(varargin);
opt = struct('sampfrom', 0, 'sampto', [], 'fs', [], 'legacy', false);
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
    wfdbx.getann(0);                    % the call that fails (error message)
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
for k = find(~cellfun('isempty', A.aux))
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

