function test_files()
%TEST_FILES Tests of finding files (wfdb-x): the input and output
%directories, network access, files named in headers, and legacy mode.
%   Remote files are served by a local HTTP server (127.0.0.1, a Python
%   script started here; these tests are skipped if python3 cannot be
%   run): no test contacts another host.  The tests of the environment
%   variables run Octave in a new process (Octave only).  The Python
%   counterpart is python/tests/test_files.py.

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
data = fullfile(fileparts(fileparts(here)), 'tests', 'data');
old = pwd();
d = tempname();
mkdir(d);
cd(d);
d = pwd();          % (the real path)
saved = save_settings(d);
cleanup = onCleanup(@() restore(old, d, saved)); %#ok<NASGU>
copyfile(fullfile(data, '*'), d);
mkdir('home');
setenv('HOME', fullfile(d, 'home'));
defaults();

settings_defaults_and_previous();
settings_survive_wfdbquit();
setwfdb_getwfdb();
names(d);
home_expansion();
output_names(d);
header_relative_files();
header_containment();
segments();
legacy_unchanged();
highlevel_local();
if wfdbx.internal.is_octave() && ~ispc()
    environment(here);
end
srv = start_server(d);
if isempty(srv)
    return;
end
c = onCleanup(@() stop_server(srv)); %#ok<NASGU>
network_off(srv);
network_on(srv);
network_subdirectories_and_errors(srv);
network_legacy(srv);
highlevel_network(srv);
end

% ---------------------------------------------------------------------------

function s = save_settings(d)
s.home = getenv('HOME');
s.env = cell(1, 4);
s.vars = {'WFDB', 'WFDBX_INPUT_DIR', 'WFDBX_OUTPUT_DIR', 'WFDBX_NETWORK'};
for k = 1:numel(s.vars)
    s.env{k} = getenv(s.vars{k});
end
s.d = d;
end

function restore(old, d, saved)
wfdbx.wfdbquit();
wfdbx.wfdbx_set_legacy(0);
defaults();
wfdbx.wfdbverbose();
setenv('HOME', saved.home);
cd(old);
if isfolder(d)
    rmdir(d, 's');
end
end

function defaults()
% The settings at their defaults (no input or output directory, network
% off, messages not yet printed), as in a new process without the
% environment variables.
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

function putfile(name, s)
p = fileparts(name);
if ~isempty(p) && ~isfolder(p)
    mkdir(p);
end
fid = fopen(name, 'wb');
fwrite(fid, uint8(s));
fclose(fid);
end

function make_sr(dir)
% Record sr (a copy of 100s) in directory DIR.
putfile(fullfile(dir, 'sr.hea'), sprintf(['sr 2 360 21600\n' ...
    'sr.dat 212 200 11 1024 995 21537 0 MLII\n' ...
    'sr.dat 212 200 11 1024 1011 -3962 0 V5\n']));
copyfile('100s.dat', fullfile(dir, 'sr.dat'));
copyfile('100s.atr', fullfile(dir, 'sr.atr'));
end

function assert_true(c, what)
if ~c
    error('wfdbx:test', '%s: failed', what);
end
end

function assert_error(f, what)
failed = false;
try
    f();
catch
    failed = true;
end
wfdbx.wfdbquit();
if ~failed
    error('wfdbx:test', '%s: no error thrown', what);
end
end

function r = net_off(url)
r = sprintf(['wfdb-x: network access is disabled; set WFDBX_NETWORK=1 ' ...
    'or call wfdbx_set_network(1) to open %s\n'], url);
end

% ---------------------------------------------------------------------------
% Settings

