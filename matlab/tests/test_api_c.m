function test_api_c()
%TEST_API_C Tests of the library functions that the tools do not exercise.
%   The expected values were produced by the original C library, using
%   tests/reference/api_expect.c (each local function below corresponds to
%   a function of that program; run it to see the values).  The Python and
%   C++ counterparts of these tests are python/tests/test_api.py and
%   cpp/tests/test_api_c.cpp.

% Part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

here = fileparts(mfilename('fullpath'));
data = fullfile(fileparts(fileparts(here)), 'tests', 'data');
old = pwd();
oldpath = getenv('WFDB');
d = tempname();
mkdir(d);
cleanup = onCleanup(@() restore(old, oldpath, d)); %#ok<NASGU>
copyfile(fullfile(data, '*'), d);
cd(d);
tests = {@t_version, @t_path, @t_bufsize, @t_signals, @t_amplitude, ...
    @t_sample, @t_frames, @t_groups, @t_segments, @t_skew, @t_output, ...
    @t_info, @t_msheader, @t_counter, @t_calib, @t_annot, @t_afreq, ...
    @t_ecgstr, @t_strings, @t_maps, @t_extra, @t_flacseek, ...
    @t_strtim_range, @t_nodefaults, @t_legacy};
for k = 1:numel(tests)
    wfdbx.wfdbquit();
    wfdbx.setwfdb('.');
    tests{k}();
end
wfdbx.wfdbquit();
end

% ---------------------------------------------------------------------------

function t_version()
% wfdbversion, wfdbdefwfdb, wfdbldflags and wfdbcflags depend on how the C
% library was built (with configure); wfdb-x gives the values of a release
% build installed in /usr/local, and empty flags strings.
assert_eq(wfdbx.wfdbversion(), '10.7.0', 'wfdbversion');
assert_eq(wfdbx.wfdbdefwfdb(), ...
    '. /usr/local/database http://physionet.org/physiobank/database', ...
    'wfdbdefwfdb');
assert_eq(wfdbx.wfdbdefwfdbcal(), 'wfdbcal', 'wfdbdefwfdbcal');
assert_eq(wfdbx.wfdbldflags(), '', 'wfdbldflags');
assert_eq(wfdbx.wfdbcflags(), '', 'wfdbcflags');
% before any error (C prints its build date)
st = wfdbx.internal.iostate();
saved = st.error_flag;
st.error_flag = false;
msg = wfdbx.wfdberror();
st.error_flag = saved;
assert_eq(msg(1:29), 'WFDB library version 10.7.0 (', 'wfdberror before errors');
assert_eq(msg(end-2:end), sprintf(').\n'), 'wfdberror before errors');
assert_eq(wfdbx.wfdb_me_fatal(), 1, 'wfdb_me_fatal');
wfdbx.wfdbmemerr(0);
assert_eq(wfdbx.wfdb_me_fatal(), 0, 'wfdb_me_fatal after wfdbmemerr(0)');
wfdbx.wfdbquiet();
q = onCleanup(@() wfdbx.wfdbverbose()); %#ok<NASGU>
assert_eq(wfdbx.isigopen('nosuch', 8), -1, 'isigopen nosuch');
assert_eq(wfdbx.wfdberror(), ...
    sprintf('init: can''t open header for record nosuch\n'), 'wfdberror');
assert_eq(wfdbx.annopen('nosuch', wfdbx.anninfo('atr', 0)), -3, ...
    'annopen nosuch');
assert_eq(wfdbx.wfdberror(), ...
    sprintf('annopen: can''t read annotator atr for record nosuch\n'), ...
    'wfdberror');
end

function t_path()
% resetwfdb restores the path returned by the first getwfdb (here, as in a
% fresh process with WFDB=. in the environment); wfdbquit calls it.
st = wfdbx.internal.iostate();
saved = {st.wfdbpath, st.wfdbpath_init};
st.wfdbpath = [];
st.wfdbpath_init = [];
setenv('WFDB', '.');
assert_eq(wfdbx.getwfdb(), '.', 'getwfdb initial');
wfdbx.setwfdb('a b');
assert_eq(wfdbx.getwfdb(), 'a b', 'getwfdb');
wfdbx.resetwfdb();
assert_eq(wfdbx.getwfdb(), '.', 'getwfdb after resetwfdb');
wfdbx.setwfdb('c');
wfdbx.wfdbquit();
assert_eq(wfdbx.getwfdb(), '.', 'getwfdb after wfdbquit');
st.wfdbpath_init = saved{2};
wfdbx.setwfdb('.');
assert_eq(wfdbx.wfdbfile('hea', '100s'), './100s.hea', 'wfdbfile');
assert_eq(wfdbx.wfdbfile([], []), './100s.hea', 'wfdbfile NULL NULL');
assert_eq(wfdbx.wfdbfile('hea', '100s.hea'), './100s.hea', 'wfdbfile .hea');
assert_eq(wfdbx.wfdbfile('atr', '100s'), './100s.atr', 'wfdbfile atr');
assert(isempty(wfdbx.wfdbfile('dat', 'nosuch')), 'wfdbfile nosuch');
assert_eq(wfdbx.wfdbfile('wfdbcal', []), './wfdbcal', 'wfdbfile wfdbcal');
end

function t_bufsize()
wfdbx.wfdbquiet();
q = onCleanup(@() quiet_end()); %#ok<NASGU>
assert_eq(wfdbx.setibsize(0), 8192, 'setibsize 0');
assert_eq(wfdbx.setibsize(1000), 1000, 'setibsize 1000');
assert_eq(wfdbx.setibsize(-1), -2, 'setibsize -1');
assert_eq(wfdbx.setobsize(0), 8192, 'setobsize 0');
assert_eq(wfdbx.setobsize(2000), 2000, 'setobsize 2000');
assert_eq(wfdbx.setobsize(-5), -2, 'setobsize -5');
wfdbx.isigopen('100s', 8);
assert_eq(wfdbx.setibsize(512), -1, 'setibsize after isigopen');
wfdbx.wfdbquit();
wfdbx.setibsize(0);
wfdbx.setobsize(0);
end

function quiet_end()
wfdbx.wfdbverbose();
end

function t_signals()
assert_eq(wfdbx.getgvmode(), 0, 'getgvmode default');
assert_eq(wfdbx.isigopen('100s', 8), 2, 'isigopen 100s');
assert_eq(wfdbx.getifreq(), 360, 'getifreq');
assert_eq(wfdbx.getspf(), 1, 'getspf');
wfdbx.wfdbquit();
wfdbx.isigopen('fmt16', 8);
assert_eq(vec(), [3 -7 32 -33], 'getvec');
assert_eq(vec(), [3 4 53 -47], 'getvec');
assert_eq(vec(), [3 -20 24 -27], 'getvec');
assert_eq(wfdbx.setifreq(100), 0, 'setifreq 100');
assert_eq(wfdbx.getifreq(), 100, 'getifreq 100');
assert_eq(wfdbx.isigsettime(0), 0, 'isigsettime 0');
assert_eq(vec(), [3 -7 32 -33], 'getvec 100');
assert_eq(vec(), [3 -21 23 -35], 'getvec 100');
assert_eq(vec(), [3 7 -14 -44], 'getvec 100');
assert_eq(wfdbx.setifreq(1000), 0, 'setifreq 1000');
assert_eq(wfdbx.getifreq(), 1000, 'getifreq 1000');
assert_eq(wfdbx.isigsettime(2), 0, 'isigsettime 2');
assert_eq(vec(), [3 -7 32 -33], 'getvec 1000');
for k = 1:4
    assert_eq(vec(), [3 4 53 -47], 'getvec 1000');
