function test_check()
%TEST_CHECK Tests of wfdbx.check_record.
%   The corpus of python/tests/check_corpus.py (one broken record for each
%   issue code, a clean record, records of tests/data, annotation files) is
%   generated in a temporary folder by running that script with python3
%   (with NumPy, and the Python package of python/src); the report of each
%   case must be the lines of the corpus' expected.txt (the output of the
%   Python reference).  If python3 cannot run the script, that comparison
%   is skipped with a note; the other tests run.

% This file is part of wfdb-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It tests wfdb-x; it has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

here = fileparts(mfilename('fullpath'));
repo = fileparts(fileparts(here));
data = fullfile(repo, 'tests', 'data');
d = tempname();
mkdir(d);
cleanup = onCleanup(@() rmdir(d, 's')); %#ok<NASGU>
wfdbx.wfdbquit();

% the sample record: its header gives no units, which is all that is
% reported
r = wfdbx.check_record('100s', 'annotators', {'atr'}, 'input_dir', data);
assert_eq(r.ok, true, '100s ok');
assert_eq(r.record, '100s', 'record');
assert_eq(r.lines, {'warning: signal 0: the units are not specified'; ...
    'warning: signal 1: the units are not specified'}, '100s lines');
assert_eq({r.issues.code}, {'units_missing', 'units_missing'}, 'codes');
assert_eq(r.issues(2).where, 'signal 1', 'where');
assert_eq(r.issues(2).severity, 'warning', 'severity');
assert_eq(r.issues(2).message, 'the units are not specified', 'message');
% one annotator as a char vector; a missing annotation file
r = wfdbx.check_record('100s', 'annotators', 'nofile', 'input_dir', data);
assert_eq(r.ok, false, 'error: not ok');
assert_eq(r.lines{end}, ['error: annotator nofile: the annotation file ' ...
    'cannot be read'], 'one annotator');
% displayed without an output argument
out = evalc('wfdbx.check_record(''100s'', ''input_dir'', data)');
assert_eq(out, sprintf(['warning: signal 0: the units are not specified\n' ...
    'warning: signal 1: the units are not specified\n']), 'display');

% invalid arguments
bad = {{[]}, {''}, {5}, {'100s', 'annotators', {1}}, ...
    {'100s', 'annotators', 3}, {'100s', 'nosuchoption', 1}};
for k = 1:numel(bad)
    failed = false;
    try
        wfdbx.check_record(bad{k}{:});
    catch err
        failed = strcmp(err.identifier, 'wfdbx:check_record');
    end
    assert_eq(failed, true, sprintf('invalid arguments %d', k));
end

% settings restored: legacy mode (off during the call), the library's
% messages, the input directory
io = wfdbx.internal.io_state();
prev_dir = wfdbx.wfdbx_get_input_dir();
copyfile(fullfile(data, '100s.*'), d);
fid = fopen(fullfile(d, 'nofs.hea'), 'wb');
fwrite(fid, uint8(sprintf('nofs 1\r\nnofs.dat 16 200/mV 16 0 0 0 0 ECG\r\n')));
fclose(fid);
fid = fopen(fullfile(d, 'nofs.dat'), 'wb');
fwrite(fid, zeros(1, 20), 'int16');
fclose(fid);
previous = wfdbx.wfdbx_set_legacy(1);
r = wfdbx.check_record('nofs', 'annotators', {'nofile'}, 'input_dir', d);
assert_eq(wfdbx.wfdbx_get_legacy(), 1, 'legacy mode restored');
wfdbx.wfdbx_set_legacy(previous);
% (legacy mode would assume 250 Hz: the frequency is reported missing)
assert_eq(r.issues(1).code, 'fs_missing', 'normal mode during the call');
assert_eq(r.lines{end - 1}, 'info: the signal files hold 20 frames', 'nofs');
assert_eq(io.error_print, true, 'messages printed again');
assert_eq(wfdbx.wfdbx_get_input_dir(), prev_dir, 'input directory restored');
wfdbx.wfdbquiet();
r = wfdbx.check_record('nofs', 'input_dir', d);
assert_eq(io.error_print, false, 'quiet restored');
wfdbx.wfdbverbose();

