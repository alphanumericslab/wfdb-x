# wfdb-x for Python

wfdb-x for Python (the `wfdbx` package) is a faithful Python implementation
of the WFDB library and command-line tools (WFDB Software Package 10.7.0). It
reads and writes the same files as the original C library, and its tools
produce byte-identical output. See the [project README](https://github.com/alphanumericslab/wfdb-x#readme) for the
overall design.

It offers three interfaces:

* the **command-line tools** (`rdsamp`, `rdann`, `wrsamp`, ...), run through
  the `wfdbx` command;
* a **high-level API** that reads and writes whole records and annotation
  files as NumPy arrays (`read_record`, `read_annotations`, ...);
* the **C library API**, with every function of the WFDB library under its C
  name (`isigopen`, `getvec`, `getann`, ...).

* Pure Python; the only dependency is **NumPy** (used for fast bulk reading
  and by the high-level API).
* Python 3.9 or later; Linux, macOS and Windows.

## Installation

From PyPI:

```sh
pip install wfdb-x                # the package and the wfdbx command
pip install "wfdb-x[examples]"    # also matplotlib and Jupyter, for the notebooks
```

From a copy of the repository (the Python package is its `python/`
directory):

```sh
pip install ./python            # or: pip install -e ./python (development)
```

The PyPI project is named `wfdb-x`; the package it installs is imported as
`wfdbx`, and its command is `wfdbx`.

## Examples and sample data

The package includes example Jupyter notebooks, each self-contained and
runnable without a network connection:

| Notebook | Contents |
|---|---|
| `01_getting_started` | the input directory; reading headers and signals; ADC and physical units |
| `02_annotations_and_heart_rate` | reading annotations; RR intervals and heart rate |
| `03_writing_records` | writing records and annotations, with explicit signal parameters |
| `04_command_line_tools` | running the tools (`rdsamp`, `rdann`, `wrsamp`, ...) |
| `05_c_library_api` | the C-style API (`isigopen`, `getvec`, `getann`, ...) |
| `06_physionet_records` | reading a record directly from PhysioNet, by explicit choice (with an offline fallback) |
| `07_legacy_mode` | the original package's assumptions, on request |

Copy them to a directory of yours and open them:

```sh
wfdbx --examples my-examples     # or: python -c "import wfdbx; wfdbx.copy_examples('my-examples')"
cd my-examples
jupyter lab                      # or: jupyter notebook
```

They use the sample record `100s`, also included in the package: the first
minute of record 100 of the
[MIT-BIH Arrhythmia Database](https://physionet.org/content/mitdb/) (two ECG
signals at 360 Hz, with its beat annotations). `wfdbx.sample_data_dir()`
gives its directory; use it as the input directory:

```python
import wfdbx
rec = wfdbx.read_record("100s", physical=True, input_dir=wfdbx.sample_data_dir())
wfdbx.wfdbx_set_input_dir(wfdbx.sample_data_dir())     # or for all that follows
```

or, for the tools, `export WFDBX_INPUT_DIR="$(python -c 'import wfdbx; print(wfdbx.sample_data_dir())')"`.

## Command-line tools

All tools are run through the `wfdbx` command, or as Python modules:

```sh
wfdbx rdsamp -r 100s -t 10 -v -p     # same as the C 'rdsamp'
wfdbx --examples my-examples         # copy the example notebooks
python -m wfdbx.apps.rdann -r 100s -a atr
wfdbx --list                          # list the available tools
wfdbx --version
```

Options, output, error messages and exit statuses are those of the original
tools, documented in the *WFDB Applications Guide*
([`third_party/wag.pdf`](https://github.com/alphanumericslab/wfdb-x/tree/main/third_party)). Available tools:

* signals: `rdsamp`, `wrsamp`, `wfdbdesc`, `sigamp`, `snip`, `xform`,
  `sampfreq`, `signame`, `signum`, `wfdbcat`, `wfdbwhich`
* time conversion: `wfdbtime`, `time2sec`
* annotations: `rdann`, `wrann`, `sortann`, `ann2rr`, `rr2ann`
* converters: `edf2mit`, `mit2edf`, `rdedfann`, `wav2mit`, `mit2wav`,
  `wfdb2mat`, `a2m`, `m2a`, `ad2m`, `md2a`, `ahaecg2mit`, `makeid`, `readid`,
  `revise`, `parsescp`

The tools never assume a sampling frequency, a gain, an ADC resolution or
units that a record or the user did not give; see
*No built-in signal parameters* below.

Records are found as described in *Finding records and files* below (the
tools use the environment variables `WFDBX_INPUT_DIR`, `WFDBX_OUTPUT_DIR` and
`WFDBX_NETWORK`).

## Finding records and files

Every relative name is read under the input directory and written under the
output directory -- whatever you set as the input directory, a local
directory or a URL, prefixes it; a name given as a full path (`/Users/...`),
a `~` path or a URL is used as given; nothing else is searched. (The
original library searched the directories of the WFDB path, and possibly
`http://physionet.org/physiobank/database`: a search can silently open the
wrong file, such as a stale copy earlier in the path, and fails in ways
nobody notices; wfdb-x tries exactly one location.) Relative names may
contain directories and `..` (`"mitdb/100"`, `"../data/100"`).

| Setting | Python | Environment variable | Default |
|---|---|---|---|
| input directory (a directory, a `~` path or a URL) | `wfdbx_set_input_dir(d)` (returns the previous one), `wfdbx_get_input_dir()`; `input_dir=` of the readers | `WFDBX_INPUT_DIR` | none: the current directory |
| output directory (local) | `wfdbx_set_output_dir(d)`, `wfdbx_get_output_dir()`; `dir=` of the writers | `WFDBX_OUTPUT_DIR` | none: the current directory |
| network access | `wfdbx_set_network(1)` (returns the previous setting), `wfdbx_get_network()`; `network=` of the readers | `WFDBX_NETWORK` (a non-zero number: on) | off |

A function call overrides the environment variable (read when the setting
is first needed); `None` (or `""`; for the network, `None` or a negative
number) restores the default, i.e. the environment variable's value if it is
set. A relative or `~` directory is used relative to the current directory
(or expanded) when a file is opened. The high-level readers set `input_dir=`
and `network=` for the duration of the call only (and restore the previous
values, also on errors); `None` keeps the current setting.

**PhysioNet.** The files of a PhysioNet database are under
`https://physionet.org/files/<database>/<version>/`. Reading from it is an
explicit choice -- wfdb-x never contacts a server unless network access is
on:

```python
wfdbx.wfdbx_set_input_dir("https://physionet.org/files/mitdb/1.0.0/")
wfdbx.wfdbx_set_network(1)
rec = wfdbx.read_record("100", sampto="0:10", physical=True)
# or, for one call:
rec = wfdbx.read_record("100", input_dir="https://physionet.org/files/mitdb/1.0.0/",
                        network=True)
```

```sh
WFDBX_NETWORK=1 WFDBX_INPUT_DIR=https://physionet.org/files/mitdb/1.0.0/ wfdbx rdsamp -r 100 -t 0:5
```

Remote files are read with `urllib`, in full, and kept for the rest of the
process (each URL is requested at most once; redirects are followed, an HTTP
status of 400 or more is a failure, and reading gives up if connecting takes 30 s or no data arrives for 30 s, with no limit on the total time).
They are read-only: a URL
cannot be written, nor be the output directory. With network access off, a
URL is not opened, and the first attempt prints `wfdb-x: network access is
disabled; set WFDBX_NETWORK=1 or call wfdbx_set_network(1) to open URL`.

**Files named in headers.** The signal files named in a header, and the
segments of a multi-segment record, are in the directory of that header (on
disk or at its URL) or below it: `100.dat` is read next to `100.hea`, and
`data/a.dat` in its subdirectory `data`. Nothing else is tried, and a name
that is absolute, begins with `~`, is a URL or contains a `..` component is
refused (`init: file NAME named in the header of record REC is not in the
header's directory`), so that a header (perhaps downloaded) cannot make the
library read other local files or contact other servers. (`~` as a segment
name, a null segment, and `-` as a signal file name, the standard input,
keep their meaning.) Annotation files, `.info` files and the calibration
file (`WFDBCAL`) follow the rule above with the name as given: the
annotations of record `mitdb/100` are `<input directory>/mitdb/100.atr`.

**The C-style API.** `setwfdb(p)` sets the input directory: `p` must name a
single directory (`setwfdb("data")`; `""` or `";"` restores the default;
several, such as `". data"`, are an error: `setwfdb: wfdb-x reads from a
single input directory; use wfdbx_set_input_dir (or legacy mode for the WFDB
search path)`). `setwfdb` splits its argument at spaces, as the original does, so a directory whose name contains a space must be set with `wfdbx_set_input_dir`, which takes the name as it is.
`getwfdb()` returns the input directory, or `"."` if none is
set; `resetwfdb()` restores the value set by the last `setwfdb`
(`wfdbquit()` leaves the settings as they are). The `WFDB` environment
variable is not used: if it is set, the first lookup prints `wfdb-x: the
WFDB environment variable is ignored; set WFDBX_INPUT_DIR instead (or use
legacy mode)`.

**Legacy mode** (`--legacy`, `wfdbx_set_legacy(1)`, `legacy=True`) keeps the
original search of the WFDB path (`WFDB`, `setwfdb` with several entries,
`@file` paths, `%r`, names containing `..` refused), without any network
access (as the reference C build, compiled without network support: URL
names and URL path entries are not opened). The input directory and
`WFDBX_NETWORK` are not used in legacy mode; the output directory is.

## No built-in signal parameters

The original package silently assumes a sampling frequency (250 Hz), a gain
(200 adu/mV), an ADC resolution (12 bits) and units (millivolts) whenever a
record or the user does not give them. These values describe the equipment
of the first PhysioNet databases, not modern recordings, and a silently
assumed value corrupts every time, duration, resampled signal and physical
value derived from it, with nothing in the output to show it. wfdb-x
therefore never assumes them: tools that write them require them, and an
operation that needs a value missing from a record stops with a clear error
instead of guessing. This deliberate divergence, the same in every wfdb-x
implementation, is described in
[`docs/DIVERGENCES.md`](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md).

New or now required options:

* `wrsamp`: with `-o`, `-F FREQ`, `-G GAIN` and the new `-R BITS` (ADC
  resolution) are required, and the new `-U UNITS` is required for
  calibrated signals unless the input's second line gives the units (`-G`,
  `-R` and `-U` take a quoted list, one value per signal, the last value
  applying to the remaining signals).
* `wav2mit`: new required `-G GAIN` (0: uncalibrated) and `-U UNITS` (unless
  the gain is 0); the frequency and resolution come from the WAV file.
* `ad2m` and `ahaecg2mit`: new required `-F`, `-G`, `-R` and `-U` (unless the
  gain is 0); the options of `ahaecg2mit` precede the input files.
* `a2m`: new `-F FREQ`, used when the record header gives no frequency;
  annotation times in milliseconds are converted at the record's frequency
  (C assumed 4 ms per sample).
* `rdann`, `ann2rr`, `sortann` and `m2a`: new `-F FREQ`, used when the record
  header is missing or gives no frequency.
* `mit2edf` stops if the frequency, a gain or an ADC resolution is not
  specified; `xform` asks for an ADC resolution it cannot take from the
  input; unspecified units are shown as `nd` (by `rdsamp -v`, `wfdbdesc`,
  `wfdb2mat`, `mit2edf` and `xform`), and an unspecified ADC resolution as 0
  (`wfdbdesc`: "not specified").

To reproduce the results of the original tools, give the values they
assumed explicitly, for example:

```sh
wfdbx wrsamp -F 250 -G 200 -R 16 -U mV -o rec -i samples.txt
wfdbx ad2m -F 250 -G 400 -R 12 -U mV -i 1201.dat -r 1201
wfdbx ahaecg2mit -F 250 -G 400 -R 12 -U mV 1201.ecg
wfdbx wav2mit -G 6400 -U mV -i sound.wav     # 16-bit; 12.5 for 8-bit files
wfdbx a2m -F 250 -i 1201.ANO
```

**Legacy mode.** For compatibility, the original behavior remains available
on request. `--legacy` as the first argument of any tool (`wfdbx rdsamp
--legacy -r 100s -t 10`) makes it behave exactly as the original tool (same
options, outputs, messages, help texts and exit statuses; the options added
by wfdb-x are then unrecognized). In the library, `wfdbx_set_legacy(1)`
turns legacy mode on (it returns the previous setting; `wfdbx_get_legacy()`
returns the current one), and the high-level functions take a `legacy=False`
keyword: `legacy=True` gives the behavior of the original package (for
example, `write_record` without gains writes 200 adu/mV and an ADC resolution
based on the format, and `read_record(..., physical=True)` assumes 200 adu/mV
for uncalibrated signals and 250 Hz for a header without a frequency), with
legacy mode on for the duration of the call. Legacy mode reproduces the
original package exactly, and is tested against its results (the legacy
conformance suite, `harness.py check --legacy`). It is kept for
compatibility only: the values it assumes are exactly the silent defaults
this project removed, so results produced with it carry the same risks.

## High-level API

```python
import wfdbx

rec = wfdbx.read_record("100s", sampfrom="0:10", sampto="0:20", physical=True)
rec.signals        # NumPy array, one column per signal (mV here)
rec.fs, rec.names, rec.units, rec.base_time, rec.comments

ann = wfdbx.read_annotations("100s", "atr")
ann.samples, ann.symbols, ann.subtypes, ann.chans, ann.nums, ann.aux

wfdbx.write_record("new", rec.signals, fs=360, fmt=212, physical=True,
                   gains=200, adcres=11, units="mV", names=["MLII", "V5"])
wfdbx.write_annotations("new", "atr", ann.samples, ann.symbols)
```

| Function | Purpose |
| --- | --- |
| `read_record(record, channels=None, sampfrom=0, sampto=None, physical=False, highres=False, pad=False)` | Read signals into a `Record` (`signals` array of shape (samples, signals), plus `fs`, `names`, `units`, `gains`, `baselines`, `base_time`, `comments`, `siginfo`). |
| `read_annotations(record, annotator, sampfrom=0, sampto=None, fs=None)` | Read an annotation file into an `Annotations` object (`samples`, `codes`, `symbols`, `subtypes`, `chans`, `nums`, `aux`, `fs`). |
| `read_header(record)` | Return the list of `Siginfo` objects (signal specifications) of a record, without reading any samples. |
| `write_record(record, signals, fs, fmt=16, gains=..., adcres=..., units=..., ..., dir=None)` | Write a header and a signal file (`record.dat`) from an array (`gains`, `adcres` and the `units` of calibrated signals are required), in the directory `dir` if given. |
| `write_annotations(record, annotator, samples, symbols=None, codes=None, ..., dir=None)` | Write an annotation file (in the directory `dir` if given). |

Notes:

* Records are found as described in *Finding records and files*:
  `read_header`, `read_record` and `read_annotations` take `input_dir=` and
  `network=` (for the call only), the writers `dir=`. Times (`sampfrom`,
  `sampto`) are sample numbers or WFDB time strings such as `"0:10"` (10 s),
  `"s3600"` (sample 3600) or `"e"` (end of record); `sampto` is exclusive.
* `read_record` also accepts `channels` (numbers or names), `highres=True`
  (multi-frequency records at the highest sampling frequency), and `pad=True`
  (replace invalid samples by the previous valid one). Invalid samples are
  `wfdbx.WFDB_INVALID_SAMPLE` (or NaN in physical units).
* No sampling frequency, gain, ADC resolution or units are ever assumed (see
  [`docs/DIVERGENCES.md`](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md)):
  * `write_record` requires `gains` (a scalar or one value per signal); a
    gain of 0 marks a signal as uncalibrated, which is allowed only for
    samples in ADC units. `fs` must be greater than 0. `adcres` (ADC
    resolution in bits, >= 1; none is inferred from the format) is required,
    and so are the `units` of every signal whose gain is not 0 (otherwise
    `ValueError`: "ADC resolution(s) must be specified" or "units must be
    specified").
  * `read_record` reports an unspecified ADC resolution as 0
    (`siginfo[k].adcres`) and unspecified units as `None` (never "mV").
  * `read_record` returns `fs = 0` for a record whose header gives no
    sampling frequency; time strings that need it (anything but sample
    numbers `"s..."`, `"e"`, `"i"` and `"o"`; see
    `wfdbx.wfdbx_time_needs_freq`) then raise `ValueError`, as does
    `physical=True` for a selected uncalibrated signal.
  * `read_annotations` takes an optional `fs`, used (like `rdann -F`) when
    the record has no header or its header gives no frequency; without one,
    the result's `fs` is 0 and time strings that need it raise `ValueError`.
* Errors raise `IOError` (a record, header or annotation file cannot be read
  or written) or `ValueError` (unknown channel, inconsistent arguments,
  missing sampling frequency, gain, ADC resolution or units).
* `read_record` raises `IOError` ("can't read signal data of record REC
  (getvec status S)") when reading stops with a getvec status below -1, e.g.
  -3 for a signal file shorter than its header says, instead of returning the
  samples read so far; reaching the end of the record is not an error. This
  applies in legacy mode too, since the high-level API is a wfdb-x addition
  (the C-compatible `getvec`/`getframes` and the tools are unchanged).
  A checksum error (status -4: all the samples were read, but their sums do
  not match the checksums in the header) is not an error: `read_record`
  returns the data and issues a `RuntimeWarning` ("checksum error in record
  REC: the signal data do not match the checksums in its header"; the
  library's own "getvec: checksum error" message is not printed), unless
  `checksum_warning=False`.
* An output signal file is never one of the files being read: a writer, a
  tool or `osigfopen`/`osigopen` that would create a signal file that is the
  same file (compared as files, not by name) as a signal file of the open
  input record, including the segments of a multi-segment record, fails
  with "osigfopen: output file F is also an input file" (`osigopen:` from
  `osigopen`) instead of
  truncating it (e.g. `xform -i vlay -o fmt16`, `fmt16` being a segment of
  `vlay`); not in legacy mode.
* These functions call `wfdbquit()`, so they close anything opened with the
  C library API.

See `help(wfdbx.read_record)` and the other docstrings for all the arguments.

### Directories, absolute paths and annotation order

**Output directory.** `write_record(..., dir="out")` and
`write_annotations(..., dir="out")` create their files in the directory
`out` (which must exist: otherwise `FileNotFoundError`), and the header names
the record and its signal file without the directory (`rec 2 360 ...`,
`rec.dat ...`), so that the record opens from that directory under its plain
name (`read_record("rec", input_dir="out")`, or `read_record("out/rec")`).
The record name must not contain a directory when `dir` is given
(`ValueError`). In the library API, `wfdbx_set_output_dir("out")` makes every
output file be created in `out` (it returns the previous directory;
`wfdbx_set_output_dir(None)` restores the default, and
`wfdbx_get_output_dir()` returns the current one); the writers set it for
the duration of the call. The C-style API and the tools are otherwise
unchanged: `newheader("out/rec")` and `wfdbx wrsamp -o out/rec` still record
the name `out/rec`, as in C.

**Absolute paths.** A record named by an absolute path
(`read_record("/data/mitdb/100")`, `wfdbx rdsamp -r /data/mitdb/100`) is
opened as given, and its signal files are found next to its header. The C
library searched for such a name in each directory of the WFDB path (`./` +
the name), so that it was found only from the root directory; it still does
so in legacy mode, where an empty component in the WFDB path makes names be
used as given: with `setwfdb(";")` (or `WFDB=";"`), `/data/mitdb/100` opens
in legacy mode too.

**Annotation order.** Annotations written out of canonical order (by time,
then `num`, then `chan`) are rearranged when the file is closed, in the same
process, with a result identical byte for byte to that of `sortann` (the
last of several annotations with the same time, `num` and `chan` is kept,
and `NOTQRS` annotations are dropped); `WFDBANNSORT=0` disables it. Unlike
the original `sortann`, neither the sort nor the `sortann` tool loses an
out-of-order annotation at time 0 (written after later ones), nor those
inserted after it. The C library ran the `sortann` program (found in the
`PATH`), as legacy mode does (running `python -m wfdbx.apps.sortann
--legacy`, in the output directory if one is set), with the original loss.

## C library API

Every function of the WFDB library is available under its C name, with the
same arguments and return values (see `help(wfdbx.isigopen)`, for example).
Where a C function fills an array supplied by the caller, the Python function
fills a list supplied by the caller:

```python
import wfdbx as w

si = []                                   # list of w.Siginfo
nsig = w.isigopen("100s", si, 2)          # opens 2 signals, fills si
v = [0] * nsig
while w.getvec(v) > 0:                    # v receives one sample per signal
    ...
print(w.timstr(w.strtim("e")), si[0].desc, si[0].gain)

a = w.Annotation()
w.annopen("100s", [w.Anninfo("atr", w.WFDB_READ)])
while w.getann(0, a) == 0:
    print(a.time, w.annstr(a.anntyp), a.aux_string())
w.wfdbquit()
```

Notes on the correspondence with C:

* As in every wfdb-x implementation, the library assumes no sampling
  frequency or gain ([`docs/DIVERGENCES.md`](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md)):
  `sampfreq` returns 0 for a header without a frequency; without a
  frequency, `strtim` fails (returns 0) for strings that need one, `timstr`
  and `mstimstr` return the time as a sample number (`"s360"`), and
  `setifreq` fails; `aduphys`, `physadu`, `adumuv` and `muvadu` fail for an
  uncalibrated signal or an invalid signal number (NaN or
  `WFDB_INVALID_SAMPLE`). `wfdbx_time_needs_freq(string)` (a wfdb-x
  addition) tells whether `strtim` needs the frequency for a string.

* Strings are `str`; text and binary data are handled as ISO-8859-1, so any
  byte sequence round-trips unchanged.
* An annotation's `aux` field is `None` or a `bytes` object whose first byte
  is the length of the data that follows (as in C); `Annotation.aux_string()`
  returns it as a `str`.
* `getframes(n)` (not in the C library) reads up to `n` frames at once and
  returns `(array, stat)`: a NumPy array with one row per frame read, and
  the `getvec` status of the first frame that could not be read (or the
  number of signals if all `n` frames were read). It is exactly equivalent
  to up to `n` calls of `getvec`.
* `getseginfo()` returns the list of `Seginfo` objects of the open
  multi-segment record (C returns their number and an array).
* Functions that report errors in C by returning a negative code do the same
  here (they do not raise exceptions); the message is available from
  `wfdberror()`, and is printed on the standard error output unless
  `wfdbquiet()` was called.
* As in C, the library keeps global state (the open record, output signals,
  annotators, time base). Call `wfdbquit()` to reset it (the input and
  output directories and the network setting are kept).

Annotation codes (`NORMAL`, `PVC`, ...) and the mapping functions of
`<wfdb/ecgmap.h>` (`isqrs`, `map1`, `map2`, `ammap`, `mamap`, `annpos`, ...)
are also provided.

## FLAC-compressed signals

Formats 508, 516 and 524 are supported without any external library. Files
written by the C library (libFLAC) are read exactly. Files written by wfdb-x are
standard FLAC streams that the C library reads back with identical sample
values; their compressed bytes differ from libFLAC's (whose output depends on
the libFLAC version and the processor).

## Performance

Sequential reading uses a vectorized (NumPy) decoder that is exactly
equivalent to the sample-by-sample path, and `write_record` a vectorized
encoder (for formats 8, 16, 24, 32, 61, 80, 160, 212, 310 and 311, when the
samples are within the range of the format) that writes the same bytes as
`putvec` (216,000 frames of 2 signals in about 0.02 s, instead of 0.6 s). For example, `rdsamp` prints a
650,000-sample, 2-signal format 212 record in about 0.9 s.

## Testing

From the root of the repository:

```sh
pip install -e "./python[test]"
pytest python/tests
```

The notebook tests execute every example notebook (they need the `test`
extra: nbformat, nbclient and ipykernel).

This runs the unit tests and the cross-language conformance suite
(`tests/conformance/`) against the Python tools. Set `WFDBX_CONFORMANCE=0` to
skip the latter, or e.g. `WFDBX_CONFORMANCE=rdsamp,rdann` to run part of it.
In a source distribution, which does not include the repository's test
records and conformance suite, the tests that need them are skipped. The
conformance suite can also be run on its own, in parallel:

```sh
PYTHONPATH=python/src python3 tests/conformance/harness.py check --impl python -j8
```

and its legacy suite (the original package's cases, run with `--legacy`)
with `... check --legacy --impl python -j8`.

## Authors and license

The WFDB library and tools were written by George B. Moody, with revisions by
Benjamin Moody and contributions from many others; `parsescp` was written by
George B. Moody and Edna S. Moody. The header of each module names the authors
of the C code it ports, and [`docs/AUTHORS.md`](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md) gives the
details. The Python implementation was developed by Reza Sameni (2026),
with AI assistance (see the project README).

The library (`wfdbx`, except `wfdbx.apps`) is distributed under the GNU
Library General Public License, version 2 or later; the command-line tools
(`wfdbx.apps`) under the GNU General Public License, version 2 or later. See
[`LICENSE.LIB`](https://github.com/alphanumericslab/wfdb-x/blob/main/LICENSE.LIB) and [`LICENSE`](https://github.com/alphanumericslab/wfdb-x/blob/main/LICENSE).
