function test_metadata()
%TEST_METADATA Tests of the header metadata functions (WFDB-x).
%   Tests wfdbx.read_metadata, get_metadata, set_metadata, remove_metadata
%   and update_metadata, the metadata of wfdbx.read_header and the
%   'metadata' option of wfdbx.write_record.  The shared cases
%   (tests/metadata/cases.tsv, with the headers expected after each change
%   in tests/metadata/expected) are run by every implementation of WFDB-x,
%   which must give the same results and write byte-identical headers.  A
%   URL is served by a local HTTP server (127.0.0.1, a Python script
%   started here; that test is skipped if python3 cannot be run): no test
%   contacts another host.  The Python counterpart is
%   python/tests/test_metadata.py.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It tests WFDB-x; it has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU Lesser General Public License as published by
% the Free Software Foundation, either version 2.1 of the License, or (at
% your option) any later version. See LICENSE.

here = fileparts(mfilename('fullpath'));
meta = fullfile(fileparts(fileparts(here)), 'tests', 'metadata');
if ~isfolder(meta)
    return;     % (the cases of the WFDB-x repository are not available)
end
old = pwd();
d = tempname();
mkdir(d);
cd(d);
d = pwd();          % (the real path)
was_on = warning('query', 'wfdbx:duplicate_key');
warning('on', 'wfdbx:duplicate_key');
cleanup = onCleanup(@() restore(old, d, was_on)); %#ok<NASGU>
defaults();

shared_cases(meta, d);
read_header_and_write_record(d);
write_record_metadata_errors(d);
info_file_ignored(meta, d);
input_dir_and_dir(meta, d);
missing_and_invalid(meta, d);
permissions_kept(meta, d);
srv = start_server(d, meta);
if ~isempty(srv)
    c = onCleanup(@() stop_server(srv)); %#ok<NASGU>
    url_header(meta, srv);
end
end

% ---------------------------------------------------------------------------

function restore(old, d, was_on)
wfdbx.wfdbquit();
defaults();
wfdbx.wfdbverbose();
warning(was_on.state, 'wfdbx:duplicate_key');
cd(old);
if isfolder(d)
    rmdir(d, 's');
end
end

function defaults()
% The settings at their defaults (no input or output directory, network
% off), as in a new process without the environment variables.
st = wfdbx.internal.io_state();
st.input_dir = [];
st.env_input_dir = [];
st.input_dir_init = true;
st.wfdb_warned = true;
st.setwfdb_called = false;
st.setwfdb_input_dir = [];
st.output_dir = [];
st.env_output_dir = [];
st.output_dir_init = true;
st.network = 0;
st.env_network = 0;
st.network_warned = false;
st.fetched_urls = cell(1, 0);
st.fetched_data = cell(1, 0);
end

function d = fresh(base)
% a new empty directory under BASE, made the current directory
d = tempname(base);
mkdir(d);
cd(d);
d = pwd();
end

function b = readfile(name)
fid = fopen(name, 'rb');
if fid < 0
    error('wfdbx:test', 'cannot open %s', name);
