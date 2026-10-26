function test_time()
%TEST_TIME Tests of time and date conversion (values checked against WFDB 10.7.0).

% Part of wfdb-x, Reza Sameni, Oct 2026.
% GNU Library General Public License, version 2 or later (see LICENSE.LIB).

here = fileparts(mfilename('fullpath'));
data = fullfile(fileparts(fileparts(here)), 'tests', 'data');
oldpath = getenv('WFDB');
cleanup = onCleanup(@() restore(oldpath)); %#ok<NASGU>
wfdbx.wfdbquit();
wfdbx.setwfdb(data);

% Elapsed times (100s: 360 Hz, 21600 samples)
assert_eq(wfdbx.isigopen('100s', 0), 2, 'isigopen 100s');
assert_eq(wfdbx.strtim('1:0'), 21600, 'strtim 1:0');
assert_eq(wfdbx.timstr(21600), '    1:00', 'timstr');
assert_eq(wfdbx.mstimstr(1234), '    0:03.428', 'mstimstr');
assert_eq(wfdbx.strtim('s7'), 7, 'strtim s7');
assert_eq(wfdbx.strtim('e'), 21600, 'strtim e');
assert_eq(wfdbx.strtim('2.5'), 900, 'strtim seconds');
assert_eq(wfdbx.strtim('1:00:00'), 1296000, 'strtim hh:mm:ss');
assert_eq(wfdbx.timstr(1296000), ' 1:00:00', 'timstr hours');
assert_eq(wfdbx.sampfreq([]), 360, 'sampfreq');
wfdbx.wfdbquit();

% Absolute times (fmt16 starts at 12:34:56.789 31/12/1999)
wfdbx.isigopen('fmt16', 0);
assert_eq(wfdbx.timstr(0), '[12:34:56 31/12/1999]', 'timstr(0)');
assert_eq(wfdbx.strtim('[12:35:00]'), -803, 'strtim absolute');
assert_eq(wfdbx.mstimstr(-2500), '[12:35:06.789 31/12/1999]', 'mstimstr absolute');
wfdbx.wfdbquit();

% Dates
d = {'01/01/2000', '29/02/2000', '15/10/1582', '31/12/1999'};
for k = 1:numel(d)
    assert_eq(wfdbx.datstr(wfdbx.strdat(d{k})), [' ' d{k}], ['date ' d{k}]);
end
% 29 February 1900 does not exist (Gregorian calendar)
assert_eq(wfdbx.datstr(wfdbx.strdat('29/02/1900')), ' 01/03/1900', '29/02/1900');
assert_eq(wfdbx.strdat('bogus'), 0, 'invalid date');

% Base time
wfdbx.setsampfreq(100);
assert_eq(wfdbx.setbasetime('10:00:00 02/01/2003'), 0, 'setbasetime');
assert_eq(wfdbx.timstr(-360000), '[11:00:00 02/01/2003]', 'one hour later');
assert_eq(wfdbx.timstr(-8640000), '[10:00:00 03/01/2003]', 'one day later');
wfdbx.wfdbquiet();
assert_eq(wfdbx.setbasetime('xyz'), -1, 'bad base time');
wfdbx.wfdbverbose();
wfdbx.wfdbquit();
end

function restore(oldpath)
wfdbx.wfdbquit();
wfdbx.wfdbverbose();
wfdbx.wfdbx_set_input_dir([]);
end
