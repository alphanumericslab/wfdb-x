# wfdb-x for Rust

wfdb-x for Rust (crate `wfdbx`) is a Rust implementation of the WFDB
library and command-line tools (WFDB Software Package 10.7.0). It reads and
writes the same files as the original C library, and its tools produce
byte-identical output. See the [project README](../README.md) for the
overall design.

* No dependencies: only the Rust standard library (no crates from the
  network), and no `unsafe` code.
* Rust 1.70 or later (2021 edition); Linux, macOS, Windows.
* Formatted output (`printf`) identical to glibc's for every value,
  including the exact decimal expansion and rounding of every `f64`.

The library covers the whole C API (signals, annotations, calibration,
headers and info strings, the WFDB path, FLAC-compressed signal formats),
and all the command-line tools of the package are available.

## Building and installing

```sh
cd rust
cargo build --release          # library and tools, in rust/target/release/
cargo test --release           # unit and integration tests
cargo install --path .         # install the tools in ~/.cargo/bin
```

(From the repository root: `cargo install --path rust`.)

## Command-line tools

Each tool is a separate program with the name, options, output, error
messages and exit statuses of the original (see the *WFDB Applications
Guide*, [`third_party/wag.pdf`](../third_party/)):

```sh
rust/target/release/wfdbwhich -r 100s 100s.dat
rust/target/release/wfdbcat 100s.hea
```

Available tools: `rdsamp`, `wrsamp`, `wfdbdesc`, `wfdbcat`, `wfdbwhich`,
`wfdbtime`, `sigamp`, `snip`, `xform`, `sampfreq`, `signame`, `signum`,
`time2sec`, `rdann`, `wrann`, `sortann`, `ann2rr`, `rr2ann`, and the
converters `edf2mit`, `mit2edf`, `rdedfann`, `wav2mit`, `mit2wav`,
`wfdb2mat`, `a2m`, `m2a`, `ad2m`, `md2a`, `ahaecg2mit`, `makeid`, `readid`,
`revise` and `parsescp`.

### No built-in signal parameters

Like every wfdb-x implementation, the tools never assume a sampling
frequency (the C package assumed 250 Hz), a gain (200 adu/mV), an ADC
resolution (12 bits, or a value based on the storage format) or units
(millivolts) that a record or the user did not give. These values describe
the equipment of the first PhysioNet databases, not modern recordings, and
a silently assumed value corrupts every time, duration and physical value
derived from it, with nothing in the output to say so. The tools use the
values in the record header or given explicitly, and stop with an error
when an operation needs one that is not specified; unspecified units are
shown as `nd` (no dimension) and an unspecified resolution as `not
specified` (`wfdbdesc`).

New or now required options:

* `wrsamp`: with `-o`, `-F FREQ`, `-G GAIN` (`-G 0` declares the signals
  uncalibrated) and `-R BITS` are required, and `-U UNITS` for calibrated
  signals unless the input gives the units (`-R`, `-G` and `-U` take
  lists; the last value applies to the remaining signals).
* `ad2m` and `ahaecg2mit`: `-F`, `-G`, `-R` and `-U` (unless the gain is 0)
  are required; `ahaecg2mit` takes its options before the input files.
* `wav2mit`: `-G` and `-U` (unless the gain is 0) are required; the
  frequency and resolution come from the WAV file.
* `a2m`, `rdann`, `ann2rr`, `sortann` and `m2a`: `-F FREQ`, used when the
  record has no header or its header gives no frequency (as `rr2ann -F`).
* `mit2edf` requires the frequency, gains and ADC resolutions in the header;
  `xform` asks for an ADC resolution that the input does not give.

To reproduce the results of the original tools, give the values they
assumed explicitly, for example:

```sh
wrsamp -o rec -F 250 -G 200 -R 16 -U mV < samples.txt
ad2m -i 1201.CMP -F 250 -G 400 -R 12 -U mV
ahaecg2mit -F 250 -G 400 -R 12 -U mV 1001.ecg
wav2mit -i sound.wav -G 6400 -U mV      # 16-bit file (12.5 for 8 bits)
a2m -i 1201.ANO -F 250
```