end
assert_eq(wfdbx.getafreq(), 1000, 'getafreq after setifreq');
wfdbx.wfdbquiet();
assert_eq(wfdbx.setifreq(-1), -1, 'setifreq -1');
wfdbx.wfdbverbose();
assert_eq(wfdbx.getifreq(), 250, 'getifreq after setifreq -1');
wfdbx.setafreq(0);
wfdbx.wfdbquit();
wfdbx.isigopen('100s', 8);
wfdbx.setgvmode(wfdbx.WFDB_HIGHRES());
assert_eq(wfdbx.getgvmode(), 1, 'getgvmode HIGHRES');
wfdbx.setgvmode(wfdbx.WFDB_GVPAD() + wfdbx.WFDB_LOWRES());
assert_eq(wfdbx.getgvmode(), 2, 'getgvmode GVPAD');
wfdbx.setgvmode(wfdbx.WFDB_HIGHRES() + wfdbx.WFDB_GVPAD() + 4);
assert_eq(wfdbx.getgvmode(), 3, 'getgvmode 7');
wfdbx.setgvmode(0);
end

function r = vec(n, f)
% the status and the samples returned by getvec (or getframe)
if nargin < 2
    [stat, v] = wfdbx.getvec();
else
    [stat, v] = f();
end
if nargin < 1 || isempty(n)
    n = numel(v);
end
r = [stat v(1:n)];
end

function t_amplitude()
wfdbx.wfdbquiet();     % (wfdb-x: invalid signal numbers are reported)
q = onCleanup(@() quiet_end()); %#ok<NASGU>
wfdbx.isigopen('100s', 8);     % gain 200, baseline 1024
assert_eq([wfdbx.adumuv(0, 200) wfdbx.adumuv(0, -37) wfdbx.adumuv(1, 1) ...
    wfdbx.adumuv(0, -1) wfdbx.adumuv(7, 100)], [1000 -185 5 -5 -32768], ...
    'adumuv');
assert_eq([wfdbx.muvadu(0, 1000) wfdbx.muvadu(0, -333) wfdbx.muvadu(1, 2) ...
    wfdbx.muvadu(9, 1000)], [200 -67 0 -32768], 'muvadu');
assert_eq([wfdbx.aduphys(0, 1224) wfdbx.aduphys(1, 900)], [1 -0.62], ...
    'aduphys');
assert_eq(isnan(wfdbx.aduphys(5, 300)), true, 'aduphys 5 (invalid signal)');
assert_eq([wfdbx.physadu(0, 1.0) wfdbx.physadu(1, -0.5023) ...
    wfdbx.physadu(5, 1.5)], [1224 924 -32768], 'physadu');
wfdbx.wfdbquit();
wfdbx.isigopen('fmt16', 8);    % 100(-5)/mV, 150(5)/uV, 200(15)/mmHg
assert_eq([wfdbx.adumuv(0, 100) wfdbx.adumuv(1, 150) wfdbx.adumuv(2, -7)], ...
    [1000 1000 -35], 'fmt16 adumuv');
assert_eq([wfdbx.muvadu(0, 1000) wfdbx.muvadu(1, 1000) ...
    wfdbx.muvadu(2, -2500)], [100 150 -500], 'fmt16 muvadu');
assert_eq([wfdbx.aduphys(0, 95) wfdbx.aduphys(1, 10) wfdbx.aduphys(2, -3)], ...
    [1 0.033333333333333333 -0.089999999999999997], 'fmt16 aduphys');
assert_eq([wfdbx.physadu(0, 1.0) wfdbx.physadu(1, -2.25) ...
    wfdbx.physadu(2, 0.4)], [95 -333 95], 'fmt16 physadu');
end

function t_sample()
wfdbx.isigopen('100s', 8);
assert_eq(wfdbx.sample_valid(), 0, 'sample_valid initial');
args = {0 0; 1 1000; 0 21599; 0 21600; 0 5; 1 -3; 2 0};
expected = [995 1; 970 1; 975 1; 975 0; 995 1; 1011 1; -32768 -1];
for k = 1:size(args, 1)
    v = wfdbx.sample(args{k, 1}, args{k, 2});
    assert_eq([v wfdbx.sample_valid()], expected(k, :), ...
        sprintf('sample %d %d', args{k, 1}, args{k, 2}));
end
end

function t_frames()
wfdbx.isigopen('mfreq', 8);    % 1, 2 and 4 samples per frame
assert_eq(wfdbx.getspf(), 1, 'mfreq getspf');
assert_eq(wfdbx.getifreq(), 100, 'mfreq getifreq');
assert_eq(vec(7, @wfdbx.getframe), [3 138 218 2699 219 -1316 1120 1973], ...
    'getframe');
assert_eq(vec(7, @wfdbx.getframe), [3 2677 1201 275 -989 1822 2762 1927], ...
    'getframe');
assert_eq(vec(3), [3 -597 -455 181], 'getvec');
wfdbx.isigsettime(599);
assert_eq(vec(7, @wfdbx.getframe), [3 -1394 715 558 2215 -1785 860 -491], ...
    'getframe 599');
assert_eq(wfdbx.getframe(), -1, 'getframe end');
wfdbx.wfdbquit();
wfdbx.setgvmode(wfdbx.WFDB_HIGHRES());
q = onCleanup(@() wfdbx.setgvmode(0)); %#ok<NASGU>
wfdbx.isigopen('mfreq', 8);
assert_eq(wfdbx.getspf(), 4, 'highres getspf');
assert_eq(wfdbx.getifreq(), 400, 'highres getifreq');
assert_eq(vec(7, @wfdbx.getframe), [3 138 218 2699 219 -1316 1120 1973], ...
    'highres getframe');
assert_eq(vec(3), [3 2677 1201 -989], 'highres getvec');
assert_eq(vec(3), [3 2677 1201 1822], 'highres getvec');
wfdbx.wfdbquit();
end

function t_groups()
wfdbx.isigopen('twog', 8);     % group 0: signal 0; group 1: signals 1, 2
assert_eq(vec(3), [3 1020 977 316], 'twog getvec');
assert_eq(wfdbx.isgsettime(1, 100), 0, 'isgsettime 1 100');
assert_eq(vec(3), [3 1880 -630 83], 'twog getvec');
assert_eq(vec(3), [3 325 245 1597], 'twog getvec');
assert_eq(wfdbx.isgsettime(0, 500), 0, 'isgsettime 0 500');
assert_eq(vec(3), [3 -1823 338 -709], 'twog getvec');
assert_eq(wfdbx.isgsettime(1, 1001), 0, 'isgsettime 1 1001');
assert_eq(wfdbx.getvec(), -1, 'twog getvec end');
end

function c = segs()
s = wfdbx.getseginfo();
c = cell(1, numel(s));
for k = 1:numel(s)
    c{k} = sprintf('%s %d %d', s(k).recname, s(k).nsamp, s(k).samp0);
end
end

function t_segments()
wfdbx.isigopen('100s', 8);
assert_eq(numel(wfdbx.getseginfo()), 0, 'getseginfo 100s');
assert_eq(wfdbx.tnextvec(0, 5), 5, 'tnextvec 100s 0 5');
assert_eq(wfdbx.tnextvec(1, 0), 0, 'tnextvec 100s 1 0');
wfdbx.wfdbquit();
wfdbx.isigopen('multi', 8);
assert_eq(segs(), {'100s 21600 0', 'null 1800 21600', '100s 21600 23400'}, ...
    'getseginfo multi');
assert_eq(wfdbx.tnextvec(0, 0), 0, 'tnextvec multi 0 0');
assert_eq(wfdbx.tnextvec(0, 21599), 21599, 'tnextvec multi 0 21599');
assert_eq(wfdbx.tnextvec(1, 21700), 23500, 'tnextvec multi 1 21700');
assert_eq(wfdbx.tnextvec(0, 44999), 44999, 'tnextvec multi 0 44999');
assert_eq(wfdbx.tnextvec(0, 45000), -1, 'tnextvec multi 0 45000');
wfdbx.wfdbquit();
wfdbx.isigopen('vlay', 8);
assert_eq(segs(), {'vlay_0 0 0', 'fmt16 1500 0', '~ 200 1500', ...
    'fmt212 1501 1700'}, 'getseginfo vlay');
wfdbx.wfdbquiet();
q = onCleanup(@() quiet_end()); %#ok<NASGU>
assert_eq(wfdbx.tnextvec(0, 0), 0, 'tnextvec vlay 0 0');
assert_eq(wfdbx.tnextvec(1, 1499), 1700, 'tnextvec vlay 1 1499');
assert_eq(wfdbx.tnextvec(2, 1500), -1, 'tnextvec vlay 2 1500');
assert_eq(wfdbx.tnextvec(0, 1600), -1, 'tnextvec vlay 0 1600');
assert_eq(wfdbx.tnextvec(5, 0), -1, 'tnextvec vlay 5 0');
end

