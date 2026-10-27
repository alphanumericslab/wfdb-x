# WFDB-x for Python

`wfdbx` reads and writes physiological signal records in the WFDB format used
by [PhysioNet](https://physionet.org). It is a complete Python implementation
of the WFDB Software Package 10.7.0: the library and all of its command-line
tools. It reads and writes the same files as the original C library, and its
tools print the same output.

You can use it in three ways:

* **High-level functions** that read and write whole records and annotation
  files as NumPy arrays: `read_record`, `read_header`, `read_annotations`,
  `write_record`, `write_annotations`, and `check_record`, which checks a
  record.
* **Command-line tools** such as `rdsamp`, `rdann` and `wrsamp`, run through
  the `wfdbx` command.
* **The WFDB library functions** under their C names (`isigopen`, `getvec`,
  `getann`, ...), for programs written against the C library.

The package is pure Python. It needs Python 3.9 or later and NumPy, and runs
on Linux, macOS and Windows.

WFDB-x is part of a project that provides the same package in seven languages
with identical behavior; see the
[project README](https://github.com/alphanumericslab/wfdb-x#readme).

## Installation

```sh
pip install wfdb-x                # the package and the wfdbx command
pip install "wfdb-x[examples]"    # also matplotlib and Jupyter, for the example notebooks
```

The package is imported as `wfdbx`. To install from a copy of the
repository, run `pip install ./python`.

## Quick start

The package includes a sample record, `100s`: the first minute of record 100
of the [MIT-BIH Arrhythmia Database](https://physionet.org/content/mitdb/),
with two ECG signals at 360 Hz and its beat annotations.

```python
import wfdbx

# Read the sample record from the package's data directory.
wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())

rec = wfdbx.read_record("100s", physical=True)   # signals in physical units
print(rec.fs, rec.names, rec.signals.shape)       # 360.0 ['MLII', 'V5'] (21600, 2)

hdr = wfdbx.read_header("100s")                    # the header only, no samples
print(hdr.nsig, hdr.nsamples)                      # 2 21600

ann = wfdbx.read_annotations("100s", "atr")        # beat annotations
print(len(ann), ann.symbols[:3], ann.samples[:3])  # 75 ['+', 'N', 'N'] [ 18  77 370]

# Write the first 10 seconds as a new record, "copy", in the current directory.
x = wfdbx.read_record("100s", sampto="0:10")       # ADC units
wfdbx.write_record("copy", x.signals, fs=x.fs, fmt=16, gains=x.gains,
                   baselines=x.baselines, adcres=11, units="mV", names=x.names)
```

## Reading and writing records

The examples in this section read the sample record `100s` (the first minute
of record 100 of the MIT-BIH Arrhythmia Database, included with WFDB-x, in
the directory `wfdbx.sample_data_dir()`), and write records of their own in
the current directory.

### Reading signals: `read_record`

```python
wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())   # the sample record 100s
rec = wfdbx.read_record("100s", channels=["MLII"], sampfrom="0:10", sampto="0:20",
                        physical=True)
```

| Argument | Meaning | Default |
|---|---|---|
| `record` | record name or path (see [Where files are read and written](#where-files-are-read-and-written)) | |
| `channels` | signals to read, by number or name (as in `names`) | all signals |
| `sampfrom`, `sampto` | first sample, and the sample after the last one: a sample number or a time string (see below) | the whole record |
| `physical` | return physical units (float64) instead of ADC units (int32) | `False` |
| `highres` | read a multi-frequency record at its highest sampling frequency | `False` |
| `pad` | replace invalid samples by the previous valid one | `False` |
| `checksum_warning` | warn when the data do not match the header's checksums | `True` |
| `input_dir`, `network` | input directory and network access for this call only | the current settings |
| `legacy` | behave as the original package (see [Legacy mode](#legacy-mode)) | `False` |

Times can be sample numbers or WFDB time strings: `"0:10"` (10 seconds),
`"1:02:03.5"`, `"s3600"` (sample 3600) or `"e"` (the end of the record).

The result is a `Record`:

| Field | Contents |
|---|---|
| `signals` | NumPy array, one row per sample and one column per signal: int32 ADC units, or float64 physical units with `physical=True` |
| `fs` | sampling frequency in Hz (0 if the header gives none) |
| `names`, `units`, `gains`, `baselines` | description (without white space at either end, which some headers add), physical units, gain (ADC units per physical unit; 0 means uncalibrated) and baseline of each signal |
| `siginfo` | the full signal specifications (`Siginfo` objects) |
| `sampfrom` | the number of the first sample returned |
| `base_time` | start time and date as text, to the second, such as `"[14:00:03 21/06/2024]"` |
| `base_time_ms` | start time in milliseconds after midnight, such as `50403500` for 14:00:03.500 |
| `base_date` | start date as `(year, month, day)` |
| `comments` | the info strings of the header |
| `checksum_ok` | `False` if the data do not match the header's checksums |

`base_time`, `base_time_ms` and `base_date` are `None` when the header does
not give them. Invalid samples are `wfdbx.WFDB_INVALID_SAMPLE`, or NaN in
physical units.

### Reading a header: `read_header`

`read_header(record)` reads the header of a record without opening its
signal files. It returns a `Header` with these fields: `name`, `fs`,
`counter_freq`, `base_counter`, `nsamples` (0 if the header does not give
the length), `nsig`, `siginfo`, `base_time`, `base_time_ms`, `base_date` and
`comments`. They have the same meaning as in `Record`.

```python
wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())   # the sample record 100s
hdr = wfdbx.read_header("100s")
for s in hdr.siginfo:
    print(s.desc, s.fmt, s.gain, s.units)
```

### Reading annotations: `read_annotations`

```python
wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())   # the sample record 100s
ann = wfdbx.read_annotations("100s", "atr", sampfrom="0:10", sampto="0:30")
```

`annotator` is the file suffix (`"atr"` reads `100s.atr`). The optional `fs`
gives the sampling frequency when the record has no header, or its header
gives none. The result is an `Annotations` object, in file order:

| Field | Contents |
|---|---|
| `samples` | annotation times, in samples (int64) |
| `codes`, `symbols` | annotation codes (`wfdbx.NORMAL`, `wfdbx.PVC`, ...) and their mnemonics (`"N"`, `"V"`, ...) |
| `subtypes`, `chans`, `nums` | subtype, channel and annotator number of each annotation (int64) |
| `aux` | auxiliary text of each annotation, or `None` |
| `fs` | the frequency in which `samples` are counted (0 if unknown) |

### Writing a record: `write_record`

```python
import numpy as np
x = np.random.randn(3600, 2)                # random numbers, written as a record "rand"
wfdbx.write_record("rand", x, fs=360, fmt=16, physical=True,
                   gains=1000, adcres=16, units="mV", names=["A", "B"])
```

This writes the header `rand.hea` and the signal file `rand.dat`. You must
give the sampling frequency, the gain and ADC resolution of each signal, and
the units of each calibrated signal; there are no defaults. A gain of 0
marks a signal as uncalibrated, which is only allowed for samples given in
ADC units. Per-signal arguments take one value for all signals, or a list
with one value per signal.

| Argument | Meaning |
|---|---|
| `signals` | array with one row per sample and one column per signal; ADC units, or physical units with `physical=True` |
| `fs` | sampling frequency in Hz |
| `fmt` | storage format, such as 16, 212, 24 or 516 (FLAC); default 16 |
| `gains`, `adcres`, `units` | gain, ADC resolution in bits, and physical units |
| `baselines`, `adczeros`, `names` | optional signal specifications |
| `base_time`, `comments` | start time (`"hh:mm:ss dd/mm/yyyy"`) and info strings |
| `samps_per_frame` | samples per frame of each signal, for a multi-frequency record; `signals` then has one row per frame and `sum(samps_per_frame)` columns |
| `dir` | directory in which to create the files |

### Writing annotations: `write_annotations`

This example writes the annotation file `rand.qrs` for the record `rand`
written above:

```python
wfdbx.write_annotations("rand", "qrs", samples=[100, 460, 820], symbols=["N", "N", "V"])
```

Give the annotation types as `symbols` or as `codes`. `subtypes`, `chans`,
`nums` and `aux` are optional. If the annotations are not in time order, the
file is sorted when it is written. `sort=False` keeps the order you gave
(without the library's advice to run `sortann`) and `sort=True` always
sorts, for that call only. Without `sort`, the `WFDBANNSORT` environment
variable decides (sorting is on unless it is `0`).

### Errors and warnings

* A record, header or annotation file that cannot be read or written raises
  `IOError`. This includes a file that cannot be written completely, for
  example on a full disk: "write error on record REC", "write error on
  annotator ANN for record REC". (`wfdbx_write_errors()` counts such errors
  for the C-style functions, which report them only with a message, as in
  C.)
* In `write_record`, `samps_per_frame` values that are not integers of at
  least 1, and a number of columns of `signals` other than their sum, raise
  `ValueError` before any file is created.
* A signal file that is shorter than its header says raises `IOError`:
  "can't read signal data of record REC (getvec status -3)".
* An annotation file that ends before its end-of-file marker raises
  `IOError`: "can't read annotation file ANN of record REC (getann status
  -3)".
* Invalid arguments, and a value the operation needs but the record does not
  give, raise `ValueError`. For example, a time string such as `"0:10"`
  needs the sampling frequency, and `physical=True` needs the gain of each
  signal.
* When the data do not match the checksums in the header, `read_record`
  returns all the data and issues a `RuntimeWarning`: "checksum error in
  record REC: the signal data do not match the checksums in its header".
  `checksum_warning=False` turns the warning off; `rec.checksum_ok` is
  `False` either way. Checksums are only checked when a read reaches the end
  of the record.
* A tool, or a program that uses the WFDB library functions, never writes a
  signal file over one of the signal files it is reading. Opening such an
  output fails with "output file NAME is also an input file". `write_record`
  reads nothing, so it overwrites any existing files of the same name.

The high-level functions call `wfdbquit()`, which closes anything opened
with the WFDB library functions.

### Checking a record: `check_record`

```python
wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())   # the sample record 100s
report = wfdbx.check_record("100s", ["atr"])
print(report)
```

`check_record(record, annotators)` checks the header of a record, its signal
specifications, every sample of its signal files, and the annotation files
you name. It reports each problem it finds. It never raises an exception for
a problem in the record. It checks for problems similar to those found by
Benjamin Moody's [wfdbcheck](https://github.com/bemoody/wfdbcheck).

The result is a `CheckReport`. `report.ok` is `True` if there is no error.
`report.issues` lists the problems. Each has a `severity`, a `code` (such as
`"checksum"`), a `where` (`""` for the record, `"signal 1"`, `"segment s2"`,
`"annotator atr"`) and a `message`.

| Severity | Meaning |
|---|---|
| `error` | the record is damaged or does not follow the WFDB format: programs will read wrong data or fail |
| `warning` | the record can be read, but something is missing or unusual, and may give wrong results |
| `info` | a fact worth knowing, such as invalid (missing) samples |

Printed, the report has one line per problem, or the line
`no problems found`:

```
warning: signal 0: the units are not specified
error: signal 1: the checksum does not match: the header gives 12, the samples sum to 13
error: annotator atr: 3 annotations are out of order; the first is at sample 50, after sample 100
```

`report.lines()` returns these lines as a list. The lines are the same in
the seven languages of WFDB-x. The checks run in normal mode, even if legacy mode is on, and the library
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

WFDB-x reads and writes files exactly where you name them, and nowhere else:

| The name is | It is read from | It is written to |
|---|---|---|
| a full path: `/data/mitdb/100`, `C:\data\100` | that path | that path |
| a home path: `~/data/100` | your home directory | your home directory |
| a URL: `https://.../100` | that URL, if network access is on | (URLs cannot be written) |
| anything else: `100`, `mitdb/100`, `../data/100` | the **input directory** | the **output directory** |

In this table, `/data/mitdb` stands for a local copy of the MIT-BIH
Arrhythmia Database, and `100` for its record 100.

The input and output directories are both the current directory unless you
set them:

| Setting | Function | Option of the high-level functions | Environment variable |
|---|---|---|---|
| input directory: a local directory, `~/...` or a URL | `wfdbx_set_input_dir(d)` | `input_dir=` | `WFDBX_INPUT_DIR` |
| output directory | `wfdbx_set_output_dir(d)` | `dir=` | `WFDBX_OUTPUT_DIR` |
| network access (off by default) | `wfdbx_set_network(1)` | `network=True` | `WFDBX_NETWORK=1` |

A function call overrides the environment variable, and an option applies to
that one call. `wfdbx_get_input_dir()`, `wfdbx_get_output_dir()` and
`wfdbx_get_network()` return the current settings, and passing `None` to a
`set` function restores the default.

In this example, `/data/mitdb` stands for a local copy of the MIT-BIH
Arrhythmia Database, which contains record 100:

```python
wfdbx.wfdbx_set_input_dir("/data/mitdb")
rec = wfdbx.read_record("100")          # reads /data/mitdb/100.hea and 100.dat
wfdbx.write_annotations("100", "qrs", samples=[100, 460], symbols=["N", "N"],
                        dir="out")       # writes out/100.qrs
```

The signal files that a header names are read from the header's directory.

### Record names

A record name is made of letters, digits, `_`, `-` and `~`. `/` separates
directories, and the names of directories may contain any characters, such
as dots: `my.data/rec` is a valid record name, `rec.1` is not. A name whose
last part contains a dot is the name of a file: `100s.hea` is read as the
header of record `100s`, and `100s.edf` as an EDF file.

Records can be written under any such name: `write_record("my.data/rec",
...)` creates `my.data/rec.hea` and `my.data/rec.dat`. The header names the
record and its signal file without the directory (`rec`, `rec.dat`), so the
record can be read under any path that leads to it. Annotator names may
contain letters, digits, `_`, `-` and `~`.

### Reading from PhysioNet

Set the input directory to the URL of the database and turn network access
on. The URL of a database is `https://physionet.org/files/<database>/<version>/`.
This example reads record 100 of the MIT-BIH Arrhythmia Database:

```python
rec = wfdbx.read_record("100", input_dir="https://physionet.org/files/mitdb/1.0.0/",
                        network=True)
```

Remote files are read once and kept for the rest of the session. A download
gives up when it cannot connect, or receives nothing, for 30 seconds.

## Signal parameters

WFDB-x never assumes a sampling frequency, gain, ADC resolution or units
that a record does not give. Where one is needed, you must give it: in
`write_record`, as the `fs` argument of `read_annotations`, or as an option
of the tools (see below). A record whose header gives no frequency has
`fs = 0`. See
[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md)
for the reasons.

## Command-line tools

Run a tool through the `wfdbx` command. These examples read the sample
record, so they first set the input directory to the package's data
directory:

```sh
export WFDBX_INPUT_DIR=$(python -c "import wfdbx; print(wfdbx.sample_data_dir())")
wfdbx rdsamp -r 100s -t 10 -p      # print the first 10 seconds, in physical units
wfdbx rdann -r 100s -a atr         # print the annotations
wfdbx --list                       # list the tools
```

The tools have the options and output of the original WFDB tools, which are
described in the *WFDB Applications Guide*
([`third_party/wag.pdf`](https://github.com/alphanumericslab/wfdb-x/tree/main/third_party)):

* signals: `rdsamp`, `wrsamp`, `wfdbdesc`, `sigamp`, `snip`, `xform`,
  `sampfreq`, `signame`, `signum`, `wfdbcat`, `wfdbwhich`
* times: `wfdbtime`, `time2sec`
* annotations: `rdann`, `wrann`, `sortann`, `ann2rr`, `rr2ann`
* converters: `edf2mit`, `mit2edf`, `rdedfann`, `wav2mit`, `mit2wav`,
  `wfdb2mat`, `a2m`, `m2a`, `ad2m`, `md2a`, `ahaecg2mit`, `makeid`, `readid`,
  `revise`, `parsescp`

When an output file or the standard output cannot be written (a full disk,
for example), a tool reports it and exits with status 1, as the standard
Unix tools do (the original tools exited with status 0).

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

For example, `wfdbx wrsamp -F 250 -G 200 -R 16 -U mV -i samples.txt -o rec`
writes a record, `rec`, from the columns of numbers in the text file
`samples.txt`.

## The WFDB library functions

Every function of the WFDB library is available under its C name, with the
same arguments and return values, so programs and documentation written for
the C library carry over directly. Where a C function fills an array, the
Python function fills a list that you pass. This example reads the sample
record `100s` (the first minute of record 100 of the MIT-BIH Arrhythmia
Database, included with WFDB-x):

```python
import wfdbx as w

w.wfdbx_set_input_dir(w.sample_data_dir())   # the directory of 100s

si = []
nsig = w.isigopen("100s", si, 2)     # open 2 signals; si receives their specifications
v = [0] * nsig
while w.getvec(v) > 0:               # v receives one sample per signal
    ...

a = w.Annotation()
w.annopen("100s", [w.Anninfo("atr", w.WFDB_READ)])
while w.getann(0, a) == 0:
    print(a.time, w.annstr(a.anntyp), a.aux_string())
w.wfdbquit()
```

Differences from C that come from the language:

* Strings are `str`. Text and binary data are handled as ISO-8859-1, so every
  byte sequence round-trips unchanged.
* An annotation's `aux` is `None`, or `bytes` whose first byte is the length
  of the text that follows, as in C. `Annotation.aux_string()` returns the
  text.
* `getframes(n)` reads up to `n` frames at once, as `n` calls of `getvec`
  would, but decoding whole blocks of the signal files (also for
  multi-frequency and multi-segment records). It returns a NumPy array
  with one row per frame, and the `getvec` status of the first frame it
  could not read. If it read all `n` frames, the status is the number of
  signals.
* `getseginfo()` returns a list of `Seginfo` objects.
* Errors are reported by return values, as in C, not by exceptions.
  `wfdberror()` returns the last message, and `wfdbquiet()` stops the
  messages from being printed.
* The library keeps the open record and annotators between calls, as in C.
  `wfdbquit()` closes them; the directory and network settings are kept.

The annotation codes (`NORMAL`, `PVC`, ...) and the functions of
`<wfdb/ecgmap.h>` (`isqrs`, `map1`, `map2`, ...) are also provided. Use
`help()` on any function for its documentation.

## Legacy mode

Legacy mode reproduces the original WFDB package exactly, including its
assumed signal parameters and its search for files. Use it only to reproduce
old results:

* tools: `--legacy` as the first argument, as in `wfdbx rdsamp --legacy -r 100s`,
  run in the directory of the sample record `100s` (`wfdbx.sample_data_dir()`).
  Legacy mode finds files through the WFDB path, which begins with the
  current directory, and does not use the input directory;
* high-level functions: `legacy=True`;
* the whole library: `wfdbx_set_legacy(1)`.

[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md#legacy-mode)
describes what changes in legacy mode.

## Example notebooks

The package includes seven Jupyter notebooks. Each runs without a network
connection.

| Notebook | Contents |
|---|---|
| `01_getting_started` | reading headers and signals; ADC and physical units |
| `02_annotations_and_heart_rate` | reading annotations; RR intervals and heart rate |
| `03_writing_records` | writing records and annotations |
| `04_command_line_tools` | running the tools |
| `05_c_library_api` | the WFDB library functions |
| `06_physionet_records` | reading a record from PhysioNet |
| `07_legacy_mode` | the original package's behavior, on request |

Copy them to a directory and open them with Jupyter:

```sh
wfdbx --examples my-examples
cd my-examples
jupyter lab
```

## Notes

* **FLAC.** Formats 508, 516 and 524 (FLAC-compressed signals) are read and
  written without any external library. The C library reads files written
  by WFDB-x with identical sample values, although the compressed bytes
  differ from those of libFLAC.
* **Speed.** Reading and writing whole records is vectorized with NumPy. On
  a typical laptop, `read_record` reads 8 million samples in a few hundredths
  of a second.

## Testing

From the root of the repository:

```sh
pip install -e "./python[test]"
pytest python/tests
```

This runs the unit tests, the example notebooks and the cross-language
conformance suite (about 1000 command-line cases, a few minutes). Set
`WFDBX_CONFORMANCE=0` to skip the conformance suite, or, for example,
`WFDBX_CONFORMANCE=rdsamp,rdann` to run the cases of some tools only. The
conformance suite can also be run on its own, with more options (see
[conformance.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/conformance.md)):

```sh
python3 tests/conformance/harness.py check --impl python
```

The tests that write to `/dev/full` (write errors) are skipped where it does
not exist, on macOS and Windows.

## Authors and license

The WFDB library and tools were written by George B. Moody, with revisions by
Benjamin Moody and contributions from many others; `parsescp` was written by
George B. Moody and Edna S. Moody. Each module names the authors of the C
code it implements, and
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md)
gives the details. The Python implementation was developed by Reza Sameni
(2026), through AI-assisted development, cross-language
verification and unit testing.

WFDB-x is an independent reimplementation. Its Python code is a
translation of the C code of the WFDB Software Package into Python,
written for WFDB-x; it is not code by the original WFDB developers. It
follows the original's logic and behavior, with the changes described
in [DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md).
The authors of the original C code are credited in each file and in
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md).

WFDB-x is distributed under the GNU General Public License, version 3 or
(at your option) any later version. See
[LICENSE](https://github.com/alphanumericslab/wfdb-x/blob/main/LICENSE).