See [`docs/DIVERGENCES.md`](../docs/DIVERGENCES.md) for the details.

**Legacy mode.** `--legacy` as the first argument of any tool (`rdsamp
--legacy -r 100s -t 10`) makes it behave exactly as the original tool:
same options (those added by wfdb-x, such as `rdann -F` or `wrsamp -R`, are
unrecognized), outputs, messages, help texts and exit statuses. In the
library, `wfdbx_set_legacy(1)` (`Wfdb::wfdbx_set_legacy`, per instance; the
free function uses the default instance) turns the original defaults back
on, `wfdbx_get_legacy()` returns the setting and `wfdbx_legacy_args(&mut
argv)` is what the tools call to recognize `--legacy`; each high-level
function has a legacy option (`ReadOptions::legacy`,
`WriteOptions::legacy`, and the last argument of `read_header` and
`read_annotations`) that turns legacy mode on for the duration of the call.
Legacy mode reproduces the original package exactly, and it is tested
against its results (the legacy conformance suite, `harness.py check
--legacy`, and the library's legacy values from
`tests/reference/api_expect.c`). It is kept for compatibility only: the
values it assumes are exactly the silent defaults this project removed, so
results produced with it carry the same risks.

**Sorting annotation files.** When an annotation file is written out of
order (`wrann`, `putann`, `write_annotations`), the library rearranges it
when it is closed, in the same process, with exactly the result of `sortann
-r. RECORD -a ANNOTATOR` (unless `WFDBANNSORT` is 0, or the `sort` option of
`write_annotations_with`, `AnnWriteOptions::sort`, decides otherwise for
that call: `Some(true)` sorts, `Some(false)` leaves the file as written,
whatever `WFDBANNSORT` says; the environment is not changed); the C
library ran the `sortann` program through the shell. In legacy mode, the `sortann` program
is run (from the directory of the running program, else from the `PATH`),
without a shell, as `sortann --legacy` and in the output directory if one is
set. Unlike the original, sorting (here and in `sortann`) keeps an
out-of-order annotation at time 0 (with `num` and `chan` 0) and those
inserted after it (input times 5, 0, 3 give 0, 3, 5; the original, and
legacy mode, give only 5).

The tools are checked against the C tools by the conformance suite of
wfdb-x (run from the repository root):

```sh
python3 tests/conformance/harness.py check --impl rust
python3 tests/conformance/harness.py check --legacy --impl rust   # legacy mode
```

## Finding records

Every relative name is read under the input directory and written under
the output directory — whatever you set as the input directory, a local
directory or a URL, prefixes it; a name given as a full path
(`/Users/...`), a `~` path or a URL is used as given; nothing else is
searched. With no input or output directory set (the default), names are
relative to the current directory (`rdsamp -r mitdb/100` reads
`mitdb/100.hea`).

| Setting | Functions (`Wfdb` methods and free functions) | Environment variable | Default |
|---|---|---|---|
| input directory (a directory, `~...`, or a URL) | `wfdbx_set_input_dir(dir)` (returns the previous value), `wfdbx_get_input_dir()` | `WFDBX_INPUT_DIR` | none: the current directory |
| output directory (local) | `wfdbx_set_output_dir(dir)`, `wfdbx_get_output_dir()` | `WFDBX_OUTPUT_DIR` | none: the current directory |
| network access | `wfdbx_set_network(1)` / `(0)` (`-1`: the default), `wfdbx_get_network()` | `WFDBX_NETWORK` (a nonzero number: on) | off |

The environment variables are read when the setting is first needed; a
function call overrides them, and `None` (or `""`, or a negative value for
the network) restores the default. The tools have no new options: they use
the environment variables. In the C-style API, `setwfdb(dir)` sets the
input directory (one directory only: a path of several is an error; it splits its argument at spaces, as the original does, so a directory whose name contains a space must be set with `wfdbx_set_input_dir`, which takes the name as it is),
`getwfdb()` returns it (`"."` if none is set), and the `WFDB` variable is
ignored, with a warning. The high-level readers take
`ReadOptions::input_dir` and `ReadOptions::network` (for `read_header` and
`read_annotations`: `read_header_with`, `read_annotations_with`), set for
the duration of the call; the writers take an output directory (see below).