function t_skew()
wfdbx.isigopen('skew', 8);
assert_eq([wfdbx.wfdbgetskew(0) wfdbx.wfdbgetskew(1) wfdbx.wfdbgetskew(2) ...
    wfdbx.wfdbgetskew(3)], [0 3 7 0], 'wfdbgetskew');
assert_eq(vec(3), [3 -7 21 -32768], 'skew getvec');
wfdbx.wfdbsetiskew(1, 2);
wfdbx.wfdbsetiskew(2, 100000);     % too large: ignored
wfdbx.wfdbsetiskew(0, -1);         % negative: ignored
assert_eq([wfdbx.wfdbgetskew(0) wfdbx.wfdbgetskew(1) wfdbx.wfdbgetskew(2)], ...
    [0 2 7], 'wfdbgetskew after wfdbsetiskew');
wfdbx.wfdbquit();
wfdbx.isigopen('prolog', 8);
assert_eq([wfdbx.wfdbgetstart(0) wfdbx.wfdbgetstart(2) ...
    wfdbx.wfdbgetstart(3)], [100 100 0], 'wfdbgetstart prolog');
wfdbx.wfdbquit();
wfdbx.isigopen('100s', 8);
assert_eq(wfdbx.wfdbgetstart(0), 0, 'wfdbgetstart 100s');
end

function t_output()
wfdbx.setcfreq(0);     % (the counter frequency survives wfdbquit)
si = wfdbx.siginfo(2);
for k = 1:2
    si(k).fname = 'out.dat';
    si(k).units = 'mV';
    si(k).gain = 100;
    si(k).group = 0;
    si(k).fmt = 16;
    si(k).adcres = 12;
end
si(1).desc = 'first';
si(2).desc = 'second';
wfdbx.setsampfreq(100);
assert_eq(wfdbx.osigfopen(si, 2), 2, 'osigfopen');
assert_eq(wfdbx.wfdbputprolog('PROLOG!', 7, 0), 0, 'wfdbputprolog');
wfdbx.wfdbsetskew(1, 4);
for i = 0:4
    wfdbx.putvec([i -i]);
end
assert_eq(wfdbx.annopen('out', wfdbx.anninfo('tst', wfdbx.WFDB_WRITE())), ...
    0, 'annopen out tst');
a = wfdbx.annotation();
a.time = 3;
a.anntyp = wfdbx.NORMAL();
wfdbx.putann(0, a);
a.time = 4;
a.anntyp = wfdbx.PVC();
wfdbx.putann(0, a);
wfdbx.wfdbflush();
assert_eq([fsize('out.dat') fsize('out.tst')], [27 4], 'sizes after wfdbflush');
assert_eq(wfdbx.newheader('out'), 0, 'newheader');
assert_eq(wfdbx.putinfo('info line'), 0, 'putinfo');
wfdbx.wfdbquit();
assert_eq(char(readfile('out.hea')), sprintf(['out 2 100 5\r\n' ...
    'out.dat 16+7 100/mV 12 0 0 10 0 first\r\n' ...
    'out.dat 16:4+7 100/mV 12 0 0 -10 0 second\r\n#info line\r\n']), ...
    'out.hea');
assert_eq(readfile('out.dat'), unhex(['50524f4c4f4721 0000 0000 0100 ffff ' ...
    '0200 feff 0300 fdff 0400 fcff']), 'out.dat');
assert_eq(readfile('out.tst'), unhex('0304 0114 0000'), 'out.tst');

wfdbx.setsampfreq(100);
[si.fname] = deal('out2.dat');
wfdbx.osigfopen(si, 2);
wfdbx.wfdbsetstart(0, 512);
wfdbx.putvec([1 2]);
wfdbx.newheader('out2');
wfdbx.wfdbquit();
assert_eq(char(readfile('out2.hea')), sprintf(['out2 2 100 1\r\n' ...
    'out2.dat 16+512 100/mV 12 0 1 1 0 first\r\n' ...
    'out2.dat 16+512 100/mV 12 0 2 2 0 second\r\n']), 'out2.hea');
assert_eq(fsize('out2.dat'), 4, 'out2.dat size');
end

function t_info()
xform = 'Produced by xform from record 100, beginning at 0:0';
assert_eq(wfdbx.getinfo('100s'), ' 69 M 1085 1629 x1', 'getinfo 100s');
assert_eq(wfdbx.getinfo([]), ' Aldomet, Inderal', 'getinfo');
assert_eq(wfdbx.getinfo([]), xform, 'getinfo');
assert_eq(wfdbx.setinfo('newrec'), 0, 'setinfo newrec');
assert_eq(wfdbx.putinfo('first'), 0, 'putinfo');
assert_eq(wfdbx.putinfo('second'), 0, 'putinfo');
assert_eq(wfdbx.setinfo([]), 0, 'setinfo NULL');
wfdbx.wfdbquiet();
assert_eq(wfdbx.putinfo('third'), -1, 'putinfo without record');
wfdbx.wfdbverbose();
assert_eq(char(readfile('newrec.info')), sprintf('#first\r\n#second\r\n'), ...
    'newrec.info');
assert_eq(wfdbx.getinfo('newrec'), 'first', 'getinfo newrec');
assert_eq(wfdbx.getinfo([]), 'second', 'getinfo');
assert(~ischar(wfdbx.getinfo([])), 'getinfo at the end');
assert_eq(wfdbx.setinfo('100s'), 0, 'setinfo 100s');
assert_eq(wfdbx.putinfo('extra'), 0, 'putinfo');
wfdbx.wfdbquit();
assert_eq(wfdbx.getinfo('100s'), ' 69 M 1085 1629 x1', 'getinfo 100s');
assert_eq(wfdbx.getinfo([]), ' Aldomet, Inderal', 'getinfo');
assert_eq(wfdbx.getinfo([]), xform, 'getinfo');
assert_eq(wfdbx.getinfo([]), 'extra', 'getinfo .info');
wfdbx.isigopen('fmt16', 8);
assert(~ischar(wfdbx.getinfo([])), 'getinfo open record');
wfdbx.wfdbquit();
% wfdb_freeinfo: getinfo([]) restarts from the first info string of the
% current input record (fmt16: its name survives wfdbquit)
assert_eq(wfdbx.getinfo('100s'), ' 69 M 1085 1629 x1', 'getinfo 100s');
assert_eq(wfdbx.getinfo([]), ' Aldomet, Inderal', 'getinfo');
wfdbx.wfdb_freeinfo();
assert_eq(wfdbx.getinfo([]), ...
    'generated by gen_records for wfdb-x conformance tests', ...
    'getinfo after wfdb_freeinfo');
wfdbx.isigopen('100s', 8);
assert(~ischar(wfdbx.getinfo([])), 'getinfo after isigopen');
wfdbx.wfdb_freeinfo();
assert_eq(wfdbx.getinfo([]), ' 69 M 1085 1629 x1', ...
    'getinfo after wfdb_freeinfo');
assert_eq(wfdbx.getinfo([]), ' Aldomet, Inderal', 'getinfo');
end

function t_msheader()
names = {'100s', 'null', '100s'};
assert_eq(wfdbx.setmsheader('msrec', names, 3), 0, 'setmsheader');
wfdbx.wfdbquiet();
assert_eq(wfdbx.setmsheader('msbad', names, 0), -1, 'setmsheader 0');
assert_eq(wfdbx.setmsheader('msbad', {'100s', 'fmt16'}, 2), -4, ...
    'setmsheader mismatch');
wfdbx.wfdbverbose();
wfdbx.wfdbquit();
assert_eq(char(readfile('msrec.hea')), sprintf(['msrec/3 2 360 45000\r\n' ...
    '100s 21600\r\nnull 1800\r\n100s 21600\r\n']), 'msrec.hea');
assert_eq(wfdbx.isigopen('msrec', 8), 2, 'isigopen msrec');
assert_eq(segs(), {'100s 21600 0', 'null 1800 21600', '100s 21600 23400'}, ...
    'getseginfo msrec');