function settings_defaults_and_previous()
assert_eq(wfdbx.wfdbx_get_input_dir(), [], 'input dir default');
assert_eq(wfdbx.wfdbx_get_output_dir(), [], 'output dir default');
assert_eq(wfdbx.wfdbx_get_network(), 0, 'network default');
assert_eq(wfdbx.wfdbx_set_input_dir('a'), [], 'set input dir a');
assert_eq(wfdbx.wfdbx_set_input_dir('b'), 'a', 'set input dir b');
assert_eq(wfdbx.wfdbx_set_input_dir(''), 'b', 'set input dir ''''');
assert_eq(wfdbx.wfdbx_get_input_dir(), [], 'input dir reset');
assert_eq(wfdbx.wfdbx_set_output_dir('o'), [], 'set output dir');
assert_eq(wfdbx.wfdbx_set_output_dir([]), 'o', 'reset output dir');
assert_eq(wfdbx.wfdbx_set_network(1), 0, 'set network 1');
assert_eq(wfdbx.wfdbx_set_network(true), 1, 'set network true');
assert_eq(wfdbx.wfdbx_set_network(0), 1, 'set network 0');
assert_eq(wfdbx.wfdbx_set_network([]), 0, 'set network []');
assert_eq(wfdbx.wfdbx_set_network(-1), 0, 'set network -1');
assert_eq(wfdbx.wfdbx_get_network(), 0, 'network reset');
% an output directory URL is refused (the current value is returned)
wfdbx.wfdbx_set_output_dir('keep');
wfdbx.wfdbquiet();
assert_eq(wfdbx.wfdbx_set_output_dir('http://127.0.0.1:1/'), 'keep', ...
    'output dir URL refused');
wfdbx.wfdbverbose();
assert_eq(wfdbx.wfdberror(), sprintf(['wfdbx_set_output_dir: the output ' ...
    'directory must be a local directory\n']), 'output dir URL message');
assert_eq(wfdbx.wfdbx_get_output_dir(), 'keep', 'output dir unchanged');
wfdbx.wfdbx_set_output_dir([]);
end

function settings_survive_wfdbquit()
wfdbx.wfdbx_set_input_dir('a');
wfdbx.wfdbx_set_output_dir('b');
wfdbx.wfdbx_set_network(1);
wfdbx.wfdbquit();
assert_eq({wfdbx.wfdbx_get_input_dir(), wfdbx.wfdbx_get_output_dir(), ...
    wfdbx.wfdbx_get_network()}, {'a', 'b', 1}, 'settings after wfdbquit');
defaults();
end

function setwfdb_getwfdb()
wfdbx.wfdbquiet();
assert_eq(wfdbx.getwfdb(), '.', 'getwfdb default');
cases = {'sub', 'sub'; '  sub  ', 'sub'; ';sub;', 'sub'; ...
    'http://h:80/a', 'http://h:80/a'; '~/x', '~/x'; '@file', '@file'; ...
    '%r', '%r'; '', []; ';', []; [], []};
for k = 1:size(cases, 1)
    wfdbx.setwfdb('old');
    wfdbx.setwfdb(cases{k, 1});
    assert_eq(wfdbx.wfdbx_get_input_dir(), cases{k, 2}, ...
        sprintf('setwfdb ''%s''', cases{k, 1}));
    g = cases{k, 2};
    if isempty(g)
        g = '.';
    end
    assert_eq(wfdbx.getwfdb(), g, 'getwfdb after setwfdb');
end
wfdbx.setwfdb('keep');
bad = {'a b', 'a;b', 'a:b', '. http://h/x', 'http://h/x:/y'};
for k = 1:numel(bad)
    wfdbx.setwfdb(bad{k});
    assert_eq(wfdbx.wfdbx_get_input_dir(), 'keep', ['setwfdb ' bad{k}]);
    assert_true(strncmp(wfdbx.wfdberror(), ...
        'setwfdb: wfdb-x reads from a single', 35), ['message ' bad{k}]);
end
% resetwfdb restores the setting of the last setwfdb
wfdbx.wfdbx_set_input_dir('other');
wfdbx.resetwfdb();
assert_eq(wfdbx.wfdbx_get_input_dir(), 'keep', 'resetwfdb');
wfdbx.wfdbverbose();
defaults();
end

% ---------------------------------------------------------------------------
% Names

