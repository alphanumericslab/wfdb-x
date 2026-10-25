# wfdb-x for MATLAB and GNU Octave

This directory holds the MATLAB and GNU Octave implementation of wfdb-x:
the WFDB library and command-line tools of the WFDB Software Package
10.7.0 (George B. Moody and contributors), as the MATLAB package `wfdbx`.
It reads and writes the same files as the C library, and its tools
produce byte-identical output, as checked by the wfdb-x conformance
suite. See the [project README](../README.md) for the overall design.

* Pure MATLAB code: nothing to compile, no toolboxes, no other dependencies.
* Written for **GNU Octave 6 or later** and **MATLAB R2019b or later**.
  It is tested with GNU Octave (8.4); it has not yet been run in MATLAB,
  but uses only the language features and functions common to both (see
  [`DEVELOPING.md`](DEVELOPING.md)).

## Installation

Add the `matlab/` directory (the one that contains `+wfdbx`) to the path:

```matlab
addpath('/path/to/wfdb-x/matlab')
savepath      % optional: keep it for later sessions
```

Everything is in the package `wfdbx`: functions are called as
`wfdbx.NAME(...)`. `help wfdbx` lists them (in Octave: `help
wfdbx.Contents`), `help wfdbx.NAME` describes each one, and `help
wfdbx.apps.TOOL` gives the usage of a command-line tool.

## Command-line tools

All the tools of the C package are available, with the same names,
options, output, error messages and exit statuses (see the *WFDB
Applications Guide*, [`third_party/wag.pdf`](../third_party/)):

* signals and annotations: `rdsamp`, `wrsamp`, `rdann`, `wrann`, `sortann`,
  `ann2rr`, `rr2ann`, `sigamp`, `snip`, `xform`, `wfdbdesc`, `wfdbcat`,
  `wfdbwhich`, `wfdbtime`, `time2sec`, `sampfreq`, `signame`, `signum`;
* format converters: `edf2mit`, `mit2edf`, `rdedfann`, `wav2mit`,
  `mit2wav`, `wfdb2mat`, `a2m`, `m2a`, `ad2m`, `md2a`, `ahaecg2mit`,
  `makeid`, `readid`, `revise`, `parsescp`.

Records are found with the WFDB path (the `WFDB` environment variable, as
with the C library). Remote (`http://`) records are not supported.

With Octave:

```sh
octave-cli --no-gui --norc -q matlab/bin/wfdbx_cli.m TOOL [ARGUMENTS ...]
octave-cli --no-gui --norc -q matlab/bin/wfdbx_cli.m --list    # the tools
```

An alias makes this convenient:

```sh
alias wfdbx='octave-cli --no-gui --norc -q /path/to/wfdb-x/matlab/bin/wfdbx_cli.m'
wfdbx rdsamp -r 100s -t 10 -p
```

With MATLAB, `matlab/bin/wfdbx_matlab.sh TOOL [ARGUMENTS ...]` runs the tool
with `matlab -batch` (set `WFDBX_MATLAB` to the MATLAB command if `matlab`
is not in the `PATH`). MATLAB starts slowly, so this is mainly useful for
testing.

From MATLAB or Octave, a tool is a function that takes its arguments in a
cell array and returns its exit status:

```matlab
status = wfdbx.apps.rdsamp({'-r', '100s', '-t', '10', '-p'});
```

## No built-in signal parameters

The C package silently assumes a sampling frequency (250 Hz), a gain
(200 adu/mV), an ADC resolution (12 bits) and units (millivolts) whenever a
record or the user does not give them. These values describe the
equipment of the first PhysioNet databases, not modern recordings, and a
silently assumed value corrupts every time, resampled signal and physical
value derived from it, with nothing in the output to say so. Like every
wfdb-x implementation, this one therefore has no built-in signal
parameters: tools that write them require them, and a tool that needs a
value missing from a record stops with an error. Where an output must show
missing units, it shows `nd` (not `mV`); a missing ADC resolution is
"not specified" (0).

New or now-required options:

* `wrsamp -o`: `-F FREQ`, `-G GAIN`, `-R BITS` (new) and `-U UNITS` (new;
  for calibrated signals, unless the input gives the units); `-G`, `-R`
  and `-U` take one value per signal (the last applies to the rest);
* `wav2mit`: `-G GAIN` and `-U UNITS` (new; `-U` unless the gain is 0);
* `ad2m`, `ahaecg2mit`: `-F FREQ`, `-G GAIN`, `-R BITS`, `-U UNITS` (new,
  all required, `-U` unless the gain is 0);
* `a2m`, `rdann`, `ann2rr`, `sortann`, `m2a`: new `-F FREQ` (and `rr2ann`'s
  `-F`), used when the record has no header or its header has no
  frequency;
* `xform` asks for the ADC resolution when the input does not give a
  suitable one.

To reproduce the results of the original tools, give the values they
assumed explicitly, for example:

```sh
wfdbx wrsamp -i data.txt -o rec -F 250 -G 200 -R 16 -U mV
wfdbx ad2m -i 1201.CMP -r 1201 -F 250 -G 400 -R 12 -U mV
wfdbx ahaecg2mit -F 250 -G 400 -R 12 -U mV 1001.ecg
wfdbx wav2mit -i sound.wav -r sound -G 6400 -U mV     # 16-bit WAV
wfdbx a2m -i 1201.ANO -F 250
```

The details, and the values that reproduce each tool, are in
[`docs/DIVERGENCES.md`](../docs/DIVERGENCES.md).

### Legacy mode

The original behavior remains available on request. `--legacy` as the
*first* argument of any tool (`wfdbx rdsamp --legacy -r 100s -p`, or
`wfdbx.apps.rdsamp({'--legacy', '-r', '100s', '-p'})`) makes it behave
exactly as the original tool: same options (those added by wfdb-x, such as
`-F` in `rdann` or `-R` in `wrsamp`, are unrecognized), outputs, messages,
help texts and exit statuses. In the library, `wfdbx.wfdbx_set_legacy(1)`
turns legacy mode on (`wfdbx.wfdbx_set_legacy(0)` off; each returns the
previous setting), `wfdbx.wfdbx_get_legacy()` returns the current setting,
and `[r, argv] = wfdbx.wfdbx_legacy_args(argv)` recognizes and removes
`--legacy` (the tools call it first). The high-level functions take a
`'legacy', true` name-value option (`read_record`, `read_header`,
`read_annotations`, `write_record`, `write_annotations`): with it, the
function behaves as it did before this redesign (`write_record`'s default
gain of 200 and ADC resolution from the format, no units required;
`read_annotations`' 250 Hz; physical values of uncalibrated signals with a
gain of 200; time strings at 250 Hz for a header without a frequency),
with the library's legacy mode on during the call (the previous setting is
restored afterwards, also on errors). Legacy mode reproduces the original
package exactly, and it is tested against its results (the legacy suite of
the conformance tests, `harness.py check --legacy`, and the library values
of `tests/reference/api_expect.c`).

It is kept for compatibility only: the values it assumes are exactly the
silent defaults this project removed, so results produced with it carry
the same risks.

## High-level API

Five functions read and write whole records and annotation files in one
call. They give exactly what the C library reads and writes, and are fast
(signals are decoded and encoded with vector operations, annotations in
bulk). Options are name-value pairs; text arguments may be char vectors or
MATLAB strings. An error is thrown when a file cannot be read or written.
These functions call `wfdbx.wfdbquit`, so they close any signals or
annotators opened with the library functions described below.

```matlab
rec = wfdbx.read_record('100s');                 % all samples, ADC units
rec.fs, rec.names, rec.units, rec.gains, rec.baselines, rec.base_time
rec = wfdbx.read_record('100s', 'channels', {'V5'}, 'sampfrom', '0:10', ...
                        'sampto', '0:20', 'physical', true);  % mV; NaN = invalid
t = rec.sampfrom / rec.fs + (0:size(rec.signals, 1) - 1)' / rec.fs;
plot(t, rec.signals);

si = wfdbx.read_header('100s');                  % signal descriptions only
```