wfdbx.isigsettime(21599);
assert_eq(vec(2), [2 975 989], 'msrec getvec');
assert_eq(vec(2), [2 -32768 -32768], 'msrec getvec');
end

function t_counter()
wfdbx.isigopen('100s', 8);
assert_eq(wfdbx.getcfreq(), 360, 'getcfreq');
assert_eq(wfdbx.getbasecount(), 0, 'getbasecount');
wfdbx.setcfreq(1000);
wfdbx.setbasecount(500.5);
assert_eq(wfdbx.getcfreq(), 1000, 'getcfreq');
assert_eq(wfdbx.getbasecount(), 500.5, 'getbasecount');
assert_eq(wfdbx.strtim('c1500.5'), 360, 'strtim c1500.5');
assert_eq(wfdbx.strtim('c500.5'), 0, 'strtim c500.5');
wfdbx.setcfreq(0);
assert_eq(wfdbx.getcfreq(), 360, 'getcfreq after setcfreq 0');
assert_eq(wfdbx.setbasetime('10:20:30 15/6/2001'), 0, 'setbasetime');
assert_eq(wfdbx.timstr(0), '[10:20:30 15/06/2001]', 'timstr 0');
assert_eq(wfdbx.timstr(360), '    0:01', 'timstr 360');
assert_eq(wfdbx.timstr(-360), '[10:20:31 15/06/2001]', 'timstr -360');
assert_eq(wfdbx.mstimstr(-1000), '[10:20:32.778 15/06/2001]', ...
    'mstimstr -1000');
assert_eq(wfdbx.setbasetime('8:00'), 0, 'setbasetime time only');
assert_eq(wfdbx.timstr(0), '[00:08:00]', 'timstr 0');
assert_eq(wfdbx.timstr(-720), '[00:08:02]', 'timstr -720');
wfdbx.wfdbquiet();
assert_eq(wfdbx.setbasetime('garbage'), -1, 'setbasetime bad');
wfdbx.wfdbverbose();
wfdbx.setcfreq(500);
wfdbx.wfdbquit();
assert_eq(wfdbx.getcfreq(), 500, 'getcfreq after wfdbquit');
wfdbx.setcfreq(0);
end

function r = cal(desc, units)
[stat, c] = wfdbx.getcal(desc, units);
if stat ~= 0
    r = {stat};
else
    r = {stat, c.low, c.high, c.scale, c.caltype, c.sigtype, c.units};
end
end

function c = mkcal(low, high, scale, sigtype, units, caltype)
c = wfdbx.calinfo();
c.low = low;
c.high = high;
c.scale = scale;
c.sigtype = sigtype;
c.units = units;
c.caltype = caltype;
end

function t_calib()
q = onCleanup(@() calib_end()); %#ok<NASGU>
assert_eq(wfdbx.calopen('wfdbcal'), 0, 'calopen');
assert_eq(cal('ECG lead II', 'mV'), {0, 0, 1, 1, 4, 'ECG', 'mV'}, 'getcal');
assert_eq(cal('ECG', 'uV'), {0, 0, 1, 1000, 4, 'ECG', 'uV'}, 'getcal');
assert_eq(cal('ABP', 'mmHg'), {0, 0, 0, 100, 3, 'ABP', 'mmHg'}, 'getcal');
assert_eq(cal('BP', []), {0, 0, 100, 100, 3, 'BP', 'mmHg'}, 'getcal');
assert_eq(cal([], []), {0, 0, 1, 1, 4, 'ECG', 'mV'}, 'getcal');
assert_eq(cal('nosuch', 'x'), {-1}, 'getcal nosuch');
test = mkcal(-1.5, 2.5, 3, 'TEST', 'xu', 1 + 4);  % DC_COUPLED | CAL_SINE
ac = mkcal(0, 0, 7, 'AC', 'yu', 0 + 8);           % AC_COUPLED | CAL_UNDEF
assert_eq(wfdbx.putcal(test), 0, 'putcal');
assert_eq(wfdbx.putcal(ac), 0, 'putcal');
assert_eq(cal('TEST signal', 'xu'), {0, -1.5, 2.5, 3, 5, 'TEST', 'xu'}, ...
    'getcal TEST');
wfdbx.flushcal();
assert_eq(cal('ECG', 'mV'), {-1}, 'getcal after flushcal');
wfdbx.putcal(test);
wfdbx.putcal(ac);
wfdbx.putcal(mkcal(1, 2, 0.25, 'SQ', 'zu', 1 + 2));
wfdbx.putcal(mkcal(1, 2, 0.25, 'SAW', 'zu', 0 + 6));
wfdbx.wfdbquiet();
assert_eq(wfdbx.newcal('my.cal'), -1, 'newcal bad name');
wfdbx.wfdbverbose();
assert_eq(wfdbx.newcal('mycal'), 0, 'newcal');
assert_eq(char(readfile('mycal')), sprintf(['TEST\t-1.5 2.5 sine 3 xu\r\n' ...
    'AC\t- - undefined 7 yu\r\nSQ\t1 2 square 0.25 zu\r\n' ...
    'SAW\t- 2 sawtooth 0.25 zu\r\n']), 'mycal');
assert_eq(wfdbx.calopen('mycal'), 0, 'calopen mycal');
assert_eq(cal('AC', 'yu'), {0, 0, 0, 7, 0, 'AC', 'yu'}, 'getcal AC');
assert_eq(cal('ECG', 'mV'), {-1}, 'getcal ECG');
assert_eq(wfdbx.calopen('+wfdbcal'), 0, 'calopen +wfdbcal');
assert_eq(cal('ECG', 'mV'), {0, 0, 1, 1, 4, 'ECG', 'mV'}, 'getcal ECG');
assert_eq(cal('SAW', []), {0, 0, 2, 0.25, 6, 'SAW', 'zu'}, 'getcal SAW');
wfdbx.wfdbquiet();
assert_eq(wfdbx.calopen('nosuch.cal'), -2, 'calopen nosuch');
end

function calib_end()
wfdbx.wfdbverbose();
wfdbx.flushcal();
end

function r = ann(n)
% getann: status, time, anntyp, subtyp, chan, num
[stat, a] = wfdbx.getann(n);
r = [stat a.time a.anntyp a.subtyp a.chan a.num];
end

function t_annot()
assert_eq(wfdbx.getafreq(), 0, 'getafreq default');
wfdbx.isigopen('100s', 8);
ai = [wfdbx.anninfo('atr', 0), wfdbx.anninfo('ooo', 0)];
assert_eq(wfdbx.annopen('100s', ai), 0, 'annopen');
assert_eq([wfdbx.getiafreq(0) wfdbx.getiafreq(1) wfdbx.getiafreq(2)], ...
    [360 360 -2], 'getiafreq');
assert_eq([wfdbx.getiaorigfreq(0) wfdbx.getiaorigfreq(1) ...
    wfdbx.getiaorigfreq(2)], [0 360 -2], 'getiaorigfreq');
assert_eq(ann(0), [0 18 28 0 0 0], 'getann');
assert_eq(ann(0), [0 77 1 0 0 0], 'getann');
wfdbx.setiafreq(0, 1000);
assert_eq(wfdbx.getiafreq(0), 1000, 'getiafreq after setiafreq');
assert_eq(wfdbx.getiaorigfreq(0), 0, 'getiaorigfreq after setiafreq');
[stat, a] = wfdbx.getann(0);
assert_eq([stat a.time a.anntyp], [0 1028 1], 'getann 1000');
wfdbx.wfdbquiet();
assert_eq(wfdbx.ungetann(0, a), 0, 'ungetann');
assert_eq(wfdbx.ungetann(0, a), -1, 'ungetann full');
assert_eq(wfdbx.ungetann(5, a), -2, 'ungetann 5');
wfdbx.wfdbverbose();
assert_eq(ann(0), [0 1028 1 0 0 0], 'getann after ungetann');
assert_eq(ann(0), [0 1839 1 0 0 0], 'getann');
a.time = 5;
a.anntyp = wfdbx.PVC();
assert_eq(wfdbx.ungetann(0, a), 0, 'ungetann other');
assert_eq(ann(0), [0 5 5 0 0 0], 'getann after ungetann other');
wfdbx.setiafreq(0, 0);
assert_eq(wfdbx.getiafreq(0), 360, 'getiafreq after setiafreq 0');
assert_eq(ann(0), [0 946 1 0 0 0], 'getann');
wfdbx.iannclose(0);        % annotator 1 (ooo) becomes annotator 0
assert_eq([wfdbx.getiafreq(0) wfdbx.getiafreq(1)], [360 -2], ...
    'getiafreq after iannclose');
