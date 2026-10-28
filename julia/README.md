# WFDB-x for Julia

> **WFDB-x** is the WFDB Software Package (the library and its 33
> command-line tools) reimplemented in seven languages: Python, C++,
> MATLAB/Octave, Rust, Julia, R and Kotlin, tested to behave identically to
> the original C package and to each other. This is the Julia
> implementation.
> [Project page and the other languages](https://github.com/alphanumericslab/wfdb-x)
> · [WFDB-x at a glance (overview figure)](https://github.com/alphanumericslab/wfdb-x#wfdb-x-at-a-glance)
> · [Benchmarks](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/BENCHMARKS.md)

`WFDBX` reads and writes physiological signal records in the WFDB format
used by [PhysioNet](https://physionet.org). It is a complete Julia
implementation of the WFDB Software Package: the library and all of its
command-line tools. It reads and writes the same files as the original C
library, and its tools print the same output.

The package is pure Julia and uses only Julia's standard libraries. It needs
Julia 1.9 or later, and runs on Linux and macOS. Windows support is
untested.

## Three ways to use WFDB-x

All three are written in Julia; none of them calls the C library.

1. **The high-level functions (recommended).** `read_record`,
   `read_header`, `read_annotations`, `write_record`,
   `write_record_physical`, `write_annotations` and `check_record` read and
   write whole records and annotation files as Julia matrices and vectors
   (`Matrix{Int32}`, `Vector{Int64}`, ...), in one call, with keyword
   arguments, and throw a `WfdbError` on errors. They read signal files in
   large blocks, so they are the fastest way to read a record. They are an
   addition of WFDB-x: the C package has no equivalent. Use them for new
   code, analysis and notebooks.
2. **The WFDB library functions** under their C names (`isigopen`,
   `getvec`, `getann`, `putann`, ...), with the C behavior: sample by
   sample and annotation by annotation, with errors reported by return
   values. Use them to port a program written against the C library, or
   for the exact C semantics.
3. **The command-line tools** (`rdsamp`, `rdann`, `wrsamp`, `xform`, and
   29 others), with the options, output and exit status of the C tools, run
   through the driver script `bin/wfdbx.jl`, or the short `wfdbx` alias of
   [Command-line tools](#command-line-tools) (`wfdbx rdsamp -r 100s`). Use
   them in shell scripts and pipelines, or to reproduce work done with the
   original tools.

The high-level functions return exactly the samples and annotations that
the library functions (and the C library) give.

## Installation

The package is installed from a copy of the repository. In Julia, run:

```julia
using Pkg
Pkg.develop(path="/path/to/wfdb-x/julia")
```

In the package REPL, `] dev /path/to/wfdb-x/julia` does the same. The
package is loaded with `using WFDBX`. The first `using WFDBX` precompiles
the package. Later sessions and tool runs load it without compiling
anything.

## Quick start

The repository includes a sample record, `100s`, in `tests/data`: the first
minute of record 100 of the
[MIT-BIH Arrhythmia Database](https://physionet.org/content/mitdb/), with
two ECG signals at 360 Hz and its beat annotations.

```julia
using WFDBX

# Read the sample record from the repository's test data.
wfdbx_set_input_dir("/path/to/wfdb-x/tests/data")

rec = read_record("100s")                       # signals in ADC units
println(rec.fs, " ", String.(signal_names(rec)), " ", size(rec.samples))
# 360.0 ["MLII", "V5"] (21600, 2)
x = physical(rec)                               # signals in physical units
println(x[1, :])                                # [-0.145, -0.065]

hdr = read_header("100s")                       # the header only, no samples
println(hdr.nsig, " ", hdr.nsamples)            # 2 21600

ann = read_annotations("100s", "atr")           # beat annotations
println(length(ann), " ", String.(ann.symbols[1:3]), " ", ann.samples[1:3])
# 75 ["+", "N", "N"] [18, 77, 370]

# Write the first 10 seconds as a new record in the current directory.
r10 = read_record("100s"; to="0:10")
write_record("copy", r10.samples, r10.fs; fmt=16, gains=[s.gain for s in r10.siginfo],
             baselines=[s.baseline for s in r10.siginfo], adcres=11, units="mV",
             names=signal_names(r10))
```

## Reading and writing records

Each high-level function also accepts a `Wfdb` object as its first
argument, as in `read_record(w, "100s")`. It then uses the settings of that
object instead of the default ones (see
[The WFDB library functions](#the-wfdb-library-functions)).

The examples in this section read the sample record `100s` (the first
minute of record 100 of the MIT-BIH Arrhythmia Database, included with
WFDB-x in `tests/data`; see [Quick start](#quick-start)), with the input
directory set as there, and write their records and annotation files in the
current directory.

### Reading signals: `read_record`

```julia
wfdbx_set_input_dir("/path/to/wfdb-x/tests/data")   # where the sample record 100s is
rec = read_record("100s"; channels=["MLII"], from="0:10", to="0:20")
x = physical(rec)
```

| Argument | Meaning | Default |
|---|---|---|
| `record` | record name or path (see [Where files are read and written](#where-files-are-read-and-written)) | |
| `channels` | signals to read, by number (`0` is the first signal) or name (as in `signal_names`) | all signals |
| `from`, `to` | first sample, and the sample after the last one: a sample number or a time string (see below) | the whole record |
| `highres` | read a multi-frequency record at its highest sampling frequency | `false` |
| `pad` | replace invalid samples by the previous valid one | `false` |
| `checksum_warning` | warn when the data do not match the header's checksums | `true` |
| `input_dir`, `network` | input directory and network access for this call only | the current settings |
| `legacy` | behave as the original package (see [Legacy mode](#legacy-mode)) | `false` |

An integer is a sample number. A string is a WFDB time string: `"0:10"`
(10 seconds), `"1:02:03.5"`, `"s3600"` (sample 3600) or `"e"` (the end of
the record).

The result is a `Record`:

| Field | Contents |
|---|---|
| `samples` | `Matrix{Int32}` in ADC units, one row per sample and one column per signal |
| `fs` | sampling frequency in Hz (0 if the header gives none) |
| `siginfo` | the signal specifications (`Siginfo` objects): description `desc`, `units`, `gain` (ADC units per physical unit; 0 means uncalibrated), `baseline`, `adcres`, `fmt`, ... |
| `channels` | the number of each returned signal in the record (`0` is the first signal) |
| `name` | the record name |
| `sampfrom` | the number of the first sample returned |
| `base_time` | start time and date as text, to the second, such as `"[14:00:03 21/06/2024]"` |
| `base_time_ms` | start time in milliseconds after midnight, such as `50403500` for 14:00:03.500 |
| `base_date` | start date as `(year, month, day)` |
| `comments` | the info strings of the header, as bytes |
| `checksum_ok` | `false` if the data do not match the header's checksums |

`base_time`, `base_time_ms` and `base_date` are `nothing` when the header
does not give them. In `siginfo`, `units` is `nothing` and `adcres` is 0
when the header does not give them. Invalid samples are
`WFDB_INVALID_SAMPLE`.

Two functions help with a `Record`:

* `physical(rec)` returns the samples in physical units, as a
  `Matrix{Float64}`. Invalid samples become `NaN`.
* `signal_names(rec)` returns the description of each signal, as bytes,
  without the white space that a header may put at either end of it. Use
  `String.(signal_names(rec))` to get strings.

### Reading a header: `read_header`

`read_header(record)` reads the header of a record without opening its
signal files. It returns a `Header` with these fields: `name`, `fs`,
`counter_freq`, `base_counter`, `nsamples` (0 if the header does not give
the length), `nsig`, `siginfo`, `base_time`, `base_time_ms`, `base_date` and
`comments`. They have the same meaning as in `Record`. It takes the
`input_dir`, `network` and `legacy` options of `read_record`.

```julia
hdr = read_header("100s")
for s in hdr.siginfo
    println(String(s.desc), " ", s.fmt, " ", s.gain)
end
```

### Reading annotations: `read_annotations`

```julia
ann = read_annotations("100s", "atr"; from="0:10", to="0:30")
```

The second argument is the annotator, the file suffix: `"atr"` reads
`100s.atr`. The `fs` option gives the sampling frequency when the record has
no header, or its header gives none. `from`, `to`, `input_dir`, `network`
and `legacy` are as in `read_record`. The result is an `Annotations` object,
in file order. `length(ann)` is the number of annotations.

| Field | Contents |
|---|---|
| `samples` | annotation times, in samples (`Vector{Int64}`) |
| `codes`, `symbols` | annotation codes (`WFDBX.NORMAL`, `WFDBX.PVC`, ...) and their mnemonics (`"N"`, `"V"`, ...) as bytes |
| `subtypes`, `chans`, `nums` | subtype, channel and annotator number of each annotation (`Vector{Int32}`) |
| `aux` | auxiliary text of each annotation as bytes, or `nothing` |
| `fs` | the frequency in which `samples` are counted (0 if unknown) |
| `record`, `annotator` | the names that were read |

### Writing a record: `write_record`

`write_record` takes samples in ADC units. `write_record_physical` takes
samples in physical units and converts them with the given gains and
baselines. `NaN` is written as an invalid sample.

```julia
x = randn(3600, 2)                  # random samples: the record "rand" is written by this example
write_record_physical("rand", x, 360; fmt=16, gains=1000, adcres=16, units="mV",
                      names=["A", "B"])
```

This writes the header `rand.hea` and the signal file `rand.dat`. The
sampling frequency, the gain and ADC resolution of each signal, and the
units of each calibrated signal are required; there are no defaults. A gain
of 0 marks a signal as uncalibrated, which is only allowed with
`write_record`. Per-signal options take one value for all signals, or a
vector with one value per signal.

| Argument | Meaning |
|---|---|
| `record` | record name |
| `samples` | matrix with one row per sample and one column per signal: integers for `write_record`, physical values for `write_record_physical` |
| `fs` | sampling frequency in Hz |
| `fmt` | storage format, such as 16, 212, 24 or 516 (FLAC); default 16 |
| `gains`, `adcres`, `units` | gain, ADC resolution in bits, and physical units |
| `baselines`, `adczeros`, `names` | optional signal specifications |
| `base_time`, `comments` | start time (`"hh:mm:ss dd/mm/yyyy"`) and info strings |
| `samps_per_frame` | samples per frame of each signal, for a multi-frequency record |
| `dir` | existing directory in which to create the files |
| `legacy` | behave as the original package (see [Legacy mode](#legacy-mode)) |

### Writing annotations: `write_annotations`

```julia
ann = Annotations(samples=[100, 460, 820], symbols=[b"N", b"N", b"V"])
write_annotations("rand", "qrs", ann)            # writes rand.qrs, for the record "rand" written above
```

Give the annotation types as `symbols` or as `codes`. `subtypes`, `chans`,
`nums` and `aux` are optional. The `fs` option records the time resolution
in the file; `ann.fs` is not used. `dir` and `legacy` are as in
`write_record`.

If the annotations are not in time order, the file is sorted when it is
written. `sort=false` keeps the given order (without the library's
advice to run `sortann`) and `sort=true` always sorts, for that call only.
Without `sort`, the `WFDBANNSORT` environment variable decides (sorting is
on unless it is `0`).

### Errors and warnings

* Every failure of a high-level function throws a `WfdbError`. Its `msg`
  field says what failed, such as "can't read record 100x". The library may
  also print a message on the standard error. `wfdbquiet()` turns these
  messages off.
* A signal file that is shorter than its header says throws a `WfdbError`:
  "can't read signal data of record REC (getvec status -3)".
* An annotation file that ends before its end-of-file marker throws a
  `WfdbError`: "can't read annotation file ANN of record REC (getann status
  -3)".
* Invalid arguments, and a value the operation needs but the record does not
  give, also throw a `WfdbError`. For example, a time string such as
  `"0:10"` needs the sampling frequency, and `physical(rec)` needs the gain
  of each signal.
* When the data do not match the checksums in the header, `read_record`
  returns all the data and logs a warning with `@warn`: "checksum error in
  record REC: the signal data do not match the checksums in its header".
  `checksum_warning=false` turns the warning off; `rec.checksum_ok` is
  `false` either way. Checksums are only checked when a read reaches the end
  of the record.
* `write_record` and `write_record_physical` throw a `WfdbError` if a
  `samps_per_frame` value is not an integer >= 1 ("write_record:
  samps_per_frame must hold integers >= 1"), or if the number of columns of
  the samples is not their sum ("write_record: signals has N columns, but
  samps_per_frame adds up to M"). These are checked before anything else,
  and nothing is written.
* `write_record`, `write_record_physical` and `write_annotations` throw a
  `WfdbError` when a file cannot be written completely, for example on a
  full disk: "write error on record REC", "write error on annotator ANN for
  record REC" (also in legacy mode).
* A tool, or a program that uses the WFDB library functions, never writes a
  signal file over one of the signal files it is reading. Opening such an
  output fails with "output file NAME is also an input file". `write_record`
  reads nothing, so it overwrites any existing files of the same name.

The high-level functions call `wfdbquit()`, which closes anything opened
with the WFDB library functions.

### Checking a record: `check_record`

```julia
report = check_record("100s"; annotators=["atr"])
print(report)
```

`check_record(record; annotators)` checks the header of a record, its signal
specifications, every sample of its signal files, and the annotation files
named (`annotators`, a vector of names, or one name). It reports each
problem it finds. It never throws an exception for a problem in the record.
`input_dir` and `network` are as in `read_record`. It checks for problems
similar to those found by Benjamin Moody's
[wfdbcheck](https://github.com/bemoody/wfdbcheck).

The result is a `CheckReport`. `report.ok` is `true` if there is no error.
`report.issues` lists the problems (`Issue`s). Each has a `severity`, a
`code` (such as `"checksum"`), a `where` (`""` for the record, `"signal 1"`,
`"segment s2"`, `"annotator atr"`) and a `message`.

| Severity | Meaning |
|---|---|
| `error` | the record is damaged or does not follow the WFDB format: programs will read wrong data or fail |
| `warning` | the record can be read, but something is missing or unusual, and may give wrong results |
| `info` | a fact worth knowing, such as invalid (missing) samples |

Printed (`print`, `show`), the report has one line per problem, or the line
`no problems found`:

```
warning: signal 0: the units are not specified
error: signal 1: the checksum does not match: the header gives 12, the samples sum to 13
error: annotator atr: 3 annotations are out of order; the first is at sample 50, after sample 100
```

`lines(report)` returns these lines as a vector of strings. The lines are
the same in the seven languages of WFDB-x. The checks run in normal mode, even if legacy mode is on, and the library
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
| a home path: `~/data/100` | the user's home directory | the user's home directory |
| a URL: `https://.../100` | that URL, if network access is on | (URLs cannot be written) |
| anything else: `100`, `mitdb/100`, `../data/100` | the **input directory** | the **output directory** |

In this table, `/data/mitdb` stands for a local copy of the MIT-BIH
Arrhythmia Database, and `100` for its record 100.

The input and output directories are both the current directory unless they
are set:

| Setting | Function | Option of the high-level functions | Environment variable |
|---|---|---|---|
| input directory: a local directory, `~/...` or a URL | `wfdbx_set_input_dir(d)` | `input_dir=` | `WFDBX_INPUT_DIR` |
| output directory | `wfdbx_set_output_dir(d)` | `dir=` | `WFDBX_OUTPUT_DIR` |
| network access (off by default) | `wfdbx_set_network(true)` | `network=true` | `WFDBX_NETWORK=1` |

A function call overrides the environment variable, and an option applies to
that one call. Each `set` function returns the previous setting.
`wfdbx_get_input_dir()`, `wfdbx_get_output_dir()` and `wfdbx_get_network()`
return the current settings. Directories are returned as bytes, or `nothing`
when none is set. Passing `nothing` to a `set` function restores the
default.

Here `/data/mitdb` stands for a local copy of the MIT-BIH Arrhythmia
Database:

```julia
wfdbx_set_input_dir("/data/mitdb")           # a local copy of the MIT-BIH Arrhythmia Database
rec = read_record("100")                     # reads /data/mitdb/100.hea and 100.dat
mkpath("out")
ann = Annotations(samples=[100, 460], symbols=[b"N", b"N"])
write_annotations("100", "qrs", ann; dir="out")   # writes out/100.qrs
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

```julia
rec = read_record("100"; input_dir="https://physionet.org/files/mitdb/1.0.0/",
                  network=true)
```

Remote files are read once and kept for the rest of the session. A download
gives up when it cannot connect, or receives nothing, for 30 seconds.

## Signal parameters

WFDB-x never assumes a sampling frequency, gain, ADC resolution or units
that a record does not give. Where one is needed, it must be given: in
`write_record`, as the `fs` option of `read_annotations`, or as an option of
the tools (see below). A record whose header gives no frequency has `fs =
0`. See
[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md)
for the reasons.

## Command-line tools

The tools are run through the driver script `bin/wfdbx.jl`. Its first
argument names the tool, and the other arguments go to the tool. The
examples in this section read the sample record `100s` (the first minute of
record 100 of the MIT-BIH Arrhythmia Database, included with WFDB-x in
`tests/data`), from that directory as the input directory:

```sh
export WFDBX_INPUT_DIR=/path/to/wfdb-x/tests/data
julia --startup-file=no --project=/path/to/wfdb-x/julia \
    /path/to/wfdb-x/julia/bin/wfdbx.jl rdsamp -r 100s -t 10
```

A small shell script, saved as `wfdbx` in a directory of the `PATH`, makes
this shorter:

```sh
#!/bin/sh
# wfdbx: run a WFDB-x tool, as in `wfdbx rdsamp -r 100s -t 10`
exec julia --startup-file=no --project=/path/to/wfdb-x/julia \
    /path/to/wfdb-x/julia/bin/wfdbx.jl "$@"
```

The examples below use it:

```sh
wfdbx rdsamp -r 100s -t 10 -p      # print the first 10 seconds, in physical units
wfdbx rdann -r 100s -a atr         # print the annotations
```

The tools have the options and output of the original WFDB tools, which are
described in the *WFDB Applications Guide*
([`third_party/wag.pdf`](https://github.com/alphanumericslab/wfdb-x/tree/main/third_party)).
`WFDBX.tools()` returns their names, and `wfdbx --version` prints the
version of WFDB-x ("WFDB-x 1.1.0"):

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

For example, `wfdbx wrsamp -F 250 -G 200 -R 16 -U mV -i samples.txt -o rec`
writes the record `rec` from the text file `samples.txt`.

A tool can also run inside a Julia session. `WFDBX.run_tool` returns
its exit status and what it wrote to the standard output and the standard
error, as bytes (here, the tool runs in `tests/data`, where the sample record
`100s` is):

```julia
status, out, err = WFDBX.run_tool("rdsamp", ["-r", "100s", "-t", "s3"];
                                  dir="/path/to/wfdb-x/tests/data")
print(String(out))
```

## The WFDB library functions

Every function of the WFDB library is available under its C name, with the
same arguments and return values, so programs and documentation written for
the C library carry over directly. Where a C function fills an array, the
Julia function fills a vector passed by the caller. The example reads the
sample record `100s` (the first minute of record 100 of the MIT-BIH
Arrhythmia Database, included with WFDB-x in `tests/data`):

```julia
using WFDBX
wfdbx_set_input_dir("/path/to/wfdb-x/tests/data")

n = isigopen("100s", nothing, 0)        # the number of signals (reads the header only)
si = [Siginfo() for _ in 1:n]
isigopen("100s", si, n)                 # open the signals; si receives their specifications
v = zeros(Int32, n)
for t in 0:9
    getvec(v) > 0 || break              # v receives one sample per signal
    println(mstimstr(t), " ", v[1], " ", v[2])
end

a = Annotation()
annopen("100s", [Anninfo("atr", WFDB_READ)], 1)
while getann(0, a) == 0
    println(a.time, " ", String(annstr(a.anntyp)))
end
wfdbquit()
```

Differences from C that come from the language:

* The library state lives in a `Wfdb` object instead of global variables.
  Every function takes one as an optional first argument. Without it, a
  function uses the default object, `lib()`. `Wfdb()` creates an
  independent one:

  ```julia
  w = Wfdb()
  wfdbx_set_input_dir(w, "/path/to/wfdb-x/tests/data")
  sampfreq(w, "100s")                   # 360.0
  ```

* Text is returned as bytes (`Vector{UInt8}`), because WFDB files are not
  always UTF-8. Time and date strings (`timstr`, `mstimstr`, `datstr`) are
  `String`s. Arguments may be `String`s or bytes. C's `NULL` is `nothing`.
* Integer types are those of C: `WFDB_Sample` and `int` are `Int32`, and
  `WFDB_Time` and `long` are `Int64`.
* The structures (`Siginfo`, `Calinfo`, `Anninfo`, `Annotation`,
  `Seginfo`) have the C field names. An annotation's `aux` is `nothing`, or
  bytes whose first byte is the length of the text that follows, as in C.
* `getvecs(v, n)` reads up to `n` sample vectors at once into `v`, as `n`
  calls of `getvec` would, and returns the number it read.
* Errors are reported by return values, as in C, not by exceptions.
  `wfdberror()` returns the last message, and `wfdbquiet()` stops the
  messages from being printed.
* The library keeps the open record and annotators between calls, as in C.
  `wfdbquit()` closes them; the directory and network settings are kept.
* `wfdbx_write_errors()` returns the number of output files that the library
  could not write, flush or close (found when it closes them), and
  `wfdbx_note_write_error()` counts one more, for a file that a program
  writes itself. The count belongs to the process (to one tool run, under
  `run_tool`). The tools exit with status 1 after a write error, or when
  the standard output cannot be written ("PROGRAM: write error on standard
  output"); with `--legacy`, they keep the original exit status.

The annotation codes (`WFDBX.NORMAL`, `WFDBX.PVC`, ...) and the functions of
`<wfdb/ecgmap.h>` (`isqrs`, `map1`, `map2`, ...) are also provided. Type
`?getvec` in the REPL for the documentation of a function.

## Legacy mode

Legacy mode reproduces the original WFDB package exactly, including its
assumed signal parameters and its search for files. Use it only to reproduce
old results:

* tools: `--legacy` as the first argument, as in `wfdbx rdsamp --legacy -r 100s`,
  run in the directory of the sample record `100s` (`tests/data` in a copy
  of the repository). Legacy mode finds files through the WFDB path, which begins with the
  current directory, and does not use the input directory;
* high-level functions: `legacy=true`;
* the whole library: `wfdbx_set_legacy(true)`.

[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md#legacy-mode)
describes what changes in legacy mode.

## Notes

* **Strings are bytes.** Signal descriptions, units, annotation mnemonics,
  aux strings and comments are returned as `Vector{UInt8}`. Use `String(x)`
  or `String.(v)` to convert them.
* **FLAC.** Formats 508, 516 and 524 (FLAC-compressed signals) are read and
  written without any external library. The C library reads files written
  by WFDB-x with identical sample values, although the compressed bytes
  differ from those of libFLAC.
* **Speed.** `read_record` and `write_record` work on whole blocks of
  samples, and are the fastest way to read and write a record (in chunks,
  with `from` and `to`, for records too large for memory). For code that
  processes a record as a stream with the library functions, `getvecs`
  reads many sample vectors in one call; a loop of `getvec` calls, one
  sample vector each, is slower. After precompilation, the tools start
  quickly; most of their startup time is Julia's own.
  [BENCHMARKS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/BENCHMARKS.md)
  compares the seven languages and wfdb-python.

## Testing

From the root of the repository:

```sh
julia --startup-file=no --project=julia julia/test/runtests.jl   # unit tests
python3 tests/conformance/harness.py check --impl julia -j8        # conformance suite
```

The conformance suite compares the output of every tool with that of the C
implementation. [DEVELOPING.md](DEVELOPING.md) describes how the code is
organized.

## Authors and license

WFDB-x implements version 10.7.0 of the WFDB Software Package.

The WFDB library and tools were written by George B. Moody, with revisions by
Benjamin Moody and contributions from many others; `parsescp` was written by
George B. Moody and Edna S. Moody. Each source file names the authors of
the C code it implements, and
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md)
gives the details. The Julia implementation was developed by Reza Sameni
(2026), through AI-assisted development, cross-language
verification and unit testing.

WFDB-x is an independent reimplementation. Its Julia code is a
translation of the C code of the WFDB Software Package into Julia,
written for WFDB-x; it is not code by the original WFDB developers. It
follows the original's logic and behavior, with the changes described
in [DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md).
The authors of the original C code are credited in each file and in
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md).

WFDB-x is distributed under the GNU General Public License, version 3 or
(at your option) any later version. See
[LICENSE](https://github.com/alphanumericslab/wfdb-x/blob/main/LICENSE).
