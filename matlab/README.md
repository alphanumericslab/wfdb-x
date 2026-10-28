# WFDB-x for MATLAB and GNU Octave

> **WFDB-x** is a reimplementation of the WFDB Software Package (the library
> and its command-line tools) in seven languages: Python, C++,
> MATLAB/Octave, Rust, Julia, R and Kotlin, tested to give byte-for-byte
> identical results to the original C package and to each other. This is the
> MATLAB/Octave implementation.
> [Project page and the other languages](https://github.com/alphanumericslab/wfdb-x)
> · [WFDB-x at a glance (overview figure)](https://github.com/alphanumericslab/wfdb-x#wfdb-x-at-a-glance)
> · [Benchmarks](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/BENCHMARKS.md)

`wfdbx` reads and writes physiological signal records in the WFDB format used
by [PhysioNet](https://physionet.org). It is a complete MATLAB and Octave
implementation of the WFDB Software Package: the library and all of its
command-line tools. It reads and writes the same files as the original C
library, and its tools print the same output.

The package is plain MATLAB code. It needs GNU Octave 6 or later, or MATLAB
R2019b or later, and no toolboxes.

## Three ways to use WFDB-x

All three are written in MATLAB; none of them calls the C library. The same
code runs in MATLAB and in Octave.

1. **The high-level functions (recommended).** `wfdbx.read_record`,
   `wfdbx.read_header`, `wfdbx.read_annotations`, `wfdbx.write_record`,
   `wfdbx.write_annotations` and `wfdbx.check_record` read and write whole
   records and annotation files as matrices of doubles and structures, in
   one call, with name-value options, and throw MATLAB errors (with an
   identifier such as `wfdbx:read_record`) on failure. They read signal
   files in large blocks, so they are the fastest way to read a record.
   They are an addition of WFDB-x: the C package has no equivalent. Use
   them for new code and analysis.
2. **The WFDB library functions** under their C names (`wfdbx.isigopen`,
   `wfdbx.getvec`, `wfdbx.getann`, `wfdbx.putann`, ...), with the C
   behavior: sample by sample and annotation by annotation, with errors
   reported by return values. Use them to port a program written against
   the C library, or for the exact C semantics.
3. **The command-line tools** (`rdsamp`, `rdann`, `wrsamp`, `xform`, and
   29 others), with the options, output and exit status of the C tools, run
   from the shell as `wfdbx rdsamp -r 100s`, where `wfdbx` is an alias of
   the Octave script `bin/wfdbx_cli.m` (see
   [Command-line tools](#command-line-tools); `bin/wfdbx_matlab.sh` runs
   them with MATLAB), or inside MATLAB and Octave as functions
   (`wfdbx.apps.rdsamp({'-r', '100s'})`). Use them in shell
   scripts and pipelines, or to reproduce work done with the original
   tools.

The high-level functions return exactly the samples and annotations that
the library functions (and the C library) give.

## Installation

Get a copy of the repository, then add its `matlab` folder (the one that
contains `+wfdbx`) to the path:

```matlab
addpath('/path/to/wfdb-x/matlab')
savepath      % optional: keep the folder on the path in later sessions
```

All functions are in the package `wfdbx` and are called as `wfdbx.NAME`.
`help wfdbx` lists them (in Octave, `help wfdbx.Contents`), and
`help wfdbx.NAME` describes each one.

## Quick start

The repository includes a sample record, `100s`, in the folder `tests/data`.
It is the first minute of record 100 of the
[MIT-BIH Arrhythmia Database](https://physionet.org/content/mitdb/), with two
ECG signals at 360 Hz and its beat annotations.

```matlab
% Read the sample record from the repository's test data.
wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');

rec = wfdbx.read_record('100s', 'physical', true);   % signals in physical units
rec.fs                      % 360
rec.names                   % {'MLII', 'V5'}
size(rec.signals)           % [21600 2]

hdr = wfdbx.read_header('100s');                % the header only, no samples
[hdr.nsig, hdr.nsamples]                        % [2 21600]

ann = wfdbx.read_annotations('100s', 'atr');    % beat annotations
numel(ann.samples)                              % 75
ann.symbols(1:3)'                               % {'+', 'N', 'N'}
ann.samples(1:3)'                               % [18 77 370]

% Write the first 10 seconds as a new record in the current folder.
x = wfdbx.read_record('100s', 'sampto', '0:10');    % ADC units
wfdbx.write_record('copy', x.signals, x.fs, 'fmt', 16, 'gains', x.gains, ...
    'baselines', x.baselines, 'adcres', 11, 'units', 'mV', 'names', x.names);
```

## Reading and writing records

Options are name-value pairs. Text arguments can be char vectors or MATLAB
strings. Signal numbers start at 0, as everywhere in WFDB.

The examples of this section read the sample record `100s` (the first minute
of record 100 of the MIT-BIH Arrhythmia Database, in the folder `tests/data`
of a copy of the repository), with the input directory set as in the quick
start:

```matlab
wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
```

### Reading signals: `read_record`

```matlab
rec = wfdbx.read_record('100s', 'channels', {'MLII'}, 'sampfrom', '0:10', ...
                        'sampto', '0:20', 'physical', true);
```

| Argument | Meaning | Default |
|---|---|---|
| `record` | record name or path (see [Where files are read and written](#where-files-are-read-and-written)) | |
| `'channels'` | signals to read: signal numbers, or a cell array of numbers and names (by name, as in `names`) | all signals |
| `'sampfrom'`, `'sampto'` | first sample, and the sample after the last one: a sample number (`'sampfrom'` not negative) or a time string (see below) | the whole record |
| `'physical'` | return physical units instead of ADC units | `false` |
| `'highres'` | read a multi-frequency record at its highest sampling frequency | `false` |
| `'pad'` | replace invalid samples by the previous valid one | `false` |
| `'checksum_warning'` | warn when the data do not match the header's checksums | `true` |
| `'input_dir'`, `'network'` | input directory and network access for this call only | the current settings |
| `'legacy'` | behave as the original package (see [Legacy mode](#legacy-mode)) | `false` |

Times can be sample numbers or WFDB time strings: `'0:10'` (10 seconds),
`'1:02:03.5'`, `'s3600'` (sample 3600) or `'e'` (the end of the record).

The result is a structure:

| Field | Contents |
|---|---|
| `signals` | matrix of doubles, one row per sample and one column per signal, in ADC units, or in physical units with `'physical', true` |
| `fs` | sampling frequency in Hz (0 if the header gives none) |
| `names`, `units` | cell arrays: the description of each signal, such as `'MLII'`, without the white space that a header may put at either end of it, and the physical units of each signal (`[]` when the header gives no units) |
| `gains`, `baselines` | row vectors: the gain (ADC units per physical unit; 0 means uncalibrated) and the baseline of each signal |
| `siginfo` | the full signal specifications, a `wfdbx.siginfo` structure array (`desc` without white space at either end, as in `names`) |
| `name` | the record name |
| `sampfrom` | the number of the first sample returned |
| `base_time` | start time and date as text, to the second, such as `'[14:00:03 21/06/2024]'` |
| `base_time_ms` | start time in milliseconds after midnight, such as `50403500` for 14:00:03.500 |
| `base_date` | start date as `[year month day]` |
| `comments` | the info strings of the header, as a cell column |
| `checksum_ok` | `false` if the data do not match the header's checksums |

`base_time`, `base_time_ms` and `base_date` are `[]` when the header does not
give them. Invalid samples are `wfdbx.WFDB_INVALID_SAMPLE()` (-32768), or NaN
in physical units.

### Reading a header: `read_header`

`wfdbx.read_header(record)` reads the header of a record without opening its
signal files. It returns a structure with these fields: `name`, `fs`,
`counter_freq`, `base_counter`, `nsamples` (0 if the header does not give
the length), `nsig`, `siginfo`, `base_time`, `base_time_ms`, `base_date` and
`comments`. They have the same meaning as in the result of `read_record`.
`read_header` takes the options `'input_dir'`, `'network'` and `'legacy'`.

```matlab
hdr = wfdbx.read_header('100s');
for k = 1:hdr.nsig
    s = hdr.siginfo(k);
    fprintf('%s %d %g\n', s.desc, s.fmt, s.gain);   % MLII 212 200
end
```

### Reading annotations: `read_annotations`

```matlab
ann = wfdbx.read_annotations('100s', 'atr', 'sampfrom', '0:10', 'sampto', '0:30');
```

The second argument is the annotator, the file suffix: `'atr'` reads
`100s.atr`. The option `'fs'` gives the sampling frequency when the record
has no header, or its header gives none. The function also takes
`'input_dir'`, `'network'` and `'legacy'`. The result is a structure, in
file order:

| Field | Contents |
|---|---|
| `samples` | annotation times, in samples (a column of doubles) |
| `codes`, `symbols` | annotation codes (`wfdbx.NORMAL()`, `wfdbx.PVC()`, ...) and their mnemonics (`'N'`, `'V'`, ...), as a column and a cell column |
| `subtypes`, `chans`, `nums` | subtype, channel and annotator number of each annotation (columns) |
| `aux` | auxiliary text of each annotation, as a cell column; `[]` where there is none |
| `fs` | the frequency in which `samples` are counted (0 if unknown) |
| `record`, `annotator` | the arguments |

### Writing a record: `write_record`

The example writes a new record, `rand`, of random samples in the current
folder:

```matlab
x = randn(3600, 2);
wfdbx.write_record('rand', x, 360, 'fmt', 16, 'physical', true, ...
    'gains', 1000, 'adcres', 16, 'units', 'mV', 'names', {'A', 'B'});
```

This writes the header `rand.hea` and the signal file `rand.dat`. The third
argument is the sampling frequency. The gain and ADC resolution of each
signal, and the units of each calibrated signal, are also required; there
are no defaults. A gain of 0 marks a signal as uncalibrated, which is only
allowed for samples given in ADC units. Per-signal options take one value
for all signals, or a vector or cell array with one value per signal.

| Argument | Meaning |
|---|---|
| `signals` | matrix with one row per sample and one column per signal; ADC units, or physical units with `'physical', true` |
| `fs` | sampling frequency in Hz |
| `'fmt'` | storage format, such as 16, 212, 24 or 516 (FLAC); default 16 |
| `'gains'`, `'adcres'`, `'units'` | gain, ADC resolution in bits, and physical units |
| `'baselines'`, `'adczeros'`, `'names'` | optional signal specifications |
| `'base_time'`, `'comments'` | start time (`'hh:mm:ss dd/mm/yyyy'`) and a cell array of info strings |
| `'samps_per_frame'` | samples per frame of each signal, for a multi-frequency record |
| `'dir'` | folder in which to create the files |
| `'legacy'` | behave as the original package (see [Legacy mode](#legacy-mode)) |

### Writing annotations: `write_annotations`

```matlab
wfdbx.write_annotations('rand', 'qrs', [100 460 820], 'symbols', {'N', 'N', 'V'});
```

This writes the annotation file `rand.qrs`, for the record `rand` written
above, in the current folder.

Give the annotation types as `'symbols'` or as `'codes'`. `'subtypes'`,
`'chans'`, `'nums'`, `'aux'`, `'fs'` and `'dir'` are optional. Each
per-annotation option is one value for all annotations, or a list with
exactly one value per annotation; a list of any other length is an error,
thrown before the file is created. As in C, subtypes and annotator numbers
are stored as signed bytes and channels as unsigned bytes (other values
wrap around). If the
annotations are not in time order, the file is sorted when it is written.
`'sort', false` keeps the given order (without the library's advice to run
`sortann`) and `'sort', true` always sorts, for that call only. Without
`'sort'`, the `WFDBANNSORT` environment variable decides (sorting is on
unless it is `0`).

### Errors and warnings

* A record, header or annotation file that cannot be read or written throws
  an error, such as "can't read record REC". Each function has its own
  error identifier: `wfdbx:read_record`, `wfdbx:read_header`,
  `wfdbx:read_annotations`, `wfdbx:write_record` and
  `wfdbx:write_annotations`.
* A signal file that is shorter than its header says throws an error:
  "can't read signal data of record REC (getvec status -3)".
* A record or annotation file that cannot be written completely (for
  example, when the disk is full) throws the error "write error on record
  REC" in `write_record`, and "write error on annotator ANN for record REC"
  in `write_annotations`, after the library's message (such as "osigclose:
  write error in signal group 0"), in legacy mode too.
* In `write_record`, each `'samps_per_frame'` value must be an integer of 1
  or more ("samps_per_frame must hold integers >= 1"), and `signals` must
  have `sum(samps_per_frame)` columns ("signals has N columns, but
  samps_per_frame adds up to M"). These are checked first, and nothing is
  written. Samples in ADC units must be integers within the range of a
  32-bit integer, and samples in physical units must not be infinite or
  have ADC values outside that range (NaN is an invalid sample); all the
  arguments are checked before any file is created. Whatever the outcome,
  `write_record` and `write_annotations` close their output files and the
  library's output signals and annotators before they return.
* A negative `'sampfrom'` in `read_record` is an error. `read_record` sets
  the getvec mode (`'highres'`, `'pad'`) for its own reading only: the mode
  in force before the call is restored afterwards.
* An annotation file that ends unexpectedly, or cannot be read, before
  `'sampto'` throws an error: "can't read annotation file ANN of record REC
  (getann status -3)".
* Invalid arguments, and a value the operation needs but the record does not
  give, throw an error. For example, a time string such as `'0:10'` needs
  the sampling frequency, and `'physical', true` needs the gain of each
  signal.
* When the data do not match the checksums in the header, `read_record`
  returns all the data and issues the warning `wfdbx:checksum`: "checksum
  error in record REC: the signal data do not match the checksums in its
  header". `'checksum_warning', false` turns the warning off;
  `rec.checksum_ok` is `false` either way. Checksums are only checked when
  a read reaches the end of the record.
* A tool, or a program that uses the WFDB library functions, never writes a
  signal file over one of the signal files it is reading. Opening such an
  output fails with "output file NAME is also an input file".
  `wfdbx.write_record` reads nothing, so it overwrites any existing files of
  the same name.

The high-level functions call `wfdbx.wfdbquit()`, which closes anything
opened with the WFDB library functions.

### Checking a record: `check_record`

```matlab
report = wfdbx.check_record('100s', 'annotators', {'atr'})
```

`wfdbx.check_record(record, 'annotators', {...})` checks the header of a
record, its signal specifications, every sample of its signal files, and the
annotation files named (a cell array, or one name as a char vector). It
reports each problem it finds. It never throws an error for a problem in the
record. It checks for problems similar to those found by Benjamin Moody's
[wfdbcheck](https://github.com/bemoody/wfdbcheck). It takes the options
`'input_dir'` and `'network'` of `wfdbx.read_record`.

The result is a structure. `report.ok` is `true` if there is no error.
`report.issues` is a structure array of the problems. Each has a `severity`,
a `code` (such as `'checksum'`), a `where` (`''` for the record,
`'signal 1'`, `'segment s2'`, `'annotator atr'`) and a `message`.

| Severity | Meaning |
|---|---|
| `error` | the record is damaged or does not follow the WFDB format: programs will read wrong data or fail |
| `warning` | the record can be read, but something is missing or unusual, and may give wrong results |
| `info` | a fact worth knowing, such as invalid (missing) samples |

`report.lines` is the text form, a cell array with one line per problem, or
the line `no problems found`; called without an output argument,
`wfdbx.check_record` displays these lines:

```
warning: signal 0: the units are not specified
error: signal 1: the checksum does not match: the header gives 12, the samples sum to 13
error: annotator atr: 3 annotations are out of order; the first is at sample 50, after sample 100
```

The lines are the same in the seven languages of WFDB-x. The checks run in normal mode, even if legacy mode is on, and the library
prints no messages during the call.

What is checked:

* the header: that it can be read, the sampling frequency, the length, lines
  of at most 255 characters, and the record name it gives;
* each signal: description, gain, units, ADC resolution and range, storage
  format, and signal file name;
* the signal files: that they can be read, samples outside the ADC range,
  invalid samples, checksums, and the length given in the header;
* each segment of a multi-segment record, and its signals against the
  record's;
* the annotation files: that they can be read to the end, time order,
  annotation codes, and annotations after the end of the record.

The sample record `100s` gives two warnings: its header gives no units.

## Where files are read and written

WFDB-x reads and writes files exactly where they are named, and nowhere else:

| The name is | It is read from | It is written to |
|---|---|---|
| a full path: `/data/mitdb/100`, `C:\data\100` | that path | that path |
| a home path: `~/data/100` | the user's home folder | the user's home folder |
| a URL: `https://.../100` | that URL, if network access is on | (URLs cannot be written) |
| anything else: `100`, `mitdb/100`, `../data/100` | the **input directory** | the **output directory** |

In this table, `/data/mitdb` stands for a local copy of the MIT-BIH
Arrhythmia Database, and `100` for its record 100.

The input and output directories are both the current folder unless they are
set:

| Setting | Function | Option of the high-level functions | Environment variable |
|---|---|---|---|
| input directory: a local folder, `~/...` or a URL | `wfdbx.wfdbx_set_input_dir(d)` | `'input_dir'` | `WFDBX_INPUT_DIR` |
| output directory | `wfdbx.wfdbx_set_output_dir(d)` | `'dir'` | `WFDBX_OUTPUT_DIR` |
| network access (off by default) | `wfdbx.wfdbx_set_network(1)` | `'network', true` | `WFDBX_NETWORK=1` |

A function call overrides the environment variable, and an option applies to
that one call. Each `set` function returns the previous setting, and passing
`[]` restores the default. `wfdbx.wfdbx_get_input_dir()`,
`wfdbx.wfdbx_get_output_dir()` and `wfdbx.wfdbx_get_network()` return the
current settings.

In this example, `/data/mitdb` stands for a local copy of the MIT-BIH
Arrhythmia Database:

```matlab
wfdbx.wfdbx_set_input_dir('/data/mitdb');
rec = wfdbx.read_record('100');          % reads /data/mitdb/100.hea and 100.dat
wfdbx.write_annotations('100', 'qrs', [100 460], 'symbols', {'N', 'N'}, ...
    'dir', 'out');                       % writes out/100.qrs
```

The signal files that a header names are read from the header's folder.

### Record names

A record name is made of letters, digits, `_`, `-` and `~`. `/` separates
folders, and the names of folders may contain any characters, such as dots:
`my.data/rec` is a valid record name, `rec.1` is not. A name whose last part
contains a dot is the name of a file: `100s.hea` is read as the header of
record `100s`, and `100s.edf` as an EDF file.

Records can be written under any such name: `wfdbx.write_record('my.data/rec',
...)` creates `my.data/rec.hea` and `my.data/rec.dat`. The header names the
record and its signal file without the folder (`rec`, `rec.dat`), so the
record can be read under any path that leads to it. Annotator names may
contain letters, digits, `_`, `-` and `~`.

### Reading from PhysioNet

Set the input directory to the URL of the database and turn network access
on. The URL of a database is `https://physionet.org/files/<database>/<version>/`.
This example reads record 100 of the MIT-BIH Arrhythmia Database:

```matlab
rec = wfdbx.read_record('100', 'input_dir', 'https://physionet.org/files/mitdb/1.0.0/', ...
                        'network', true);
```

Remote files are read once and kept for the rest of the session. A download
gives up when it cannot connect, or receives nothing, for 30 seconds.

## Signal parameters

WFDB-x never assumes a sampling frequency, gain, ADC resolution or units
that a record does not give. Where one is needed, it must be given: in
`write_record`, as the `'fs'` option of `read_annotations`, or as an option
of the tools (see below). A record whose header gives no frequency has `fs =
0`. See
[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md)
for the reasons.

## Command-line tools

With Octave, run a tool through the script `bin/wfdbx_cli.m`. Its first
argument names the tool, and the rest are the tool's arguments. An alias
makes this shorter. These examples define the alias, then read the sample
record `100s` (the first minute of record 100 of the MIT-BIH Arrhythmia
Database) from the folder `tests/data` of a copy of the repository:

```sh
alias wfdbx='octave-cli --no-gui --norc -q /path/to/wfdb-x/matlab/bin/wfdbx_cli.m'
export WFDBX_INPUT_DIR=/path/to/wfdb-x/tests/data
wfdbx rdsamp -r 100s -t 10 -p      # print the first 10 seconds, in physical units
wfdbx rdann -r 100s -a atr         # print the annotations
wfdbx --list                       # list the tools
```

With MATLAB, run a tool through the shell script `bin/wfdbx_matlab.sh`,
which starts `matlab -batch`. Set `WFDBX_MATLAB` to the MATLAB command if
`matlab` is not on the `PATH`:

```sh
export WFDBX_INPUT_DIR=/path/to/wfdb-x/tests/data   # the sample record 100s
/path/to/wfdb-x/matlab/bin/wfdbx_matlab.sh rdsamp -r 100s -t 10 -p
```

Inside MATLAB or Octave, a tool is a function. It takes its arguments as a
cell array and returns its exit status:

```matlab
wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');   % the sample record 100s
status = wfdbx.apps.rdsamp({'-r', '100s', '-t', '10', '-p'});
```

The tools have the options and output of the original WFDB tools, which are
described in the *WFDB Applications Guide*
([`third_party/wag.pdf`](https://github.com/alphanumericslab/wfdb-x/tree/main/third_party)).
`help wfdbx.apps.TOOL` shows the usage of a tool.

* signals: `rdsamp`, `wrsamp`, `wfdbdesc`, `sigamp`, `snip`, `xform`,
  `sampfreq`, `signame`, `signum`, `wfdbcat`, `wfdbwhich`
* times: `wfdbtime`, `time2sec`
* annotations: `rdann`, `wrann`, `sortann`, `ann2rr`, `rr2ann`
* converters: `edf2mit`, `mit2edf`, `rdedfann`, `wav2mit`, `mit2wav`,
  `wfdb2mat`, `a2m`, `m2a`, `ad2m`, `md2a`, `ahaecg2mit`, `makeid`, `readid`,
  `revise`, `parsescp`

The tools use the environment variables of the table above. To read record
100 of the MIT-BIH Arrhythmia Database from PhysioNet:

```sh
export WFDBX_INPUT_DIR=https://physionet.org/files/mitdb/1.0.0/
export WFDBX_NETWORK=1
wfdbx rdsamp -r 100 -t 0:05
```

Tools that write signal parameters require them as options:

| Tool | Required options |
|---|---|
| `wrsamp` (with `-o`) | `-F` frequency, `-G` gain, `-R` ADC resolution, and `-U` units for calibrated signals |
| `wav2mit` | `-G` gain, and `-U` units unless the gain is 0 |
| `ad2m`, `ahaecg2mit` | `-F`, `-G`, `-R`, and `-U` unless the gain is 0 |
| `a2m`, `rdann`, `ann2rr`, `sortann`, `m2a` | `-F` frequency, when the record's header does not give one |

For example, where `samples.txt` stands for a text file of samples in the
current folder, `wfdbx wrsamp -F 250 -G 200 -R 16 -U mV -i samples.txt -o rec`
writes the record `rec` there.

## The WFDB library functions

Every function of the WFDB library is available under its C name in the
package `wfdbx`, with the same arguments and return values, so programs and
documentation written for the C library carry over directly. Where a C
function fills an array passed by the caller, the MATLAB function returns it
as an extra output. The example reads the sample record `100s` from
`tests/data`:

```matlab
wfdbx.wfdbx_set_input_dir('/path/to/wfdb-x/tests/data');
[nsig, si] = wfdbx.isigopen('100s', 2);   % open 2 signals; si holds their specifications
[stat, v] = wfdbx.getvec();               % v holds one sample per signal
x = wfdbx.getframes(3600);                % the next 3600 frames, as a 3600-by-2 matrix

wfdbx.annopen('100s', wfdbx.anninfo('atr', wfdbx.WFDB_READ()));
[stat, a] = wfdbx.getann(0);
while stat == 0
    fprintf('%d %s\n', a.time, wfdbx.annstr(a.anntyp));
    [stat, a] = wfdbx.getann(0);
end
wfdbx.wfdbquit();
```

Differences from C that come from the language:

* Strings are char vectors, one character per byte. A C `NULL` string is
  `[]`. Record names can also be MATLAB strings.
* Samples, times and counts are doubles.
* C structures are MATLAB structures with the same fields. `wfdbx.siginfo(n)`,
  `wfdbx.anninfo(name, mode)`, `wfdbx.annotation()`, `wfdbx.calinfo()` and
  `wfdbx.seginfo(n)` create them.
* An annotation's `aux` is `[]`, or a `uint8` row vector whose first element
  is the length of the text that follows, as in C. `char(a.aux(2:1 + a.aux(1)))`
  is the text.
* Constants are functions without arguments: `wfdbx.WFDB_READ()`,
  `wfdbx.NORMAL()`, ... `C = wfdbx.ecgcodes()` returns all the annotation
  codes as one structure (`C.NORMAL`, `C.PVC`, ...).
* `wfdbx.getframes(n)` reads up to `n` frames at once, as a matrix with one
  row per frame. `wfdbx.putframes(M)` writes the rows of `M`.
* Errors are reported by return values, as in C, not by MATLAB errors.
  `wfdbx.wfdberror()` returns the last message, `wfdbx.wfdb_error(fmt,
  ...)` reports a message of your own as the library does, and
  `wfdbx.wfdbquiet()` stops the messages from being printed.
* `wfdbx.wfdbx_write_errors()` (a WFDB-x addition) returns the number of
  output files that the library could not write, flush or close, plus those
  counted by `wfdbx.wfdbx_note_write_error()` (also an addition), which a
  program that writes a file itself calls. The tools exit with status 1 when
  the count goes up or the standard output cannot be written ("TOOL: write
  error on standard output"); in legacy mode they keep status 0, as in C.
* The library keeps the open record and annotators between calls, as in C.
  `wfdbx.wfdbquit()` closes them; the directory and network settings are
  kept.

The functions of `<wfdb/ecgmap.h>` (`wfdbx.isqrs`, `wfdbx.map1`,
`wfdbx.map2`, ...) are also provided. Use `help wfdbx.NAME` on any function
for its documentation.

## Legacy mode

Legacy mode reproduces the original WFDB package exactly, including its
assumed signal parameters and its search for files. Use it only to reproduce
old results:

* tools: `--legacy` as the first argument, as in `wfdbx rdsamp --legacy -r
  100s`, run in the directory of the sample record `100s` (`tests/data` in a
  copy of the repository). Legacy mode finds files through the WFDB path,
  which begins with the current directory, and does not use the input
  directory;
* high-level functions: `'legacy', true`;
* the whole library: `wfdbx.wfdbx_set_legacy(1)`.

[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md#legacy-mode)
describes what changes in legacy mode.

## Notes

* **MATLAB and Octave.** The same code runs in both. It is tested with GNU
  Octave 8.4. It has not yet been run in MATLAB, but it uses only features
  that both provide.
* **Help.** In Octave, `help wfdbx` does not list the package; use
  `help wfdbx.Contents`.
* **Starting the tools.** Octave starts in a fraction of a second, so the
  Octave script suits everyday use. MATLAB starts slowly, so
  `wfdbx_matlab.sh` is mainly useful for testing. It reads all of its
  standard input before it starts MATLAB. When it runs from a script whose
  standard input stays open, add `< /dev/null`.
* **Network access.** Remote files are downloaded with the `curl` program
  when it is installed. Otherwise WFDB-x uses `webread` in Octave and
  `websave` in MATLAB.
* **FLAC.** Formats 508, 516 and 524 (FLAC-compressed signals) are read and
  written without any external library. The C library reads files written
  by WFDB-x with identical sample values, although the compressed bytes
  differ from those of libFLAC.
* **Speed.** `wfdbx.read_record` and `wfdbx.write_record` work on whole
  blocks of samples, including multi-frequency and multi-segment records,
  so they are the fastest way to read and write a record (read in chunks,
  with `'sampfrom'` and `'sampto'`, records too large for memory). Code
  that processes a record as a stream should read it with the block
  reader `wfdbx.getframes`. Calling `wfdbx.getvec` sample by sample is much
  slower in MATLAB and Octave; avoid it where speed matters.
  [BENCHMARKS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/BENCHMARKS.md)
  compares the seven languages and wfdb-python.

## Testing

From the root of the repository, run the unit tests with Octave or MATLAB:

```sh
octave-cli --no-gui --norc -q --eval "cd matlab/tests; run_tests"
matlab -batch "cd matlab/tests; run_tests"
```

The cross-language conformance suite runs every tool and compares its
output with that of the C programs:

```sh
python3 tests/conformance/harness.py check --impl octave -j8
```

[DEVELOPING.md](DEVELOPING.md) describes the organization of the code.

## Authors and license

WFDB-x implements version 10.7.0 of the WFDB Software Package.

The WFDB library and tools were written by George B. Moody, with revisions by
Benjamin Moody and contributions from many others; `parsescp` was written by
George B. Moody and Edna S. Moody. Each file names the authors of the C code
it implements, and
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md)
gives the details. The MATLAB/Octave implementation was developed by Reza
Sameni (2026), through AI-assisted development, cross-language
verification and unit testing.

WFDB-x is an independent reimplementation. Its MATLAB/Octave code is a
translation of the C code of the WFDB Software Package into MATLAB/Octave,
written for WFDB-x; it is not code by the original WFDB developers. It
follows the original's logic and behavior, with the changes described
in [DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md).
The authors of the original C code are credited in each file and in
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md).

WFDB-x is distributed under the GNU General Public License, version 3 or
(at your option) any later version. See
[LICENSE](https://github.com/alphanumericslab/wfdb-x/blob/main/LICENSE).