assert_eq(ann(0), [0 18 1 0 0 0], 'getann ooo');
wfdbx.wfdbquiet();
assert_eq(wfdbx.getann(1), -2, 'getann 1 after iannclose');
wfdbx.iannclose(0);
assert_eq(wfdbx.getann(0), -2, 'getann 0 after iannclose');
wfdbx.iannclose(3);
wfdbx.wfdbverbose();
end

function t_afreq()
wfdbx.setafreq(1000);
assert_eq(wfdbx.getafreq(), 1000, 'getafreq');
wfdbx.annopen('100s', wfdbx.anninfo('hf', wfdbx.WFDB_WRITE()));
a = wfdbx.annotation();
a.anntyp = wfdbx.NORMAL();
a.time = 1000;
wfdbx.putann(0, a);
a.time = 2500;
wfdbx.putann(0, a);
wfdbx.wfdbquit();
assert_eq(wfdbx.getafreq(), 1000, 'getafreq after wfdbquit');
wfdbx.setafreq(0);
wfdbx.annopen('100s', wfdbx.anninfo('hf', 0));
assert_eq(wfdbx.getiafreq(0), 1000, 'hf getiafreq');
assert_eq(wfdbx.getiaorigfreq(0), 1000, 'hf getiaorigfreq');
assert_eq(ann(0), [0 1000 1 0 0 0], 'hf getann');
wfdbx.setiafreq(0, 360);
assert_eq(wfdbx.getiafreq(0), 360, 'hf getiafreq 360');
assert_eq(ann(0), [0 900 1 0 0 0], 'hf getann 360');
end

function t_ecgstr()
assert_eq({wfdbx.ecgstr(1), wfdbx.ecgstr(0), wfdbx.ecgstr(15), ...
    wfdbx.ecgstr(22), wfdbx.ecgstr(50), wfdbx.ecgstr(-1)}, ...
    {'N', ' ', '[15]', '"', '[50]', '[-1]'}, 'ecgstr');
assert_eq([wfdbx.strecg('V') wfdbx.strecg('xx') wfdbx.strecg('') ...
    wfdbx.strecg('[15]')], [5 0 0 15], 'strecg');
q = onCleanup(@() ecgstr_end()); %#ok<NASGU>
assert_eq(wfdbx.setecgstr(5, 'PVC'), 0, 'setecgstr 5');
assert_eq(wfdbx.ecgstr(5), 'PVC', 'ecgstr 5');
assert_eq(wfdbx.annstr(5), 'V', 'annstr 5');
assert_eq([wfdbx.strecg('PVC') wfdbx.strecg('V')], [5 0], 'strecg');
wfdbx.wfdbquiet();
assert_eq(wfdbx.setecgstr(50, 'x'), -1, 'setecgstr 50');
assert_eq(wfdbx.setecgstr(-1, 'x'), -1, 'setecgstr -1');
wfdbx.wfdbverbose();
assert_eq(wfdbx.setecgstr(0, 'Z'), 0, 'setecgstr 0');
assert_eq(wfdbx.ecgstr(0), 'Z', 'ecgstr 0');
end

function ecgstr_end()
wfdbx.wfdbverbose();
wfdbx.setecgstr(5, 'V');
wfdbx.setecgstr(0, ' ');
end

function t_strings()
% (the flags of modified codes and the NULL descriptions, which no library
% function restores, are restored from a copy of the state)
st = wfdbx.internal.annstate();
saved = {st.astring, st.tstring, st.modified};
q = onCleanup(@() strings_end(saved)); %#ok<NASGU>
assert_eq(wfdbx.setannstr(5, 'pvc'), 0, 'setannstr 5');
assert_eq(wfdbx.annstr(5), 'pvc', 'annstr 5');
assert_eq(wfdbx.ecgstr(5), 'V', 'ecgstr 5');
assert_eq([wfdbx.strann('pvc') wfdbx.strann('V')], [5 0], 'strann');
assert_eq(wfdbx.setannstr(-6, 'fus'), 0, 'setannstr -6');
assert_eq(wfdbx.annstr(6), 'fus', 'annstr 6');
wfdbx.wfdbquiet();
assert_eq(wfdbx.setannstr(60, 'x'), -1, 'setannstr 60');
assert_eq(wfdbx.setannstr(-60, 'x'), -1, 'setannstr -60');
wfdbx.wfdbverbose();
assert_eq(wfdbx.setannstr(0, 'zero'), 0, 'setannstr 0');
assert_eq(wfdbx.annstr(0), 'zero', 'annstr 0');
assert_eq(wfdbx.annstr(60), '[60]', 'annstr 60');
assert_eq(wfdbx.setannstr(42, 'new'), 0, 'setannstr 42');
assert_eq(wfdbx.strann('new'), 42, 'strann new');
assert_eq(wfdbx.anndesc(1), 'Normal beat', 'anndesc 1');
assert(~ischar(wfdbx.anndesc(15)), 'anndesc 15 is NULL');
assert_eq(wfdbx.anndesc(60), 'illegal annotation code', 'anndesc 60');
assert_eq(wfdbx.anndesc(-1), 'illegal annotation code', 'anndesc -1');
assert_eq(wfdbx.setanndesc(15, 'my description'), 0, 'setanndesc 15');
assert_eq(wfdbx.anndesc(15), 'my description', 'anndesc 15');
assert_eq(wfdbx.setanndesc(-43, 'negative'), 0, 'setanndesc -43');
assert_eq(wfdbx.anndesc(43), 'negative', 'anndesc 43');
wfdbx.wfdbquiet();
assert_eq(wfdbx.setanndesc(50, 'x'), -1, 'setanndesc 50');
wfdbx.wfdbverbose();

% Modified mnemonics (but not those set with a negative code) are written
% into output annotation files ...
wfdbx.annopen('100s', wfdbx.anninfo('mod', wfdbx.WFDB_WRITE()));
a = wfdbx.annotation();
a.time = 10;
a.anntyp = wfdbx.PVC();
wfdbx.putann(0, a);
wfdbx.wfdbquit();
assert_eq(readfile('100s.mod'), [unhex('0058 1efc') ...
    uint8('## annotation type definitions') unhex('0058 27fc') ...
    uint8('5 pvc Premature ventricular contraction') unhex('00 0058 16fc') ...
    uint8('15 [15] my description') unhex('0058 07fc') uint8('42 new ') ...
    unhex('00 0058 15fc') uint8('## end of definitions') ...
    unhex('00 00ec ffff ffff 0100 0a14 0000')], '100s.mod');
wfdbx.setannstr(5, 'V');
wfdbx.setannstr(-6, 'F');
wfdbx.setannstr(0, ' ');
wfdbx.setannstr(-42, '[42]');
wfdbx.setanndesc(-15, '');
wfdbx.setanndesc(-43, '');
% ... and reading the file defines them again.
wfdbx.annopen('100s', wfdbx.anninfo('mod', 0));
assert_eq(ann(0), [0 10 5 0 0 0], 'getann mod');
assert_eq(wfdbx.annstr(5), 'pvc', 'annstr 5 after reading');
assert_eq(wfdbx.anndesc(15), 'my description', 'anndesc 15 after reading');
assert_eq(wfdbx.anndesc(42), '', 'anndesc 42 after reading');
wfdbx.wfdbquit();
end

function strings_end(saved)
wfdbx.wfdbverbose();
st = wfdbx.internal.annstate();
st.astring = saved{1};
st.tstring = saved{2};
st.modified = saved{3};
end

