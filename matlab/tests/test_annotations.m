function test_annotations()
%TEST_ANNOTATIONS Annotation I/O tests (annopen, getann, putann, ...).

% Part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

here = fileparts(mfilename('fullpath'));
data = fullfile(fileparts(fileparts(here)), 'tests', 'data');
old = pwd();
oldpath = getenv('WFDB');
d = tempname();
mkdir(d);
cleanup = onCleanup(@() restore(old, oldpath, d)); %#ok<NASGU>
cd(d);
wfdbx.wfdbquit();
wfdbx.setwfdb(['. ' data]);
C = wfdbx.ecgcodes();

% high-level reading
a = wfdbx.read_annotations('100s', 'atr');
assert_eq(numel(a.samples), 75, 'number of annotations');
assert_eq(a.symbols(1:3), {'+'; 'N'; 'N'}, 'symbols');
assert_eq(a.aux{1}, '(N', 'aux');
assert_eq(a.fs, 360, 'fs');
b = wfdbx.read_annotations('100s', 'atr', 'sampfrom', 1000, 'sampto', '0:30');
k = a.samples >= 1000 & a.samples < 10800;
assert_eq(b.samples, a.samples(k), 'sampfrom/sampto');

% getann one at a time and in bulk give the same annotations
wfdbx.annopen('100s', wfdbx.anninfo('atr', wfdbx.WFDB_READ()));
n = 0;
while true
    [stat, x] = wfdbx.getann(0);
    if stat ~= 0
        break;
    end
    n = n + 1;
    assert_eq([x.time x.anntyp x.subtyp x.chan x.num], ...
        [a.samples(n) a.codes(n) a.subtypes(n) a.chans(n) a.nums(n)], 'getann');
