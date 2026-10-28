function test_wfdbio()
%TEST_WFDBIO Tests of the WFDB path, file lookup and WFDBFile I/O.

% This file is part of WFDB-x, an independent reimplementation of the WFDB
% Software Package in Python, C++, MATLAB/Octave, Rust, Julia, R and Kotlin.
% It tests WFDB-x; it has no counterpart in the original package.
%
% Copyright (C) 2026 Reza Sameni.
%
% This program is free software: you can redistribute it and/or modify it
% under the terms of the GNU General Public License as published by the Free
% Software Foundation, either version 3 of the License, or (at your option)
% any later version. See LICENSE.

old = pwd();
oldpath = getenv('WFDB');
d = tempname();
mkdir(d);
cleanup = onCleanup(@() restore(old, oldpath, d));
cd(d);
mkdir('sub');
write_file('rec.hea', sprintf('rec 1 360\nrec.dat 16 200 12 0 0 0 0 MLII\n'));
write_file(fullfile('sub', 'srec.hea'), sprintf('srec 0\n'));
write_file(fullfile('sub', 'srec.atr'), uint8([0 4 1 2 255 128]));
write_file('pathfile', sprintf('. sub\r\n'));

% The WFDB path (legacy mode: WFDB-x reads from a single input directory;
% see test_files)
wfdbx.wfdbx_set_legacy(1);
wfdbx.setwfdb('. sub;/x/y http://example.org/db');
st = wfdbx.internal.io_state();
assert_eq(st.path_prefix, {'.', 'sub', '/x/y', 'http://example.org/db'}, ...
    'parsed path');
assert_eq(st.path_type, [0 0 0 1], 'path types');
assert_eq(wfdbx.getwfdb(), '. sub;/x/y http://example.org/db', 'getwfdb');
assert_eq(getenv('WFDB'), '. sub;/x/y http://example.org/db', 'setwfdb sets WFDB');
wfdbx.internal.wfdb_parse_path('a:b c');
assert_eq(st.path_prefix, {'a', 'b', 'c'}, 'colon separators');
wfdbx.internal.wfdb_parse_path('');
assert_eq(numel(st.path_prefix), 0, 'empty path');

% Indirect path
wfdbx.setwfdb('@pathfile');
assert_eq(wfdbx.getwfdb(), '. sub', 'indirect path');

% File lookup
assert_eq(wfdbx.wfdbfile('hea', 'rec'), './rec.hea', 'wfdbfile hea');
assert_eq(wfdbx.wfdbfile('hea', 'rec.hea'), './rec.hea', 'wfdbfile strips .hea');
assert_eq(wfdbx.wfdbfile('rec.hea', []), './rec.hea', 'wfdbfile by name');
assert(~ischar(wfdbx.wfdbfile('dat', 'rec')), 'missing file');
assert_eq(wfdbx.wfdbfile([], []), 'sub/rec.dat', 'last file name tried');
assert_eq(wfdbx.wfdbfile('atr', 'srec'), 'sub/srec.atr', 'found in sub');
% sub is now first after '.'
assert_eq(st.path_prefix, {'.', 'sub'}, 'addtopath (already second)');
wfdbx.setwfdb('/nonexistent .');
wfdbx.internal.wfdb_addtopath('sub/srec.hea');
assert_eq(st.path_prefix, {'sub', '/nonexistent', '.'}, 'addtopath new');
wfdbx.internal.wfdb_addtopath('/nonexistent/x.hea');
assert_eq(st.path_prefix, {'/nonexistent', 'sub', '.'}, 'addtopath move');
wfdbx.setwfdb('. sub');
assert(~ischar(wfdbx.wfdbfile('hea', '../rec')), 'names with .. are refused');
assert(~ischar(wfdbx.wfdbfile('sub', [])), 'directories are not files');

% %r in the path
wfdbx.setwfdb('. %r %1rx');
wfdbx.internal.wfdb_setirec('a/sub');
assert_eq(wfdbx.internal.wfdb_getirec(), 'sub', 'irec');
assert_eq(wfdbx.wfdbfile('hea', 'srec'), 'sub/srec.hea', '%r substitution');
wfdbx.setwfdb('. sub');
wfdbx.setwfdb('.');
setenv('WFDB', oldpath);    % (set by setwfdb in legacy mode, as in C)
wfdbx.wfdbx_set_legacy(0);

% Name checks
wfdbx.wfdbquiet();
assert_eq(wfdbx.internal.wfdb_checkname('rec_1-a/b~', 'record'), 0, 'checkname ok');
assert_eq(wfdbx.internal.wfdb_checkname('a.b', 'record'), -1, 'checkname bad');
assert_eq(wfdbx.wfdberror(), sprintf('init: illegal character 46 in record name\n'), ...
    'wfdberror');
