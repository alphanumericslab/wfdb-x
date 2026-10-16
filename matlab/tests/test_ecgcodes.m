function test_ecgcodes()
%TEST_ECGCODES Tests of the annotation codes and mapping functions.

% Part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

C = wfdbx.ecgcodes();
assert_eq([C.NOTQRS C.NORMAL C.PVC C.NOTE C.LINK C.RONT C.ACMAX], ...
    [0 1 5 22 36 41 49], 'code values');
assert_eq([C.PQ C.JPT C.WFON C.WFOFF], [39 40 39 40], 'aliases');
assert_eq([C.APUNDEF C.APSTD C.APALOW], [0 1 6], 'position codes');
assert_eq([wfdbx.NORMAL() wfdbx.VFOFF() wfdbx.APHIGH()], [1 33 2], 'functions');
names = fieldnames(C);
for k = 1:numel(names)
    assert_eq(feval(['wfdbx.' names{k}]), C.(names{k}), names{k});
end
assert(wfdbx.isann(1) && wfdbx.isann(49) && ~wfdbx.isann(0) && ~wfdbx.isann(50), ...
    'isann');
assert_eq([wfdbx.isqrs(C.NORMAL) wfdbx.isqrs(C.NOTE) wfdbx.isqrs(60)], [1 0 0], 'isqrs');
assert_eq([wfdbx.map1(C.APC) wfdbx.map2(C.APC) wfdbx.map1(C.RONT)], ...
    [C.NORMAL C.SVPB C.PVC], 'map1/map2');
assert_eq(wfdbx.annpos(C.RHYTHM), C.APLOW, 'annpos');
assert_eq(wfdbx.ammap(double('V')), C.PVC, 'ammap');
assert_eq(wfdbx.ammap(double('A')), C.NOTQRS, 'ammap invalid');
assert_eq(char(wfdbx.mamap(C.PVC, 0)), 'V', 'mamap');
assert_eq(char(wfdbx.mamap(C.NOISE, 0)), 'O', 'mamap U');
assert_eq(char(wfdbx.mamap(C.NOISE, -1)), 'U', 'mamap U -1');
old = wfdbx.isqrs(C.NOTE);
assert_eq(wfdbx.setisqrs(C.NOTE, 255), -1, 'setisqrs char');
assert_eq(wfdbx.isqrs(C.NOTE), -1, 'isqrs after set');
wfdbx.setisqrs(C.NOTE, old);
assert_eq(wfdbx.setmap1(0, 5), 0, 'setmap1 invalid');
end