`read_record` options: `'channels'` (signal numbers, 0-based as everywhere
in WFDB, or a cell of numbers and names), `'sampfrom'` and `'sampto'`
(sample numbers or WFDB time strings such as `'1:30'` or `'s1000'`;
`'sampto'` is exclusive), `'physical'` (`(adu - baseline) / gain`, with
`NaN` for invalid samples; ADC units are returned as doubles, invalid
samples being -32768; an error if a selected signal is uncalibrated),
`'highres'` (multi-frequency records: all samples of
the fastest signals, as `rdsamp -H`; by default one averaged sample per
frame) and `'pad'` (replace invalid samples by the previous valid one).
`rec.fs` is 0 for a record whose header does not give a sampling frequency;
time strings that need one (anything but sample numbers `'sN'`, see
`wfdbx.wfdbx_time_needs_freq`) are then an error. Unspecified ADC
resolutions are 0 (`rec.siginfo(k).adcres`) and unspecified units `[]`
(never millivolts).

```matlab
% RECORD.dat and RECORD.hea in the current directory
x = round(1000 * sin(2 * pi * (0:999)' / 100));
wfdbx.write_record('sine', [x, -x], 250, 'fmt', 212, 'gains', 200, ...
    'adcres', 12, 'names', {'sin', '-sin'}, 'units', 'mV', ...
    'base_time', '12:00:00 01/02/2003', 'comments', {'made by MATLAB'});
% physical units, converted with the gains and baselines (NaN -> invalid)
wfdbx.write_record('phys', rec.signals, rec.fs, 'physical', true, ...
    'gains', rec.gains, 'baselines', rec.baselines, 'fmt', 16, ...
    'adcres', 16, 'units', 'mV');
% multi-frequency: a row holds the samples of a frame (signal 0 at 100 Hz,
% signal 1 at 200 Hz: 2 samples per frame)
wfdbx.write_record('mf', [x(1:2:end), x(1:2:end), x(2:2:end)], 100, ...
    'samps_per_frame', [1 2], 'gains', 200, 'adcres', 16, 'units', 'mV');
```

`write_record` options (a scalar applies to all signals, a vector or cell
gives one value per signal): `'fmt'` (default 16, the same for all
signals), `'gains'` (required: there is no default gain; 0 declares a
signal uncalibrated, which is an error with `'physical'`), `'baselines'`
(default: the ADC zeros), `'adczeros'` (default 0), `'adcres'` (required:
there is no default resolution; >= 1), `'units'` (required for each
signal whose gain is not 0; `[]` for none), `'names'`, `'base_time'`,
`'comments'`, `'physical'`, `'samps_per_frame'`, `'dir'` (see below). The
sampling frequency must be > 0.

```matlab
% a structure of column vectors (samples, codes, subtypes, chans, nums),
% cells (symbols, aux) and fs
ann = wfdbx.read_annotations('100s', 'atr');
ann.samples(1:3), ann.symbols(1:3)              % 18 77 370, '+' 'N' 'N'
pvc = ann.samples(ann.codes == wfdbx.PVC());
ann = wfdbx.read_annotations('100s', 'atr', 'sampfrom', '0:10', 'sampto', 7200);
% a record without a header (or without a frequency in it): give fs
ann = wfdbx.read_annotations('rec', 'atr', 'fs', 250, 'sampto', '0:10');

wfdbx.write_annotations('100s', 'my', ann.samples, 'symbols', ann.symbols, ...
    'aux', ann.aux);                            % or 'codes', ann.codes
wfdbx.write_annotations('100s', 'qrs', [100 460 820], 'symbols', 'NVN', ...
    'subtypes', 0, 'chans', [0 0 1], 'nums', 0, 'aux', {[], '(AFIB', []});
```

Annotation times are doubles (exact up to 2^53). An aux string is read up
to its first null byte, and at most 255 bytes of it are written. With
`'fs', F`, `write_annotations` records F as the time resolution of the file
(the times are then ticks of 1/F seconds). The `'fs'` option of
`read_annotations` gives the sampling frequency when the record has no
header or its header does not give one (as `rdann -F`); without it,
`ann.fs` is 0 and time strings that need a frequency are an error.