assert_eq(wfdbx.internal.wfdb_checkname(['a' char(200)], 'annotator'), -1, ...
    'checkname high');
assert_eq(wfdbx.wfdberror(), ...
    sprintf('init: illegal character -56 in annotator name\n'), 'signed char');
% (a record name: only its last component, outside legacy mode)
assert_eq(wfdbx.internal.wfdb_checkname('my.data/rec', 'record'), 0, ...
    'checkname directory with a dot');
assert_eq(wfdbx.internal.wfdb_checkname('/a.b/c d/rec', 'record'), 0, ...
    'checkname absolute path');
assert_eq(wfdbx.internal.wfdb_checkname('my.data/rec.1', 'record'), -1, ...
    'checkname last component');
assert_eq(wfdbx.wfdberror(), sprintf('init: illegal character 46 in record name\n'), ...
    'checkname last component message');
assert_eq(wfdbx.internal.wfdb_checkname('dir/', 'record'), -1, ...
    'checkname empty last component');
assert_eq(wfdbx.wfdberror(), sprintf('init: illegal character 0 in record name\n'), ...
    'checkname empty message');
assert_eq(wfdbx.internal.wfdb_checkname('my.data/atr', 'annotator'), -1, ...
    'checkname annotator: whole name');
wfdbx.wfdbx_set_legacy(1);
assert_eq(wfdbx.internal.wfdb_checkname('my.data/rec', 'record'), -1, ...
    'checkname legacy: whole name');
wfdbx.wfdbx_set_legacy(0);
wfdbx.wfdbverbose();
assert_eq(wfdbx.internal.wfdb_striphea('x.hea'), 'x', 'striphea');
assert_eq(wfdbx.internal.wfdb_striphea('.hea'), '.hea', 'striphea short');

% WFDBFile reading
wfdbx.wfdbx_set_input_dir('sub');
f = wfdbx.internal.wfdb_open('atr', 'srec', 0);
assert(isa(f, 'wfdbx.internal.WFDBFile'), 'wfdb_open result');
assert_eq(f.g16(), 1024, 'g16');
assert_eq(f.tell(), 2, 'tell');
assert_eq(f.getc(), 1, 'getc');
assert_eq(f.seek(0, 0), 0, 'seek');
assert_eq(f.g32(), 1024 * 65536 + 513, 'g32');
assert_eq(f.g16(), -32513, 'g16 negative');
assert(~f.feof(), 'not eof');
assert_eq(f.getc(), -1, 'getc at eof');
assert(f.feof(), 'eof');
assert_eq(f.seek(-2, 2), 0, 'seek from end');
assert_eq(f.read(10), uint8([255 128]), 'read short');
f.close();
wfdbx.wfdbx_set_input_dir([]);
f = wfdbx.internal.wfdb_open('hea', 'rec', 0);
assert_eq(f.getline(), sprintf('rec 1 360\n'), 'getline 1');
assert_eq(f.getline(), sprintf('rec.dat 16 200 12 0 0 0 0 MLII\n'), 'getline 2');
assert_eq(f.getline(), '', 'getline eof');
assert(f.feof(), 'getline eof flag');
f.close();

% WFDBFile writing
f = wfdbx.internal.wfdb_open('dat', 'out', 1);
assert(~isempty(f), 'open for writing');
assert_eq(wfdbx.wfdbfile([], []), 'out.dat', 'output file name');
f.p16(-2);
f.p32(65536 * 3 + 4);
f.putc(300);
f.write('ab');
f.printf('%d|%s\n', 7, 'x');
f.close();
assert_eq(read_file('out.dat'), uint8([254 255 3 0 4 0 44 97 98 55 124 120 10]), ...
    'written bytes');
f = wfdbx.internal.wfdb_open('dat', 'out', 4);
f.write(uint8(1));
f.close();
assert_eq(numel(read_file('out.dat')), 14, 'append');
f = wfdbx.internal.wfdb_open('hea', 'new/dir/rec', 1);
assert(~isempty(f), 'directories created for output');
f.close();
assert(isfile(fullfile('new', 'dir', 'rec.hea')), 'file in new dir');
f = wfdbx.internal.wfdb_open('hea', 'new/', 1);
f.close();
assert(isfile(fullfile('new', 'new.hea')), 'record dir/ = dir/dir');
end

function write_file(name, data)
fid = fopen(name, 'wb');
fwrite(fid, data, 'uint8');
fclose(fid);
end

function b = read_file(name)
fid = fopen(name, 'rb');
b = fread(fid, Inf, 'uint8=>uint8')';
fclose(fid);
end

function restore(old, oldpath, d)
cd(old);
wfdbx.wfdbverbose();
wfdbx.wfdbx_set_legacy(0);
wfdbx.wfdbx_set_input_dir([]);
setenv('WFDB', oldpath);
if isfolder(d)
    rmdir(d, 's');
end
end