function t_maps()
% code isann isqrs map1 map2 annpos mamap(code, 0) mamap(code, -1)
maps = [
    -1 0 0 0 0 0 79 79; 0 0 0 0 0 0 79 79; 1 1 1 1 1 1 78 78
    2 1 1 1 1 1 78 78; 3 1 1 1 1 1 78 78; 4 1 1 1 9 1 78 78
    5 1 1 5 5 1 86 86; 6 1 1 6 6 1 70 70; 7 1 1 1 9 1 78 78
    8 1 1 1 9 1 78 78; 9 1 1 1 9 1 78 78; 10 1 1 5 5 1 69 69
    11 1 1 1 1 1 78 78; 12 1 1 1 1 1 80 80; 13 1 1 1 1 1 81 81
    14 1 0 0 0 2 79 85; 15 1 0 0 0 0 79 79; 16 1 0 0 0 2 79 79
    17 1 0 0 0 0 79 79; 18 1 0 0 0 2 79 79; 19 1 0 0 0 2 79 79
    20 1 0 0 0 2 79 79; 21 1 0 0 0 2 79 79; 22 1 0 0 0 2 79 79
    23 1 0 0 0 2 79 79; 24 1 0 0 0 2 79 79; 25 1 1 1 1 1 78 78
    26 1 0 0 0 2 79 79; 27 1 0 0 0 2 79 79; 28 1 0 0 0 3 79 79
    29 1 0 0 0 2 79 79; 30 1 1 30 30 1 81 81; 31 1 1 5 5 1 79 79
    32 1 0 0 0 1 91 91; 33 1 0 0 0 1 93 93; 34 1 1 1 1 1 78 78
    35 1 1 1 1 1 78 78; 36 1 0 0 0 2 79 79; 37 1 0 0 0 2 79 79
    38 1 1 1 1 1 78 78; 39 1 0 0 0 2 79 79; 40 1 0 0 0 2 79 79
    41 1 1 5 5 1 82 82; 42 1 0 0 0 0 79 79; 43 1 0 0 0 0 79 79
    44 1 0 0 0 0 79 79; 45 1 0 0 0 0 79 79; 46 1 0 0 0 0 79 79
    47 1 0 0 0 0 79 79; 48 1 0 0 0 0 79 79; 49 1 0 0 0 0 79 79
    50 0 0 0 0 0 79 79];
for k = 1:size(maps, 1)
    c = maps(k, 1);
    got = [c wfdbx.wfdb_isann(c) wfdbx.wfdb_isqrs(c) wfdbx.wfdb_map1(c) ...
        wfdbx.wfdb_map2(c) wfdbx.wfdb_annpos(c) wfdbx.wfdb_mamap(c, 0) ...
        wfdbx.wfdb_mamap(c, -1)];
    assert_eq(got, maps(k, :), sprintf('maps of code %d', c));
end
ammaps = [0 0 10 6 0 0 0 0 0 0 0 1 22 12 13 41 0 0 14 5 0 0 0 0 32 0 33 0 0];
got = zeros(1, numel(ammaps));
for c = double('C'):double('_')
    got(c - double('C') + 1) = wfdbx.wfdb_ammap(c);
end
assert_eq(got, ammaps, 'ammap');
q = onCleanup(@() maps_end()); %#ok<NASGU>
assert_eq(wfdbx.wfdb_setisqrs(1, 0), 0, 'setisqrs 1 0');
assert_eq(wfdbx.wfdb_isqrs(1), 0, 'isqrs 1');
assert_eq(wfdbx.wfdb_setisqrs(60, 1), 0, 'setisqrs 60 1');
assert_eq(wfdbx.wfdb_setisqrs(2, 300), 44, 'setisqrs 2 300 (a char)');
assert_eq(wfdbx.wfdb_isqrs(2), 44, 'isqrs 2');
assert_eq(wfdbx.wfdb_setmap1(14, wfdbx.PVC()), 5, 'setmap1 14 PVC');
assert_eq(wfdbx.wfdb_map1(14), 5, 'map1 14');
assert_eq(wfdbx.wfdb_setmap1(0, wfdbx.PVC()), 0, 'setmap1 0 PVC');
assert_eq(wfdbx.wfdb_setmap2(14, wfdbx.SVPB()), 9, 'setmap2 14 SVPB');
assert_eq(wfdbx.wfdb_map2(14), 9, 'map2 14');
assert_eq(wfdbx.wfdb_setmap2(-3, wfdbx.PVC()), 0, 'setmap2 -3 PVC');
assert_eq(wfdbx.wfdb_setannpos(14, 6), 6, 'setannpos 14 6');
assert_eq(wfdbx.wfdb_annpos(14), 6, 'annpos 14');
assert_eq(wfdbx.wfdb_setannpos(50, 2), 0, 'setannpos 50 2');
end

function maps_end()
wfdbx.wfdb_setisqrs(1, 1);
wfdbx.wfdb_setisqrs(2, 1);
wfdbx.wfdb_setmap1(14, wfdbx.NOTQRS());
wfdbx.wfdb_setmap2(14, wfdbx.NOTQRS());
wfdbx.wfdb_setannpos(14, 2);
end

function t_extra()
% default calibration file ($WFDBCAL: wfdbcal, set by setwfdb)
q = onCleanup(@() wfdbx.flushcal()); %#ok<NASGU>
assert_eq(wfdbx.calopen([]), 0, 'calopen NULL');
assert_eq(cal('Resp', []), {0, 0, 0, 1, 0, 'Resp', 'l'}, 'getcal Resp');
% uncalibrated signals (gain 0; wfdb-x: reported as errors)
wfdbx.isigopen('null', 8);
wfdbx.wfdbquiet();
q2 = onCleanup(@() quiet_end()); %#ok<NASGU>
assert_eq([wfdbx.adumuv(0, 100) wfdbx.muvadu(1, 100)], [-32768 -32768], ...
    'null adumuv');
assert_eq([isnan(wfdbx.aduphys(0, 100)) wfdbx.physadu(1, 0.5)], ...
    [1 -32768], 'null aduphys');
assert_eq(vec(2), [2 -32768 -32768], 'null getvec');
wfdbx.wfdbquit();
% deskewing by getframe
wfdbx.isigopen('skew', 8);
assert_eq(vec(3, @wfdbx.getframe), [3 -7 21 -32768], 'skew getframe');
assert_eq(vec(3, @wfdbx.getframe), [3 4 -14 -85], 'skew getframe');
wfdbx.isigsettime(1497);
assert_eq(vec(3, @wfdbx.getframe), [-1 -32755 16705 -32768], ...
    'skew getframe 1497');
assert_eq(vec(3, @wfdbx.getframe), [-1 -32751 -14 16705], ...
    'skew getframe 1498');
wfdbx.wfdbquit();
% resampling and sample() of a multi-frequency record
wfdbx.isigopen('mfreq', 8);
assert_eq(wfdbx.setifreq(200), 0, 'mfreq setifreq 200');
assert_eq(vec(3), [3 138 1459 499], 'mfreq getvec 200');
assert_eq(vec(3), [3 2677 738 1381], 'mfreq getvec 200');
assert_eq(vec(3), [3 2677 738 1381], 'mfreq getvec 200');
assert_eq(wfdbx.getafreq(), 200, 'getafreq after setifreq');
wfdbx.setafreq(0);
wfdbx.wfdbquit();
wfdbx.isigopen('mfreq', 8);
v = wfdbx.sample(2, 10);
assert_eq([v wfdbx.sample_valid()], [869 1], 'mfreq sample 2 10');
v = wfdbx.sample(1, 599);
assert_eq([v wfdbx.sample_valid()], [637 1], 'mfreq sample 1 599');
wfdbx.wfdbquit();
wfdbx.isigopen('multi', 8);
assert_eq(wfdbx.isigsettime(100), 0, 'isigsettime multi 100');
assert_eq(wfdbx.tnextvec(0, 21650), 23450, 'tnextvec multi 0 21650');
assert_eq(vec(2), [2 969 996], 'multi getvec');
end

% ---------------------------------------------------------------------------

function b = readfile(name)
fid = fopen(name, 'rb');
b = fread(fid, inf, 'uint8=>uint8')';
fclose(fid);
end

function n = fsize(name)
s = dir(name);
n = s.bytes;
end