% codes defined by an annotation file's modification labels have a
% mnemonic (no warning); the definitions do not outlive the check
st = wfdbx.internal.ann_state();
wfdbx.setannstr(42, 'QQ');
wfdbx.setanndesc(42, 'my beat');
wfdbx.write_annotations('100s', 'lab', [10 20 30], 'codes', [42 1 43], ...
    'dir', d);
wfdbx.setannstr(-42, '[42]');
wfdbx.setanndesc(-42, []);
st.modified(43) = 0;
r = wfdbx.check_record('100s', 'annotators', {'lab'}, 'input_dir', d);
assert_eq(r.lines, {'warning: signal 0: the units are not specified'; ...
    'warning: signal 1: the units are not specified'; ...
    ['warning: annotator lab: 1 annotation uses a code without a ' ...
    'mnemonic: at sample 30 (code 43)']}, 'modification labels');
assert_eq(wfdbx.annstr(42), '[42]', 'tables restored');

% the record name of the header: its first field up to the first '/'
% after its first character
fid = fopen(fullfile(d, 'root.hea'), 'wb');
fwrite(fid, uint8(sprintf('/a/b 0\r\n')));
fclose(fid);
r = wfdbx.check_record('root', 'input_dir', d);
assert_eq(r.lines, {'error: the header cannot be read'; ['warning: the ' ...
    'header names the record "/a", but its file name is "root"']}, '/a/b');

% the corpus
corpus = fullfile(d, 'corpus');
gen = fullfile(repo, 'python', 'tests', 'check_corpus.py');
q = @wfdbx.internal.shell_quote;
cmd = sprintf('PYTHONPATH=%s python3 %s %s %s', ...
    q(fullfile(repo, 'python', 'src')), q(gen), q(corpus), q(data));
[status, msg] = system(cmd);
if ispc() || status ~= 0 || ~isfile(fullfile(corpus, 'expected.txt'))
    fprintf('     (test_check: corpus comparison skipped: %s)\n', ...
        strtrim(msg));
    return;
end
expected = fileread(fullfile(corpus, 'expected.txt'));
cases = regexp(fileread(fullfile(corpus, 'cases.txt')), '\n', 'split');
got = cell(1, 0);
codes = {};
for k = 1:numel(cases)
    if isempty(cases{k})
        continue;
    end
    f = regexp(cases{k}, ' ', 'split');
    r = wfdbx.check_record(f{1}, 'annotators', f(2:end), 'input_dir', corpus);
    got = [got, {['== ' cases{k}]}, reshape(r.lines, 1, [])]; %#ok<AGROW>
    assert_eq(r.ok, ~any(strcmp({r.issues.severity}, 'error')), 'ok');
    codes = [codes, {r.issues.code}]; %#ok<AGROW>
end
got = sprintf('%s\n', got{:});
if ~strcmp(got, expected)
    a = regexp(got, '\n', 'split');
    b = regexp(expected, '\n', 'split');
    k = find(~strcmp(a(1:min(end, numel(b))), b(1:min(end, numel(a)))), 1);
    if isempty(k)
        k = min(numel(a), numel(b)) + 1;
        error('corpus: %d lines, expected %d', numel(a), numel(b));
    end
    error('corpus line %d: "%s", expected "%s"', k, a{k}, b{k});
end
% every issue code is produced by the corpus (except file_large: a file of
% 2 GiB)
all_codes = {'header_unreadable', 'no_signals', 'fs_missing', ...
    'length_missing', 'header_line_long', 'header_not_ascii', ...
    'header_name', 'length_large', 'desc_missing', 'desc_number', ...
    'desc_control', 'format_difference', 'gain_missing', 'gain_negative', ...
    'units_missing', 'units_control', 'adcres_missing', ...
    'adcres_too_large', 'adc_range', 'filename', 'desc_duplicate', ...
    'file_unreadable', 'sample_range', 'invalid_samples', 'checksum', ...
    'length_short', 'length_long', 'length_unspecified_frames', ...
    'read_error', 'nested', 'segment_unreadable', 'segment_fs', ...
    'layout_missing_signal', 'layout_signals', 'layout_mismatch', ...
    'segment_lengths', 'annotator_name', 'annotations_unreadable', ...
    'annotations_truncated', 'annotations_order', 'annotation_code', ...
    'annotation_null', 'annotation_undefined', 'annotations_after_end'};
assert_eq(sort(unique(codes)), sort(all_codes), 'issue codes');
end
