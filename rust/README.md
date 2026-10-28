# WFDB-x for Rust

> **WFDB-x** is the WFDB Software Package (the library and its 33
> command-line tools) reimplemented in seven languages: Python, C++,
> MATLAB/Octave, Rust, Julia, R and Kotlin, tested to behave identically to
> the original C package and to each other. This is the Rust
> implementation.
> [Project page and the other languages](https://github.com/alphanumericslab/wfdb-x)
> · [WFDB-x at a glance (overview figure)](https://github.com/alphanumericslab/wfdb-x#wfdb-x-at-a-glance)
> · [Benchmarks](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/BENCHMARKS.md)

The `wfdbx` crate reads and writes physiological signal records in the WFDB
format used by [PhysioNet](https://physionet.org). It is a complete Rust
implementation of the WFDB Software Package: the library and all of its
command-line tools. It reads and writes the same files as the original C
library, and its tools print the same output.

The crate needs Rust 1.70 or later. It has no dependencies beyond the Rust
standard library, and runs on Linux, macOS and Windows.

## Three ways to use WFDB-x

All three are written in Rust; none of them calls the C library.

1. **The high-level functions (recommended).** `read_record`,
   `read_header`, `read_annotations`, `write_record`,
   `write_record_physical`, `write_annotations` and `check_record` read and
   write whole records and annotation files in one call, as `Vec`s (samples
   in `Vec<i32>`, frame by frame, or `Vec<f64>` in physical units), with
   their options in a `ReadOptions` or `WriteOptions` struct, and return a
   `Result` whose error type is `wfdbx::record::Error`. They read signal
   files in large blocks, so they are the fastest way to read a record.
   They are an addition of WFDB-x: the C package has no equivalent. Use
   them for new code and analysis.
2. **The WFDB library functions** under their C names (`isigopen`,
   `getvec`, `getann`, `putann`, ...), with the C behavior: sample by
   sample and annotation by annotation, errors reported by return values.
   Use them to port a program written against the C library, or for the
   exact C semantics.
3. **The command-line tools** (`rdsamp`, `rdann`, `wrsamp`, `xform`, and
   29 others), with the options, output and exit status of the C tools,
   each a separate program run by name after `cargo install --path rust`
   (`rdsamp -r 100s`). Use them in shell scripts and pipelines, or to
   reproduce work done with the original tools.

The high-level functions return exactly the samples and annotations that
the library functions (and the C library) give.

## Installation

To use the library in a Cargo project, add it to the project's `Cargo.toml`:

```toml
[dependencies]
wfdbx = { git = "https://github.com/alphanumericslab/wfdb-x" }
# or, from a copy of the repository:
wfdbx = { path = "../wfdb-x/rust" }
```

To install the command-line tools in `~/.cargo/bin`, run this from the root
of a copy of the repository:

```sh
cargo install --path rust
```

`cargo build --release` in the `rust` directory builds the library and the
tools in `rust/target/release/` without installing them.

## Quick start

The repository includes a sample record, `100s`, in `tests/data`: the first
minute of record 100 of the
[MIT-BIH Arrhythmia Database](https://physionet.org/content/mitdb/), with two
ECG signals at 360 Hz and its beat annotations. This program reads it and
writes a copy of its first 10 seconds as a new record, `copy`. Run it from
the root of the repository, or change the directory in its first line.

```rust
use wfdbx::{read_annotations, read_header, read_record, ReadOptions, WriteOptions};

fn main() -> Result<(), wfdbx::record::Error> {
    // Read the sample record from the repository's tests/data directory.
    wfdbx::wfdbx_set_input_dir("tests/data");

    let rec = read_record("100s", &ReadOptions::default())?; // signals in ADC units
    println!("{} {} {}", rec.fs, rec.nsig, rec.nsamples());  // 360 2 21600
    let mlii = rec.physical_signal(0)?;                       // signal 0 in physical units
    println!("{:?}", &mlii[..3]);                             // [-0.145, -0.145, -0.145]

    let hdr = read_header("100s", false)?;                    // the header only, no samples
    println!("{} {}", hdr.nsig, hdr.nsamples);                // 2 21600

    let ann = read_annotations("100s", "atr", None, None, None, false)?; // beat annotations
    println!("{} {:?}", ann.len(), &ann.samples[..3]);        // 75 [18, 77, 370]

    // Write the first 10 seconds as a new record, "copy", in the current directory.
    let opt = ReadOptions { to: Some("0:10".into()), ..Default::default() };
    let x = read_record("100s", &opt)?;
    let w = WriteOptions {
        gains: x.siginfo.iter().map(|s| s.gain).collect(),
        baselines: x.siginfo.iter().map(|s| s.baseline).collect(),
        adcres: vec![11],
        units: vec![Some("mV".into())],
        names: x.names(),
        ..Default::default()
    };
    wfdbx::write_record("copy", &x.samples, x.nsig, x.fs, &w)?;
    Ok(())
}
```

## Reading and writing records

The examples in this section read the sample record `100s` of the quick
start (the first minute of record 100 of the MIT-BIH Arrhythmia Database,
included with WFDB-x in the `tests/data` directory of a copy of the
repository). Run them from the root of the repository: each one sets the
input directory to `tests/data` in its first line.

Each high-level function returns a `Result` whose error type is
`wfdbx::record::Error`. Text read from files, such as signal descriptions,
units and annotation mnemonics, is given as bytes (`Vec<u8>`). Use
`String::from_utf8_lossy` to print it.

### Reading signals: `read_record`

`read_record(record, &opt)` reads the signals of a record. The options are
the fields of a `ReadOptions`:

```rust
use wfdbx::{read_record, ReadOptions};

wfdbx::wfdbx_set_input_dir("tests/data");   // the sample record 100s
let opt = ReadOptions {
    channels: vec!["MLII".into()],
    from: Some("0:10".into()),
    to: Some("0:20".into()),
    ..Default::default()
};
let rec = read_record("100s", &opt)?;
let mlii = rec.physical_signal(0)?;   // Vec<f64>, in physical units
```

| Argument or option | Meaning | Default |
|---|---|---|
| `record` | record name or path (see [Where files are read and written](#where-files-are-read-and-written)) | |
| `channels` | signals to read, by number (`"0"`) or name (`"MLII"`, as in `names()`) | all signals |
| `from`, `to` | first sample, and the sample after the last one: a sample number or a time string (see below) | the whole record |
| `highres` | read a multi-frequency record at its highest sampling frequency | `false` |
| `pad` | replace invalid samples by the previous valid one | `false` |
| `checksum_warning` | warn when the data do not match the header's checksums | `true` |
| `input_dir`, `network` | input directory and network access for this call only | the current settings |
| `legacy` | behave as the original package (see [Legacy mode](#legacy-mode)) | `false` |

`from` and `to` accept a sample number (`Some(3600.into())`) or a WFDB time
string: `"0:10"` (10 seconds), `"1:02:03.5"`, `"s3600"` (sample 3600) or
`"e"` (the end of the record).

The result is a `Record`:

| Field or method | Contents |
|---|---|
| `samples` | all samples in ADC units (`i32`), frame by frame: `samples[i * nsig + s]` is sample `i` of signal `s` |
| `nsig`, `nsamples()` | the number of signals, and the number of samples per signal |
| `at(i, s)` | sample `i` of signal `s`, in ADC units |
| `physical(i, s)`, `physical_signal(s)` | one sample, or all samples of signal `s`, in physical units (`f64`) |
| `fs` | sampling frequency in Hz (0 if the header gives none) |
| `siginfo` | the specifications of each signal (`Siginfo`): `desc`, `units`, `gain` (ADC units per physical unit; 0 means uncalibrated), `baseline`, `adcres`, `fmt`, ... |
| `names()` | the description of each signal, without the white space that a header may put at either end of it |
| `signals` | the number, in the record, of each signal read |
| `sampfrom` | the number of the first sample returned |
| `base_time` | start time and date as text, to the second, such as `"[14:00:03 21/06/2024]"` |
| `base_time_ms` | start time in milliseconds after midnight, such as `50403500` for 14:00:03.500 |
| `base_date` | start date as `[year, month, day]` |
| `comments` | the info strings of the header |
| `checksum_ok` | `false` if the data do not match the header's checksums |

`base_time`, `base_time_ms` and `base_date` are `None` when the header does
not give them. Invalid samples are `wfdbx::WFDB_INVALID_SAMPLE`, or NaN in
physical units.

### Reading a header: `read_header`

`read_header(record, legacy)` reads the header of a record without opening
its signal files. It returns a `Header` with these fields: `name`, `fs`,
`counter_freq`, `base_counter`, `nsamples` (0 if the header does not give
the length), `nsig`, `siginfo`, `base_time`, `base_time_ms`, `base_date` and
`comments`. They have the same meaning as in `Record`. `read_header_with`
takes a `ReadOptions` instead of `legacy`, for its `input_dir`, `network`
and `legacy` options.

```rust
wfdbx::wfdbx_set_input_dir("tests/data");   // the sample record 100s
let hdr = wfdbx::read_header("100s", false)?;
for s in &hdr.siginfo {
    let desc = String::from_utf8_lossy(s.desc.as_deref().unwrap_or(b""));
    println!("{} {} {} {:?}", desc, s.fmt, s.gain, s.units);   // MLII 212 200 None
}
```

### Reading annotations: `read_annotations`

```rust
use wfdbx::{read_annotations, PVC};

wfdbx::wfdbx_set_input_dir("tests/data");   // the sample record 100s
let ann = read_annotations("100s", "atr", Some("0:10".into()), Some("0:30".into()), None, false)?;
let npvc = ann.codes.iter().filter(|&&c| c == PVC).count();
```

The arguments are `record`, `annotator`, `from`, `to`, `fs` and `legacy`.
`annotator` is the file suffix (`"atr"` reads `100s.atr`). `from` and `to`
limit the annotations to a time interval, as in `read_record`. `fs` gives
the sampling frequency when the record has no header, or its header gives
none. `read_annotations_with(record, annotator, fs, &opt)` takes `from`,
`to`, `input_dir`, `network` and `legacy` from a `ReadOptions`. The result
is an `Annotations` value, in file order:

| Field | Contents |
|---|---|
| `samples` | annotation times, in samples (`i64`) |
| `codes`, `symbols` | annotation codes (`wfdbx::NORMAL`, `wfdbx::PVC`, ...) and their mnemonics (`b"N"`, `b"V"`, ...) |
| `subtypes`, `chans`, `nums` | subtype, channel and annotator number of each annotation (`i32`) |
| `aux` | auxiliary text of each annotation, or `None` |
| `fs` | the frequency in which `samples` are counted (0 if unknown) |
| `len()` | the number of annotations |

### Writing a record: `write_record`

`write_record(record, &samples, nsig, fs, &opt)` writes a record from
samples in ADC units (`i32`). `write_record_physical` takes the same
arguments with samples in physical units (`f64`). This example writes two
sine waves as a new record, `sine`, in the current directory:

```rust
use wfdbx::{write_record_physical, WriteOptions};

let fs = 360.0;
let mut x = Vec::new();                       // frame by frame: signal 0, signal 1, ...
for i in 0..3600 {
    let t = 2.0 * std::f64::consts::PI * i as f64 / fs;
    x.push(t.sin());
    x.push(0.5 * t.cos());
}
let opt = WriteOptions {
    gains: vec![1000.0],
    adcres: vec![16],
    units: vec![Some("mV".into())],
    names: vec!["A".into(), "B".into()],
    ..Default::default()
};
write_record_physical("sine", &x, 2, fs, &opt)?;
```

This writes the header `sine.hea` and the signal file `sine.dat`. The
sampling frequency, the gain and ADC resolution of each signal, and the
units of each calibrated signal are required; there are no defaults. A gain
of 0 marks a signal as uncalibrated, which is only allowed for samples given
in ADC units. Per-signal options take one value for all signals, or a vector
with one value per signal.

| Argument or option | Meaning |
|---|---|
| `samples` | the samples, frame by frame: `nsig` values per frame |
| `nsig` | the number of signals |
| `fs` | sampling frequency in Hz |
| `fmt` | storage format, such as 16, 212, 24 or 516 (FLAC); default 16 |
| `gains`, `adcres`, `units` | gain, ADC resolution in bits, and physical units |
| `baselines`, `adczeros`, `names` | optional signal specifications |
| `base_time`, `comments` | start time (`"hh:mm:ss dd/mm/yyyy"`) and info strings |
| `samps_per_frame` | samples per frame of each signal, for a multi-frequency record |
| `dir` | an existing directory in which to create the files |
| `legacy` | behave as the original package (see [Legacy mode](#legacy-mode)) |

### Writing annotations: `write_annotations`

This example writes annotations for the record `sine` written by the
previous example:

```rust
use wfdbx::{write_annotations, Annotations};

let ann = Annotations {
    samples: vec![100, 460, 820],
    symbols: vec!["N".into(), "N".into(), "V".into()],
    ..Default::default()
};
write_annotations("sine", "qrs", &ann, 0.0, None)?;   // writes sine.qrs
```

The arguments are `record`, `annotator`, the annotations, `fs` and an
optional existing output directory. Give the annotation types as `symbols`
or as `codes`. `subtypes`, `chans`, `nums` and `aux` are optional. A
positive `fs` is stored in the file as the frequency of its sample numbers.

If the annotations are not in time order, the file is sorted when it is
written. `write_annotations_with` takes an `AnnWriteOptions` with the fields
`dir` and `sort`: `sort: Some(false)` keeps the given order (without
the library's advice to run `sortann`) and `Some(true)` always sorts, for
that call only. With `sort: None`, the
`WFDBANNSORT` environment variable decides (sorting is on unless it is `0`).

### Errors and warnings

* A record, header or annotation file that cannot be read or written gives
  an error, such as "can't read record REC".
* A signal file that is shorter than its header says gives the error
  "can't read signal data of record REC (getvec status -3)". An annotation
  file that ends early, or cannot be read to its end, gives the error
  "can't read annotation file ANN of record REC (getann status -3)".
* Invalid arguments, and a value the operation needs but the record does not
  give, give an error. For example, a time string such as `"0:10"` needs the
  sampling frequency, and `physical_signal` needs the gain of the signal.
* When the data do not match the checksums in the header, `read_record`
  returns all the data and prints a warning on the standard error:
  "WFDB-x: checksum error in record REC: the signal data do not match the
  checksums in its header". `checksum_warning: false` turns the warning off;
  `rec.checksum_ok` is `false` either way. Checksums are only checked when a
  read reaches the end of the record.
* A tool, or a program that uses the WFDB library functions, never writes a
  signal file over one of the signal files it is reading. Opening such an
  output fails with "output file NAME is also an input file". `write_record`
  reads nothing, so it overwrites any existing files of the same name.
* A file that cannot be written completely, for example when the disk is
  full, gives the error "write error on record REC" (`write_record`) or
  "write error on annotator ANN for record REC" (`write_annotations`), also
  in legacy mode.
* `write_record` checks `samps_per_frame` before anything else: each value
  must be at least 1 ("samps_per_frame must hold integers >= 1"), and the
  number of samples must be a multiple of the frame size.

`Error::message()` and `Display` give the text of an error. The WFDB
library functions that a high-level function calls may also print their own
messages on the standard error, such as "init: can't open header for record
REC". `wfdbquiet()` turns these messages off.

The high-level functions call `wfdbquit()`, which closes anything opened
with the WFDB library functions.

### Checking a record: `check_record`

```rust
wfdbx::wfdbx_set_input_dir("tests/data");   // the sample record 100s
let report = wfdbx::check_record("100s", &["atr"])?;
println!("{report}");
```

`check_record(record, annotators)` checks the header of a record, its signal
specifications, every sample of its signal files, and the annotation files
named. It reports each problem it finds. It returns an error only for an
empty record name, never for a problem in the record. `check_record_with`
also takes a `ReadOptions`, whose `input_dir` and `network` apply to that
call. It checks for problems similar to those found by Benjamin Moody's
[wfdbcheck](https://github.com/bemoody/wfdbcheck).

The result is a `CheckReport`. `report.ok` is `true` if there is no error.
`report.issues` lists the problems. Each `Issue` has a `severity`
(`Severity::Error`, `Warning` or `Info`), a `code` (such as `"checksum"`), a
`where` (`""` for the record, `"signal 1"`, `"segment s2"`,
`"annotator atr"`; the field is `issue.r#where`) and a `message`.

| Severity | Meaning |
|---|---|
| `error` | the record is damaged or does not follow the WFDB format: programs will read wrong data or fail |
| `warning` | the record can be read, but something is missing or unusual, and may give wrong results |
| `info` | a fact worth knowing, such as invalid (missing) samples |

Printed (`Display`), the report has one line per problem, or the line
`no problems found`:

```
warning: signal 0: the units are not specified
error: signal 1: the checksum does not match: the header gives 12, the samples sum to 13
error: annotator atr: 3 annotations are out of order; the first is at sample 50, after sample 100
```

`report.lines()` returns these lines as a vector. The lines are the same in
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
| input directory: a local directory, `~/...` or a URL | `wfdbx_set_input_dir(d)` | `ReadOptions::input_dir` | `WFDBX_INPUT_DIR` |
| output directory | `wfdbx_set_output_dir(d)` | `WriteOptions::dir`, `AnnWriteOptions::dir` | `WFDBX_OUTPUT_DIR` |
| network access (off by default) | `wfdbx_set_network(1)` | `ReadOptions::network` | `WFDBX_NETWORK=1` |

A function call overrides the environment variable, and an option applies to
that one call. Each `set` function returns the previous setting.
`wfdbx_get_input_dir()`, `wfdbx_get_output_dir()` and `wfdbx_get_network()`
return the current settings. Passing `None` to `wfdbx_set_input_dir` or
`wfdbx_set_output_dir`, or `-1` to `wfdbx_set_network`, restores the
default.

In this example, `/data/mitdb` stands for a local copy of the MIT-BIH
Arrhythmia Database in `/data/mitdb`; the annotations are written to a
directory `out`:

```rust
use std::path::Path;
use wfdbx::{read_record, write_annotations, Annotations, ReadOptions};

wfdbx::wfdbx_set_input_dir("/data/mitdb");
let rec = read_record("100", &ReadOptions::default())?;   // reads /data/mitdb/100.hea and 100.dat
let ann = Annotations {
    samples: vec![100, 460],
    symbols: vec!["N".into(), "N".into()],
    ..Default::default()
};
write_annotations("100", "qrs", &ann, rec.fs, Some(Path::new("out")))?;   // writes out/100.qrs
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

```rust
use wfdbx::{read_record, ReadOptions};

let opt = ReadOptions {
    input_dir: Some("https://physionet.org/files/mitdb/1.0.0/".into()),
    network: Some(true),
    ..Default::default()
};
let rec = read_record("100", &opt)?;
```

Network access uses the `curl` program, which must be installed. Remote
files are read once and kept until the program ends. A download gives up
when it cannot connect, or receives nothing, for 30 seconds.

## Signal parameters

WFDB-x never assumes a sampling frequency, gain, ADC resolution or units
that a record does not give. Where one is needed, it must be given: in
`write_record`, as the `fs` argument of `read_annotations`, or as an option
of the tools (see below). A record whose header gives no frequency has `fs =
0`. See
[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md)
for the reasons.

## Command-line tools

Each tool is a separate program. After `cargo install --path rust`, run the
tools by name. These commands, run in the `tests/data` directory of a copy
of the repository, read the sample record `100s` (the first minute of record
100 of the MIT-BIH Arrhythmia Database, included with WFDB-x):

```sh
rdsamp -r 100s -t 10 -p      # print the first 10 seconds, in physical units
rdann -r 100s -a atr         # print the annotations
wfdbdesc 100s                # describe the record
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

The tools use the environment variables of the table above. To read record
100 of the MIT-BIH Arrhythmia Database from PhysioNet:

```sh
export WFDBX_INPUT_DIR=https://physionet.org/files/mitdb/1.0.0/
export WFDBX_NETWORK=1
rdsamp -r 100 -t 0:05
```

Tools that write signal parameters require them as options:

| Tool | Required options |
|---|---|
| `wrsamp` (with `-o`) | `-F` frequency, `-G` gain, `-R` ADC resolution, and `-U` units for calibrated signals |
| `wav2mit` | `-G` gain, and `-U` units unless the gain is 0 |
| `ad2m`, `ahaecg2mit` | `-F`, `-G`, `-R`, and `-U` unless the gain is 0 |
| `a2m`, `rdann`, `ann2rr`, `sortann`, `m2a` | `-F` frequency, when the record's header does not give one |

For example, `wrsamp -F 250 -G 200 -R 16 -U mV -i samples.txt -o rec`
writes the record `rec` from `samples.txt`, which stands for a text file of
samples, one frame per line.

## The WFDB library functions

Every function of the WFDB library is available under its C name, with the
same arguments and return values, so programs and documentation written for
the C library carry over directly. The library's state, such as the open
record and annotators, is held by a `Wfdb` value, and each function is a
method of it. Where a C function fills an array, the Rust function fills a
slice passed by the caller. This example reads the sample record `100s` (see
the quick start) from `tests/data`; run it from the root of the repository:

```rust
use wfdbx::{Anninfo, Annotation, Siginfo, Wfdb, WFDB_READ};

let mut w = Wfdb::new();
w.wfdbx_set_input_dir("tests/data");
let mut si = vec![Siginfo::default(); 2];
let nsig = w.isigopen("100s", &mut si, 2);   // open 2 signals; si receives their specifications
let mut v = vec![0; nsig.max(0) as usize];
while w.getvec(&mut v) > 0 {                 // v receives one sample per signal
    // ...
}

let mut a = Annotation::default();
w.annopen("100s", &[Anninfo { name: "atr".into(), stat: WFDB_READ }], 1);
while w.getann(0, &mut a) == 0 {
    println!("{} {}", a.time, String::from_utf8_lossy(&w.annstr(a.anntyp as i32)));
}
w.wfdbquit();
```

Differences from C that come from the language:

* Every method is also a free function with the same name and arguments,
  such as `wfdbx::isigopen(...)`. The free functions use a default `Wfdb`
  value, one per thread. Separate `Wfdb` values do not share any state, so
  several records can be open at once, in one thread or in several.
* Strings are bytes. Arguments accept `&str`, `&[u8]` or `b"..."`, and
  results are `Vec<u8>`. C's `NULL` is `None`; pass `wfdbx::NULL` for a
  `NULL` argument.
* C's `int` is `i32`, `long` and `WFDB_Time` are `i64`, `WFDB_Sample` is
  `i32`, and `char` is `i8`.
* The structures (`Siginfo`, `Calinfo`, `Anninfo`, `Annotation`,
  `Seginfo`) have the C field names. `Default::default()` gives C's zero
  values.
* An annotation's `aux` is `None`, or bytes whose first byte is the length
  of the text that follows, as in C.
* `getvecs(&mut buf, n)` reads up to `n` frames at once into `buf`. It
  returns the number of frames it read, or the `getvec` status if it read
  none.
* Errors are reported by return values, as in C. `wfdberror()` returns the
  last message, and `wfdbquiet()` stops the messages from being printed.
* `wfdbx_write_errors()` returns the number of write errors since the
  program started: the output files that the library could not write, flush
  or close (found when they are closed, as by `wfdbquit()`).
  `wfdbx_note_write_error()` counts one more, for a file that a program
  writes itself, and `wfdbx_fclose_output(file, pname, name)` closes such a
  file, reporting "PNAME: write error on NAME" and counting it. The tools
  exit with status 1 after a write error, or when the standard output
  cannot be written ("PROGRAM: write error on standard output"); legacy
  mode keeps the original status, 0.

The annotation codes (`NORMAL`, `PVC`, ...) and the functions of
`<wfdb/ecgmap.h>` (`isqrs`, `map1`, `map2`, ...) are also provided. The
`cstd` module provides the C standard functions that the tools use, such as
a `printf` that formats numbers exactly as the GNU C library does. Run
`cargo doc --open` in the `rust` directory for the documentation of every
function.

## Legacy mode

Legacy mode reproduces the original WFDB package exactly, including its
assumed signal parameters and its search for files. Use it only to reproduce
old results:

* tools: `--legacy` as the first argument, as in `rdsamp --legacy -r 100s`,
  run in the directory of the sample record `100s` (`tests/data` in a copy
  of the repository). Legacy mode finds files through the WFDB path, which begins with the
  current directory, and does not use the input directory;
* high-level functions: `legacy: true` in `ReadOptions` or `WriteOptions`,
  or `true` as the `legacy` argument of `read_header` and `read_annotations`;
* the whole library: `wfdbx_set_legacy(1)`, or `w.wfdbx_set_legacy(1)` for
  one `Wfdb` value.

[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md#legacy-mode)
describes what changes in legacy mode.

## Notes

* **FLAC.** Formats 508, 516 and 524 (FLAC-compressed signals) are read and
  written without any external library. The C library reads files written
  by WFDB-x with identical sample values, although the compressed bytes
  differ from those of libFLAC.
* **Speed.** Build programs in release mode (`cargo build --release`).
  `read_record` reads signal files in large blocks and is the fastest way to
  read a record. For a program that processes a record as a stream,
  `getvecs` reads many frames at once; it is faster than calling `getvec`
  for each frame.
  [BENCHMARKS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/BENCHMARKS.md)
  compares the seven languages and wfdb-python.
* **Tool names.** The tools have the same names as the original WFDB tools.
  If both are installed, the one that comes first in the `PATH` runs.
* **No unsafe code.** The crate does not use `unsafe`.

## Testing

From the `rust` directory of the repository:

```sh
cargo test --release
```

This runs the unit tests, the integration tests and the examples in the
documentation. To run the cross-language conformance suite, which compares
the tools with the original C tools, build the tools and run the harness
from the root of the repository:

```sh
cargo build --release --manifest-path rust/Cargo.toml
python3 tests/conformance/harness.py check --impl rust
python3 tests/conformance/harness.py check --legacy --impl rust   # legacy mode
```

[DEVELOPING.md](DEVELOPING.md) describes how the crate is organized, for
developers of WFDB-x.

## Authors and license

WFDB-x implements version 10.7.0 of the WFDB Software Package.

The WFDB library and tools were written by George B. Moody, with revisions by
Benjamin Moody and contributions from many others; `parsescp` was written by
George B. Moody and Edna S. Moody. Each module names the authors of the C
code it implements, and
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md)
gives the details. The Rust implementation was developed by Reza Sameni
(2026), through AI-assisted development, cross-language
verification and unit testing.

WFDB-x is an independent reimplementation. Its Rust code is a translation of
the C code of the WFDB Software Package into Rust, written for WFDB-x; it is
not code by the original WFDB developers. It follows the original's logic
and behavior, with the changes described in
[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md).
The authors of the original C code are credited in each file and in
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md).

WFDB-x is distributed under the GNU General Public License, version 3 or
(at your option) any later version. See
[LICENSE](https://github.com/alphanumericslab/wfdb-x/blob/main/LICENSE).