function names(cwd)
make_sr('sub');
make_sr(fullfile('home', 'hr'));
mkdir(fullfile('sub', 'deeper'));
f = @wfdbx.wfdbfile;
assert_eq(f('hea', '100s'), '100s.hea', 'relative name');
assert_eq(f('hea', 'sub/sr'), 'sub/sr.hea', 'subdirectory');
assert_eq(f('hea', 'sub/deeper/../sr'), 'sub/deeper/../sr.hea', '..');
assert_eq(f('hea', 'sub/../100s'), 'sub/../100s.hea', '.. (2)');
assert_eq(f('hea', [cwd '/sub/sr']), [cwd '/sub/sr.hea'], 'absolute name');
assert_eq(f('hea', '~/hr/sr'), [cwd '/home/hr/sr.hea'], '~ name');
assert_eq(f('hea', '~nosuchuser-wfdbx/hr/sr'), [], 'unknown user');
assert_eq(f('hea', 'sr'), [], 'nothing is searched');
wfdbx.wfdbx_set_input_dir('sub');
assert_eq(f('hea', 'sr'), 'sub/sr.hea', 'input dir');
assert_eq(f('hea', '100s'), [], 'input dir: nothing is searched');
assert_eq(f('hea', '../100s'), 'sub/../100s.hea', 'input dir and ..');
assert_eq(f('hea', [cwd '/100s']), [cwd '/100s.hea'], 'input dir, absolute');
wfdbx.wfdbx_set_input_dir('sub/');
assert_eq(f('hea', 'sr'), 'sub/sr.hea', 'one separator');
wfdbx.wfdbx_set_input_dir([cwd '/sub']);
assert_eq(f('hea', 'sr'), [cwd '/sub/sr.hea'], 'absolute input dir');
wfdbx.wfdbx_set_input_dir('~/hr');
assert_eq(f('hea', 'sr'), [cwd '/home/hr/sr.hea'], '~ input dir');
wfdbx.wfdbx_set_input_dir('~');
assert_eq(f('hea', 'hr/sr'), [cwd '/home/hr/sr.hea'], '~ input dir (2)');
% (the trailing '/' expansion and the 8.3 form are kept)
wfdbx.wfdbx_set_input_dir([]);
mkdir('sr');
copyfile(fullfile('sub', 'sr.hea'), fullfile('sr', 'sr.hea'));
assert_eq(f('hea', 'sr/'), 'sr/sr.hea', 'trailing /');
putfile(fullfile('sub', 'x.abc'), '');
assert_eq(f('abcdef', 'sub/x'), 'sub/x.abc', '8.3 form');
end

function home_expansion()
e = @wfdbx.internal.expand_home;
home = getenv('HOME');
setenv('HOME', '/h/');
assert_eq({e('~'), e('~/a'), e('a~'), e('x')}, {'/h', '/h/a', 'a~', 'x'}, ...
    'expand_home');
setenv('HOME', '/');
assert_eq({e('~/a'), e('~')}, {'/a', '/'}, 'expand_home /');
assert_eq(e('~nosuchuser-wfdbx/a'), '~nosuchuser-wfdbx/a', 'unknown user');
if wfdbx.internal.is_octave() && ~ispc()
    pw = getpwuid(getuid());
    h = pw.dir;
    while numel(h) > 1 && h(end) == '/'
        h = h(1:end-1);
    end
    assert_eq(e(['~' pw.name '/a']), [h '/a'], '~user');
end
setenv('HOME', home);
end

function output_names(cwd)
w = @(record, name) write_ann(record, name);
wfdbx.wfdbx_set_output_dir('out');
assert_true(w('r', 'x') == 0 && isfile('out/r.x'), 'output dir');
assert_true(w('sub/r', 'x') == 0 && isfile('out/sub/r.x'), 'output subdir');
assert_true(w('../up', 'x') == 0 && isfile('up.x'), 'output ..');
assert_true(w([cwd '/abs'], 'x') == 0 && isfile('abs.x'), 'output absolute');
assert_true(w('~/hm', 'x') == 0 && isfile('home/hm.x'), 'output ~');
wfdbx.wfdbx_set_output_dir('~/o2');
assert_true(w('r', 'x') == 0 && isfile('home/o2/r.x'), '~ output dir');
wfdbx.wfdbx_set_output_dir('out/');
assert_true(w('r', 'y') == 0 && isfile('out/r.y'), 'output one separator');
wfdbx.wfdbx_set_output_dir([]);
wfdbx.wfdbquiet();
assert_eq(w('http://127.0.0.1:1/r', 'x'), -4, 'a URL cannot be written');
wfdbx.wfdbverbose();
% legacy mode: any name in the output directory (as in round 1)
wfdbx.wfdbx_set_legacy(1);
wfdbx.wfdbx_set_output_dir('lout');
assert_eq(w([cwd '/labs'], 'x'), 0, 'legacy output dir');
assert_true(isfile(['lout' cwd '/labs.x']), 'legacy output dir: any name');
wfdbx.wfdbx_set_legacy(0);
wfdbx.wfdbx_set_output_dir([]);
end