### Directories, absolute paths and annotation order

**Output directory.** `wfdbx.write_record(..., 'dir', 'out')` and
`wfdbx.write_annotations(..., 'dir', 'out')` create their files in the
directory `out` (which must exist: otherwise an error), and the header
names the record and its signal file without the directory (`rec 2 360
...`, `rec.dat ...`), so that the record opens from that directory under
its plain name (`wfdbx.setwfdb('out')`, then `wfdbx.read_record('rec')`;
or `wfdbx.read_record('out/rec')`). The record name must not contain a
directory when `'dir'` is given (an error). In the library API,
`wfdbx.wfdbx_set_output_dir('out')` makes every output file be created in
`out` (it returns the previous directory; `wfdbx.wfdbx_set_output_dir([])`
restores the default, files created as named, and
`wfdbx.wfdbx_get_output_dir()` returns the current one); the writers set
it for the duration of the call (and restore it, also on errors). The
C-style API and the tools are otherwise unchanged:
`wfdbx.newheader('out/rec')` and `wfdbx wrsamp -o out/rec` still record
the name `out/rec`, as in C.

**Absolute paths.** A record named by an absolute path
(`wfdbx.read_record('/data/mitdb/100')`, `wfdbx rdsamp -r
/data/mitdb/100`) is opened directly, and the files next to its header
(signal and annotation files) are found there. The C library searched for
such a name in each directory of the WFDB path (`./` + the name), so that
it was found only from the root directory; it still does so in legacy
mode. In both modes, an empty component in the WFDB path makes names be
used as given: with `wfdbx.setwfdb(';')` (or `WFDB=";"`),
`/data/mitdb/100` opens in legacy mode too.

**Annotation order.** Annotations written out of canonical order (by
time, then `num`, then `chan`) are rearranged when the file is closed, in
the same process, with a result identical byte for byte to that of
`sortann` (the last of several annotations with the same time, `num` and
`chan` is kept, and `NOTQRS` annotations are dropped); `WFDBANNSORT=0`
disables it. Unlike the original `sortann`, nothing is lost: an
annotation at time 0 (`num` and `chan` 0) that follows later ones was
dropped, with the annotations then inserted next to it; the `sortann`
tool is fixed the same way. The C library ran the `sortann` program
(found in the `PATH`), as legacy mode does (running the `sortann` tool of
this package with `--legacy`, so with the original loss, in a new Octave
or MATLAB process, through the shell, in the output directory if one is
set).

## The WFDB library API

The functions of the C library are available under their C names
(`wfdbx.isigopen`, `wfdbx.getvec`, `wfdbx.putvec`, `wfdbx.strtim`,
`wfdbx.annopen`, `wfdbx.getann`, `wfdbx.putann`, `wfdbx.calopen`, ...),
with these conventions:

* Strings are `char` vectors, one character per byte (record names may
  also be MATLAB strings); a C `NULL` string is `[]`.
* Numbers (samples, times, counts) are `double`s.
* C structures are MATLAB structures with the same fields, created by
  `wfdbx.siginfo(n)`, `wfdbx.anninfo(name, stat)`, `wfdbx.annotation()`,
  `wfdbx.calinfo()` and `wfdbx.seginfo(n)`.
* A function that fills an array supplied by the caller returns it
  instead: `[nsig, si] = wfdbx.isigopen('100s', 2)`,
  `[stat, v] = wfdbx.getvec()`, `[stat, a] = wfdbx.getann(0)`.
* Constants are functions: `wfdbx.WFDB_READ()`, `wfdbx.NORMAL()`, ...;
  `C = wfdbx.ecgcodes()` returns all the annotation codes as a structure
  (`C.NORMAL`, `C.PVC`, ...).
* As in C, the library keeps global state (open signals and annotators,
  WFDB path, time base); `wfdbx.wfdbquit()` resets it.
* `wfdbx.getframes(n)` and `wfdbx.putframes(M)` (additions) read and
  write many frames at once, with exactly the effect of `n` calls of
  `getvec` or of `putvec`.
