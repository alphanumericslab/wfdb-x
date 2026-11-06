# WFDB-x for C++

> **WFDB-x** is a reimplementation of the WFDB Software Package (the library
> and its command-line tools) in seven languages: Python, C++,
> MATLAB/Octave, Rust, Julia, R and Kotlin, tested to give byte-for-byte
> identical results to the original C package and to each other. This is the
> C++ implementation.
> [Project page and the other languages](https://github.com/alphanumericslab/wfdb-x)
> · [WFDB-x at a glance (overview figure)](https://github.com/alphanumericslab/wfdb-x#wfdb-x-at-a-glance)
> · [Benchmarks](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/BENCHMARKS.md)
> · [User's manual (PDF)](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/user-manual/wfdb-x-user-manual.pdf)
> (chapter "C++" for this language)
> · [How to cite WFDB-x](https://github.com/alphanumericslab/wfdb-x#how-to-cite)

`libwfdbx` reads and writes physiological signal records in the WFDB format
used by [PhysioNet](https://physionet.org). It is a complete C++17
implementation of the WFDB Software Package: the library and all of its
command-line tools. It reads and writes the same files as the original C
library, and its tools print the same output.

Everything is in namespace `wfdbx`. The library needs only the C++17
standard library. It builds with CMake 3.14 or later and a C++17 compiler whose
standard library has `std::filesystem` (GCC 9, Clang 9 or MSVC 2019 and
later; macOS 10.15 or later), on Linux, macOS and Windows.

## Three ways to use WFDB-x

All three are written in C++; none of them calls the C library.

1. **The high-level functions (recommended).** `read_record`,
   `read_header`, `read_annotations`, `write_record`, `write_annotations`
   and `check_record`, in `<wfdbx/record.hpp>`, read and write whole
   records and annotation files as `std::vector`s, in one call, with
   options given as fields of a struct (`ReadOptions`, `WriteOptions`), and
   throw `wfdbx::Error` on errors. `read_metadata`, `set_metadata` and the
   other functions of [Header metadata](#header-metadata) read and change
   the `Key: value` entries of a header. They read signal files in large blocks,
   so they are the fastest way to read a record. They are an addition of
   WFDB-x: the C package has no equivalent. Use them for new code and
   analysis.
2. **The WFDB library functions** in `<wfdbx/wfdb.hpp>`, under their C
   names (`isigopen`, `getvec`, `getann`, `putann`, ...), with the C
   behavior: sample by sample and annotation by annotation, with errors
   reported by return values. Use them to port a program written against
   the C library, or for the exact C semantics.
3. **The command-line tools** (`rdsamp`, `rdann`, `wrsamp`, `xform`, and
   29 others), with the options, output and exit status of the C tools,
   built as separate programs and run by their names (`rdsamp -r 100s`).
   Use them in shell scripts and pipelines, or to reproduce work done with
   the original tools.

The high-level functions return exactly the samples and annotations that
the library functions (and the C library) give.

## Installation

From the root of a copy of the repository, build the library, the tools and
the unit tests, then install them:

```sh
cmake -S cpp -B cpp/build                        # a Release build
cmake --build cpp/build -j8
cmake --install cpp/build --prefix /usr/local    # optional
```

The library is `cpp/build/libwfdbx.a` and the tools are in `cpp/build/bin/`.
The install step copies the library, the headers (`include/wfdbx/`), the
tools and a CMake package file. These options change what is built:

| Option | Default | Effect |
|---|---|---|
| `WFDBX_BUILD_TOOLS` | `ON` | build the command-line tools |
| `WFDBX_BUILD_TESTS` | `ON` | build the unit tests |
| `BUILD_SHARED_LIBS` | `OFF` | build a shared library |

To use the installed library from a CMake project, add these lines to its
`CMakeLists.txt`:

```cmake
find_package(wfdbx REQUIRED)
target_link_libraries(myprogram PRIVATE wfdbx::wfdbx)
```

To compile a program directly, link it with `-lwfdbx`:

```sh
c++ -std=c++17 myprogram.cpp -lwfdbx
```

## Quick start

The repository includes a sample record, `100s`, in `tests/data`: the first
minute of record 100 of the
[MIT-BIH Arrhythmia Database](https://physionet.org/content/mitdb/), with two
ECG signals at 360 Hz and its beat annotations. This program reads it and
writes a copy of its first 10 seconds:

```cpp
#include <cstdio>
#include <wfdbx/record.hpp>

int main() {
    // Read the sample record from the tests/data directory of the repository.
    wfdbx::wfdbx_set_input_dir("tests/data");

    wfdbx::ReadOptions opt;
    opt.to = "0:10";                                   // the first 10 seconds
    wfdbx::Record rec = wfdbx::read_record("100s", opt);
    std::printf("%g %d %zu\n", rec.fs, rec.nsig, rec.nsamples());  // 360 2 3600
    std::printf("%d %g\n", rec.at(0, 0), rec.physical(0, 0));      // 995 -0.145

    wfdbx::Header hdr = wfdbx::read_header("100s");    // the header only, no samples
    std::printf("%d %lld\n", hdr.nsig, hdr.nsamples);  // 2 21600

    wfdbx::Annotations ann = wfdbx::read_annotations("100s", "atr");
    std::printf("%zu %s %lld\n", ann.size(), ann.symbols[1].c_str(),
                ann.samples[1]);                       // 75 N 77

    // Write the 10 seconds as a new record in the current directory.
    wfdbx::WriteOptions w;
    w.gains = {200};
    w.baselines = {1024};
    w.adczeros = {1024};
    w.adcres = {11};
    w.units = {"mV"};
    w.names = rec.names();
    wfdbx::write_record("copy", rec.samples, rec.nsig, rec.fs, w);  // copy.hea, copy.dat
}
```

Compile it and run it from the root of the repository:

```sh
c++ -std=c++17 -Icpp/include quick.cpp cpp/build/libwfdbx.a -o quick
./quick
```

## Reading and writing records

The functions of `<wfdbx/record.hpp>` return their results by value, and
throw `wfdbx::Error` when they fail.

### Reading signals: `read_record`

`read_record(record, opt)` reads the signals of a record. The record name
is given without the `.hea` extension, as a full path, a relative path
(read from the input directory) or a URL (see
[Record names](#record-names)). The options are fields of a `ReadOptions`.
The examples of this section read the sample record `100s` (the first
minute of record 100 of the MIT-BIH Arrhythmia Database), which is included
with WFDB-x in the `tests/data` directory of a copy of the repository; run
them from the root of the repository:

```cpp
wfdbx::ReadOptions opt;
opt.input_dir = "tests/data";     // where the sample record 100s is
opt.channels = {"MLII"};
opt.from = "0:10";
opt.to = "0:20";
wfdbx::Record rec = wfdbx::read_record("100s", opt);
std::vector<double> mlii = rec.physical_signal(0);    // 3600 values
```

| Field of `ReadOptions` | Meaning | Default |
|---|---|---|
| `channels` | signals to read, by number (`"0"`) or name (`"V5"`, as in `names()`) | all signals |
| `from`, `to` | first sample, and the sample after the last one: a sample number or a time string (see below) | the whole record |
| `highres` | read a multi-frequency record at its highest sampling frequency | `false` |
| `pad` | replace invalid samples by the previous valid one | `false` |
| `checksum_warning` | warn when the data do not match the header's checksums | `true` |
| `input_dir`, `network` | input directory (under which relative record names are read; not used for full paths or URLs) and network access, for this call only | the current settings |
| `legacy` | behave as the original package (see [Legacy mode](#legacy-mode)) | `false` |

Times can be sample numbers or WFDB time strings: `"0:10"` (10 seconds),
`"1:02:03.5"`, `"s3600"` (sample 3600) or `"e"` (the end of the record).
`opt.from = 3600;` and `opt.from = "0:10";` both work.

The result is a `Record`:

| Member | Contents |
|---|---|
| `samples` | the samples in ADC units, frame by frame: `samples[i * nsig + s]` is sample `i` of signal `s` |
| `at(i, s)`, `physical(i, s)` | sample `i` of signal `s`, in ADC units or in physical units |
| `physical_signal(s)` | all the samples of signal `s` in physical units, as a `std::vector<double>` |
| `nsamples()`, `nsig` | the number of samples per signal, and the number of signals |
| `fs` | sampling frequency in Hz (0 if the header gives none) |
| `names()` | the description of each signal, without the white space that a header may put at either end of it |
| `siginfo` | the signal specifications (`WFDB_Siginfo`): `desc`, `units`, `gain` (ADC units per physical unit; 0 means uncalibrated), `baseline`, `adcres`, `fmt`, ... |
| `signals` | the number, in the record, of each signal returned |
| `sampfrom` | the number of the first sample returned |
| `base_time` | start time and date as text, to the second, such as `"[14:00:03 21/06/2024]"` |
| `base_time_ms` | start time in milliseconds after midnight, such as `50403500` for 14:00:03.500 |
| `base_date` | start date as `{year, month, day}` |
| `comments` | the info strings of the header |
| `checksum_ok` | `false` if the data do not match the header's checksums |

`base_time`, `base_time_ms` and `base_date` are `std::nullopt` when the
header does not give them, and so are the `units` of a signal. Invalid
samples are `WFDB_INVALID_SAMPLE`, or NaN in physical units.

### Reading a header: `read_header`

`read_header(record)` reads the header of a record without opening its
signal files. It returns a `Header` with these fields: `name`, `fs`,
`counter_freq`, `base_counter`, `nsamples` (0 if the header does not give
the length), `nsig`, `siginfo`, `base_time`, `base_time_ms`, `base_date`,
`comments` and `metadata` (the `Key: value` entries of the header, as
`read_metadata` returns them, from the `.hea` file only; empty for an EDF
record, which has no `.hea` file, and for a header read from the standard
input, `-`; see [Header metadata](#header-metadata)).
The others have the same meaning as in `Record`.

```cpp
wfdbx::wfdbx_set_input_dir("tests/data");     // the sample record 100s
wfdbx::Header hdr = wfdbx::read_header("100s");
for (const wfdbx::WFDB_Siginfo &s : hdr.siginfo)
    std::printf("%s %d %g %d\n", s.desc->c_str(), s.fmt, s.gain, s.adcres);
```

The full signature is `read_header(record, legacy, input)`. `input` is an
`InputOptions` with the fields `input_dir` and `network`, as in
`ReadOptions`.

### Reading annotations: `read_annotations`

This reads the annotations of the sample record `100s` from 10 to 30
seconds:

```cpp
wfdbx::wfdbx_set_input_dir("tests/data");     // the sample record 100s
wfdbx::Annotations ann = wfdbx::read_annotations("100s", "atr", "0:10", "0:30");
```

The full signature is
`read_annotations(record, annotator, from, to, fs, legacy, input)`.
`annotator` is the file suffix (`"atr"` reads `100s.atr`). The optional `fs`
gives the sampling frequency when the record has no header, or its header
gives none. `input` is an `InputOptions`, as for `read_header`. The result
is an `Annotations` object, in file order:

| Member | Contents |
|---|---|
| `samples` | annotation times, in samples |
| `codes`, `symbols` | annotation codes (`wfdbx::NORMAL`, `wfdbx::PVC`, ...) and their mnemonics (`"N"`, `"V"`, ...) |
| `subtypes`, `chans`, `nums` | subtype, channel and annotator number of each annotation |
| `aux` | auxiliary text of each annotation, or `std::nullopt` |
| `fs` | the frequency in which `samples` are counted (0 if unknown) |
| `size()` | the number of annotations |

### Writing a record: `write_record`

`write_record(record, samples, nsig, fs, opt)` writes samples in ADC units.
`write_record_physical` takes the same arguments, with samples in physical
units. This writes a new record, `rand`, of two signals of random values:

```cpp
std::mt19937 gen(1);
std::normal_distribution<double> randn;
std::vector<double> x(3600 * 2);                // 3600 frames of 2 signals
for (double &v : x) v = randn(gen);

wfdbx::WriteOptions w;
w.gains = {1000};
w.adcres = {16};
w.units = {"mV"};
w.names = {"A", "B"};
wfdbx::write_record_physical("rand", x, 2, 360, w);
```

This writes the header `rand.hea` and the signal file `rand.dat`. The
samples are given frame by frame, as in `Record::samples`. The sampling
frequency, the gain and ADC resolution of each signal, and the units of each
calibrated signal are required; there are no defaults. A gain of 0 marks a
signal as uncalibrated, which is only allowed for samples given in ADC
units; negative gains are allowed. The sampling frequency and the gains must
be finite. Per-signal fields take one value for all signals, or one value
per signal; any other length throws `wfdbx::Error`.

| Field of `WriteOptions` | Meaning |
|---|---|
| `fmt` | storage format, such as 16, 212, 24 or 516 (FLAC); default 16 |
| `gains`, `adcres`, `units` | gain, ADC resolution in bits, and physical units |
| `baselines`, `adczeros`, `names` | optional signal specifications |
| `base_time`, `comments` | start time (`"hh:mm:ss dd/mm/yyyy"`) and info strings |
| `metadata` | `Key: value` entries, written after the comments as `# Key: value`: a `wfdbx::Metadata`, a vector of (key, value) pairs (see [Header metadata](#header-metadata)) |
| `samps_per_frame` | samples per frame of each signal, for a multi-frequency record |
| `dir` | directory (which must exist) in which to create the files, for this call only; the record name must then be a plain name, without a directory |
| `legacy` | behave as the original package (see [Legacy mode](#legacy-mode)) |

### Writing annotations: `write_annotations`

This writes the annotation file `rand.qrs` for the record `rand` written
above:

```cpp
wfdbx::Annotations qrs;
qrs.samples = {100, 460, 820};
qrs.symbols = {"N", "N", "V"};
wfdbx::write_annotations("rand", "qrs", qrs);
```

The full signature is `write_annotations(record, annotator, ann, fs, dir,
sort)`. Give the annotation types as `symbols` or as `codes`. Both may be
given, as `read_annotations` returns them, if they agree: each non-empty
symbol must be the mnemonic of the code at the same position (otherwise
"symbols and codes disagree at annotation K", K counted from 0). `subtypes`,
`chans`, `nums` and `aux` are optional. Each of these fields is either empty
or has one entry per annotation; any other length throws `wfdbx::Error`
before anything is written. `subtypes`, `chans` and `nums` are stored in 8
bits, as in C (300 is stored as 44). `fs` is 0 (none) or a finite
frequency greater than 0, which is recorded in the file (for this file
only: the previous time resolution of output annotators, `getafreq()`, is
restored). `dir` is the directory (which must exist) in which to create the
file, for that call only; the record name must then be a plain name, and the
file is `DIR/RECORD.ANNOTATOR`. Without `dir`, the file is created as the
record name says (see [Record names](#record-names)). The arguments are
checked before the file is created.

If the annotations are not in time order, the file is sorted when it is
written. `sort = false` keeps the given order (without the library's
advice to run `sortann`) and `sort = true` always sorts, for that call
only. Without `sort`, the `WFDBANNSORT` environment variable decides
(sorting is on unless it is `0`).

### Header metadata

Many datasets store facts about a recording in the header, as comment
lines of the form `# Key: value`, such as `# Age: 63` or `# Dx: 164889003`.
These functions read and change them, without touching the rest of the
header:

```cpp
wfdbx::Metadata m = wfdbx::read_metadata("rec");   // {{"Age", "63"}, {"Sex", "F"}}
std::optional<std::string> age = wfdbx::get_metadata("rec", "age");
                                                   // "63" (std::nullopt if there is none)
wfdbx::set_metadata("rec", "Age", "64");           // replaces the line, or adds "# Age: 64"
int n = wfdbx::remove_metadata("rec", "Sex");      // 1: the number of lines removed
wfdbx::update_metadata("rec", {{"Age", "65"}, {"Dx", std::nullopt}});
                                                   // several changes; std::nullopt removes
```

* **Reading.** An entry is a comment line after the record line (an info
  string, as the C function `getinfo` reads it) that contains a colon. The
  key is the text before the first colon, the value the rest of the line,
  both without spaces at either end: `#Age:45`, `# Age: 45` and
  `#  Age : 45` all give `{"Age", "45"}`. Comment lines without a colon are
  free comments: they are not returned, and never changed. Only the `.hea`
  file is read (not a `.info` file). `read_metadata` returns a
  `wfdbx::Metadata`, a `std::vector` of (key, value) pairs in file order.
* **Keys** are compared without regard to letter case: `"age"` finds
  `Age`. A key must not be empty, and must not contain `:`, `#`, a line
  break or a NUL character; it may contain spaces (`"Date of birth"`). If a
  header holds two entries whose keys differ only in letter case (written
  by other software), reading returns the first, with a warning on the
  standard error ("WFDB-x: header of record REC has more than one entry
  for key KEY (lines L1, L2); the first is used"; `wfdbquiet()` silences
  it, as the checksum warning); `set_metadata` and `update_metadata`
  refuse to change that key (`wfdbx::ArgumentError`), and
  `remove_metadata` removes both.
* **Values** are text, which may be a whole sentence, without a line break
  or a NUL character. Spaces at either end are removed; an empty value is
  allowed. Keys and values are bytes (`std::string`), as elsewhere in the
  library: UTF-8 text is stored as its bytes.
* **Writing.** An entry is written as `# Key: value` (`# Key:` if the value
  is empty), with the spelling of the key given. A changed entry keeps its
  position; a new one goes after the last comment line of the header. Every
  other byte of the header is kept, including its line endings. The header
  is replaced in one step (through a temporary file in its directory, which
  then replaces it and keeps its permissions), and all the arguments are
  checked first, so an error leaves it unchanged. Nothing is written if
  nothing changes.
* **Files.** The header is found as `read_header` finds it. The last
  argument of `read_metadata` and `get_metadata` is an `InputOptions`
  (`input_dir`, `network`, for that call only); that of `set_metadata`,
  `remove_metadata` and `update_metadata` is a `wfdbx::MetadataOptions`,
  which adds `dir`. A change is written to the header itself, or, with
  `dir`, to a header of the same name in that directory, which must exist
  (the signal files are not copied; the header is written there even if
  nothing changes). A header read from a URL can only be written
  elsewhere, with `dir`. For a multi-segment record, the master header is
  read or changed, unless a segment is named.

```cpp
wfdbx::MetadataOptions o;
o.input_dir = "in";            // read in/rec.hea
o.dir = "out";                 // write out/rec.hea; in/rec.hea is unchanged
wfdbx::set_metadata("rec", "Age", "64", o);
```

Errors throw `wfdbx::ArgumentError` for an invalid argument (an invalid key
or value, a record name that is empty or `-`, a key that the header has
more than once, a header without a record line, or a header read from a
URL without `dir`), and `wfdbx::FileError` for a file that cannot be read
or written ("can't read header for record REC", "can't write header for
record REC", "directory D does not exist"). Both are `wfdbx::Error`s. These
functions do not call `wfdbquit()`: they open only the header.

`write_record` writes the entries of `WriteOptions::metadata` after its
comments. Their keys must be unique (ignoring letter case), and none may be
the key of an entry in `comments`; this is checked before any file is
created (`wfdbx::ArgumentError`).

Metadata often holds information about patients. WFDB-x stores it as plain
text, exactly as given, and does not de-identify it. The comments of
`<wfdbx/record.hpp>` give the full rules.

### Errors and warnings

* A record, header or annotation file that cannot be read or written throws
  `wfdbx::Error`, such as "can't read record nosuchrecord". `e.what()`
  returns the message.
* A signal file that is shorter than its header says throws `wfdbx::Error`:
  "can't read signal data of record REC (getvec status -3)".
* An annotation file that ends early or cannot be read throws
  `wfdbx::Error`: "can't read annotation file ANN of record REC (getann
  status S)". A read that stops (at `to`) before the damaged part returns
  its annotations.
* Invalid arguments, and a value the operation needs but the record does not
  give, throw `wfdbx::Error`. For example, a time string such as `"0:10"`
  needs the sampling frequency ("sampling frequency of record REC is not
  specified"), and `physical()` needs the gain of the signal ("signal N of
  record REC is uncalibrated").
* When the data do not match the checksums in the header, `read_record`
  returns all the data and prints a warning on the standard error: "WFDB-x:
  checksum error in record REC: the signal data do not match the checksums
  in its header". `checksum_warning = false` turns the warning off;
  `rec.checksum_ok` is `false` either way. Checksums are only checked when a
  read reaches the end of the record.
* `write_record` throws `wfdbx::Error` if a `samps_per_frame` value is less
  than 1 ("write_record: samps_per_frame must hold integers >= 1", checked
  before anything else), if the record name is empty, if there are no
  signals ("write_record: at least one signal is required"), if the number
  of samples is not a multiple of the frame size, or if `base_time` is not
  a valid time ("write_record: incorrect base time 'T'"), or if an entry
  of `metadata` is not valid (`wfdbx::ArgumentError`).
  `write_record_physical` also throws if a sample is infinite or out of the
  range of a 32-bit ADC value (NaN is stored as an invalid sample). Nothing
  is written then.
* `read_record` throws `wfdbx::Error` if `from` is negative. `write_record` and `write_annotations` throw
  `wfdbx::Error` when a file cannot be written completely, for example on a
  full disk: "write error on record REC", "write error on annotator ANN for
  record REC" (also in legacy mode).
* A tool, or a program that uses the WFDB library functions, never writes a
  signal file over one of the signal files it is reading. Opening such an
  output fails with "output file NAME is also an input file".
  `write_record` reads nothing, so it overwrites any existing files of the
  same name.

The messages of the library are printed on the standard error.
`wfdbx::wfdbquiet()` turns them off.

This catches an error:

```cpp
try {
    wfdbx::Record rec = wfdbx::read_record("nosuchrecord");
} catch (const wfdbx::Error &e) {
    std::printf("%s\n", e.what());    // can't read record nosuchrecord
}
```

The high-level functions (except the header metadata functions) call
`wfdbquit()` before and after their work, also when they throw, which
closes anything opened with the WFDB library functions. The library's
settings (legacy mode, getvec mode, time resolution of output annotators,
input and output directories) are the same after a call as before it, also
after reading an EDF record, whose opening sets the getvec mode and the
time resolution (see below).

### Checking a record: `check_record`

This checks the sample record `100s` (in `tests/data`) and its reference
annotations:

```cpp
wfdbx::wfdbx_set_input_dir("tests/data");     // the sample record 100s
wfdbx::CheckReport report = wfdbx::check_record("100s", {"atr"});
std::printf("%s\n", report.to_string().c_str());
```

`check_record(record, annotators, input)` checks the header of a record,
its signal specifications, every sample of its signal files, and the
annotation files named. It reports each problem it finds. It never
throws for a problem in the record (it throws `wfdbx::Error` only for an
empty record name). `input` is an `InputOptions` (`input_dir`, `network`),
as for `read_header`. It checks for problems similar to those found by
Benjamin Moody's [wfdbcheck](https://github.com/bemoody/wfdbcheck).

The result is a `wfdbx::CheckReport`. `report.ok` is `true` if there is no
error. `report.issues` lists the problems. Each `wfdbx::Issue` has a
`severity`, a `code` (such as `"checksum"`), a `where` (`""` for the record,
`"signal 1"`, `"segment s2"`, `"annotator atr"`) and a `message`.

| Severity | Meaning |
|---|---|
| `error` | the record is damaged or does not follow the WFDB format: programs will read wrong data or fail |
| `warning` | the record can be read, but something is missing or unusual, and may give wrong results |
| `info` | a fact worth knowing, such as invalid (missing) samples |

`report.to_string()` gives one line per problem, or the line
`no problems found`:

```
warning: signal 0: the units are not specified
error: signal 1: the checksum does not match: the header gives 12, the samples sum to 13
error: annotator atr: 3 annotations are out of order; the first is at sample 50, after sample 100
```

`report.lines()` returns these lines as a `std::vector<std::string>`, and
`issue.to_string()` the line of one issue. The lines are the same in the seven
languages of WFDB-x. The checks run in normal mode, even if legacy mode is
on, and the library prints no messages during the call.

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
| input directory: a local directory, `~/...` or a URL | `wfdbx_set_input_dir(d)` | `input_dir` of `ReadOptions` and `InputOptions` | `WFDBX_INPUT_DIR` |
| output directory | `wfdbx_set_output_dir(d)` | `WriteOptions::dir`, `dir` of `write_annotations` | `WFDBX_OUTPUT_DIR` |
| network access (off by default) | `wfdbx_set_network(1)` | `network` of `ReadOptions` and `InputOptions` | `WFDBX_NETWORK=1` |

A function call overrides the environment variable, and an option applies to
that one call. Each `set` function returns the previous setting.
`wfdbx_get_input_dir()`, `wfdbx_get_output_dir()` and `wfdbx_get_network()`
return the current settings. Passing `nullptr` to `wfdbx_set_input_dir` or
`wfdbx_set_output_dir`, or `-1` to `wfdbx_set_network`, restores the
default.

This reads record 100 from `/data/mitdb`, which stands for a local copy of
the MIT-BIH Arrhythmia Database, and writes an annotation file in `out`:

```cpp
wfdbx::wfdbx_set_input_dir("/data/mitdb");
wfdbx::Record rec = wfdbx::read_record("100");   // reads /data/mitdb/100.hea and 100.dat
wfdbx::Annotations ann = wfdbx::read_annotations("100", "atr");
wfdbx::write_annotations("100", "qrs", ann, 0, "out");  // writes out/100.qrs
```

The signal files that a header names are read from the header's directory.

### Record names

A record name is given without the `.hea` extension (the readers also
accept a trailing `.hea`; `write_record` does not). It is one of:

* a full path, absolute (`/data/mitdb/100`) or in the home directory
  (`~/Documents/100s`), used as given;
* a relative path (`100s`, `data/100s`), read from the input directory if
  one is set, otherwise from the current directory, and written to the
  output directory if one is set, otherwise to the current directory
  (missing directories are created);
* a URL (`https://physionet.org/files/mitdb/1.0.0/100`), read only if
  network access is on; a URL cannot be written.

The `input_dir` option is optional, and applies to relative names only, not
to full paths or URLs. A writer given a name with a path creates the files
in that directory, and the header names the record and its signal file
without the path (`rec`, `rec.dat`), so that the record opens under any
path that leads to it; in legacy mode, as in the original, the header gives
the name with its path. With the `dir` option, the name must be a plain
name (`rec`): the files are created in `dir`, and the record opens from that
directory under its plain name.

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
This reads record 100 of the MIT-BIH Arrhythmia Database:

```cpp
wfdbx::ReadOptions opt;
opt.input_dir = "https://physionet.org/files/mitdb/1.0.0/";
opt.network = true;
wfdbx::Record rec = wfdbx::read_record("100", opt);
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

Each tool is a separate program in `cpp/build/bin/`, or in the `bin`
directory of the installation. With that directory in the `PATH`, run a
tool by its name. These commands read the sample record `100s` (the first
minute of record 100 of the MIT-BIH Arrhythmia Database), included with
WFDB-x in the `tests/data` directory of a copy of the repository:

```sh
export WFDBX_INPUT_DIR=tests/data   # run from the root of the repository
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

The tools use the environment variables of the table above, also for the
files that they read or create themselves: the `-i` file of `wrsamp`,
`edf2mit`, `wav2mit`, `a2m` and `ad2m`, the input files of `ahaecg2mit` and
the `-S` script of `xform` are read from the input directory, and the WAV
file of `mit2wav`, the EDF file of `mit2edf`, the master header of `snip -m`
and the `.des`, `.ecg`, `.key` and `.txt` files of `parsescp` are created in
the output directory, as the records they read and write are. Such a file
cannot be read from a URL. `wfdbx_input_path(name)` and
`wfdbx_output_path(name)` return the path where a program of its own should
open such a file.

To read record 100 of the MIT-BIH Arrhythmia Database from PhysioNet:

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
writes a new record, `rec`, from the columns of a text file `samples.txt`.

## The WFDB library functions

`<wfdbx/wfdb.hpp>` declares every function of the WFDB library under its C
name, with the same arguments and return values, so programs and
documentation written for the C library carry over directly. The *WFDB
Programmer's Guide* applies, and the header summarizes each function. This
program reads the samples and the annotations of the sample record `100s`
(the first minute of record 100 of the MIT-BIH Arrhythmia Database), from
the `tests/data` directory of a copy of the repository:

```cpp
#include <cstdio>
#include <wfdbx/wfdb.hpp>
using namespace wfdbx;

int main() {
    wfdbx_set_input_dir("tests/data");

    WFDB_Siginfo si[2];
    if (isigopen("100s", si, 2) == 2) {        // open 2 signals; si receives their specifications
        WFDB_Sample v[2];
        while (getvec(v) > 0) {                // v receives one sample per signal
            // ...
        }
    }

    WFDB_Anninfo ai{"atr", WFDB_READ};
    WFDB_Annotation a;
    if (annopen("100s", &ai, 1) == 0)
        while (getann(0, &a) == 0)
            std::printf("%s %s\n", mstimstr(a.time).c_str(), annstr(a.anntyp)->c_str());
    wfdbquit();
}
```

Differences from C that come from the language:

* Everything is in namespace `wfdbx`. String arguments are `const char *`.
* Strings returned by the library are `std::string`, or
  `std::optional<std::string>` where C may return `NULL`. They stay valid
  after later calls.
* The string fields of `WFDB_Siginfo` and `WFDB_Calinfo` are
  `std::optional<std::string>`, since C distinguishes `NULL` from `""`.
* An annotation's `aux` is `std::nullopt`, or a `std::string` whose first
  byte is the length of the text that follows, as in C.
* `WFDB_Time` is 64 bits.
* `getvecs(buffer, n)` reads up to `n` frames at once, with the same result
  as `n` calls of `getvec`.
* Arrays are allocated by the caller, as in C. Errors are reported by return
  values, not by exceptions. `wfdberror()` returns the last message, and
  `wfdbquiet()` stops the messages from being printed.
* The library keeps the open record and annotators between calls, as in C,
  and is not thread-safe. `wfdbquit()` closes them; the directory and
  network settings are kept, and so are the time resolution of output
  annotators (`getafreq()`), which opening an EDF record sets to its
  sampling frequency when none is set, and the getvec mode (`getgvmode()`),
  to which it adds `WFDB_HIGHRES`, as in C. The high-level functions
  (`read_record`, `read_header`, `read_annotations`, `write_record`,
  `write_record_physical`, `write_annotations`, `check_record`) leave both
  as they were.
* `wfdbx_write_errors()` returns the number of output files that the library
  could not write, flush or close (found when it closes them), and
  `wfdbx_note_write_error()` counts one more, for a file that a program
  writes itself. The tools exit with status 1 after a write error, or when
  the standard output cannot be written ("PROGRAM: write error on standard
  output"); with `--legacy`, they keep the original exit status.

The annotation codes (`NORMAL`, `PVC`, ...) are in `<wfdbx/ecgcodes.hpp>`,
and the macros of `<wfdb/ecgmap.h>` (`isqrs`, `map1`, `map2`, ...) are
functions in `<wfdbx/ecgmap.hpp>`.

## Legacy mode

Legacy mode reproduces the original WFDB package exactly, including its
assumed signal parameters and its search for files. Use it only to reproduce
old results:

* tools: `--legacy` as the first argument, as in `rdsamp --legacy -r 100s`,
  run in the directory of the sample record `100s` (`tests/data` in a copy
  of the repository). Legacy mode finds files through the WFDB path, which
  begins with the current directory, and does not use the input directory
  (the files that a tool reads itself are opened as named, relative to the
  current directory); the output directory, if set, is a prefix of every
  output name, those of the files that a tool creates itself included;
* high-level functions: the `legacy` field of `ReadOptions` and
  `WriteOptions`, and the `legacy` argument of `read_header` and
  `read_annotations`;
* the whole library: `wfdbx_set_legacy(1)`.

[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md#legacy-mode)
describes what changes in legacy mode.

## Notes

* **FLAC.** Formats 508, 516 and 524 (FLAC-compressed signals) are read and
  written without any external library. The C library reads files written
  by WFDB-x with identical sample values, although the compressed bytes
  differ from those of libFLAC.
* **Speed.** `read_record` reads signal files in large blocks, and is the
  fastest way to read a record. Code that processes a record as a stream
  should read it with `getvecs(buffer, n)`, which reads many frames at once,
  rather than with one `getvec` call per frame.
  [BENCHMARKS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/BENCHMARKS.md)
  compares the seven languages and wfdb-python.

## Testing

From the root of the repository, after building:

```sh
ctest --test-dir cpp/build                                  # unit tests
python3 tests/conformance/harness.py check --impl cpp -j8   # conformance suite
```

The unit tests cover the WFDB library functions, the high-level functions
(including the shared header metadata cases of `tests/metadata`) and the
FLAC codec. The tests of `check_record` write the corpus of
`python/tests/check_corpus.py` with `python3` (or the program named by
`WFDBX_PYTHON`) and the Python package of `python/src`, and compare the
reports with its `expected.txt`; without Python they are skipped.
`cpp/build/wfdbx_check_corpus DIR` prints the reports for a corpus in DIR.
Developer notes are in [DEVELOPING.md](DEVELOPING.md). The conformance suite
([`docs/conformance.md`](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/conformance.md))
runs every tool and compares its results, byte for byte, with those of the
original C programs. Add `--legacy` to run it in legacy mode.

## Authors and license

WFDB-x implements version 10.7.0 of the WFDB Software Package.

The WFDB library and tools were written by George B. Moody, with revisions by
Benjamin Moody and contributions from many others; `parsescp` was written by
George B. Moody and Edna S. Moody. The header of each source file names the
authors of the C code it implements, and
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md)
gives the details. The C++ implementation was developed by Reza Sameni
(2026), through AI-assisted development, cross-language
verification and unit testing.

WFDB-x is an independent reimplementation. Its C++ code is a
translation of the C code of the WFDB Software Package into C++,
written for WFDB-x; it is not code by the original WFDB developers. It
follows the original's logic and behavior, with the changes described
in [DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md).
The authors of the original C code are credited in each file and in
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md).

WFDB-x is distributed under the GNU General Public License, version 3 or
(at your option) any later version. See
[LICENSE](https://github.com/alphanumericslab/wfdb-x/blob/main/LICENSE).
