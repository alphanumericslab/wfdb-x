# WFDB-x for Kotlin

> **WFDB-x** is a reimplementation of the WFDB Software Package (the library
> and its command-line tools) in seven languages: Python, C++,
> MATLAB/Octave, Rust, Julia, R and Kotlin, tested to give byte-for-byte
> identical results to the original C package and to each other. This is the
> Kotlin implementation.
> [Project page and the other languages](https://github.com/alphanumericslab/wfdb-x)
> · [WFDB-x at a glance (overview figure)](https://github.com/alphanumericslab/wfdb-x#wfdb-x-at-a-glance)
> · [Benchmarks](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/BENCHMARKS.md)

`wfdbx` reads and writes physiological signal records in the WFDB format used
by [PhysioNet](https://physionet.org). It is a complete Kotlin implementation
of the WFDB Software Package: the library and all of its command-line tools. It reads and writes the same files as the original C library, and its
tools print the same output.

The Kotlin implementation exists for mobile application developers and JVM
developers. With Kotlin Multiplatform, the same code runs on Android, on iOS
and on every JVM, so an app that records or displays physiological signals
can read and write WFDB records on the device with the WFDB engine that the
other implementations of WFDB-x use, with identical behavior, natively in
its own language: no native libraries to build for each platform, no JNI,
and no other runtime (such as Python) to embed. Server and desktop programs
in Kotlin or Java get the same library from Maven coordinates.

The library is written in common Kotlin code (Kotlin 2.1). Its only
dependency is the Kotlin standard library. The JVM artifact is compiled for
Java 11, so it runs on every current JVM and on Android (API level 26 or
later); the iOS targets (`iosArm64`, `iosSimulatorArm64`, `iosX64`) are
declared in the same project (see [Notes](#notes)).

## Three ways to use WFDB-x

All three are written in Kotlin; none of them calls the C library.

1. **The high-level functions (recommended).** `readRecord`, `readHeader`,
   `readAnnotations`, `writeRecord`, `writeAnnotations` and `checkRecord`
   read and write whole records and annotation files in one call, with
   named arguments: the samples are an `IntArray` (and a `DoubleArray` in
   physical units), frame by frame, and errors throw a `WfdbException`.
   They read signal files in large blocks, so they are the fastest way to
   read a record. They are an addition of WFDB-x: the C package has no
   equivalent. Use them for new code, apps and analysis.
2. **The WFDB library functions** under their C names (`isigopen`,
   `getvec`, `getann`, `putann`, ...), with the C behavior: frame by
   frame and annotation by annotation, with errors reported by return
   values. Use them to port a program written against the C library, or for
   the exact C semantics.
3. **The command-line tools** (`rdsamp`, `rdann`, `wrsamp`, `xform`, and
   29 others), with the options, output and exit status of the C tools, run
   on the JVM through the `bin/wfdbx` launcher (`kotlin/bin/wfdbx rdsamp -r
   100s`). Use them in shell scripts and pipelines, or to reproduce work
   done with the original tools.

The high-level functions return exactly the samples and annotations that
the library functions (and the C library) give.

## Installation

The library is built from a copy of the repository and installed in the
local Maven repository (below); its Gradle coordinates are
`io.github.alphanumericslab:wfdbx:1.1.0`. In a Gradle project (an Android
app, a JVM program, or the common source set of a Kotlin Multiplatform
project) that lists `mavenLocal()` among its repositories, add it to the
dependencies:

```kotlin
dependencies {
    implementation("io.github.alphanumericslab:wfdbx:1.1.0")
}
```

To build it from a copy of the repository and install it in the local Maven
repository (`~/.m2`), run, in the `kotlin` directory:

```sh
./gradlew publishToMavenLocal
```

and add `mavenLocal()` to the repositories of the project. The build uses
the Gradle wrapper of the repository (Gradle 8.14, which downloads itself),
and needs a JDK 11 or later.

The build downloads the Kotlin Gradle plugin and its dependencies from Maven
Central. Where Maven Central cannot be reached (or is rate-limited), the
Gradle property `mavenMirror` names another Maven repository, for plugins and
dependencies alike: give it on the command line, or set it once in
`~/.gradle/gradle.properties`:

```sh
./gradlew -PmavenMirror=https://maven-central.storage-download.googleapis.com/maven2/ publishToMavenLocal
# or, in ~/.gradle/gradle.properties:
#   mavenMirror=https://maven-central.storage-download.googleapis.com/maven2/
```

The command-line tools need the runnable jar of the tools,
`build/libs/wfdbx-all.jar`:

```sh
./gradlew fatJar
bin/wfdbx --list                   # the tools
```

## Quick start

The repository includes a sample record, `100s`, in `tests/data`: the first
minute of record 100 of the
[MIT-BIH Arrhythmia Database](https://physionet.org/content/mitdb/), with two
ECG signals at 360 Hz and its beat annotations. This program reads it and
writes a copy of its first 10 seconds. Run it from the root of the
repository, or change the directory in its first line.

```kotlin
import wfdbx.*

fun main() {
    // Read the sample record from the repository's tests/data directory.
    wfdbxSetInputDir("tests/data")

    val rec = readRecord("100s", physical = true)          // samples in ADC and physical units
    println("${rec.fs} ${rec.names} ${rec.nsamples}")      // 360.0 [MLII, V5] 21600

    val hdr = readHeader("100s")                            // the header only, no samples
    println("${hdr.nsig} ${hdr.nsamples}")                 // 2 21600

    val ann = readAnnotations("100s", "atr")                // beat annotations
    println("${ann.size} ${ann.symbols.take(3)} ${ann.samples.take(3)}")  // 75 [+, N, N] [18, 77, 370]

    // Write the first 10 seconds as a new record in the current directory.
    val x = readRecord("100s", to = TimeSpec("0:10"))       // ADC units
    writeRecord("copy", x.samples, x.nsig, x.fs, fmt = 16, gains = x.gains.toDoubleArray(),
                baselines = x.baselines.toIntArray(), adcres = intArrayOf(11), units = listOf("mV"),
                names = x.names)
}
```

## Reading and writing records

Each high-level function is a top-level function, which uses a default
library state (one per thread), and an extension function of `Wfdb`, the
class that holds the library state: `w.readRecord(...)` uses the state `w`.
The options are named arguments with default values.

The examples of this section read the sample record `100s` (the first
minute of record 100 of the MIT-BIH Arrhythmia Database, in `tests/data` of
a copy of the repository), after `wfdbxSetInputDir("tests/data")`, as in the
quick start; `rand` is a record that the examples write themselves.

### Reading signals: `readRecord`

```kotlin
val rec = readRecord("100s", channels = listOf("MLII"), from = TimeSpec("0:10"),
                     to = TimeSpec("0:20"), physical = true)
rec.nsamples          // 3600: 10 s of lead MLII
rec.physical!![0]     // its first sample, in mV
```

| Argument | Meaning | Default |
|---|---|---|
| `record` | record name or path (see [Where files are read and written](#where-files-are-read-and-written)) | |
| `channels` | signals to read, by number (`"0"`) or name (`"MLII"`, as in `names`) | all signals |
| `from`, `to` | first sample, and the sample after the last one: a `TimeSpec` (see below; `from` is not negative) | the whole record |
| `physical` | also return the samples in physical units (`Record.physical`) | `false` |
| `highres` | read a multi-frequency record at its highest sampling frequency | `false` |
| `pad` | replace invalid samples by the previous valid one | `false` |
| `checksumWarning` | warn when the data do not match the header's checksums | `true` |
| `onWarning` | receives the warning, instead of the standard error | `null` |
| `inputDir`, `network` | input directory and network access for this call only | the current settings |
| `legacy` | behave as the original package (see [Legacy mode](#legacy-mode)) | `false` |

A `TimeSpec` is a sample number, `TimeSpec(3600)`, or a WFDB time string,
`TimeSpec("0:10")` (10 seconds), `TimeSpec("1:02:03.5")`, `TimeSpec("s3600")`
(sample 3600) or `TimeSpec("e")` (the end of the record). A sample number
is a whole number by its type; `null` (the default `to`) reads to the end.
On any error once the record is open, its input signals are closed, and
the getvec mode and the settings changed for the call are restored.

The result is a `Record`. The samples are in one `IntArray`, frame by frame,
as the library returns them: `samples[i * nsig + s]` is sample `i` of signal
`s` (`rec.at(i, s)`), so that a record of millions of samples is one array,
without a copy per signal. `rec.signal(s)` returns the samples of one signal
(`IntArray`), and `rec.physicalSignal(s)` the same in physical units
(`DoubleArray`).

| Field | Contents |
|---|---|
| `samples` | `IntArray` of ADC units, frame by frame: `nsig` values per frame |
| `physical` | with `physical = true`, a `DoubleArray` of the same samples in physical units, `(adc - baseline) / gain`; otherwise `null` |
| `nsig`, `nsamples` | the number of signals and of samples per signal |
| `fs` | sampling frequency in Hz (0 if the header gives none) |
| `names`, `units`, `gains`, `baselines` | description (without the white space that a header may put at either end of it), physical units, gain (ADC units per physical unit; 0 means uncalibrated) and baseline of each signal |
| `siginfo` | the full signal specifications (`Siginfo` objects) |
| `signalNumbers` | the number, in the record, of each signal returned |
| `sampfrom` | the number of the first sample returned |
| `baseTime` | start time and date as text, to the second, such as `"[14:00:03 21/06/2024]"` |
| `baseTimeMs` | start time in milliseconds after midnight, such as `50403500` for 14:00:03.500 |
| `baseDate` | start date as a `BaseDate(year, month, day)` |
| `comments` | the info strings of the header |
| `checksumOk` | `false` if the data do not match the header's checksums |

`baseTime`, `baseTimeMs` and `baseDate` are `null` when the header does not
give them. Invalid samples are `WFDB_INVALID_SAMPLE`, or NaN in physical
units.

### Reading a header: `readHeader`

`readHeader(record)` reads the header of a record without opening its
signal files. It returns a `Header` with these fields: `name`, `fs`,
`counterFreq`, `baseCounter`, `nsamples` (0 if the header does not give the
length), `nsig`, `siginfo`, `baseTime`, `baseTimeMs`, `baseDate` and
`comments`. They have the same meaning as in `Record`.

```kotlin
val hdr = readHeader("100s")
for (s in hdr.siginfo) {
    println("${s.desc?.latin1()} ${s.fmt} ${s.gain} ${s.units?.latin1()}")   // MLII 212 200.0 null
}
```

(The fields of `Siginfo` are byte strings, as in C; `latin1()`, from
`wfdbx.cstd`, converts them.)

### Reading annotations: `readAnnotations`

```kotlin
val ann = readAnnotations("100s", "atr", from = TimeSpec("0:10"), to = TimeSpec("0:30"))
val beats = (0 until ann.size).filter { isqrs(ann.codes[it]) != 0 }.map { ann.samples[it] }
```

`annotator` is the file suffix (`"atr"` reads `100s.atr`). The optional `fs`
gives the sampling frequency when the record has no header, or its header
gives none. The result is an `Annotations` object, in file order:

| Field | Contents |
|---|---|
| `samples` | annotation times, in samples (`LongArray`) |
| `codes`, `symbols` | annotation codes (`NORMAL`, `PVC`, ...) and their mnemonics (`"N"`, `"V"`, ...) |
| `subtypes`, `chans`, `nums` | subtype, channel and annotator number of each annotation (`IntArray`) |
| `aux` | auxiliary text of each annotation, or `null` |
| `fs` | the frequency in which `samples` are counted (0 if unknown) |
| `size` | the number of annotations |

### Writing a record: `writeRecord`

```kotlin
val rnd = java.util.Random(1)
val x = DoubleArray(3600 * 2) { rnd.nextGaussian() }   // 3600 frames of 2 signals, in mV
writeRecord("rand", x, nsig = 2, fs = 360.0, fmt = 16, gains = doubleArrayOf(1000.0),
            adcres = intArrayOf(16), units = listOf("mV"), names = listOf("A", "B"))
```

This writes the header `rand.hea` and the signal file `rand.dat`. The
sampling frequency (finite and > 0), the gain (finite) and ADC resolution
of each signal, and the units of each calibrated signal are required; there
are no defaults. The record name must not be empty, there must be at least
one signal, and a `baseTime` that cannot be parsed is an error. The
samples are given frame by frame, as `Record.samples`: an `IntArray` of ADC
units, or a `DoubleArray` of physical units, converted to ADC units as
`round(x * gain) + baseline` (NaN becomes an invalid sample; an infinite
value, or one beyond the range of 32-bit integers in ADC units, is an error).
A gain of 0 marks a signal as uncalibrated, which is only allowed for
samples in ADC units; negative gains are allowed. Per-signal arguments take one value for all signals,
or one value per signal; anything else is an error. The arguments are
checked before any file is created, and the output signals are closed
whatever happens.

| Argument | Meaning |
|---|---|
| `samples`, `nsig` | the samples, frame by frame, and the number of signals |
| `fs` | sampling frequency in Hz |
| `fmt` | storage format, such as 16, 212, 24 or 516 (FLAC); default 16 |
| `gains`, `adcres`, `units` | gain, ADC resolution in bits, and physical units |
| `baselines`, `adczeros`, `names` | optional signal specifications |
| `baseTime`, `comments` | start time (`"hh:mm:ss dd/mm/yyyy"`) and info strings |
| `sampsPerFrame` | samples per frame of each signal, for a multi-frequency record |
| `dir` | directory in which to create the files |
| `legacy` | behave as the original package (see [Legacy mode](#legacy-mode)) |

### Writing annotations: `writeAnnotations`

```kotlin
writeAnnotations("rand", "qrs", longArrayOf(100, 460, 820), symbols = listOf("N", "N", "V"))
```

Give the annotation types as `symbols` or as `codes`. Both may be given (as
`readAnnotations` returns them) if they agree: the code of each symbol must
be the code at its position (an empty symbol agrees with any code), or
"writeAnnotations: symbols and codes disagree at annotation K" (K counting
from 0) is thrown. `subtypes`, `chans`, `nums` and `aux` are optional.
Each of these arguments, when given, has one value per annotation; anything
else is an error. `fs`, if given, must be finite and > 0. These checks are
made before the file is created. As in C, the subtype, channel and annotator number are stored
in one byte each (other values wrap around). An `Annotations` object can also be written
as it is: `writeAnnotations("rand", "atr2", ann)`. If the annotations are
not in time order, the file is sorted when it is written. `sort = false`
keeps the given order (without the library's advice to run `sortann`) and
`sort = true` always sorts, for that call only. Without `sort`, the
`WFDBANNSORT` environment variable decides (sorting is on unless it is `0`).

### Errors and warnings

* Every error of a high-level function throws a `WfdbException`, whose
  message says what failed, such as "can't read record 100s".
* A signal file that is shorter than its header says throws "can't read
  signal data of record REC (getvec status -3)".
* An annotation file that ends before its end-of-file marker throws "can't
  read annotation file ANN of record REC (getann status -3)".
* Invalid arguments, and a value the operation needs but the record does not
  give, also throw a `WfdbException`. For example, a time string such as
  `"0:10"` needs the sampling frequency ("sampling frequency of record REC is
  not specified"), and `physical = true` needs the gain of each signal
  ("signal 1 of record REC is uncalibrated").
* When the data do not match the checksums in the header, `readRecord`
  returns all the data and warns: "checksum error in record REC: the signal
  data do not match the checksums in its header". By default the warning is
  printed on the standard error, as `WFDB-x: ` followed by the message,
  unless `wfdbquiet()` was called; `onWarning = { msg -> ... }` receives it
  instead, and `checksumWarning = false` turns it off. `rec.checksumOk` is
  `false` either way. Checksums are only checked when a read reaches the end
  of the record.
* A tool, or a program that uses the WFDB library functions, never writes a
  signal file over one of the signal files it is reading. Opening such an
  output fails with "output file NAME is also an input file". `writeRecord`
  reads nothing, so it overwrites any existing files of the same name.
* A file that cannot be written completely, for example when the disk is
  full, throws "write error on record REC" (`writeRecord`) or "write error
  on annotator ANN for record REC" (`writeAnnotations`), also in legacy
  mode.
* `writeRecord` checks `sampsPerFrame` before anything else: each value
  must be at least 1 ("writeRecord: sampsPerFrame must hold integers >=
  1"), and the number of samples must be a multiple of the frame size.

The high-level functions call `wfdbquit()`, which closes anything opened
with the WFDB library functions on the same `Wfdb` state.

### Checking a record: `checkRecord`

```kotlin
val report = checkRecord("100s", listOf("atr"))
println(report)
```

`checkRecord(record, annotators)` checks the header of a record, its signal
specifications, every sample of its signal files, and the annotation files
named. It reports each problem it finds. It never throws an exception for a
problem in the record. It checks for problems similar to those found by
Benjamin Moody's [wfdbcheck](https://github.com/bemoody/wfdbcheck).

The result is a `CheckReport`. `report.ok` is `true` if there is no error.
`report.issues` lists the problems. Each `Issue` has a `severity`
(`Severity.ERROR`, `WARNING` or `INFO`), a `code` (such as `"checksum"`), a
`where` (`""` for the record, `"signal 1"`, `"segment s2"`,
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

### The names in the other languages

The high-level functions have the same behavior in every language of
WFDB-x, under the naming conventions of each:

| Kotlin | Python, C++, Rust, Julia, R, MATLAB/Octave |
|---|---|
| `readRecord` | `read_record` |
| `readHeader` | `read_header` |
| `readAnnotations` | `read_annotations` |
| `writeRecord` (`IntArray`) | `write_record` |
| `writeRecord` (`DoubleArray`) | `write_record(..., physical=True)` (Python, R, MATLAB), `write_record_physical` (C++, Rust, Julia) |
| `writeAnnotations` | `write_annotations` |
| `checkRecord` | `check_record` |
| `wfdbxSetInputDir`, `wfdbxGetInputDir` | `wfdbx_set_input_dir`, `wfdbx_get_input_dir` |
| `wfdbxSetOutputDir`, `wfdbxGetOutputDir` | `wfdbx_set_output_dir`, `wfdbx_get_output_dir` |
| `wfdbxSetNetwork`, `wfdbxGetNetwork` | `wfdbx_set_network`, `wfdbx_get_network` |
| `wfdbxSetLegacy`, `wfdbxGetLegacy` | `wfdbx_set_legacy`, `wfdbx_get_legacy` |
| `from`, `to` (`TimeSpec`) | `sampfrom`, `sampto` (Python, R, MATLAB); `from`, `to` (C++, Rust, Julia) |
| `inputDir`, `checksumWarning`, `sampsPerFrame`, `baseTime` | `input_dir`, `checksum_warning`, `samps_per_frame`, `base_time` |
| `Record.checksumOk`, `baseTimeMs`, `baseDate` | `checksum_ok`, `base_time_ms`, `base_date` |
| `WfdbException` | `IOError`/`ValueError` (Python), `wfdbx::Error` (C++), `wfdbx::record::Error` (Rust), `WfdbError` (Julia), an R error, a MATLAB error |

The WFDB library functions (`isigopen`, `getvec`, ...) have their C names in
every language, Kotlin included.

## Where files are read and written

WFDB-x reads and writes files exactly where they are named, and nowhere else:

| The name is | It is read from | It is written to |
|---|---|---|
| a full path: `/data/mitdb/100` | that path | that path |
| a home path: `~/data/100` | the user's home directory | the user's home directory |
| a URL: `https://.../100` | that URL, if network access is on | (URLs cannot be written) |
| anything else: `100`, `mitdb/100`, `../data/100` | the **input directory** | the **output directory** |

In this table, `/data/mitdb` stands for a local copy of the MIT-BIH
Arrhythmia Database, and `100` for its record 100.

The input and output directories are both the current directory unless they
are set:

| Setting | Function | Option of the high-level functions | Environment variable |
|---|---|---|---|
| input directory: a local directory, `~/...` or a URL | `wfdbxSetInputDir(d)` | `inputDir =` | `WFDBX_INPUT_DIR` |
| output directory | `wfdbxSetOutputDir(d)` | `dir =` | `WFDBX_OUTPUT_DIR` |
| network access (off by default) | `wfdbxSetNetwork(true)` | `network = true` | `WFDBX_NETWORK=1` |

A function call overrides the environment variable, and an option applies to
that one call. `wfdbxGetInputDir()`, `wfdbxGetOutputDir()` and
`wfdbxGetNetwork()` return the current settings; each `set` function returns
the previous setting, and passing `null` to `wfdbxSetInputDir` or
`wfdbxSetOutputDir` restores the default.

On Android and iOS, the current directory is not a useful place for files:
set the input and output directories to a directory of the app, such as
`context.filesDir.path` on Android.

In this example, `/data/mitdb` stands for a local copy of the MIT-BIH
Arrhythmia Database, and `100` is its record 100:

```kotlin
wfdbxSetInputDir("/data/mitdb")
val rec = readRecord("100")             // reads /data/mitdb/100.hea and 100.dat
writeAnnotations("100", "qrs", longArrayOf(100, 460), symbols = listOf("N", "N"),
                 dir = "out")            // writes out/100.qrs
```

The signal files that a header names are read from the header's directory.

### Record names

A record name is made of letters, digits, `_`, `-` and `~`. `/` separates
directories, and the names of directories may contain any characters, such
as dots: `my.data/rec` is a valid record name, `rec.1` is not. A name whose
last part contains a dot is the name of a file: `100s.hea` is read as the
header of record `100s`, and `100s.edf` as an EDF file.

Records can be written under any such name: `writeRecord("my.data/rec",
...)` creates `my.data/rec.hea` and `my.data/rec.dat`. The header names the
record and its signal file without the directory (`rec`, `rec.dat`), so the
record can be read under any path that leads to it. Annotator names may
contain letters, digits, `_`, `-` and `~`. Record, annotator and directory
names are converted to bytes with the platform's file name encoding; text in
the files (descriptions, units, info strings, aux strings) is read and
written as ISO-8859-1, one character per byte, so that every byte
round-trips.

### Reading from PhysioNet

Set the input directory to the URL of the database and turn network access
on. The URL of a database is `https://physionet.org/files/<database>/<version>/`.
This example reads record 100 of the MIT-BIH Arrhythmia Database from
PhysioNet:

```kotlin
val rec = readRecord("100", inputDir = "https://physionet.org/files/mitdb/1.0.0/", network = true)
```

Remote files are read once and kept for the rest of the session. A download
gives up when it cannot connect, or receives nothing, for 30 seconds. On the
JVM and Android, files are downloaded with `java.net.HttpURLConnection` (an
Android app needs the `INTERNET` permission); on iOS, with `NSURLSession`.

## Signal parameters

WFDB-x never assumes a sampling frequency, gain, ADC resolution or units
that a record does not give. Where one is needed, it must be given: in
`writeRecord`, as the `fs` argument of `readAnnotations`, or as an option of
the tools (see below). A record whose header gives no frequency has `fs =
0`. See
[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md)
for the reasons.

## Command-line tools

The tools run on the JVM, through the launcher `bin/wfdbx` (a POSIX shell
script that runs `java -cp build/libs/wfdbx-all.jar wfdbx.cli.MainKt TOOL
...`; build the jar first with `./gradlew fatJar`, which also makes
`build/libs/wfdbx-all.jsa`, a class data sharing archive with which the JVM
starts faster). A link to `bin/wfdbx` named after a tool runs that tool.
These examples, run in the `kotlin` directory, read the sample record:

```sh
export WFDBX_INPUT_DIR=../tests/data
bin/wfdbx rdsamp -r 100s -t 10 -p      # print the first 10 seconds, in physical units
bin/wfdbx rdann -r 100s -a atr         # print the annotations
bin/wfdbx --list                       # list the tools
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
bin/wfdbx rdsamp -r 100 -t 0:05
```

Tools that write signal parameters require them as options:

| Tool | Required options |
|---|---|
| `wrsamp` (with `-o`) | `-F` frequency, `-G` gain, `-R` ADC resolution, and `-U` units for calibrated signals |
| `wav2mit` | `-G` gain, and `-U` units unless the gain is 0 |
| `ad2m`, `ahaecg2mit` | `-F`, `-G`, `-R`, and `-U` unless the gain is 0 |
| `a2m`, `rdann`, `ann2rr`, `sortann`, `m2a` | `-F` frequency, when the record's header does not give one |

For example, `bin/wfdbx wrsamp -F 250 -G 200 -R 16 -U mV -i samples.txt -o rec`
writes a new record `rec` from the text file `samples.txt`.

The tools are also functions of the library (`wfdbx.apps`: `w.rdsampMain(argv)`,
...), but they may end the process (with `exit`, as C programs do); use the
high-level functions or the library functions in an app.

## The WFDB library functions

Every function of the WFDB library is available under its C name, with the
same arguments and return values, so programs and documentation written for
the C library carry over directly. Where a C function fills an array, the
Kotlin function fills an array passed by the caller:

```kotlin
import wfdbx.*
import wfdbx.cstd.latin1

val w = Wfdb()                              // the library state
w.wfdbx_set_input_dir("tests/data")
val si = Array(2) { Siginfo() }
val nsig = w.isigopen("100s", si, 2)        // open 2 signals; si receives their specifications
val v = IntArray(nsig)
while (w.getvec(v) > 0) {                   // v receives one sample per signal
    // ...
}

val a = Annotation()
w.annopen("100s", arrayOf(Anninfo("atr", WFDB_READ)), 1)
while (w.getann(0, a) == 0) {
    println("${a.time} ${w.annstr(a.anntyp).latin1()}")
}
w.wfdbquit()
```

Differences from C that come from the language:

* The library's state (the open record and annotators, the settings) is
  held by a `Wfdb` object, and each function is an extension function of it
  (`w.isigopen(...)`). Every function is also a top-level function with the
  same name and arguments, such as `isigopen(...)`, which uses a default
  `Wfdb`, one per thread. Separate `Wfdb` objects do not share any state,
  so several records can be open at once, in one thread or in several; a
  `Wfdb` object must be used by one thread at a time.
* Strings are bytes (`ByteArray`), as in C: WFDB files are not UTF-8. Most
  functions also take a `String` (one character per byte, ISO-8859-1);
  `"..".latin1()` and `bytes.latin1()` (in `wfdbx.cstd`) convert. C's
  `NULL` is `null`.
* C's `int` and `WFDB_Sample` are `Int`, `long` and `WFDB_Time` are `Long`,
  and `double` is `Double`. The `char` fields of the structures are `Int`
  properties that keep C's range (`anntyp`, `subtyp`, `num`: -128 to 127;
  `chan`: 0 to 255).
* The structures (`Siginfo`, `Calinfo`, `Anninfo`, `Annotation`,
  `Seginfo`) have the C field names and C's zero values. An annotation's
  `aux` is `null`, or bytes whose first byte is the length of the text that
  follows, as in C.
* `getvecs(out, n)` reads up to `n` frames at once into `out`. It returns
  the number of frames it read, or the `getvec` status if it read none.
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
* C's `printf` and `scanf` families are in `wfdbx.cstd` (`cformat`,
  `sscanf`, ...), formatting numbers exactly as the GNU C library does.

The annotation codes (`NORMAL`, `PVC`, ...) and the functions of
`<wfdb/ecgmap.h>` (`isqrs`, `map1`, `map2`, ...) are also provided. The
functions are documented in KDoc comments.

## Legacy mode

Legacy mode reproduces the original WFDB package exactly, including its
assumed signal parameters and its search for files. Use it only to reproduce
old results:

* tools: `--legacy` as the first argument, as in
  `../../kotlin/bin/wfdbx rdsamp --legacy -r 100s`, run in the directory of
  the sample record `100s` (`tests/data` in a copy of the repository).
  Legacy mode finds files through the WFDB path, which begins with the
  current directory, and does not use the input directory;
* high-level functions: `legacy = true`;
* the whole library: `wfdbxSetLegacy(true)`, or `w.wfdbxSetLegacy(true)`
  for one `Wfdb` object.

[DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md#legacy-mode)
describes what changes in legacy mode.

## Notes

* **iOS.** The iOS targets (`iosArm64`, `iosSimulatorArm64`, `iosX64`) are
  declared, with a small platform layer for iOS (POSIX files and
  `NSURLSession`). They can only be built on macOS. The tests of the
  repository build the JVM code, and check the common code, which is all of
  the library's logic, with `./gradlew compileCommonMainKotlinMetadata`; they
  do not compile the native code (iOS, and Linux through
  `-Pwfdbx.linux=true`).
  Legacy-mode sorting of annotation files runs the `sortann` program, which
  an iOS app cannot do (the in-process sort of normal mode works
  everywhere).
* **Android.** Use the JVM artifact (API level 26 or later). The library
  uses `java.nio.file`; give it paths in the app's storage.
* **FLAC.** Formats 508, 516 and 524 (FLAC-compressed signals) are read and
  written without any external library. The C library reads files written
  by WFDB-x with identical sample values, although the compressed bytes
  differ from those of libFLAC.
* **Threads.** The top-level functions use one `Wfdb` per thread. Use
  separate `Wfdb` objects to work on several records in parallel.
* **Speed.** `readRecord` and `writeRecord` work on whole blocks of
  samples, and are the fastest way to read and write a record. For code
  that processes a record as a stream, `getvecs` reads many frames per
  call, and is faster than a `getvec` loop. On the JVM, the first call in a
  process is slower than the next ones, which run code compiled by the JIT
  compiler.
  [BENCHMARKS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/BENCHMARKS.md)
  compares the seven languages and wfdb-python.

## Testing

From the `kotlin` directory of the repository:

```sh
./gradlew jvmTest                           # the unit tests, on the JVM
./gradlew compileCommonMainKotlinMetadata   # the common code uses only common APIs
```

The unit tests check the library functions with expected values printed by
the C library, the high-level functions, the bulk paths against the
per-frame paths, and `checkRecord` against the reports of the Python
implementation on the corpus made by `python/tests/check_corpus.py` (this
test is skipped, with a message, when `python3` with NumPy is not
available). Network access is tested against a local HTTP server. To run
the cross-language conformance suite, which compares the tools with the
original C tools, build the jar and run the harness from the root of the
repository:

```sh
(cd kotlin && ./gradlew fatJar)
python3 tests/conformance/harness.py check --impl kotlin -j8
python3 tests/conformance/harness.py check --impl kotlin -j8 --legacy   # legacy mode
```

[DEVELOPING.md](DEVELOPING.md) describes how the implementation is
organized, for developers of WFDB-x.

## Authors and license

WFDB-x implements version 10.7.0 of the WFDB Software Package.

The WFDB library and tools were written by George B. Moody, with revisions by
Benjamin Moody and contributions from many others; `parsescp` was written by
George B. Moody and Edna S. Moody. Each file names the authors of the C
code it implements, and
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md)
gives the details. The Kotlin implementation was developed by Reza Sameni
(2026), through AI-assisted development, cross-language
verification and unit testing.

WFDB-x is an independent reimplementation. Its Kotlin code is a
translation of the C code of the WFDB Software Package into Kotlin,
written for WFDB-x; it is not code by the original WFDB developers. It
follows the original's logic and behavior, with the changes described
in [DIVERGENCES.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/DIVERGENCES.md).
The authors of the original C code are credited in each file and in
[AUTHORS.md](https://github.com/alphanumericslab/wfdb-x/blob/main/docs/AUTHORS.md).

WFDB-x is distributed under the GNU General Public License, version 3 or
(at your option) any later version. See
[LICENSE](https://github.com/alphanumericslab/wfdb-x/blob/main/LICENSE).