function b = unhex(h)
h = h(h ~= ' ');
b = uint8(hex2dec(reshape(h, 2, [])'))';
end

function restore(old, oldpath, d)
wfdbx.wfdbquit();
wfdbx.setwfdb(oldpath);
cd(old);
rmdir(d, 's');
end

function t_flacseek()
% After a failed seek (past the end of a FLAC stream), libFLAC aborts the
% decoding of the next block in the C library: getvec fails, and so do
% later seeks; a seek to the current time is not performed.
assert_eq(wfdbx.isigopen('flac16', 8), 3, 'isigopen flac16');
assert_eq(wfdbx.isigsettime(99999), -1, 'flac isigsettime 99999');
assert_eq(vec(3), [-3 0 0 0], 'flac getvec after failed seek');
assert_eq(wfdbx.isigsettime(0), -1, 'flac isigsettime 0 after abort');
assert_eq(vec(3), [-3 0 0 0], 'flac getvec after abort');
wfdbx.wfdbquit();
wfdbx.isigopen('flac16', 8);
assert_eq(wfdbx.isigsettime(99999), -1, 'flac isigsettime 99999');
assert_eq(wfdbx.isigsettime(5), 0, 'flac isigsettime 5 after failed seek');
assert_eq(vec(3), [3 -77 -57 -47], 'flac getvec 5');
wfdbx.wfdbquit();
wfdbx.isigopen('flac16', 8);
assert_eq(vec(3), [3 -31 -38 -33], 'flac getvec 0');
assert_eq(wfdbx.isigsettime(9001), -1, 'flac isigsettime 9001');
assert_eq(wfdbx.isigsettime(1), 0, 'flac isigsettime 1 (current time)');
assert_eq(vec(3), [-3 0 0 0], 'flac getvec after failed seek');
wfdbx.wfdbquit();
end

function t_strtim_range()
% Frame numbers without a record and times out of the range of WFDB_Time:
% the C conversion of the double gives LONG_MIN on x86-64.  (wfdb-x:
% without a sampling frequency, strtim reports an error and returns 0.)
wfdbx.wfdbquiet();
q = onCleanup(@() strtim_range_end()); %#ok<NASGU>
assert_eq(wfdbx.strtim('f5'), 0, 'strtim f5 (no frequency)');
assert_eq(wfdbx.strtim('f0'), 0, 'strtim f0 (no frequency)');
assert_eq(wfdbx.strtim('1e300'), 0, 'strtim 1e300 (no frequency)');
wfdbx.setsampfreq(1);
assert_eq(wfdbx.strtim('1e300'), -2^63, 'strtim 1e300');
assert_eq(wfdbx.strtim('1:1e300'), -2^63, 'strtim 1:1e300');
end

function strtim_range_end()
wfdbx.setsampfreq(0);
wfdbx.wfdbverbose();
end

function t_nodefaults()
% wfdb-x: no default sampling frequency or gain (docs/DIVERGENCES.md)
ts = {'s10', 'e', 'i', 'o', 'c10', 'f3', '10', '1:0', '[10:00:00]', ...
    ' s5', ''};
wfdbx.setcfreq(500);        % (as left by t_counter in api_expect.c)
assert_eq(cellfun(@wfdbx.wfdbx_time_needs_freq, ts), ...
    [0 0 0 0 1 1 1 1 1 0 1], 'wfdbx_time_needs_freq');
wfdbx.setcfreq(0);
assert_eq(wfdbx.wfdbx_time_needs_freq('c10'), 0, ...
    'wfdbx_time_needs_freq c10 (no counter frequency)');
assert_eq(wfdbx.wfdbx_time_needs_freq(sprintf('\t\r\n e')), 0, ...
    'wfdbx_time_needs_freq (leading white space)');
wfdbx.wfdbquiet();
q = onCleanup(@() quiet_end()); %#ok<NASGU>
% no input record: no sampling frequency
assert_eq(wfdbx.strtim('1:0'), 0, 'strtim 1:0 (no frequency)');
assert_eq(wfdbx.wfdberror(), ...
    sprintf('strtim: sampling frequency is not specified\n'), 'error');
assert_eq(wfdbx.strtim('s10'), 10, 'strtim s10 (no frequency)');
assert_eq(wfdbx.timstr(360), 's360', 'timstr 360 (no frequency)');
assert_eq(wfdbx.wfdberror(), ...
    sprintf('timstr: sampling frequency is not specified\n'), 'error');
assert_eq(wfdbx.mstimstr(-360), 's360', 'mstimstr -360 (no frequency)');
assert_eq(wfdbx.wfdberror(), ...
    sprintf('mstimstr: sampling frequency is not specified\n'), 'error');
% a header without a sampling frequency
fid = fopen('nf.hea', 'wb');
fwrite(fid, uint8(sprintf(['nf 2\n100s.dat 212 200 11 1024 995 21537 0 ' ...
    'MLII\n100s.dat 212 200 11 1024 1011 -3962 0 V5\n'])));
fclose(fid);
assert_eq(wfdbx.isigopen('nf', 8), 2, 'isigopen nf');
assert_eq(wfdbx.sampfreq([]), 0, 'sampfreq nf');
assert_eq(wfdbx.getifreq(), 0, 'getifreq nf');
assert_eq(wfdbx.setifreq(100), -1, 'setifreq 100 (nf)');
assert_eq(wfdbx.wfdberror(), ...
    sprintf('setifreq: sampling frequency is not specified\n'), 'error');
assert_eq(wfdbx.strtim('2'), 0, 'strtim 2 (nf)');
assert_eq(wfdbx.strtim('e'), 0, 'strtim e (nf)');
assert_eq(wfdbx.mstimstr(100), 's100', 'mstimstr 100 (nf)');
wfdbx.wfdbquit();
% a frequency set by the caller applies
assert_eq(wfdbx.setsampfreq(500), 0, 'setsampfreq 500');
assert_eq(wfdbx.isigopen('nf', 8), 2, 'isigopen nf after setsampfreq');
assert_eq(wfdbx.sampfreq([]), 500, 'sampfreq');
assert_eq(wfdbx.strtim('2'), 1000, 'strtim 2');
assert_eq(wfdbx.mstimstr(100), '    0:00.200', 'mstimstr 100');
wfdbx.wfdbquit();
assert_eq(wfdbx.sampfreq('nf'), 0, 'sampfreq nf (record)');
wfdbx.wfdbquit();
% uncalibrated signals (record null) and invalid signal numbers
wfdbx.isigopen('null', 8);
assert_eq(isnan(wfdbx.aduphys(0, 100)), true, 'aduphys 0 100 (uncalibrated)');
assert_eq(wfdbx.wfdberror(), ...
    sprintf('aduphys: signal 0 is uncalibrated\n'), 'error');
assert_eq(wfdbx.physadu(0, 1.0), -32768, 'physadu 0 1.0 (uncalibrated)');
assert_eq(wfdbx.wfdberror(), ...
    sprintf('physadu: signal 0 is uncalibrated\n'), 'error');
assert_eq(wfdbx.adumuv(1, 100), -32768, 'adumuv 1 100 (uncalibrated)');
assert_eq(wfdbx.muvadu(1, 100), -32768, 'muvadu 1 100 (uncalibrated)');
assert_eq(wfdbx.wfdberror(), ...
    sprintf('muvadu: signal 1 is uncalibrated\n'), 'error');
wfdbx.wfdbquit();
wfdbx.isigopen('100s', 8);
assert_eq(wfdbx.aduphys(0, 1124), 0.5, 'aduphys 0 1124');
assert_eq(wfdbx.physadu(1, -0.5), 924, 'physadu 1 -0.5');
assert_eq(wfdbx.adumuv(0, 100), 500, 'adumuv 0 100');
assert_eq(wfdbx.muvadu(0, 1000), 200, 'muvadu 0 1000');
assert_eq(isnan(wfdbx.aduphys(5, 100)), true, ...
    'aduphys 5 100 (invalid signal)');
assert_eq(wfdbx.wfdberror(), ...
    sprintf('aduphys: invalid signal number 5\n'), 'error');
assert_eq(wfdbx.physadu(5, 1.0), -32768, 'physadu 5 1.0 (invalid signal)');
assert_eq(wfdbx.adumuv(2, 100), -32768, 'adumuv 2 100 (invalid signal)');
assert_eq(wfdbx.muvadu(2, 100), -32768, 'muvadu 2 100 (invalid signal)');
assert_eq(wfdbx.wfdberror(), ...
    sprintf('muvadu: invalid signal number 2\n'), 'error');
wfdbx.wfdbquit();
% no default ADC resolution: 0 if the header does not give it
fid = fopen('nr.hea', 'wb');
fwrite(fid, uint8(sprintf('nr 2 360 21600\n100s.dat 212 200\n100s.dat 212 200\n')));
fclose(fid);
[n, si] = wfdbx.isigopen('nr', 8);
assert_eq(n, 2, 'isigopen nr');
assert_eq([si.adcres], [0 0], 'nr adcres');
assert_eq(si(1).units, [], 'nr units');
wfdbx.wfdbquit();
[n, si] = wfdbx.isigopen('100s', 8); %#ok<ASGLU>
assert_eq([si.adcres], [11 11], '100s adcres');
wfdbx.wfdbquit();
end

function t_legacy()
% wfdb-x legacy mode (wfdbx_set_legacy, docs/DIVERGENCES.md): the original
% library's built-in defaults (t_legacy of api_expect.c; nf.hea and nr.hea
% were written by t_nodefaults)
assert_eq(wfdbx.wfdbx_set_legacy(1), 0, 'wfdbx_set_legacy 1');
q = onCleanup(@() legacy_end()); %#ok<NASGU>
assert_eq(wfdbx.wfdbx_get_legacy(), 1, 'wfdbx_get_legacy');
% amplitude conversion (gain 200, baseline 1024; invalid signal numbers:
% gain 200, baseline 0)
wfdbx.isigopen('100s', 8);
assert_eq([wfdbx.adumuv(0, 200), wfdbx.adumuv(0, -37), wfdbx.adumuv(1, 1), ...
    wfdbx.adumuv(0, -1), wfdbx.adumuv(7, 100)], [1000 -185 5 -5 500], ...
    'legacy adumuv');
assert_eq([wfdbx.muvadu(0, 1000), wfdbx.muvadu(0, -333), wfdbx.muvadu(1, 2), ...
    wfdbx.muvadu(9, 1000)], [200 -67 0 200], 'legacy muvadu');
assert_eq(wfdbx.aduphys(0, 1224), 1, 'legacy aduphys 0 1224');
assert_eq(wfdbx.aduphys(1, 900), -0.62, 'legacy aduphys 1 900');
assert_eq(wfdbx.aduphys(5, 300), 1.5, 'legacy aduphys 5 300 (invalid signal)');
assert_eq([wfdbx.physadu(0, 1.0), wfdbx.physadu(1, -0.5023), ...
    wfdbx.physadu(5, 1.5)], [1224 924 300], 'legacy physadu');
assert_eq(wfdbx.aduphys(5, 100), 0.5, 'legacy aduphys 5 100 (invalid signal)');
assert_eq(wfdbx.physadu(5, 1.0), 200, 'legacy physadu 5 1.0 (invalid signal)');
assert_eq(wfdbx.adumuv(2, 100), 500, 'legacy adumuv 2 100 (invalid signal)');
assert_eq(wfdbx.muvadu(2, 100), 20, 'legacy muvadu 2 100 (invalid signal)');
wfdbx.wfdbquit();
% uncalibrated signals (record null): gain 200
wfdbx.isigopen('null', 8);
assert_eq([wfdbx.adumuv(0, 100), wfdbx.muvadu(1, 100)], [500 20], ...
    'legacy null adumuv');
assert_eq(wfdbx.aduphys(0, 100), 0.5, 'legacy null aduphys 0 100');
assert_eq(wfdbx.physadu(1, 0.5), 100, 'legacy null physadu 1 0.5');
assert_eq(wfdbx.physadu(0, 1.0), 200, 'legacy null physadu 0 1.0');
wfdbx.wfdbquit();
wfdbx.wfdbquiet();
% no input record: 1 sample per second
assert_eq(wfdbx.strtim('1:0'), 60, 'legacy strtim 1:0 (no frequency)');
assert_eq(wfdbx.strtim('s10'), 10, 'legacy strtim s10 (no frequency)');
assert_eq(wfdbx.timstr(360), '    6:00', 'legacy timstr 360 (no frequency)');
assert_eq(wfdbx.mstimstr(-360), '    6:00.000', ...
    'legacy mstimstr -360 (no frequency)');
% a header without a sampling frequency: 250 Hz
assert_eq(wfdbx.isigopen('nf', 8), 2, 'legacy isigopen nf');
assert_eq(wfdbx.sampfreq([]), 250, 'legacy sampfreq nf');
assert_eq(wfdbx.getifreq(), 250, 'legacy getifreq nf');
assert_eq(wfdbx.strtim('2'), 500, 'legacy strtim 2 (nf)');
assert_eq(wfdbx.strtim('e'), 0, 'legacy strtim e (nf)');
assert_eq(wfdbx.mstimstr(100), '    0:00.400', 'legacy mstimstr 100 (nf)');
assert_eq(wfdbx.setifreq(100), 0, 'legacy setifreq 100 (nf)');
assert_eq(wfdbx.getifreq(), 100, 'legacy getifreq nf');
wfdbx.wfdbquit();
assert_eq(wfdbx.sampfreq('nf'), 250, 'legacy sampfreq nf (record)');
wfdbx.wfdbquit();
% setifreq with an input record but no frequency
wfdbx.isigopen('100s', 8);
wfdbx.setsampfreq(0);
assert_eq(wfdbx.setifreq(100), -1, 'legacy setifreq 100 (frequency 0)');
assert_eq(wfdbx.wfdberror(), sprintf('setifreq: no open input record\n'), ...
    'error');
wfdbx.wfdbquit();
% ADC resolution inferred from the format, or WFDB_DEFRES
[n, si] = wfdbx.isigopen('nr', 8);
assert_eq(n, 2, 'legacy isigopen nr');
assert_eq([si.adcres], [12 12], 'legacy nr adcres');
wfdbx.wfdbquit();
fid = fopen('nr3.hea', 'wb');
fwrite(fid, uint8(sprintf(['nr3 5 360 10\nfmt16.dat 16\nfmt80.dat 80\n' ...
    'fmt310.dat 310\nfmt160.dat 160\nfmt24.dat 24\n'])));
fclose(fid);
[n, si] = wfdbx.isigopen('nr3', 8);
assert_eq(n, 5, 'legacy isigopen nr3');
assert_eq([si.adcres], [12 8 10 16 12], 'legacy nr3 adcres');
wfdbx.wfdbquit();
wfdbx.wfdbverbose();
assert_eq(wfdbx.wfdbx_set_legacy(0), 1, 'wfdbx_set_legacy 0');
assert_eq(wfdbx.wfdbx_get_legacy(), 0, 'wfdbx_get_legacy');
% wfdbx_legacy_args: only a first argument --legacy is recognized
[r, a] = wfdbx.wfdbx_legacy_args({'rdsamp', '--legacy', '-r', '100s'});
assert_eq(r, 1, 'wfdbx_legacy_args (--legacy first)');
assert_eq(a, {'rdsamp', '-r', '100s'}, 'wfdbx_legacy_args argv');
assert_eq(wfdbx.wfdbx_get_legacy(), 1, 'wfdbx_legacy_args turns legacy on');
wfdbx.wfdbx_set_legacy(0);
[r, a] = wfdbx.wfdbx_legacy_args({'rdsamp', '-r', '--legacy'});
assert_eq(r, 0, 'wfdbx_legacy_args (--legacy not first)');
assert_eq(a, {'rdsamp', '-r', '--legacy'}, 'wfdbx_legacy_args argv unchanged');
[r, a] = wfdbx.wfdbx_legacy_args({'rdsamp'});
assert_eq([r, numel(a), wfdbx.wfdbx_get_legacy()], [0 1 0], ...
    'wfdbx_legacy_args (no arguments)');
end

function legacy_end()
wfdbx.wfdbx_set_legacy(0);
wfdbx.setafreq(0);      % (set by setifreq; it survives wfdbquit)
wfdbx.wfdbverbose();
end