end
assert_eq([stat n], [-1 75], 'getann at the end');
[stat, y] = wfdbx.getann(0, x);
assert_eq(stat, -1, 'getann after the end');
assert(isequal(y, x), 'annot unchanged at the end');
% iannsettime, ungetann
assert_eq(wfdbx.iannsettime(1000), 0, 'iannsettime');
[~, x] = wfdbx.getann(0);
assert_eq(x.time, a.samples(find(a.samples >= 1000, 1)), 'time after iannsettime');
assert_eq(wfdbx.ungetann(0, x), 0, 'ungetann');
wfdbx.wfdbquiet();
assert_eq(wfdbx.ungetann(0, x), -1, 'pushback buffer full');
wfdbx.wfdbverbose();
[~, y] = wfdbx.getann(0);
assert(isequal(x, y), 'pushed-back annotation');
[stat, B] = wfdbx.internal.getann_bulk(0, inf);
assert_eq(stat, -1, 'bulk status');
assert_eq(B.time, a.samples(find(a.samples > x.time, 1):end).', 'bulk times');
wfdbx.wfdbquit();

% write and read back (times beyond 2^32, out-of-range chan/num, long aux)
samples = [0, 5, 5, 5, 300, 70000, 70001, 5000000000, 5000000000];
codes = [C.NOTE, C.NORMAL, C.NORMAL, C.NORMAL, C.PVC, C.ARFCT, C.RHYTHM, ...
    C.NORMAL, C.NOISE];
chans = [0, 0, 1, 1, 0, 3, 0, 0, 2];
nums = [0, 0, 0, 2, 0, -1, 0, 0, 1];
sub = [0, 0, 0, 0, 3, 0, 0, 0, -1];
aux = {'start', [], [], [], [], [], '(AFIB', [], repmat('x', 1, 200)};
wfdbx.write_annotations('100s', 'rt', samples, 'codes', codes, 'chans', ...
    chans, 'nums', nums, 'subtypes', sub, 'aux', aux);
wfdbx.wfdbquiet();
r = wfdbx.read_annotations('100s', 'rt');
wfdbx.wfdbverbose();
% (the NOTE at time 0 is consumed as a modification label by annopen)
assert_eq(r.samples, samples(2:end).', 'rt samples');
assert_eq(r.codes, codes(2:end).', 'rt codes');
assert_eq(r.chans, chans(2:end).', 'rt chans');
assert_eq(r.nums, nums(2:end).', 'rt nums');
assert_eq(r.subtypes, sub(2:end).', 'rt subtypes');
assert_eq(r.aux, aux(2:end).', 'rt aux');

% putann one at a time gives the same file as the bulk writer
wfdbx.annopen('100s', wfdbx.anninfo('rt2', wfdbx.WFDB_WRITE()));
x = wfdbx.annotation();
for k = 1:numel(samples)
    x.time = samples(k);
    x.anntyp = codes(k);
    x.subtyp = sub(k);
    x.chan = chans(k);
    x.num = nums(k);
    if ischar(aux{k})
        x.aux = uint8([numel(aux{k}), double(aux{k})]);
    else
        x.aux = [];
    end
    assert_eq(wfdbx.putann(0, x), 0, 'putann');
end
wfdbx.wfdbquit();
assert(isequal(readfile('100s.rt'), readfile('100s.rt2')), 'putann = putann_bulk');

% out-of-order annotations are sorted when the file is closed
old = getenv('WFDBANNSORT');
setenv('WFDBANNSORT', '1');
copyfile(fullfile(data, '100s.hea'), '100s.hea');
wfdbx.wfdbquiet();
wfdbx.write_annotations('100s', 'ooo', [300 100 200], 'codes', [1 5 1]);
wfdbx.wfdbverbose();
setenv('WFDBANNSORT', old);
r = wfdbx.read_annotations('100s', 'ooo');
assert_eq([r.samples, r.codes], [100 200 300; 5 1 1].', 'sorted by oannclose');

% wfdb-x: out-of-order annotations are sorted in this process (in legacy
% mode, by running sortann, as the C library)
sort_in_process(C);
sort_legacy_in_output_dir();
sort_list_time0();
sort_disabled(C);
sort_keeps_other_annotators(C);

% AHA format
wfdbx.annopen('100s', wfdbx.anninfo('aha', wfdbx.WFDB_AHA_WRITE()));
x = wfdbx.annotation();
for k = 2:6
    x.time = a.samples(k);
    x.anntyp = a.codes(k);
    x.aux = [];
    wfdbx.putann(0, x);
end
wfdbx.wfdbquit();
assert_eq(mod(numel(readfile('100s.aha')), 1024), 0, 'AHA file padded');
wfdbx.annopen('100s', wfdbx.anninfo('aha', wfdbx.WFDB_AHA_READ()));
[stat, B] = wfdbx.internal.getann_bulk(0, inf);
wfdbx.wfdbquit();
assert_eq(stat, -1, 'AHA status');
assert_eq(B.time, a.samples(2:6).', 'AHA times');
assert_eq(B.anntyp, a.codes(2:6).', 'AHA codes');

% crafted MIT files (expected values from the C library / Python port):
% several aux strings in one annotation, a truncated aux string at the
% end of the file, a skip at the start of the file, chan carried over.
check_file('t1', '0a0405fc48454c4c4f00031409fc6162', ...
    {'10 1 0 0 0 0548454c4c4f'}, -3);
check_file('t2', '0a0403fc78797a0002fc7071077003f402f801f001040000', ...
    {'10 1 0 0 0 027071', '17 28 3 2 1 -', '18 1 0 2 1 -'}, -1);
check_file('t3', '00ec0100a086010404f80214e80700ec000088130104', ...
    {'100001 1 0 4 0 -', '100003 5 0 4 0 -', '101003 1 0 4 0 -'}, -3);

% mnemonics and descriptions
assert_eq(wfdbx.annstr(C.NORMAL), 'N', 'annstr');
assert_eq(wfdbx.strann('V'), C.PVC, 'strann');
assert_eq(wfdbx.strann('nosuch'), 0, 'strann unknown');
assert_eq(wfdbx.anndesc(C.PVC), 'Premature ventricular contraction', 'anndesc');
assert(isempty(wfdbx.anndesc(15)), 'anndesc NULL');
assert_eq(wfdbx.anndesc(99), 'illegal annotation code', 'anndesc illegal');
assert_eq(wfdbx.ecgstr(99), '[99]', 'ecgstr');
assert_eq(wfdbx.strecg('A'), C.APC, 'strecg');
assert_eq(wfdbx.setannstr(-45, 'X1'), 0, 'setannstr');
assert_eq(wfdbx.annstr(45), 'X1', 'annstr redefined');
assert_eq(wfdbx.strann('X1'), 45, 'strann redefined');
assert_eq(wfdbx.ecgstr(45), '[45]', 'ecgstr not redefined');
wfdbx.setannstr(-45, '[45]');
wfdbx.wfdbquiet();
assert_eq(wfdbx.setannstr(60, 'x'), -1, 'setannstr illegal');
wfdbx.wfdbverbose();
assert(wfdbx.isqrs(C.NORMAL) && ~wfdbx.isqrs(C.NOTE), 'isqrs');
assert(wfdbx.map1(C.APC) == C.NORMAL && wfdbx.map2(C.APC) == C.SVPB, 'map1/map2');
assert_eq([wfdbx.wfdb_isann(5) wfdbx.wfdb_isqrs(C.NOTE) wfdbx.wfdb_map1(C.APC) ...
    wfdbx.wfdb_map2(C.APC) wfdbx.wfdb_ammap(double('V')) ...
    wfdbx.wfdb_mamap(C.PVC, 0) wfdbx.wfdb_annpos(C.RHYTHM)], ...
    [1 0 C.NORMAL C.SVPB C.PVC double('V') C.APLOW], 'wfdb_ functions');

% time resolution
wfdbx.setafreq(1000);
wfdbx.annopen('100s', wfdbx.anninfo('hr', wfdbx.WFDB_WRITE()));
x = wfdbx.annotation();
x.time = 2500;
x.anntyp = C.NORMAL;
wfdbx.putann(0, x);
wfdbx.wfdbquit();
wfdbx.setafreq(0);
wfdbx.sampfreq('100s');
wfdbx.annopen('100s', wfdbx.anninfo('hr', wfdbx.WFDB_READ()));
assert_eq(wfdbx.getiaorigfreq(0), 1000, 'getiaorigfreq');
[~, x] = wfdbx.getann(0);
assert_eq(x.time, 900, 'time at the sampling frequency');
wfdbx.setiafreq(0, 1000);
assert_eq(wfdbx.getiafreq(0), 1000, 'getiafreq');
wfdbx.wfdbquit();

% calibration list
fid = fopen('cal', 'wb');
fwrite(fid, sprintf(['# comment\nECG\t- 1 square 1 mV\nBP\t0 100 sine 100 mmHg\n' ...
    '*\t- - undefined 1 units\n']));
fclose(fid);
assert_eq(wfdbx.calopen('cal'), 0, 'calopen');
[stat, c] = wfdbx.getcal('ECG lead II', 'mV');
assert_eq(stat, 0, 'getcal');
assert_eq([c.low c.high c.scale c.caltype], [0 1 1 2], 'getcal values');
[stat, c] = wfdbx.getcal('BP', []);
assert_eq([stat c.low c.high c.scale c.caltype], [0 0 100 100 5], 'getcal BP');
assert_eq(c.units, 'mmHg', 'getcal units');
[stat, c] = wfdbx.getcal('Resp', 'units');
assert_eq([stat c.caltype], [0 0], 'getcal wildcard');
assert_eq(wfdbx.getcal('ECG', 'uV'), -1, 'getcal not found');
c = wfdbx.calinfo();
c.sigtype = 'Temp';
c.units = 'degC';
c.scale = 10;
c.caltype = 7;
c.low = 35;
c.high = 40;
wfdbx.putcal(c);
assert_eq(wfdbx.newcal('cal2'), 0, 'newcal');
assert_eq(char(readfile('cal2')), sprintf(['ECG\t- 1 square 1 mV\r\n' ...
    'BP\t0 100 sine 100 mmHg\r\n*\t- - undefined 1 units\r\n' ...
    'Temp\t35 40 sawtooth 10 degC\r\n']), 'newcal output');
wfdbx.flushcal();
assert_eq(wfdbx.getcal([], []), -1, 'flushcal');
end

function T = tricky(C)
% Ties in time, num and chan, duplicates (the last one is kept), NOTQRS
% (dropped), aux strings, and a time 0 annotation that follows later ones
% (lost by the original sortann, with the one at time 5 inserted after it,
% as in legacy mode; see docs/KNOWN_C_BEHAVIORS.md): time, code, subtype,
% chan, num, aux.
T = {100, C.NORMAL, 0, 0, 0, []; 50, C.PVC, 0, 0, 0, '(VT'; ...
    100, C.APC, 0, 1, 0, []; 100, C.NORMAL, 0, 0, 1, 'num 1'; ...
    100, C.PVC, 0, 0, 0, 'replaces N'; 75, C.NOTQRS, 0, 2, 0, []; ...
    75, C.NORMAL, 1, 2, 0, 'odd'; 10, C.NOTQRS, 0, 0, 0, []; ...
    200, C.RHYTHM, 0, 0, 0, '(AFIB'; 150, C.NOISE, 0, 3, -1, []; ...
    150, C.NOISE, 0, 3, 0, []; 20, C.NORMAL, 0, 0, 0, repmat('x', 1, 101); ...
    0, C.NORMAL, 0, 0, 0, []; 5, C.NORMAL, 0, 1, 0, []; ...
    5000, C.NORMAL, 0, 0, 0, []};
end

function b = write_tricky(C, name, legacy)
% writes 100s.NAME (in the output directory, if one is set) and returns
% the bytes of the file in the current directory, if any
T = tricky(C);
wfdbx.write_annotations('100s', name, [T{:, 1}], 'codes', [T{:, 2}], ...
    'subtypes', [T{:, 3}], 'chans', [T{:, 4}], 'nums', [T{:, 5}], ...
    'aux', T(:, 6), 'legacy', legacy);
b = [];
if isfile(['100s.' name])
    b = readfile(['100s.' name]);
end
end

function got = read_all(name, freq)
% time, anntyp, chan, num of each annotation of 100s.NAME (times in ticks
% of the time resolution FREQ)
wfdbx.annopen('100s', wfdbx.anninfo(name, wfdbx.WFDB_READ()));
wfdbx.setiafreq(0, freq);
[~, A] = wfdbx.internal.getann_bulk(0, inf);
wfdbx.wfdbquit();
got = [A.time; A.anntyp; A.chan; A.num].';
end

function sort_in_process(C)
old = getenv('WFDBANNSORT');
setenv('WFDBANNSORT', '1');
st = wfdbx.internal.ann_state();
wfdbx.setannstr(42, 'Z');               % (a definition table in the file)
c = onCleanup(@() sort_end(old)); %#ok<NASGU>
wfdbx.wfdbquiet();
wfdbx.setafreq(1000);                   % (a time resolution)
modern = write_tricky(C, 'srt', false);
% (the library's settings and tables are unchanged)
assert_eq([wfdbx.getafreq(), find(st.modified) - 1], [1000 42], ...
    'library state after the sort');
assert_eq(wfdbx.annstr(42), 'Z', 'library table after the sort');
rest = [20 C.NORMAL 0 0; 50 C.PVC 0 0; 75 C.NORMAL 2 0; ...
    100 C.PVC 0 0; 100 C.APC 1 0; 100 C.NORMAL 0 1; 150 C.NOISE 3 -1; ...
    150 C.NOISE 3 0; 200 C.RHYTHM 0 0; 5000 C.NORMAL 0 0];
% wfdb-x: nothing is lost (the time-0 annotation that follows later ones,
% and the one at time 5 inserted next to it, are kept)
assert_eq(read_all('srt', 1000), [0 C.NORMAL 0 0; 5 C.NORMAL 1 0; rest], ...
    'sorted in process');
% the in-process sort and the sortann tool give the same bytes
setenv('WFDBANNSORT', '0');
wfdbx.setafreq(1000);
write_tricky(C, 'uns', false);
wfdbx.setafreq(0);
assert_eq(wfdbx.apps.sortann({'-r', '100s', '-a', 'uns'}), 0, 'sortann');
assert_eq(readfile('100s.uns'), modern, 'in-process sort = sortann tool');
setenv('WFDBANNSORT', '1');
% legacy mode: the sortann program (with --legacy, as the original) loses
% them; so the modern result above was not produced by it
if wfdbx.internal.is_octave()           % (the sortann driver for Octave)
    wfdbx.setafreq(1000);
    write_tricky(C, 'leg', true);
    assert_eq(read_all('leg', 1000), rest, 'legacy sort loses time 0');
end
end

function sort_legacy_in_output_dir()
% legacy mode: the sortann program runs in the output directory (where
% the file is), with --legacy; the result is that of the modern sort
if ~wfdbx.internal.is_octave()          % (the sortann driver for Octave)
    return;
end
old = getenv('WFDBANNSORT');
setenv('WFDBANNSORT', '1');
c = onCleanup(@() sort_end(old)); %#ok<NASGU>
mkdir('out');
t = [300 100 200 100 50];
s = 'NVNAN';
wfdbx.wfdbquiet();
wfdbx.write_annotations('rec', 'leg', t, 'symbols', s, 'dir', 'out', ...
    'legacy', true);
wfdbx.write_annotations('rec', 'mod', t, 'symbols', s, 'dir', 'out');
wfdbx.wfdbverbose();
d = dir('out');
assert_eq(sort({d(~[d.isdir]).name}), {'rec.leg', 'rec.mod'}, 'files in out');
assert_eq(readfile(fullfile('out', 'rec.leg')), ...
    readfile(fullfile('out', 'rec.mod')), 'legacy sort in out = modern');
wfdbx.wfdbquiet();
a = wfdbx.read_annotations('out/rec', 'leg', 'fs', 360);
wfdbx.wfdbverbose();
assert_eq(a.samples.', [50 100 200 300], 'legacy sort in out: times');
assert_eq(a.symbols{2}, 'A', 'legacy sort in out: duplicate replaced');
end

function sort_list_time0()
% wfdbx.internal.ann_sortlist: 5, 0, 3 -> 0, 3, 5 (legacy: 5 only)
for legacy = [false true]
    [order, in_order] = wfdbx.internal.ann_sortlist([5 0 3], [0 0 0], ...
        [0 0 0], legacy);
    t = [5 0 3];
    if legacy
        want = 5;
    else
        want = [0 3 5];
    end
    assert_eq([t(order), in_order], [want, 0], 'ann_sortlist 5 0 3');
end
% a later annotation at time 0 replaces a real one (both modes), and one
% at time 0 on another channel is kept (both modes)
for legacy = [false true]
    order = wfdbx.internal.ann_sortlist([0 7 0 0], [0 0 0 0], [0 0 1 0], ...
        legacy);
    assert_eq(order, [4 3 2], 'ann_sortlist time-0 duplicate');
end
assert_eq(wfdbx.internal.ann_sortlist([5 0 3], [0 0 0], [0 0 0]), ...
    [2 3 1], 'ann_sortlist default (modern)');
end

function sort_end(old)
wfdbx.wfdbquit();
wfdbx.wfdbverbose();
wfdbx.wfdbx_set_output_dir([]);
wfdbx.setafreq(0);
wfdbx.setannstr(-42, '[42]');
st = wfdbx.internal.ann_state();
st.modified(43) = 0;
setenv('WFDBANNSORT', old);
end

function sort_disabled(C)
old = getenv('WFDBANNSORT');
setenv('WFDBANNSORT', '0');
c = onCleanup(@() setenv('WFDBANNSORT', old)); %#ok<NASGU>
wfdbx.wfdbquiet();
write_tricky(C, 'ns', false);
wfdbx.wfdbverbose();
assert_eq(wfdbx.wfdberror(), ...
    sprintf('to rearrange annotations in the correct order.\n'), ...
    'WFDBANNSORT=0 message');
T = tricky(C);
got = read_all('ns', 0);
assert_eq(got(:, 1).', [T{:, 1}], 'WFDBANNSORT=0: not sorted');
end

function sort_keeps_other_annotators(C)
% An input annotator and the signals stay open while an output annotator
% is closed and sorted.
assert_eq(wfdbx.isigopen('100s', 2), 2, 'isigopen');
ai = [wfdbx.anninfo('atr', wfdbx.WFDB_READ()), ...
    wfdbx.anninfo('o1', wfdbx.WFDB_WRITE()), ...
    wfdbx.anninfo('o2', wfdbx.WFDB_WRITE())];
assert_eq(wfdbx.annopen('100s', ai), 0, 'annopen');
[~, first] = wfdbx.getann(0);
x = wfdbx.annotation();
for t = [30 10 20]
    x.time = t;
    x.anntyp = C.NORMAL;
    wfdbx.putann(0, x);
    x.anntyp = C.PVC;
    wfdbx.putann(1, x);
end
wfdbx.wfdbquiet();
wfdbx.oannclose(0);                     % sorted now; o2 becomes number 0
wfdbx.wfdbverbose();
[stat, a] = wfdbx.getann(0);
assert_eq([stat, first.time, a.time], [0 18 77], 'input annotator kept');
[stat, v] = wfdbx.getvec();
assert_eq([stat, v], [2 995 1011], 'signals kept');
x.time = 40;
wfdbx.putann(0, x);
wfdbx.wfdbquiet();
wfdbx.wfdbquit();
wfdbx.wfdbverbose();
o1 = wfdbx.read_annotations('100s', 'o1');
o2 = wfdbx.read_annotations('100s', 'o2');
assert_eq([o1.samples.', o1.codes.'], [10 20 30, 1 1 1], 'o1 sorted');
assert_eq(o2.samples.', [10 20 30 40], 'o2 sorted');
end

function check_file(name, hex, expected, laststat)
fid = fopen(['x.' name], 'wb');
fwrite(fid, hex2dec(reshape(hex, 2, [])'));
fclose(fid);
wfdbx.wfdbquiet();
wfdbx.annopen('x', wfdbx.anninfo(name, 0));
for k = 1:numel(expected)
    [stat, x] = wfdbx.getann(0);
    assert_eq(stat, 0, [name ' getann']);
    if isempty(x.aux)
        s = '-';
    else
        s = lower(reshape(dec2hex(x.aux, 2)', 1, []));
    end
    assert_eq(sprintf('%d %d %d %d %d %s', x.time, x.anntyp, x.subtyp, ...
        x.chan, x.num, s), expected{k}, [name ' annotation']);
end
assert_eq(wfdbx.getann(0), laststat, [name ' end']);
wfdbx.wfdbquit();
wfdbx.wfdbverbose();
end

function b = readfile(name)
fid = fopen(name, 'rb');
b = fread(fid, inf, 'uint8=>uint8')';
fclose(fid);
end

function restore(old, oldpath, d)
wfdbx.wfdbquit();
wfdbx.setwfdb(oldpath);
cd(old);
rmdir(d, 's');
end
