function test_structs()
%TEST_STRUCTS Tests of the structure constructors.

% Part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

si = wfdbx.siginfo();
assert_eq(fieldnames(si)', {'fname', 'desc', 'units', 'gain', 'initval', ...
    'group', 'fmt', 'spf', 'bsize', 'adcres', 'adczero', 'baseline', ...
    'nsamp', 'cksum'}, 'siginfo fields');
assert(~ischar(si.fname) && si.spf == 1 && si.gain == 0, 'siginfo values');
assert_eq(size(wfdbx.siginfo(3)), [1 3], 'siginfo array');
assert_eq(size(wfdbx.siginfo(0)), [1 0], 'siginfo empty');
ai = wfdbx.anninfo('atr', wfdbx.WFDB_WRITE());
assert(strcmp(ai.name, 'atr') && ai.stat == 1, 'anninfo');
ai = wfdbx.anninfo();
assert(~ischar(ai.name) && ai.stat == 0, 'anninfo defaults');
a = wfdbx.annotation();
assert_eq(fieldnames(a)', {'time', 'anntyp', 'subtyp', 'chan', 'num', 'aux'}, ...
    'annotation fields');
assert(a.time == 0 && isempty(a.aux), 'annotation values');
c = wfdbx.calinfo();
assert_eq(fieldnames(c)', {'low', 'high', 'scale', 'sigtype', 'units', ...
    'caltype'}, 'calinfo fields');
s = wfdbx.seginfo(2);
assert(numel(s) == 2 && strcmp(s(1).recname, ''), 'seginfo');
assert_eq([wfdbx.WFDB_READ() wfdbx.WFDB_WRITE() wfdbx.WFDB_AHA_READ() ...
    wfdbx.WFDB_AHA_WRITE() wfdbx.WFDB_APPEND()], [0 1 2 3 4], 'modes');
assert_eq(wfdbx.wfdbversion(), '10.7.0', 'version');
end
