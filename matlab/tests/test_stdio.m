function test_stdio()
%TEST_STDIO Tests of the standard input emulation and of app_run/cexit.

% Part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

name = [tempname() '.in'];
fid = fopen(name, 'wb');
fwrite(fid, [uint8(sprintf('line 1\nline 2\n')) 200 0 10 uint8('x')], 'uint8');
fclose(fid);
old = getenv('WFDBX_STDIN');
cleanup = onCleanup(@() restore(old, name));
setenv('WFDBX_STDIN', name);
clear functions             % forget the standard input read so far
b = wfdbx.internal.stdin_bytes();
assert_eq(numel(b), 18, 'stdin size');
assert(isa(b, 'uint8'), 'stdin class');
f = wfdbx.internal.wfdb_open([], '-', 0);
assert(f.is_std, 'stdin is_std');
assert_eq(f.getline(), sprintf('line 1\n'), 'stdin getline');
assert_eq(f.getc(), double('l'), 'stdin getc');
assert_eq(f.read(6), uint8(sprintf('ine 2\n')), 'stdin read');
assert_eq(f.seek(0, 0), -1, 'stdin not seekable');
assert_eq(f.tell(), -1, 'stdin tell');
assert_eq(f.getline(), char([200 0 10]), 'stdin getline bytes');
assert_eq(f.getline(), 'x', 'stdin last line');
assert(f.feof(), 'stdin eof');
assert_eq(f.getc(), -1, 'stdin getc eof');
f2 = wfdbx.internal.wfdb_open('hea', '-', 0);
assert(f2.feof(), 'same stdin object');
lines = wfdbx.internal.fgets_lines(wfdbx.internal.stdin_bytes(), 1024);
assert_eq(numel(lines), 4, 'fgets_lines of stdin');

% app_run and cexit
assert_eq(wfdbx.internal.app_run(@(argv) exit_with(3), {'x'}), 3, 'cexit');
assert_eq(wfdbx.internal.app_run(@(argv) numel(argv), {'x', 'y'}), 2, ...
    'return status');
try
    wfdbx.internal.app_run(@(argv) error('wfdbx:test', 'boom'), {'x'});
    error('wfdbx:test', 'error not passed on');
catch err
    assert_eq(err.message, 'boom', 'error passed on');
end
end

function s = exit_with(st)
wfdbx.internal.cexit(st);
s = 0;
end

function restore(old, name)
setenv('WFDBX_STDIN', old);
delete(name);
clear functions
end