end
b = char(fread(fid, Inf, 'uint8=>uint8')');
fclose(fid);
end

function putfile(name, s)
fid = fopen(name, 'wb');
fwrite(fid, uint8(s));
fclose(fid);
end

function rec = copy_header(meta, name, d)
% Copy tests/metadata/headers/NAME.hea into directory D; returns the
% record name (D/NAME).
putfile(fullfile(d, [name '.hea']), readfile(fullfile(meta, 'headers', ...
    [name '.hea'])));
rec = [d '/' name];
end

function L = listing(d)
% the names of the files in directory D (hidden files included)
L = dir(d);
L = sort({L.name});
L = L(~strcmp(L, '.') & ~strcmp(L, '..'));
end

function assert_true(c, what)
if ~c
    error('wfdbx:test', '%s: failed', what);
end
end

function kind = error_kind(f)
% 'argument' or 'file' for the error f() throws, '' if none
kind = '';
try
    f();
catch err
    kind = classify(err);
end
wfdbx.wfdbquit();
end

function kind = classify(err)
% the kind of error of a metadata function: its identifier is
% 'wfdbx:FUNCTION' for an invalid argument, 'wfdbx:FUNCTION:file' for a
% header that cannot be read or written; any other error is rethrown
id = err.identifier;
if numel(id) > 5 && strcmp(id(end-4:end), ':file')
    kind = 'file';
elseif strncmp(id, 'wfdbx:', 6) && sum(id == ':') == 1
    kind = 'argument';
else
    rethrow(err);
end
end

function assert_kind(f, kind, what)
assert_eq(error_kind(f), kind, what);
end

% ---------------------------------------------------------------------------
% The shared cases

function C = read_cases(meta)
% The cases of cases.tsv, as a structure array (see tests/metadata/README.md)
text = readfile(fullfile(meta, 'cases.tsv'));
lines = regexp(text, '\n', 'split');
C = struct('name', {}, 'header', {}, 'op', {}, 'key', {}, 'value', {}, ...
    'changes', {}, 'error', {}, 'warnings', {}, 'result', {}, 'output', {});
for k = 1:numel(lines)
    ln = lines{k};
    if isempty(ln) || ln(1) == '#'
        continue;
    end
    f = regexp(ln, '\t', 'split');
    if numel(f) ~= 10
        error('wfdbx:test', 'cases.tsv: bad line %s', ln);
    end
    c.name = f{1};
    c.header = f{2};
    c.op = f{3};
    c.key = str(f{4});
    c.value = str(f{5});
    c.changes = pairs(f{6});
    c.error = f{7};
    c.warnings = str2double(f{8});
    c.result = f{9};
    c.output = f{10};
    C(end + 1) = c; %#ok<AGROW>
end
end

function s = str(f)
% a string of cases.tsv: 'x' and its bytes in hexadecimal; '-' is none ([])
if strcmp(f, '-')
    s = [];
    return;
end
s = char(reshape(sscanf(f(2:end), '%2x'), 1, []));
if isempty(s)
    s = '';
end
end

function P = pairs(f)
% a list of KEY:VALUE pairs of cases.tsv, as an N-by-2 cell array
P = cell(0, 2);
if isempty(f)
    return;
end
items = regexp(f, ',', 'split');
for k = 1:numel(items)
    kv = regexp(items{k}, ':', 'split');
    P(end + 1, :) = {str(kv{1}), str(kv{2})}; %#ok<AGROW>
end
end

function shared_cases(meta, base)
C = read_cases(meta);
assert_eq(numel(C), 49, 'number of shared cases');
for k = 1:numel(C)
    c = C(k);
    d = fresh(base);
    rec = copy_header(meta, c.header, d);
    before = readfile([rec '.hea']);
    [got, kind, txt] = run_case(c, rec);
    what = ['case ' c.name];
    if strcmp(c.error, '-')
        assert_eq(kind, '', [what ': no error']);
        switch c.op
            case 'read'
                assert_eq(got, pairs(c.result), [what ': entries']);
                assert_true(iscell(got) && size(got, 2) == 2, [what ': N-by-2']);
            case 'get'
                expected = str(c.result);
                assert_eq(ischar(got), ischar(expected), [what ': value or []']);
                assert_eq(got, expected, [what ': value']);
            case 'remove'
                assert_eq(got, str2double(c.result), [what ': count']);
        end
    else
        assert_eq(kind, c.error, [what ': error']);
    end
    n = numel(strfind(txt, 'has more than one entry for key'));
    assert_eq(n, c.warnings, [what ': warnings']);
    after = readfile([rec '.hea']);
    if strcmp(c.output, '-')
        assert_eq(after, before, [what ': header unchanged']);
    else
        assert_eq(after, readfile(fullfile(meta, c.output)), [what ': header']);
    end
    % no temporary file is left behind
    assert_eq(listing(d), {[c.header '.hea']}, [what ': files']);
    cd(base);
    rmdir(d, 's');
end
end

function [got, kind, txt] = run_case(c, rec)
% Run case C on record REC: the result, the kind of error ('' if none)
% and the text of the warnings.
got = [];
kind = '';
err = [];
txt = evalc('try; got = op(c, rec); catch err; end');
if ~isempty(err)
    kind = classify(err);
end
end

function got = op(c, rec)
got = [];
switch c.op
    case 'read'
        got = wfdbx.read_metadata(rec);
    case 'get'
        got = wfdbx.get_metadata(rec, c.key);
    case 'set'
        wfdbx.set_metadata(rec, c.key, c.value);
    case 'remove'
        got = wfdbx.remove_metadata(rec, c.key);
    case 'update'
        wfdbx.update_metadata(rec, c.changes);
end
end

% ---------------------------------------------------------------------------

function read_header_and_write_record(base)
d = fresh(base);
x = zeros(10, 1);
wfdbx.write_record('w', x, 100, 'gains', 200, 'adcres', 12, 'units', 'mV', ...
    'comments', {'a comment', 'Site: B'}, ...
    'metadata', {'Age', ' 63 '; 'Notes', ''});
data = readfile('w.hea');
tail = sprintf('#a comment\r\n#Site: B\r\n# Age: 63\r\n# Notes:\r\n');
assert_eq(data(end-numel(tail)+1:end), tail, 'write_record metadata lines');
h = wfdbx.read_header('w');
assert_eq(h.metadata, {'Site', 'B'; 'Age', '63'; 'Notes', ''}, ...
    'read_header metadata');
assert_eq(size(h.metadata), [3 2], 'read_header metadata N-by-2');
assert_eq(h.comments, {'a comment'; 'Site: B'; ' Age: 63'; ' Notes:'}, ...
    'read_header comments');
wfdbx.write_record('v', x, 100, 'gains', 200, 'adcres', 12, 'units', 'mV', ...
    'metadata', {'Dx', '426783006'});
assert_eq(wfdbx.read_metadata('v'), {'Dx', '426783006'}, ...
    'write_record metadata without comments');
% no metadata: an empty N-by-2 cell array
wfdbx.write_record('u', x, 100, 'gains', 200, 'adcres', 12, 'units', 'mV');
h = wfdbx.read_header('u');
assert_eq(size(h.metadata), [0 2], 'read_header without metadata');
assert_eq(size(wfdbx.read_metadata('u')), [0 2], 'read_metadata: none');
% an EDF record (no .hea file): no metadata, and no error
data = fullfile(fileparts(fileparts(fileparts(mfilename('fullpath')))), ...
    'tests', 'data');
h = wfdbx.read_header(fullfile(data, 'fmt16.edf'));
assert_eq(size(h.metadata), [0 2], 'read_header of an EDF record');
assert_true(h.nsig > 0, 'read_header of an EDF record: signals');
cd(base);
rmdir(d, 's');
end

function write_record_metadata_errors(base)
d = fresh(base);
x = zeros(10, 1);
kw = {'gains', 200, 'adcres', 12, 'units', 'mV'};
bad = {{'a:b', '1'}, {'Age', sprintf('1\n2')}, {'Age', '1'; 'AGE', '2'}, ...
    {'Age', []}, {'', 'x'}, {'Age'}, struct('Age', '1'), {'Age', 63}};
for k = 1:numel(bad)
    try
        wfdbx.write_record('e', x, 100, kw{:}, 'metadata', bad{k});
        error('wfdbx:test', 'write_record metadata %d: no error', k);
    catch err
        assert_eq(err.identifier, 'wfdbx:write_record', ...
            sprintf('write_record metadata %d: identifier', k));
    end
end
try
    wfdbx.write_record('e', x, 100, kw{:}, 'comments', {'age: 1'}, ...
        'metadata', {'Age', '2'});
    error('wfdbx:test', 'write_record metadata in comments: no error');
catch err
    assert_eq(err.message, 'metadata key ''age'' is also given in comments', ...
        'write_record metadata in comments');
end
assert_eq(listing(d), cell(1, 0), 'nothing was written');
cd(base);
rmdir(d, 's');
end

function info_file_ignored(meta, base)
d = fresh(base);
rec = copy_header(meta, 'lf', d);
putfile([rec '.info'], sprintf('#Age: 1\n'));
assert_eq(size(wfdbx.read_metadata(rec)), [0 2], '.info ignored');
cd(base);
rmdir(d, 's');
end

function input_dir_and_dir(meta, base)
d = fresh(base);
mkdir('in');
mkdir('out');
copy_header(meta, 'basic', 'in');
original = readfile('in/basic.hea');
assert_eq(wfdbx.get_metadata('basic', 'Sex', 'input_dir', 'in'), 'F', ...
    'get_metadata input_dir');
assert_eq(wfdbx.wfdbx_get_input_dir(), [], 'input_dir restored');
wfdbx.wfdbx_set_input_dir('in');
assert_eq(wfdbx.get_metadata('basic.hea', 'sex'), 'F', 'name with .hea');
wfdbx.set_metadata('basic', 'Age', '64', 'dir', 'out');
assert_eq(readfile('in/basic.hea'), original, 'dir: the original unchanged');
assert_eq(wfdbx.get_metadata('out/basic', 'Age', 'input_dir', ''), '64', ...
    'dir: the changed header');
% an unchanged header is still written to dir
assert_eq(wfdbx.remove_metadata('basic', 'Weight', 'dir', 'out'), 0, ...
    'remove_metadata of a missing key');
assert_eq(readfile('out/basic.hea'), original, 'dir: unchanged header written');
assert_kind(@() wfdbx.set_metadata('basic', 'Age', '1', 'dir', 'none'), ...
    'file', 'dir that does not exist');
assert_kind(@() wfdbx.set_metadata('basic', 'Age', '1', 'dir', 3), ...
    'argument', 'dir not a string');
wfdbx.update_metadata('basic', {'Age', '70'; 'Sex', []}, 'dir', 'out');
assert_eq(wfdbx.read_metadata('out/basic', 'input_dir', ''), ...
    {'Age', '70'; 'Dx', '164889003, 59118001'; 'Notes', ''; ...
    'Recorded by', 'Holter monitor, model X'}, 'update_metadata dir');
assert_eq(listing('out'), {'basic.hea'}, 'dir: no other file');
wfdbx.wfdbx_set_input_dir([]);
% the header is changed where it was read, not in the output directory
wfdbx.wfdbx_set_output_dir('out');
wfdbx.set_metadata('in/basic', 'Age', '65');
assert_eq(wfdbx.get_metadata('in/basic', 'Age'), '65', 'changed in place');
assert_eq(wfdbx.get_metadata('out/basic', 'Age'), '70', ...
    'output directory unchanged');
assert_eq(listing('in'), {'basic.hea'}, 'in place: no other file');
defaults();
cd(base);
rmdir(d, 's');
end

function missing_and_invalid(meta, base)
d = fresh(base);
assert_kind(@() wfdbx.read_metadata('none'), 'file', 'read a missing header');
assert_kind(@() wfdbx.set_metadata('none', 'Age', '1'), 'file', ...
    'set in a missing header');
assert_kind(@() wfdbx.get_metadata('none', 'Age'), 'file', 'get, missing');
assert_kind(@() wfdbx.remove_metadata('none', 'Age'), 'file', ...
    'remove, missing');
assert_kind(@() wfdbx.update_metadata('none', {'Age', '1'}), 'file', ...
    'update, missing');
assert_kind(@() wfdbx.read_metadata(''), 'argument', 'empty record name');
assert_kind(@() wfdbx.read_metadata([]), 'argument', 'record name []');
assert_kind(@() wfdbx.read_metadata('-'), 'argument', 'standard input');
assert_kind(@() wfdbx.set_metadata('-', 'Age', '1'), 'argument', ...
    'set: standard input');
copy_header(meta, 'basic', d);
original = readfile('basic.hea');
assert_kind(@() wfdbx.set_metadata('basic', 'Age', 63), 'argument', ...
    'a value that is not a string');
assert_kind(@() wfdbx.set_metadata('basic', 63, '1'), 'argument', ...
    'a key that is not a string');
assert_kind(@() wfdbx.set_metadata('basic', 'Age'), 'argument', ...
    'set_metadata without a value');
assert_kind(@() wfdbx.get_metadata('basic'), 'argument', ...
    'get_metadata without a key');
assert_kind(@() wfdbx.remove_metadata('basic'), 'argument', ...
    'remove_metadata without a key');
assert_kind(@() wfdbx.update_metadata('basic'), 'argument', ...
    'update_metadata without changes');
assert_kind(@() wfdbx.update_metadata('basic', {'Age'}), 'argument', ...
    'changes not N-by-2');
assert_kind(@() wfdbx.update_metadata('basic', struct('Age', '1')), ...
    'argument', 'changes as a structure');
assert_kind(@() wfdbx.read_metadata('basic', 'nosuch', 1), 'argument', ...
    'unknown option');
assert_kind(@() wfdbx.read_metadata('basic', 'input_dir'), 'argument', ...
    'option without a value');
assert_kind(@() wfdbx.read_metadata('basic', 'dir', 'x'), 'argument', ...
    'read_metadata has no dir option');
assert_kind(@() wfdbx.get_metadata('basic', 'Age', 'network', 'yes'), ...
    'argument', 'network not true or false');
if ~wfdbx.internal.is_octave()
    % (in Octave, a char array holds bytes: no character is above 255)
    assert_kind(@() wfdbx.set_metadata('basic', 'Name', char(256)), ...
        'argument', 'a character that is not Latin-1');
end
assert_eq(readfile('basic.hea'), original, 'unchanged after the errors');
% bytes (uint8), as given
wfdbx.set_metadata('basic', uint8('Name'), uint8([90 195 188 114 105 99 104]));
assert_eq(wfdbx.get_metadata('basic', 'Name'), char([90 195 188 114 105 99 104]), ...
    'bytes');
if exist('string', 'builtin') || exist('string', 'class')
    % MATLAB strings (none in Octave)
    assert_eq(wfdbx.get_metadata(string('basic'), string('Sex')), 'F', 'strings');
end
putfile('norec.hea', sprintf('# only a comment\n'));
assert_eq(size(wfdbx.read_metadata('norec')), [0 2], 'no record line: none');
assert_kind(@() wfdbx.set_metadata('norec', 'Age', '1'), 'argument', ...
    'no record line: set');
assert_eq(readfile('norec.hea'), sprintf('# only a comment\n'), ...
    'no record line: unchanged');
assert_eq(listing(d), {'basic.hea', 'norec.hea'}, 'no other file');
cd(base);
rmdir(d, 's');
end

function permissions_kept(meta, base)
if ispc()
    return;
end
d = fresh(base);
rec = copy_header(meta, 'basic', d);
q = @wfdbx.internal.shell_quote;
[s, ~] = system(['chmod 640 ' q([rec '.hea'])]);
if s ~= 0
    cd(base);
    rmdir(d, 's');
    return;
end
assert_eq(mode_of([rec '.hea']), 416, 'mode set (0640)');
wfdbx.set_metadata(rec, 'Age', '64');
assert_eq(wfdbx.get_metadata(rec, 'Age'), '64', 'changed');
assert_eq(mode_of([rec '.hea']), 416, 'permissions kept (0640)');
assert_eq(listing(d), {'basic.hea'}, 'permissions: no other file');
cd(base);
rmdir(d, 's');
end

function m = mode_of(name)
% the permission bits of file NAME
if wfdbx.internal.is_octave()
    info = stat(name);
    m = mod(info.mode, 512);
else
    [~, a] = fileattrib(name);
    m = 256 * a.UserRead + 128 * a.UserWrite + 64 * a.UserExecute + ...
        32 * a.GroupRead + 16 * a.GroupWrite + 8 * a.GroupExecute + ...
        4 * a.OtherRead + 2 * a.OtherWrite + a.OtherExecute;
end
end

% ---------------------------------------------------------------------------
% A URL (a local server)

function srv = start_server(d, meta)
% A local HTTP server (127.0.0.1) serving a directory of D that holds the
% header basic.hea; [] if python3 cannot be run.
srv = [];
if ispc()
    return;
end
srv.dir = fullfile(d, 'www');
mkdir(srv.dir);
copy_header(meta, 'basic', srv.dir);
script = fullfile(d, 'srv.py');
putfile(script, sprintf(['import functools, http.server, os, sys\n' ...
    'd, info = sys.argv[1:3]\n' ...
    'class H(http.server.SimpleHTTPRequestHandler):\n' ...
    '    def log_message(self, *a): pass\n' ...
    's = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ' ...
    'functools.partial(H, directory=d))\n' ...
    'open(info + ".tmp", "w").write("%%d %%d" %% (s.server_address[1], os.getpid()))\n' ...
    'os.rename(info + ".tmp", info)\n' ...
    's.serve_forever()\n']));
info = fullfile(d, 'srv.info');
q = @wfdbx.internal.shell_quote;
[s, ~] = system(['python3 ' q(script) ' ' q(srv.dir) ' ' q(info) ...
    ' </dev/null >/dev/null 2>&1 &']);
t0 = tic();
while s == 0 && ~isfile(info) && toc(t0) < 20
    pause(0.1);
end
if ~isfile(info)
    srv = [];
    return;
end
v = sscanf(readfile(info), '%d');
srv.url = sprintf('http://127.0.0.1:%d/', v(1));
srv.pid = v(2);
setenv('NO_PROXY', '127.0.0.1,localhost');
setenv('no_proxy', '127.0.0.1,localhost');
end

function stop_server(srv)
system(sprintf('kill %d', srv.pid));
end

function url_header(meta, srv)
defaults();
base = pwd();
d = fresh(base);
url = [srv.url 'basic'];
wfdbx.wfdbquiet();
assert_kind(@() wfdbx.read_metadata(url), 'file', 'URL: network off');
wfdbx.wfdbverbose();
assert_eq(wfdbx.get_metadata(url, 'Age', 'network', true), '63', ...
    'URL: get_metadata');
assert_eq(wfdbx.wfdbx_get_network(), 0, 'URL: network restored');
assert_kind(@() wfdbx.set_metadata(url, 'Age', '1', 'network', true), ...
    'argument', 'URL: no change without dir');
mkdir('copy');
wfdbx.set_metadata(url, 'Age', '1', 'network', true, 'dir', 'copy');
assert_eq(wfdbx.get_metadata('copy/basic', 'Age'), '1', 'URL: copy changed');
assert_eq(listing('copy'), {'basic.hea'}, 'URL: no other file');
assert_eq(readfile(fullfile(srv.dir, 'basic.hea')), ...
    readfile(fullfile(meta, 'headers', 'basic.hea')), 'URL: served unchanged');
h = wfdbx.read_header(url, 'network', true);
assert_eq(h.metadata{1, 2}, '63', 'URL: read_header metadata');
defaults();
cd(base);
rmdir(d, 's');
end