function st = write_ann(record, name)
a = wfdbx.annotation();
a.anntyp = wfdbx.NORMAL();
st = wfdbx.annopen(record, wfdbx.anninfo(name, 1), 1);
if st == 0
    wfdbx.putann(0, a);
end
wfdbx.wfdbquit();
end

% ---------------------------------------------------------------------------
% Files named in headers

function header_relative_files()
putfile(fullfile('sub', 'dd.hea'), sprintf('dd 1 360 10\ndata/a.dat 16\n'));
copyfile('fmt16.dat', fullfile('sub', 'a.dat'));
mkdir(fullfile('sub', 'data'));
copyfile('fmt16.dat', fullfile('sub', 'data', 'a.dat'));
% sr.dat is next to sub/sr.hea (not in the current directory)
rec = wfdbx.read_record('sub/sr', 'sampto', 2);
assert_eq(rec.signals, [995 1011; 995 1011], 'signal file next to header');
assert_eq(rec.siginfo(1).fname, 'sr.dat', 'fname as in the header');
rec = wfdbx.read_record('sub/dd', 'sampto', 2);
assert_eq(rec.signals, [-7; 32], 'data/a.dat next to header');
% a header naming a file that is not next to it: nothing is searched
putfile(fullfile('sub', 'sib.hea'), sprintf('sib 1 360 10\n100s.dat 212\n'));
wfdbx.wfdbquiet();
assert_error(@() wfdbx.read_record('sub/sib'), 'sibling not searched');
% legacy mode: the WFDB path is searched (here, '.')
rec = wfdbx.read_record('sub/sib', 'legacy', true);
assert_true(~isempty(rec.signals), 'legacy: WFDB path searched');
wfdbx.wfdbverbose();
end

function header_containment()
bad = {'../100s.dat', '/100s.dat', '~/100s.dat', '~', ...
    'http://127.0.0.1:1/a.dat', 'https://127.0.0.1:1/a.dat', ...
    'data/../../100s.dat', '..', 'a/../b.dat'};
copyfile('fmt16.dat', fullfile('sub', 'ok.dat'));
wfdbx.wfdbquiet();
for k = 1:numel(bad)
    putfile(fullfile('sub', 'bad.hea'), ...
        sprintf('bad 2 360 10\n%s 16\nok.dat 16\n', bad{k}));
    assert_eq(wfdbx.isigopen('sub/bad', 2), 1, ['containment ' bad{k}]);
    assert_eq(wfdbx.wfdberror(), sprintf(['init: file %s named in the ' ...
        'header of record sub/bad is not in the header''s directory\n'], ...
        bad{k}), ['containment message ' bad{k}]);
    wfdbx.wfdbquit();
end
wfdbx.wfdbverbose();
% '..' within a name, './x'
mkdir(fullfile('sub', 'a..b'));
putfile(fullfile('sub', 'ok3.hea'), sprintf(['ok3 3 360 10\nx..y.dat 16\n' ...
    'a..b/c.dat 16\n./d.dat 16\n']));
n = {'x..y.dat', 'a..b/c.dat', 'd.dat'};
for k = 1:3
    copyfile('fmt16.dat', fullfile('sub', n{k}));
end
assert_eq(wfdbx.isigopen('sub/ok3', 3), 3, 'names that stay in the directory');
wfdbx.wfdbquit();
end

function segments()
mkdir(fullfile('sub', 'seg'));
putfile(fullfile('sub', 'seg', 'dd.hea'), ...
    sprintf('dd 1 360 10\nx.dat 16 200 12 0 0 0 0 s\n'));
copyfile('fmt16.dat', fullfile('sub', 'seg', 'x.dat'));
putfile(fullfile('sub', 'dd.hea'), ...
    sprintf('dd 1 360 10\ndata/a.dat 16 200 12 0 0 0 0 s\n'));
% a null segment (~), a layout header, and a segment in a subdirectory
putfile(fullfile('sub', 'ms.hea'), ...
    sprintf('ms/4 1 360 30\nms_0 0\n~ 10\ndd 10\nseg/dd 10\n'));
