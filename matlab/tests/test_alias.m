function test_alias()
%TEST_ALIAS An output signal file is never one of the input files (wfdb-x).
%   The library refuses to create an output signal file that is the same
%   file as a signal file of the open input record (the files are
%   compared, not their names); legacy mode does not check.  The Python
%   counterpart is python/tests/test_api.py::test_output_file_is_input_file
%   (t_alias of tests/reference/api_expect.c).

% Part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

here = fileparts(mfilename('fullpath'));
data = fullfile(fileparts(fileparts(here)), 'tests', 'data');
old = pwd();
d = tempname();
mkdir(d);
cleanup = onCleanup(@() restore(old, d)); %#ok<NASGU>
copyfile(fullfile(data, '*'), d);
cd(d);
wfdbx.wfdbquit();
fmt16 = readfile('fmt16.dat');
fmt212 = readfile('fmt212.dat');
cases = {'fmt16', 'fmt16.dat'; 'fmt16', './fmt16.dat'; 'skew', 'fmt16.dat'; ...
    'vlay', 'fmt16.dat'; 'vlay', 'fmt212.dat'};
if ~ispc()
    if wfdbx.internal.is_octave()
        link('fmt16.dat', 'ahard16.dat');
    else
        system('ln fmt16.dat ahard16.dat');
    end
    cases(end + 1, :) = {'fmt16', 'ahard16.dat'};
end
% an open signal file; under another name; a hard link; a file named by
% another header; a segment of a multi-segment record that is not open
% yet (fmt212, vlay's last)
for k = 1:size(cases, 1)
    rec = cases{k, 1};
    fname = cases{k, 2};
    wfdbx.wfdbquit();
    wfdbx.wfdbquiet();          % (vlay: a sigmap_init message)
    assert_eq(wfdbx.isigopen(rec, 3), 3, ['isigopen ' rec]);
    wfdbx.setsampfreq(250);
    assert_eq(wfdbx.osigfopen(spec(fname), 3), -3, ['osigfopen ' fname]);
    assert_eq(wfdbx.wfdberror(), sprintf(['osigfopen: output file %s is ' ...
        'also an input file\n'], fname), ['message ' fname]);
    assert_eq(wfdbx.getvec(), 3, ['the input is still readable ' fname]);
    wfdbx.wfdbverbose();
end
% osigopen names itself
wfdbx.wfdbquit();
assert_eq(wfdbx.isigopen('fmt16', 3), 3, 'isigopen fmt16');
wfdbx.wfdbquiet();
assert_eq(wfdbx.osigopen('fmt16', 3), -3, 'osigopen fmt16');
wfdbx.wfdbverbose();
assert_eq(wfdbx.wfdberror(), sprintf(['osigopen: output file fmt16.dat is ' ...
    'also an input file\n']), 'osigopen message');
wfdbx.wfdbquit();
assert_eq(readfile('fmt16.dat'), fmt16, 'fmt16.dat intact');
assert_eq(readfile('fmt212.dat'), fmt212, 'fmt212.dat intact');
% not an input file: another file, a file that does not exist yet
names = {'fmt8.dat', 'new.dat'};
for k = 1:2
    wfdbx.wfdbquiet();
    assert_eq(wfdbx.isigopen('vlay', 3), 3, 'isigopen vlay');
    wfdbx.setsampfreq(250);
    assert_eq(wfdbx.osigfopen(spec(names{k}), 3), 3, ['osigfopen ' names{k}]);
    wfdbx.wfdbquit();
    wfdbx.wfdbverbose();
end
% with no input record open, any file can be written
wfdbx.setsampfreq(250);
assert_eq(wfdbx.osigfopen(spec('fmt8.dat'), 3), 3, 'no input open');
wfdbx.wfdbquit();
% legacy mode: the original behavior (the file is created, truncated)
previous = wfdbx.wfdbx_set_legacy(1);
c = onCleanup(@() wfdbx.wfdbx_set_legacy(previous)); %#ok<NASGU>
assert_eq(wfdbx.isigopen('fmt16', 3), 3, 'legacy isigopen');
wfdbx.setsampfreq(250);
assert_eq(wfdbx.osigfopen(spec('fmt16.dat'), 3), 3, 'legacy osigfopen');
wfdbx.wfdbquit();
wfdbx.wfdbx_set_legacy(previous);
assert_eq(numel(readfile('fmt16.dat')), 0, 'legacy: the input truncated');
end

function si = spec(fname)
si = wfdbx.siginfo(3);
for i = 1:3
    si(i).fname = fname;
    si(i).desc = sprintf('s%d', i - 1);
    si(i).units = 'mV';
    si(i).gain = 100;
    si(i).group = 0;
    si(i).fmt = 16;
    si(i).adcres = 12;
end
end

function b = readfile(name)
fid = fopen(name, 'rb');
b = fread(fid, inf, 'uint8=>uint8')';
fclose(fid);
end

function restore(old, d)
wfdbx.wfdbquit();
wfdbx.wfdbverbose();
cd(old);
rmdir(d, 's');
end