**Remote records.** URLs (`http://`, `https://`) are opened only when
network access is on; each file is read in full by the system's `curl`
program (run without a shell; following redirections; reading gives up if connecting takes 30 s or no data arrives for 30 s, with no limit on the total time),
once per process. There is no default server. For example, the files of a
PhysioNet database are under `https://physionet.org/files/DATABASE/VERSION/`:

```rust,no_run
use wfdbx::{read_record, ReadOptions};

fn main() -> Result<(), wfdbx::record::Error> {
    let opt = ReadOptions {
        input_dir: Some("https://physionet.org/files/mitdb/1.0.0/".into()),
        network: Some(true),
        to: Some("0:10".into()),
        ..Default::default()
    };
    let rec = read_record("100", &opt)?;    // MIT-BIH Arrhythmia Database, record 100
    println!("{} Hz", rec.fs);
    Ok(())
}
```

(With the C-style API: `wfdbx_set_input_dir("https://physionet.org/files/mitdb/1.0.0/")`
and `wfdbx_set_network(1)`, then `isigopen("100", ...)`; with the tools:
`WFDBX_INPUT_DIR=https://physionet.org/files/mitdb/1.0.0/ WFDBX_NETWORK=1
rdsamp -r 100`.)

**Files named in a header.** The signal files named in a header, and the
segments of a multi-segment record, are in the directory of that header (on
disk or at its URL), or below it: `data/a.dat` in `db/rec.hea` is
`db/data/a.dat`. A name that is absolute, begins with `~`, is a URL or has
a `..` component is refused (`init: file NAME named in the header of record
REC is not in the header's directory`); `~` as a segment (a gap) and `-` as
a signal file (the standard input) keep their meaning.

Legacy mode keeps the original search of the WFDB path (the `WFDB`
environment variable, or `setwfdb`), without network access, as the
original package built without network support.

## Using the library

As a dependency of another Cargo project:

```toml
[dependencies]
wfdbx = { path = "../wfdb-x/rust" }
# or
wfdbx = { git = "https://github.com/alphanumericslab/wfdb-x" }
```

### The C-style API

All the state of the C library is held by a `Wfdb` value, and each C
library function is a method with the C name. Every function is also
available as a free function operating on a (thread-local) default
instance, which is convenient for ports of C programs:

```rust
use wfdbx::{Wfdb, NULL};

let mut w = Wfdb::new();
w.wfdbx_set_input_dir("/usr/local/database");
if let Some(path) = w.wfdbfile("hea", "100s") {
    println!("{}", String::from_utf8_lossy(&path));
}

// The same with the default instance:
wfdbx::setwfdb(".");
let f = wfdbx::wfdbfile("100s.hea", NULL);
```

Independent `Wfdb` instances can be used at the same time (for example in
different threads); each has its own open records and settings.

Conventions:

* **Strings are bytes.** WFDB files are not UTF-8, so strings are `&[u8]`
  arguments (a `&str` or `b"..."` literal works too) and `Vec<u8>` results.
  C's `NULL` is `None` (`wfdbx::NULL` for arguments).
* **C integer types:** `int` is `i32`, `long` and `WFDB_Time` are `i64`,
  `WFDB_Sample` is `i32`, `char` is `i8`.
* **Structures** (`Siginfo`, `Calinfo`, `Anninfo`, `Annotation`,
  `Seginfo`) have the C field names; `Default` gives C's zero values. An
  annotation's `aux` holds the C bytes, including the leading length byte.
* Functions that fill a caller's array take a mutable slice
  (`isigopen(record, &mut si, nsig)`).
* Errors are reported as in C: functions return status codes (a negative
  value, or `None` for a C `NULL` pointer, on failure; the meaning of each
  code is given in the documentation of each function), and an error
  message is printed on the standard error unless `wfdbquiet()` is
  called; `wfdberror()` returns the last one.

### The high-level API