putfile(fullfile('sub', 'ms_0.hea'), ...
    sprintf('ms_0 1 360 0\n~ 0 200 12 0 0 0 0 s\n'));
dd = wfdbx.read_record('sub/dd', 'sampto', 9);
rec = wfdbx.read_record('sub/ms', 'sampto', 19);
assert_eq(rec.signals(:, 1), [-32768 * ones(10, 1); dd.signals(:, 1)], ...
    'null segment and segment next to the header');
rec = wfdbx.read_record('sub/ms', 'sampfrom', 20, 'sampto', 29);
assert_eq(rec.signals(:, 1), dd.signals(:, 1), 'segment in a subdirectory');
% segments outside the directory are refused
wfdbx.wfdbquiet();
seg = {'../sub/dd', '/x', '~/dd', 'http://127.0.0.1:1/dd'};
for k = 1:numel(seg)
    putfile(fullfile('sub', 'ms2.hea'), ...
        sprintf('ms2/2 1 360 20\ndd 10\n%s 10\n', seg{k}));
    assert_eq(wfdbx.isigopen('sub/ms2', 1), 1, ['isigopen ms2 ' seg{k}]);
    assert_eq(wfdbx.isigsettime(10), -1, ['segment refused ' seg{k}]);
    wfdbx.wfdbquit();
end
wfdbx.wfdbverbose();
% setmsheader: the segment names are given by the caller (resolved as
% any name)
assert_eq(wfdbx.setmsheader('msw', {'sub/dd', 'sub/seg/dd'}), 0, 'setmsheader');
wfdbx.wfdbquit();
h = regexp(char(readfile('msw.hea')), '\r?\n', 'split');
assert_eq(h(2:3), {'sub/dd 10', 'sub/seg/dd 10'}, 'setmsheader names');
end

function b = readfile(name)
fid = fopen(name, 'rb');
b = fread(fid, inf, 'uint8=>uint8')';
fclose(fid);
end

function legacy_unchanged()
wfdbx.wfdbquiet();
wfdbx.wfdbx_set_legacy(1);
wfdbx.setwfdb('.');                         % (the WFDB path)
wfdbx.wfdbx_set_input_dir('sub');           % (not used in legacy mode)
assert_eq(wfdbx.isigopen('sr', 2), -1, 'legacy: input dir ignored');
wfdbx.setwfdb('sub .');                     % the WFDB path
assert_eq(wfdbx.isigopen('sr', 2), 2, 'legacy: WFDB path');
assert_eq(wfdbx.wfdbfile('atr', 'sr'), 'sub/sr.atr', 'legacy: wfdbfile');
assert_eq(wfdbx.getwfdb(), 'sub .', 'legacy: getwfdb');
assert_eq(wfdbx.isigopen('sub/../100s', 2), -1, 'legacy: .. refused');
assert_eq(wfdbx.wfdbfile('hea', '~/x'), [], 'legacy: ~ not expanded');
wfdbx.setwfdb('.');
wfdbx.wfdbquit();
wfdbx.wfdbx_set_legacy(0);
setenv('WFDB', '');         % (set by setwfdb in legacy mode, as in C)
wfdbx.wfdbverbose();
defaults();
end

function highlevel_local()
wfdbx.wfdbx_set_input_dir('elsewhere');
h = wfdbx.read_header('sr', 'input_dir', 'sub');
assert_eq(h.nsig, 2, ...
    'read_header input_dir');
a = wfdbx.read_annotations('sr', 'atr', 'input_dir', 'sub');
assert_eq(numel(a.samples), 75, 'read_annotations input_dir');
assert_eq(wfdbx.wfdbx_get_input_dir(), 'elsewhere', 'input_dir restored');
wfdbx.wfdbquiet();
assert_error(@() wfdbx.read_record('nosuch', 'input_dir', 'sub', ...
    'network', true), 'read_record of a missing record');
wfdbx.wfdbverbose();
assert_eq({wfdbx.wfdbx_get_input_dir(), wfdbx.wfdbx_get_network()}, ...
    {'elsewhere', 0}, 'restored after an error');