* No sampling frequency, gain, ADC resolution or units are assumed (see
  [`docs/DIVERGENCES.md`](../docs/DIVERGENCES.md)): a header without an
  ADC resolution gives `adcres` 0 (C: inferred from the format, or 12
  bits), and missing units stay `[]`; `wfdbx.sampfreq`
  returns 0 for a header without a frequency; `strtim`, `timstr` and
  `mstimstr` then report an error (`strtim` returns 0, the others the time
  as a sample number, `'sN'`), except for the strings for which
  `wfdbx.wfdbx_time_needs_freq` (an addition) returns 0; `aduphys`,
  `physadu`, `adumuv` and `muvadu` report an error for an uncalibrated
  signal or an invalid signal number and return `NaN` (`aduphys`) or
  `WFDB_INVALID_SAMPLE`.

```matlab
wfdbx.setwfdb('. /data/mitdb');
wfdbx.wfdbfile('hea', '100')             % './100.hea', or [] if not found

[n, si] = wfdbx.isigopen('100', 2);      % si(1).desc, si(1).gain, ...
[stat, v] = wfdbx.getvec();              % one sample of each signal
x = wfdbx.getframes(3600);               % the next 3600 frames (3600-by-2)
wfdbx.timstr(wfdbx.strtim('e'))          % length of the record
wfdbx.wfdbquit();

si = wfdbx.siginfo(2);                   % writing
[si.fname] = deal('new.dat'); [si.fmt] = deal(212); [si.gain] = deal(200);
wfdbx.osigfopen(si);
wfdbx.setsampfreq(360);
wfdbx.putframes(x);
wfdbx.newheader('new');
wfdbx.wfdbquit();

wfdbx.annopen('100', wfdbx.anninfo('atr', wfdbx.WFDB_READ()));
[stat, a] = wfdbx.getann(0);             % a.time, a.anntyp, a.aux, ...
wfdbx.annstr(a.anntyp)                   % e.g. 'N'
wfdbx.wfdbquit();
```

## FLAC-compressed signals

Signal formats 508, 516 and 524 are supported by a FLAC codec written in
MATLAB, without any external library. Files written by the C library
(libFLAC) are read exactly; files written by wfdb-x are standard FLAC
streams that the C library reads back with identical sample values (their
compressed bytes differ from libFLAC's, whose output depends on its
version).

## Performance

Sequential reading and writing, and annotation files, are processed with
vector operations that are exactly equivalent to the sample-by-sample
functions. In Octave 8, `rdsamp` prints a 650,000-frame, 2-signal format
212 record in about 1 s (process start included); `getframes` reads it in
0.13 s and `putframes` writes it in 0.12 s; `write_record` (which uses
`putframes`) writes 216,000 frames of 2 signals in about 0.08 s, and
`read_record` reads them in about 0.07 s. The per-sample functions
(`getvec`, `putvec`) are much slower (a fraction of a millisecond per
call). MATLAB is expected to be faster.

## Testing

From the root of the repository:

```sh
octave-cli --no-gui --norc -q --eval "cd matlab/tests; run_tests"   # unit tests
python3 tests/conformance/harness.py check --impl octave -j8          # conformance
```

The conformance suite runs every tool on the test cases of
`tests/conformance/` and compares all outputs with those of the C programs
([`docs/conformance.md`](../docs/conformance.md)). In MATLAB, the unit
tests run with `matlab -batch "cd matlab/tests; run_tests"`.

[`DEVELOPING.md`](DEVELOPING.md) describes the organization of the code and
its conventions.

## License

The library (`+wfdbx/`, except `+wfdbx/+apps/`) is distributed under the
GNU Library General Public License, version 2 or later
([`LICENSE.LIB`](../LICENSE.LIB)); the tools (`+wfdbx/+apps/`, `bin/`)
under the GNU General Public License, version 2 or later
([`LICENSE`](../LICENSE)). Each file names the authors of the C code it
ports; see [`docs/AUTHORS.md`](../docs/AUTHORS.md). The MATLAB/Octave
implementation was developed by Reza Sameni (2026), with AI assistance (see
the project README).