`read_record`, `read_header`, `read_annotations`, `write_record`,
`write_record_physical` and `write_annotations` read and write whole
records and annotation files in one call (as the tools do) and return
`Result<_, wfdbx::record::Error>`. `read_record` returns the error "can't
read signal data of record REC (getvec status S)" when reading stops with a
getvec status below -1, e.g. -3 for a signal file shorter than its header
says, instead of the samples read so far; reaching the end of the record is
not an error. This applies in legacy mode too, since the high-level API is a
wfdb-x addition (`getvec`, `getvecs`, `getvecs_status`, which also
returns that status, and the tools are unchanged).

`read_header` returns a `Header`: the record name, `fs` (as `sampfreq`
gives it, 0 if the header gives none), `counter_freq` (`getcfreq`),
`base_counter` (`getbasecount`), `nsamples` (from the record line, 0 if
absent), `nsig`, `siginfo` (one `Siginfo` per signal), `base_time`,
`base_time_ms`, `base_date` and `comments`, without opening any signal
file. `Record` and `Header` give the base time as text (`base_time`, as
`timstr(0)` gives it, e.g. `"[14:00:03 21/06/2024]"`), and as numbers:
`base_time_ms`, the milliseconds after midnight (`Some(50403500)` for
`14:00:03.500`; `Some` exactly when `base_time` is), and `base_date`,
`Some([year, month, day])` when the header gives a date. `Record::checksum_ok`
is false if the signal data were found not to match the checksums in the
header (whether or not the warning below is printed); the checksums are
verified only when a read reaches the end of the record.

**Checksum errors.** A checksum error (getvec status -4: the data are
complete, but their sum does not match the checksum in the header) is not
an error for `read_record`: it returns every frame, including the last one,
and prints the warning `wfdb-x: checksum error in record REC: the signal
data do not match the checksums in its header` on the standard error,
through the library's message path (so `wfdbquiet()` silences it; the
library's own `getvec: checksum error in signal N` is not printed during
the read, but `wfdberror()` returns it with `checksum_warning` off). Set
`ReadOptions::checksum_warning` to false to read without the warning. This
behavior is identical in all six implementations of wfdb-x.

**Output files are never input files.** When output signal files are
created (`osigfopen`, `osigopen`, and so every tool and `write_record`), a
file that is one of the signal files of the open input record (an open
signal file, or one of the segments of an open multi-segment record, even
not opened yet) is refused, instead of being truncated while it is read
(`xform -i vlay -o fmt16`, whose input includes `fmt16.dat`): the function
reports `osigfopen: output file F is also an input file` (or `osigopen:
...`) and fails with -3, leaving the input intact. Files are compared by
identity (device and inode; on Windows, the canonical path, without regard
to case), so another name of the same file, or a hard link, is refused too.
Legacy mode keeps the original behavior. This behavior is identical in all
six implementations of wfdb-x.

```rust,no_run
use wfdbx::{read_annotations, read_record, ReadOptions};

fn main() -> Result<(), wfdbx::record::Error> {
    let opt = ReadOptions { to: Some("0:10".into()), ..Default::default() };
    let rec = read_record("100s", &opt)?;       // the first 10 seconds
    println!("{} Hz, {} signals", rec.fs, rec.nsig);
    println!("{}", rec.physical(0, 1)?);        // sample 0 of signal 1, physical units

    let ann = read_annotations("100s", "atr", None, None, None, false)?;
    println!("{} annotations", ann.len());
    Ok(())
}
```

There are no default sampling frequency, gain, ADC resolution or units
(see [`docs/DIVERGENCES.md`](../docs/DIVERGENCES.md)): `WriteOptions::gains`
and `WriteOptions::adcres` are required (`write_record` fails with "gains
must be specified" or "ADC resolution(s) must be specified" without them; a
gain of 0 declares a signal uncalibrated, which `write_record_physical`
refuses), `WriteOptions::units` must give the units of every signal whose
gain is not 0 ("units must be specified"), and `fs` must be greater than 0.
Each of these takes one value for all signals or one per signal:

```rust,no_run
use wfdbx::{write_record, WriteOptions};

fn main() -> Result<(), wfdbx::record::Error> {
    let samples = [0, 10, 5, 12, 9, 14];          // two signals, three frames
    let opt = WriteOptions {
        gains: vec![200.0],                       // adu/mV
        adcres: vec![16],                         // bits
        units: vec![Some("mV".into())],
        names: vec!["I".into(), "II".into()],
        ..Default::default()
    };
    write_record("example", &samples, 2, 360.0, &opt)
}
```

`read_record` gives `fs` 0 for a header without a frequency and fails for
time strings that need one (`wfdbx_time_needs_freq`); a signal without an
ADC resolution has `adcres` 0, and one without units has `units` `None`
(never "mV"); `Record::physical` fails for an uncalibrated signal. The
fifth argument of `read_annotations` is an optional sampling frequency
(`Some(fs)`), used, like `rdann -F`, when the record has no header or its
header gives none; the last one selects legacy mode (see above: with it, as
with `ReadOptions::legacy` and `WriteOptions::legacy`, the function behaves
as in the original package, e.g. 250 Hz for a record without a frequency,
gain 200 for uncalibrated signals, and the format's resolution by default).

**Output directory.** `WriteOptions::dir` and the last argument of
`write_annotations` (`Some(path)`) create the files in that directory,
which must exist; the record name must then be a plain name (an error
otherwise), and the header names the record and its signal file without the
directory (`rec 2 360 ...`, `rec.dat ...`), so that the record opens from
that directory under its plain name:

```rust,no_run
use std::path::Path;
use wfdbx::{write_annotations, write_record, Annotations, WriteOptions};

fn main() -> Result<(), wfdbx::record::Error> {
    let opt = WriteOptions {
        gains: vec![200.0],
        adcres: vec![16],
        units: vec![Some("mV".into())],
        dir: Some("out".into()),                  // out/rec.hea, out/rec.dat
        ..Default::default()
    };
    write_record("rec", &[0, 10, 5, 12], 2, 360.0, &opt)?;
    let ann = Annotations { samples: vec![1], symbols: vec!["N".into()], ..Default::default() };
    write_annotations("rec", "atr", &ann, 0.0, Some(Path::new("out")))
}
```

The library's output directory (`wfdbx_set_output_dir(dir)`, which returns
the previous value, and `wfdbx_get_output_dir()`; per instance, like the
legacy setting) is set for the duration of the call and restored
afterwards. With it set, `wfdb_open` creates every output file as
`DIR/NAME`; the C-style API and the tools are otherwise unchanged
(`newheader("out/rec")` still records `out/rec`).

The free functions use the default instance; the same functions are
methods of `Wfdb` (`w.read_record(...)`). Each call closes the records
and annotators open in the instance it uses (it calls `wfdbquit` before
and after), so do not mix them with C-style calls on an open record of
the same instance.

### C library emulation (`wfdbx::cstd`)

The `cstd` module provides the C functions whose exact behavior the WFDB
tools depend on, for use in programs that must match C output:

```rust
use wfdbx::{cformat, cprintf, csscanf, cstd};

assert_eq!(cformat!(b"%5.1f|%-4s|%e", 2.25, "ab", 1e-310),
           b"  2.2|ab  |1.000000e-310");
cprintf!(b"%d\n", 42);                    // buffered standard output
let (mut d, mut m) = (0i32, 0i32);
assert_eq!(csscanf!(b"12/5", b"%d/%d", &mut d, &mut m), 2);
assert_eq!(cstd::strtol(b"  0x1fz", 16), (31, 6));
cstd::exit(0);                            // flushes, then exits
```

## License

The library is distributed under the GNU Library General Public License,
version 2 or later ([`LICENSE.LIB`](../LICENSE.LIB)); the command-line tools
under the GNU General Public License, version 2 or later
([`LICENSE`](../LICENSE)). The original C implementation is by George B.
Moody, Benjamin Moody and others (each file names the authors of the C code
it ports; see [`docs/AUTHORS.md`](../docs/AUTHORS.md)). The Rust
implementation was developed by Reza Sameni (2026), with AI assistance (see
the project README).

## For developers

See [`DEVELOPING.md`](DEVELOPING.md) (architecture and conventions of the
Rust implementation) and [`docs/porting-guide.md`](../docs/porting-guide.md).