% the output directory (dir) and the input directory are independent
wfdbx.write_annotations('w1', 'q', [1 2], 'symbols', 'NN', 'dir', 'sub');
assert_true(isfile(fullfile('sub', 'w1.q')), 'write_annotations dir');
wfdbx.wfdbquiet();
a = wfdbx.read_annotations('w1', 'q', 'input_dir', 'sub', 'fs', 100);
wfdbx.wfdbverbose();
assert_eq(numel(a.samples), 2, 'read back with input_dir');
defaults();
end

% ---------------------------------------------------------------------------
% The environment variables (a new Octave process for each)

function environment(here)
exe = fullfile(OCTAVE_HOME(), 'bin', 'octave-cli');
if ~isfile(exe)
    exe = 'octave-cli';
end
q = @wfdbx.internal.shell_quote;
run1 = @(env, code) run_octave(exe, q, fileparts(here), env, code);
[out, err] = run1('WFDBX_INPUT_DIR=in WFDBX_OUTPUT_DIR=out WFDBX_NETWORK=1', ...
    ['p(wfdbx.wfdbx_get_input_dir()); p(wfdbx.wfdbx_get_output_dir()); ' ...
    'p(wfdbx.wfdbx_get_network()); p(wfdbx.wfdbx_set_input_dir(''x'')); ' ...
    'p(wfdbx.wfdbx_set_input_dir([])); p(wfdbx.wfdbx_set_network(0)); ' ...
    'p(wfdbx.wfdbx_set_network(-1))']);
assert_eq({out, err}, {sprintf('in\nout\n1\nin\nx\n1\n0\n'), ''}, ...
    'environment variables');
values = {'0', 0; 'x', 0; ' 2', 1; '-1', 1; '0x1', 0; '1abc', 1};
for k = 1:size(values, 1)
    out = run1(['WFDBX_NETWORK=' q(values{k, 1})], 'p(wfdbx.wfdbx_get_network())');
    assert_eq(out, sprintf('%d\n', values{k, 2}), ['WFDBX_NETWORK=' values{k, 1}]);
end
[out, err] = run1('WFDBX_OUTPUT_DIR=http://127.0.0.1:1/', ...
    'p(isempty(wfdbx.wfdbx_get_output_dir()))');
assert_eq({out, err}, {sprintf('1\n'), sprintf(['wfdbx_set_output_dir: ' ...
    'the output directory must be a local directory\n'])}, ...
    'WFDBX_OUTPUT_DIR URL');
% WFDB is ignored (said once), not needed for an absolute name, and the
% WFDB path in legacy mode
wfdb_ignored = sprintf(['wfdb-x: the WFDB environment variable is ' ...
    'ignored; set WFDBX_INPUT_DIR instead (or use legacy mode)\n']);
[out, err] = run1('WFDB=sub', ['p(wfdbx.isigopen(''100s'', 2)); ' ...
    'wfdbx.wfdbquit(); p(wfdbx.isigopen(''100s'', 2))']);
assert_eq({out, err}, {sprintf('2\n2\n'), wfdb_ignored}, 'WFDB ignored');
[out, err] = run1('WFDB=sub', ['p(wfdbx.isigopen(''' pwd() '/100s'', 2))']);
assert_eq({out, err}, {sprintf('2\n'), ''}, 'WFDB: absolute name');
[out, err] = run1('WFDB=sub', ['wfdbx.wfdbx_set_legacy(1); ' ...
    'p(wfdbx.isigopen(''sr'', 2))']);
assert_eq({out, err}, {sprintf('2\n'), ''}, 'WFDB in legacy mode');
end

function [out, err] = run_octave(exe, q, mdir, env, code)
% Run CODE in a new Octave process with the environment variables ENV (in
% the current directory, without WFDB and the WFDBX_ variables otherwise);
% p(x) prints x.
pre = ['addpath(' q(mdir) '); p = @(x) fprintf(''%s\n'', num2str(x)); '];
efile = [tempname() '.err'];
cmd = ['env -u WFDB -u WFDBX_INPUT_DIR -u WFDBX_OUTPUT_DIR -u WFDBX_NETWORK ' ...
    env ' ' q(exe) ' --no-gui --norc -q --eval ' q([pre code]) ...
    ' </dev/null 2>' q(efile)];
[s, out] = system(cmd);
fid = fopen(efile, 'rb');
err = char(fread(fid, inf, 'uint8=>uint8')');
fclose(fid);
delete(efile);
err = regexprep(err, 'warning: function [^\n]*shadows a core library function\n', '');
assert_eq(s, 0, ['status of ' code]);
end

% ---------------------------------------------------------------------------
% Network access (a local server)

function srv = start_server(d)
% A local HTTP server (127.0.0.1) serving directory D, which logs the
% paths requested; [] if python3 cannot be run.
srv = [];
if ispc()
    return;
end
script = fullfile(d, 'srv.py');
putfile(script, sprintf(['import functools, http.server, os, sys\n' ...
    'd, info, log = sys.argv[1:4]\n' ...
    'class H(http.server.SimpleHTTPRequestHandler):\n' ...
    '    def log_message(self, *a): pass\n' ...
    '    def do_GET(self):\n' ...
    '        with open(log, "a") as f: f.write(self.path + "\\n")\n' ...
    '        if self.path.startswith("/redirect/"):\n' ...
    '            self.send_response(302)\n' ...
    '            self.send_header("Location", "/www/" + self.path[10:])\n' ...
    '            self.end_headers(); return\n' ...
    '        super().do_GET()\n' ...
    's = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ' ...
    'functools.partial(H, directory=d))\n' ...
    'open(info + ".tmp", "w").write("%%d %%d" %% (s.server_address[1], os.getpid()))\n' ...
    'os.rename(info + ".tmp", info)\n' ...
    's.serve_forever()\n']));
info = fullfile(d, 'srv.info');
srv.log = fullfile(d, 'srv.log');
putfile(srv.log, '');
q = @wfdbx.internal.shell_quote;
[s, ~] = system(['python3 ' q(script) ' ' q(d) ' ' q(info) ' ' q(srv.log) ...
    ' </dev/null >/dev/null 2>&1 &']);
t0 = tic();
while s == 0 && ~isfile(info) && toc(t0) < 20
    pause(0.1);
end
if ~isfile(info)
    srv = [];
    return;
end
v = sscanf(char(readfile(info)), '%d');
srv.url = sprintf('http://127.0.0.1:%d/', v(1));
srv.pid = v(2);
setenv('NO_PROXY', '127.0.0.1,localhost');
setenv('no_proxy', '127.0.0.1,localhost');
end

function stop_server(srv)
system(sprintf('kill %d', srv.pid));
end

function L = requests(srv)
L = regexp(char(readfile(srv.log)), '\n', 'split');
L = L(~cellfun('isempty', L));
end

function clear_log(srv)
putfile(srv.log, '');
end

function network_off(srv)
defaults();
clear_log(srv);
wfdbx.wfdbquiet();
assert_eq(wfdbx.isigopen([srv.url '100s'], 2), -1, 'network off');
assert_eq(wfdbx.wfdberror(), sprintf('init: can''t open header for record %s100s\n', ...
    srv.url), 'network off: the usual message last');
wfdbx.wfdbquit();
st = wfdbx.internal.io_state();
st.network_warned = false;
st.error_message = [];
wfdbx.wfdbfile('hea', [srv.url '100s']);
assert_eq(wfdbx.wfdberror(), net_off([srv.url '100s.hea']), ...
    'network off message (the first time)');
st.error_message = [];
wfdbx.wfdbfile('atr', [srv.url '100s']);
assert_true(~ischar(st.error_message), 'network off message once');
wfdbx.wfdbverbose();
assert_eq(requests(srv), cell(1, 0), 'network off: no request');
end

function network_on(srv)
defaults();
clear_log(srv);
wfdbx.wfdbx_set_network(1);
rec = wfdbx.read_record([srv.url '100s'], 'sampto', 3);
assert_eq(rec.signals, repmat([995 1011], 3, 1), 'read_record of a URL');
a = wfdbx.read_annotations([srv.url '100s'], 'atr');
assert_eq(numel(a.samples), 75, 'read_annotations of a URL');
% each URL is requested once
L = requests(srv);
assert_eq(numel(L), numel(unique(L)), 'each URL requested once');
assert_true(all(ismember({'/100s.hea', '/100s.dat', '/100s.atr'}, L)), ...
    'the files requested');
wfdbx.wfdbx_set_input_dir(srv.url);
rec = wfdbx.read_record('100s', 'sampto', 1);
assert_eq(rec.signals, [995 1011], 'URL input dir');
assert_eq(numel(requests(srv)), numel(L), 'cached');
assert_eq(wfdbx.wfdbfile('hea', '100s'), [srv.url '100s.hea'], 'wfdbfile URL');
wfdbx.wfdbx_set_input_dir(srv.url(1:end-1));    % (without the final '/')
assert_eq(wfdbx.wfdbfile('hea', '100s'), [srv.url '100s.hea'], ...
    'URL input dir without /');
defaults();
end

function network_subdirectories_and_errors(srv)
defaults();
clear_log(srv);
mkdir(fullfile('www', 'data'));
putfile(fullfile('www', 'rec.hea'), sprintf('rec 1 360 10\ndata/a.dat 16\n'));
copyfile('fmt16.dat', fullfile('www', 'data', 'a.dat'));
putfile(fullfile('www', 'nodat.hea'), sprintf('nodat 1 360 10\nnodat.dat 16\n'));
putfile(fullfile('www', 'bad.hea'), sprintf('bad 1 360 10\n../100s.dat 16\n'));
make_sr('www');
wfdbx.wfdbx_set_network(1);
wfdbx.wfdbx_set_input_dir([srv.url 'www']);
rec = wfdbx.read_record('rec', 'sampto', 2);
assert_eq(rec.signals, [-7; 32], 'signal file in a subdirectory of a URL');
assert_true(ismember('/www/data/a.dat', requests(srv)), 'its URL');
wfdbx.wfdbquiet();
assert_error(@() wfdbx.read_record('nodat'), 'missing signal file (404)');
assert_error(@() wfdbx.read_record('nosuch'), 'missing header (404)');
assert_error(@() wfdbx.read_record('bad'), 'remote containment');
n = numel(requests(srv));
assert_error(@() wfdbx.read_record('nosuch'), 'missing header again');
assert_eq(numel(requests(srv)), n, 'the failure is cached');
L = requests(srv);
assert_true(~any(ismember({'/100s.dat', '/www/../100s.dat'}, L)), ...
    'nothing outside the header''s directory requested');
% redirects are followed (the header's directory is that of its URL)
wfdbx.wfdbx_set_input_dir([]);
rec = wfdbx.read_record([srv.url 'redirect/sr'], 'sampto', 1);
assert_eq(rec.signals, [995 1011], 'redirect');
% a URL cannot be written; an output directory URL is refused
assert_eq(wfdbx.annopen([srv.url 'x'], wfdbx.anninfo('a', 1), 1), -4, ...
    'URL not written');
assert_eq(wfdbx.wfdbx_set_output_dir(srv.url), [], 'output dir URL');
wfdbx.wfdbverbose();
defaults();
end

function network_legacy(srv)
% legacy mode reads no remote files (as the reference C build), even with
% network access on; URL path entries are not opened either
defaults();
clear_log(srv);
wfdbx.wfdbx_set_network(1);
wfdbx.wfdbx_set_legacy(1);
wfdbx.wfdbquiet();
assert_eq(wfdbx.isigopen([srv.url '100s'], 2), -1, 'legacy: URL');
wfdbx.setwfdb(srv.url);
assert_eq(wfdbx.isigopen('100s', 2), -1, 'legacy: URL path entry');
wfdbx.setwfdb('.');
wfdbx.wfdbquit();
wfdbx.wfdbx_set_legacy(0);
setenv('WFDB', '');
wfdbx.wfdbverbose();
assert_eq(requests(srv), cell(1, 0), 'legacy: no request');
defaults();
end

function highlevel_network(srv)
defaults();
rec = wfdbx.read_record('100s', 'input_dir', srv.url, 'network', true, ...
    'sampto', 1);
assert_eq(rec.signals, [995 1011], 'read_record input_dir URL, network');
assert_eq({wfdbx.wfdbx_get_input_dir(), wfdbx.wfdbx_get_network()}, ...
    {[], 0}, 'settings restored');
% network false forbids it for the call; [] keeps the setting
wfdbx.wfdbx_set_network(1);
wfdbx.wfdbquiet();
assert_error(@() wfdbx.read_header([srv.url '100s'], 'network', false), ...
    'network false');
wfdbx.wfdbverbose();
assert_eq(wfdbx.wfdbx_get_network(), 1, 'network restored');
h = wfdbx.read_header([srv.url '100s']);
assert_eq(h.nsig, 2, 'network kept');
defaults();
end
