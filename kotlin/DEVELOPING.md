# WFDB-x for Kotlin: implementation notes

These notes describe how the Kotlin Multiplatform implementation is
organized, and the decisions that later work must follow. They complement
[`docs/porting-guide.md`](../docs/porting-guide.md) (the C semantics every
implementation must reproduce). The Rust implementation (`rust/`) is the
model: most Kotlin files are close ports of the Rust module of the same
name; `cpp/` settles doubts, and `python/src/wfdbx/` is the reference for
the high-level API.

## Requirements and build

* Gradle 8.14.3 (wrapper committed: `./gradlew`), Kotlin 2.1.21, Kotlin
  Multiplatform plugin. No dependencies besides the Kotlin standard library
  (and `kotlin-test` for the tests): files, the environment and processes
  go through a small platform layer of our own (`cstd/Platform.kt`).
* Targets: `jvm()` (bytecode for Java 11, so it runs on Android API 26+ and
  every current JVM), `iosArm64()`, `iosSimulatorArm64()`, `iosX64()`
  (declared; they can only be built on macOS), and `linuxX64()` when
  `-Pwfdbx.linux=true` is given (it needs the Kotlin/Native toolchain,
  downloaded from `download.jetbrains.com` on first use; it is blocked in
  the container where this port was written, so the native code has not
  been compiled yet: see "Native code" below).
* Repositories: Maven Central, or the repository named by the Gradle
  property `mavenMirror` (`-PmavenMirror=URL`, or `mavenMirror=URL` in
  `~/.gradle/gradle.properties`), for plugins and dependencies alike.
* Coordinates: `io.github.alphanumericslab:wfdbx:1.0.0`; Kotlin package
  `wfdbx` (`wfdbx.cstd` for the C standard library emulation; `wfdbx.apps`
  for the tools and `wfdbx.cli` for the launcher's `main`, phase 3).

```sh
cd kotlin
./gradlew jvmTest                       # unit tests on the JVM
./gradlew jvmTest -Pwfdbx.linux=true linuxX64Test   # also on Linux/Native, where the toolchain downloads
./gradlew compileCommonMainKotlinMetadata           # checks that common code uses only common APIs
```

The code must build without warnings.

## Layout

| Path | Contents |
|---|---|
| `src/commonMain/kotlin/wfdbx/Wfdb.kt` | the `Wfdb` class (all library state), the default instance (`wfdbDefault()`, `withDefault`) |
| `.../wfdbx/Types.kt` | constants and structures of `wfdb.h` (`Siginfo`, `Calinfo`, `Anninfo`, `Annotation`, `Seginfo`, `WFDB_*`, `DEFWFDB`, ...) |
| `.../wfdbx/WfdbFile.kt` | `WfdbFile`, C's `FILE *` / `WFDB_FILE` (buffered, C stdio semantics) |
| `.../wfdbx/Wfdbio.kt` | port of `lib/wfdbio.c`: input/output directories, network access, legacy WFDB path, `wfdb_open`, `wfdb_fopen`, errors, `freopen_stdin`, `run_sortann`, and the legacy switch (`wfdbx_set_legacy`, `wfdbx_get_legacy`, `wfdbx_legacy_args`) |
| `.../wfdbx/Signal.kt` | port of `lib/signal.c` (through `rust/src/signal.rs`): headers (including EDF), opening and closing signals, `getvec`/`getframe`/`getvecs` (bulk path), `putvec`, seeks, multi-segment and variable-layout records, skew, `setheader`/`newheader`/`setmsheader`, info strings, `sample` |
| `.../wfdbx/SignalTime.kt` | the time, date and amplitude conversions of `signal.c` (`strtim`, `timstr`, `mstimstr`, `datstr`, `strdat`, `setbasetime`, counter frequency, `adumuv`, ...), and the local time (TZif files, as in Rust) |
| `.../wfdbx/Flac.kt` | FLAC decoder and encoder (port of `rust/src/flac.rs`), MD5 |
| `.../wfdbx/Annot.kt` | port of `lib/annot.c`, the in-process sort (`AnnList`, used by the `sortann` tool too) |
| `.../wfdbx/Calib.kt` | port of `lib/calib.c` |
| `.../wfdbx/Wfdbinit.kt` | port of `lib/wfdbinit.c` |
| `.../wfdbx/Ecgcodes.kt` | `ecgcodes.h` codes and the `ecgmap.h` functions |
| `.../wfdbx/cstd/` | C standard library emulation (port of `rust/src/cstd*`): `Printf.kt` + `Float.kt` (glibc-exact printf), `Parse.kt` (strtol, strtod, sscanf, strtok, fgets lines), `Rand.kt` (glibc rand), `Stdio.kt` (buffered stdout, stderr, exit, environment), `ByteVec.kt` (byte buffer and byte-string helpers), `Platform.kt` (the platform layer: `expect` declarations) |
| `src/jvmMain/` | JVM platform layer (`cstd/PlatformJvm.kt`) and the thread-local default instance |
| `src/nativeMain/`, `src/linuxMain/`, `src/iosMain/` | native platform layer (POSIX; Linux: `curl` and `posix_spawnp`; iOS: `NSURLSession`) |
| `src/commonTest/` | unit tests (run on every target), with helpers in `TestSupport.kt` (`DataDir` copies `tests/data` to a scratch directory) |
| `src/jvmTest/`, `src/nativeTest/` | platform parts of the test helpers; JVM-only tests (network, against a local HTTP server) |
| `src/commonMain/kotlin/wfdbx/apps/` | the 33 tools, one file per tool (`Rdsamp.kt`, ...), and `Common.kt` (see "Tools") |
| `src/jvmMain/kotlin/wfdbx/cli/Main.kt` | `wfdbx.cli.MainKt`: the command-line driver (`TOOL ARGS...`, `--list`, `--version`) |
| `bin/wfdbx` | the launcher (POSIX shell): `java -cp build/libs/wfdbx-all.jar wfdbx.cli.MainKt TOOL ARGS...` |

| `src/commonMain/kotlin/wfdbx/Record.kt` | the high-level API (port of `python/src/wfdbx/highlevel.py`, through `rust/src/record.rs`): `readRecord`, `readHeader`, `readAnnotations`, `writeRecord`, `writeAnnotations`, `Record`, `Header`, `Annotations`, `TimeSpec`, `WfdbException`, `wfdbxSetInputDir`, ... |
| `src/commonMain/kotlin/wfdbx/Check.kt` | `checkRecord` (port of `python/src/wfdbx/check.py`, through `rust/src/check.rs`), `CheckReport`, `Issue`, `Severity` |
| `benchmarks/` | the benchmark programs (Kotlin `src/Bench.kt`, `cpp/bench.cpp`, `rust/`, `bench.py`) and `run.sh` (see [Performance](#performance)) |

## The library object and the C-style API

All the state of the C library is held by one class, **`Wfdb`**. Its fields
are the states of the C source files, each a class defined in the file that
ports it (as in Rust):

| field | class | defined in |
|---|---|---|
| `io` | `IoState` | `Wfdbio.kt` |
| `sig` | `SigState` | `Signal.kt` |
| `ann` | `AnnState` | `Annot.kt` |
| `cal` | `CalState` | `Calib.kt` |
| `maps` | `EcgMaps` | `Ecgcodes.kt` |
| `legacy` | `Boolean` | (`Wfdb.kt`; the legacy flag is used by every file, so it is not in `SigState` as in Rust) |

The state classes and their fields are `internal`; the files use each
other's state directly where the C code shares globals, and otherwise call
the library functions.

**Each C library function is an extension function of `Wfdb`** with the C
name and arguments, defined in the file that ports its C source
(`fun Wfdb.annopen(record: ByteArray?, aiarray: Array<Anninfo>, nann: Int): Int`),
and **also a top-level function with the same name and arguments** that
runs it on the default instance (`fun annopen(...) = wfdbDefault().annopen(...)`),
for line-by-line ports of C programs. The default instance is one per
thread (`ThreadLocal` on the JVM, `@ThreadLocal` on Native). A `Wfdb` is not
thread-safe: use each instance from one thread at a time; separate instances
share nothing but the process-wide structures guarded by `withGlobalLock`
(open output streams, fetched URLs).

Rules for library code (they matter, because a mistake compiles and calls
the wrong instance):

* Write library functions as `fun Wfdb.name(...)`. Inside them, an
  unqualified call `name(...)` resolves to the extension on `this` (Kotlin
  prefers a function with an implicit receiver to a top-level one; this was
  checked), so library functions call each other naturally.
* Private helpers that need the library state must also be `Wfdb`
  extensions. **Never call a top-level (default-instance) function from
  library code**, and never from a function without a `Wfdb` receiver: it
  would silently use the default instance. Helpers without a receiver (as
  `getannIa` in `Annot.kt`) return their error messages in a list that the
  caller reports with `wfdb_error` (the Rust `Msgs` pattern).
* Functions that are library-private in C (`wfdb_open`, `wfdb_checkname`,
  `wfdb_setirec`, ...) are public, as in Rust; hooks used only by other
  files (`wfdb_anclose`, `wfdb_oaflush`, `wfdb_sigclose`, `wfdb_osflush`,
  ...) are `internal`.

## Data representation

* **Integer types** follow the C reference platform: `WFDB_Sample` and C
  `int` are `Int`, `WFDB_Time`, `WFDB_Date` and `long` are `Long`,
  `WFDB_Frequency` and `double` are `Double`. Kotlin's `Int`/`Long`
  arithmetic wraps as C's does on x86. Conversions from `Double` to integers
  must use `d2i`/`d2l` (C's x86 casts: NaN and out-of-range give the
  minimum), not `toInt()`/`toLong()` (which saturate). Unsigned C
  arithmetic is written with `ULong`/`UInt` or with masks (`and 0xffff`),
  and `ushr` for unsigned shifts.
* **C `char` fields** of the structures are `Int` properties normalized by
  their setters to the C type's range (`Annotation.anntyp`, `subtyp` and
  `num`: signed char, -128..127; `chan`: unsigned char, 0..255), so that an
  assignment behaves as in C.
* **Strings are bytes.** WFDB files are not UTF-8: every string of the
  C-style API is a `ByteArray` (a C string ends at its first NUL: `cstr`),
  and C's `NULL` is `null`. Where natural, a function also has an overload
  taking `String` (characters are bytes, ISO-8859-1: `String.latin1()` and
  `ByteArray.latin1()` convert). Give the `String` overloads non-null
  parameters where a `null` argument would be ambiguous (`f(null)` must
  resolve to the `ByteArray?` version; write `null as ByteArray?` where both
  exist). `ByteArray` has identity equality: compare with `beq`,
  `contentEquals`, `startsWith(...)`, and copy what you store (C's static
  buffers are copied when returned).
* **Structures** (`Siginfo`, `Calinfo`, `Anninfo`, `Annotation`,
  `Seginfo`) are mutable classes with the C field names and C's zero values
  by default; `copy()` is C's structure assignment, `set(o)` copies into an
  existing structure (what a C function filling `*p` does). `equals`
  compares contents. `Annotation.aux` holds the C bytes including the
  leading length byte.
* Functions that fill an array supplied by the caller take an array:
  `getann(n, annot)` fills `annot`; `isigopen(record, siarray, nsig)`
  takes `Array<Siginfo>?` (null for C's `NULL`); `getvec(v: IntArray)`.

## C standard library emulation (`wfdbx.cstd`)

* `cformat(fmt, args...)` / `sprintf` (to `ByteArray`), `sprintfInto(ByteVec,
  ...)`, `printf`/`cprintf` (buffered standard output), `eprintf`/`ceprintf`
  (standard error), `WfdbFile.printf`. The format is a `String` (one byte
  per character) or a `ByteArray`. Arguments: `Int`, `Long`, `Short`,
  `Byte`, unsigned types, `Double`, `Float`, `Char`, `Boolean`, `ByteArray`,
  `ByteVec`, `String`, `null`. As in C, `%d` prints the low 32 bits of its
  argument and `%ld` all 64; `%e`, `%f`, `%g` are glibc-exact (checked
  against 30000 random cases and the Rust test values). `fixedFast(buf, x,
  width, prec)` is an exact fast path for `%W.Pf` (P <= 9) for tools that
  print many numbers.
* Parsing: `strtol(s, base, pos)` returns `LongEnd(value, end)` with
  absolute positions (`end == pos`: no conversion); `strtoul`, `strtod`
  (`DoubleEnd`), `strtof`, `atoi`, `atol`, `atof`; `sscanf(input, fmt,
  dests...)` with destinations `CInt`, `CLong`, `CShort`, `CDouble`,
  `CFloat`, `CBytes` (`%s`, `%[`, `%Nc`), `CChar` (`%c`) holding a `v`
  field (unreached destinations keep their value); `Strtok(s).next(delims)`
  (with `position()` and `rest()`); `fgetsLines(data, size)`.
* `GlibcRand`, `srand`, `rand`: glibc's generator (per thread).
* `Stdout`: the process's buffered standard output (flushed when 64 KB are
  buffered, after each write to a terminal, by `flushStdout()`, and by
  `exit`); a `WfdbFile` on `-` writes into it. `ewrite`/`eprintf`: the
  unbuffered standard error. `exit(status)` flushes every open output
  `WfdbFile` (they register themselves while open), then the standard
  output, and ends the process: C's `exit` semantics (no annotation end
  marks, no header updates). Tools must end through `exit` (or return
  normally after flushing); never `System.exit`.
* Write errors. The standard output is never written through `System.out`
  (a `PrintStream`, which swallows `IOException`s and only reports them
  through `checkError()`): `Platform.writeStdout` writes to the file
  descriptor with a `FileOutputStream` (JVM) or `write(2)` (Native) and
  reports the failure. `Stdout` records the first one (`Stdout.error()`,
  C's `ferror(stdout)`) and discards everything after it, as if the
  standard output were the null device. `wfdbx_legacy_args` enables a check
  in `exit`: in normal mode, it flushes the standard output, prints
  `PROGRAM: write error on standard output` if it failed, and turns the
  status 0 into 1 if it failed or `wfdbx_write_errors()` is not 0.
  `WfdbFile.close` counts a write error for an output file opened by
  `wfdb_open`/`wfdb_fopen`/`localFopen` (not `WfdbFile.fopen`); a tool
  closes the files it writes itself with `wfdbx_fclose_output`.
* `getenv`/`setenv`/`unsetenv`: on the JVM, which cannot change its own
  environment, `setenv` keeps an overlay that `getenv` and child processes
  (`run_sortann`) see.

## Files: `WfdbFile`

Port of Rust's `WfdbFile` on top of the platform's unbuffered `RawFile`
(file descriptors on Native, `FileChannel`s on the JVM): `fopen(name,
mode)`, `stdin()`, `stdout()`, `stderr()`, `fromBytes(...)`; `getc`,
`ungetc`, `read`, `fread`, `getline(ByteVec)`, `fgets(ByteVec, size)`,
`readToEnd`, `g16`, `g32`, `putc`, `write`, `printf`, `p16`, `p32`,
`flush`, `tell`, `seek`, `eof`, `error`, `clearerr`, `close`. End of file
is sticky until `clearerr` or a seek. Reads go through a buffer of the
file's block size (4096 on the JVM, `st_blksize` on Native), as glibc
reads, which matters in legacy mode when a file is read while it is
rewritten. **There are no destructors: a `WfdbFile` must be closed** (its
buffered output is otherwise written only by `exit`). A file on the
standard input never closes it and gives back unconsumed buffered bytes to
the next reader; `freopen_stdin(name)` is C's `freopen(name, "rb", stdin)`.

Inside the library, open files with `wfdb_open`/`wfdb_fopen` (the
settings apply), `localFopen` for a local file that must not depend on the
settings, and `wfdbx_open_in(headerDir, type, name, record)` for files
named in a header (containment check). `pathId(name)` and the internal
`WfdbFile.fileId()` give file identities (device and inode) for the
"output file is an input file" check of phase 2.

## Platform layer

`cstd/Platform.kt` declares everything common code needs from the system:
`RawFile` (read, write, seek, position, size, blksize, fileId, close) and
`Platform` (open, stdin, freopenStdin, writeStdout, writeStderr,
stdoutIsTty, stdoutTell, getenv, setenv, isDirectory, mkdir, pathId,
readFile, currentUid, timeNow, fetchUrl, runSortann, exit, currentDir,
nameBytes, nameString), plus `withGlobalLock`
and the per-thread default instances. Keep platform code minimal; add a
declaration there rather than platform code elsewhere.

* JVM: names, arguments and environment values are converted between
  bytes and Java strings with the file name encoding
  (`sun.jnu.encoding`; `jnuString`/`jnuBytes`). Network access:
  `HttpURLConnection`, redirects followed by hand (also across http/https),
  30 s to connect, `readTimeout` 30 s (no data for 30 s), no total limit,
  status >= 400 is a failure. `runSortann` starts `java -cp
  <java.class.path> wfdbx.cli.MainKt sortann --legacy -r. REC -a ANN` in
  the output directory: **phase 3 must provide `wfdbx.cli.MainKt` taking
  the tool name as its first argument** (until then, legacy sorting reports
  that the annotations still need to be rearranged, as when `sortann` is
  not found).
* Native: POSIX file descriptors; Linux runs `curl` and `sortann` with
  `posix_spawnp` (no shell; `env -C DIR` for a working directory); iOS uses
  `NSURLSession` and cannot run `sortann`.

### Native code

The Kotlin/Native toolchain could not be downloaded where phases 1 and 2
were written (`download.jetbrains.com` is blocked), so `nativeMain`,
`linuxMain`, `iosMain` and `nativeTest` have **not been compiled**. Where
the toolchain is available, build with `-Pwfdbx.linux=true` and fix what
the compiler reports (likely: cinterop type conversions of `struct stat`
fields and of `posix_spawn` arguments; phase 2 added only
`Platform.timeNow()`, `platform.posix.time(null)`).

## Signals (`Signal.kt`, `SignalTime.kt`, `Flac.kt`)

Close ports of `rust/src/signal.rs` and `rust/src/flac.rs`, with every
WFDB-x divergence and addition (no assumed frequency, gain, resolution or
units; files named in a header in its directory; segments of a
multi-segment record next to its header; the output-is-input guard of
`osigfopen`/`osigopen`; `hea_name`: names written in a header relative to
its directory; `wfdb_checkname` on the last component; checksum messages
recorded without printing during a high-level read; legacy mode).

The C-style signatures, where C's types do not map directly:

| C | Kotlin |
|---|---|
| `isigopen(rec, siarray, nsig)` (also `osigopen`, `wfdbinit`) | `isigopen(rec: ByteArray?/String, siarray: Array<Siginfo>?, nsig: Int)`; `null` is C's `NULL`; the elements are filled with `Siginfo.set` (allocate them: `Array(n) { Siginfo() }`) |
| `osigfopen(siarray, nsig)` | `osigfopen(Array<Siginfo>?, Int)` |
| `getvec(v)`, `getframe(v)`, `putvec(v)` | `IntArray`; a shorter array receives what fits (as in Rust) |
| `WFDB_Signal`, `WFDB_Group` (unsigned) | `Int`; negative values are compared as C's unsigned values (invalid signal numbers) |
| `getseginfo(&sarray)` | `getseginfo(sarray: MutableList<Seginfo>?)`: the list is cleared and receives copies of the segments |
| `setmsheader(rec, names, n)` | `setmsheader(ByteArray, Array<ByteArray>, Int)` or `(String, Array<String>, Int)` |
| `timstr`, `mstimstr`, `datstr`, `getinfo` | return a new `ByteArray` (a copy of C's static buffer); `getinfo` returns `null` at the end |
| `sample(s, t)`, `tnextvec(s, t)`, `isgsettime(g, t)` | `Int` signal or group, `Long` time |

WFDB-x additions, not in C: `getvecs(out, n): Long` and
`getvecs_status(out, n): GetvecsResult(count, status)` (n vectors at
once, as n `getvec` calls; the bulk path decodes the complete frames
already in the input buffers in one pass: about 10 times faster than a
`getvec` loop on the JVM, with identical results, which
`BulkTest` verifies against the per-frame path); `wfdbx_bulk_read(on)`
(turns the bulk path off, for tests); `wfdbx_time_needs_freq`. The bulk
path (`bulkFrames`) handles formats 8, 16, 24, 32, 61, 80, 160, 212, 310
and 311 (one format per signal group), and null signals (format 0) of
known length, without deskewing or resampling: records of several
sampling frequencies, in low-resolution mode (averaging the oversampled
signals with `meansamp`) and in high-resolution mode (from the start of a
frame), and the segments of multi-segment records, of fixed or variable
layout (mapped with `sigmap`), null segments included. A frame that
crosses the end of an input buffer, the frame at which checksums are
verified or a null signal ends, the change from one segment to the next
and everything else go through `getvec`, so the files are read in the
same blocks, and the statuses, messages and state (samples, checksums,
counts, `gvc`, `tvector`, `ovec`) are those of frame-by-frame reading
(`wfdbxBulkVectors` and `wfdbxInputState` are for the tests). Internal
accessors for the high-level API and `check_record` (phase 4):
`wfdbxHeaderNsamples`, `wfdbxRecordNsamples`, `wfdbxIsEdf`,
`wfdbxCksumResiduals`, `wfdbxGroupFileSizes`, `wfdbxBaseTimeDate`,
`wfdbxSetCksumQuiet` (getvec's checksum message recorded, not printed).

Rules followed by the port (keep them when changing it):

* Every `WfdbFile` the library opens is closed explicitly where Rust
  drops it (header files after `readheader`, signal files in `isigclose`,
  info and segment files after reading them); there are no destructors.
* Rust slices with offsets (`&mut out[pos..]`) are `(IntArray, offset)`
  pairs in the private functions (`getvecAt`, `getframeAt`,
  `getskewedframe(v, off)`, `bulkFrames(out, off, n)`).
* Rust's `std::mem::take` of buffers (to call `&mut self` methods with
  them) is unnecessary: the private functions use the arrays of
  `SigState` directly (a buffer reallocated by `isigopen` during a segment
  switch replaces the field, the old array being used to the end of the
  call, as in Rust).
* The local time (`setbasetime(NULL)`) is computed from `Platform.timeNow()`
  (C `time(NULL)`) and the TZif file named by `TZ` (or `/etc/localtime`),
  exactly as Rust does, on every platform.
* The FLAC encoder writes exactly the bytes of the other implementations
  (`FlacTest` checks sizes and MD5 digests computed by the Python
  implementation; files written in every format, FLAC included, were
  compared byte for byte with `rust/target/release/wrsamp`); the decoder
  reproduces libFLAC's block-by-block behavior after failed seeks.

## Tools

Each tool is a function `fun Wfdb.<tool>Main(argv: Array<ByteArray>): Int`
in `wfdbx/apps/<Tool>.kt`, a close port of `rust/src/bin/<tool>.rs`.
`argv` is C's `argv` (`argv[0]` is the tool name, as for a C tool found in
the `PATH`). The function starts with `val argv = toolArgv(argv0)`
(`Common.kt`: a mutable copy after `wfdbx_legacy_args`, which handles a
first argument `--legacy`), and ends with `exit(status)` (`wfdbx.cstd.exit`,
C's `exit`, which may also be called anywhere) or returns the status. The
driver (`wfdbx.cli.MainKt`) runs it on the default instance and exits with
the status; an uncaught exception is reported as `wfdbx: error: ...`
(status 1). Helpers that need the library state are `Wfdb` extensions, as
in the library. Files the tool opens are closed explicitly (Rust closes
them when they are dropped).

```sh
cd kotlin && ./gradlew fatJar        # build/libs/wfdbx-all.jar
export WFDBX_INPUT_DIR=../tests/data # the sample record 100s
bin/wfdbx rdsamp -r 100s -t 5        # bin/wfdbx --list, bin/wfdbx --version
```

(`100s`, in `tests/data` of the repository, is the first minute of record
100 of the MIT-BIH Arrhythmia Database.)

`bin/wfdbx` runs the jar named by `WFDBX_KOTLIN_JAR`, or
`build/libs/wfdbx-all.jar`; it moves `JAVA_TOOL_OPTIONS` to the command line
(the JVM would otherwise report it on the standard error) and starts the
JVM with options for a short start-up (`-XX:TieredStopAtLevel=1
-XX:+UseSerialGC`). A link to `bin/wfdbx` named after a tool runs that tool.
In legacy mode, the library runs `sortann` as `java -cp <class path>
wfdbx.cli.MainKt sortann --legacy ...`.

Conformance (from the repository root; the harness runs
`kotlin/bin/wfdbx TOOL ...`, and passes `WFDBX_KOTLIN_JAR` through):

```sh
PYTHONPATH=$PWD/python/src python3 tests/conformance/harness.py check --impl kotlin -j8 [TOOL|CASE ...]
PYTHONPATH=$PWD/python/src python3 tests/conformance/harness.py check --impl kotlin -j8 --legacy [TOOL|CASE ...]
```

## The high-level API (`Record.kt`, `Check.kt`)

* Each function is an extension of `Wfdb` and a top-level function on the
  default instance, with named arguments and defaults (no option
  structures). The behavior, the order of the checks and the messages are
  those of the Python reference (`highlevel.py`), with the messages of the
  compiled implementations for argument errors (`writeRecord: gains must be
  specified`, as C++'s and Rust's `write_record: ...`). Every error is a
  `WfdbException`.
* `Record.samples` is one `IntArray`, frame by frame (as Rust's
  `Record::samples`); `physical = true` adds `Record.physical`, a
  `DoubleArray` in the same layout. `readRecord` reads with
  `getvecsStatusAt` (getvecs into an offset of one growing array: no copy
  per block), in blocks of whole frames, a multiple of 6 of them, so that
  formats 212, 310 and 311 end each block on a whole packed unit. The
  signal descriptions it returns (and those of `readHeader`) have no white
  space at either end, and a channel given by name is looked up among them
  first, then with `findsig`.
* Record, annotator and directory names are file names: `Platform.nameBytes`
  and `nameString` convert them with the platform's file name encoding (the
  tools' arguments are converted the same way). Text in the files is
  ISO-8859-1 (`latin1`), as in Python.
* The checksum warning: `onWarning` receives it; by default it is
  `wfdb_error("wfdb-x: " + message + "\n")`, so `wfdbquiet()` silences it
  and `wfdberror()` returns it (as in C++ and Rust).
* Bulk writing: `putframes` (`Signal.kt`) encodes the frames of formats 16,
  61, 80, 160, 212, 310, 311, 24 and 32 in one loop with the `OgData`
  writers putvec uses (it halved the time of `writeRecord`); other formats
  (8, FLAC, several signal files) call putvec for each frame. `putanns`
  (`Annot.kt`) encodes MIT-format annotations into one buffer, byte for
  byte as `putann` (an AHA-format annotator uses putann). The tests compare
  both with the per-frame paths (`bulkPutOff`, random annotations).
* `checkRecord` needs `Platform.currentDir()` (the directory of a
  multi-segment record's header given by a relative name), and
  `checkSimulatedFileSize` lets a test simulate a signal file larger than
  2 GiB.

## Testing

Unit tests are in `commonTest` and run on every target; expected values
come from the C library (through the Rust tests and
`tests/reference/api_expect.c`). The tests never change the current
directory (the JVM cannot): they copy `tests/data` to a scratch directory
(`DataDir`) and use the input and output directories. Environment changes
go through `setenv`/`unsetenv` and are restored. The path of `tests/data`
is passed by Gradle (`wfdbx.testdata` system property, `WFDBX_TESTDATA`
for native tests).

Bytes that the C programs produce (sorted annotation files) were checked
against `rust/target/release/sortann`, which matches the C program.

| Test file | Contents |
|---|---|
| `cstd/PrintfTest.kt`, `cstd/ParseTest.kt` | C formatting and parsing |
| `WfdbioTest.kt`, `FilesTest.kt` | files, directories, WFDB path, files named in headers, multi-segment records |
| `AnnotTest.kt` | annotations, code tables, calibration, sorting, `wfdbinit`/`wfdbquit` |
| `SignalTest.kt` | the signal functions (port of the C-style parts of `rust/tests/signals.rs`: values of `api_expect.c`, no-defaults and legacy behavior, EDF, FLAC seeks, round trips in every format, output-is-input guard, checksum errors, record names with directories) |
| `BulkTest.kt` | `getvecs` and `readRecord`: bulk path against the per-frame path, for single- and multi-frequency, multi-segment and all `tests/data` records (port of `rust/tests/bulk.rs`) |
| `FlacTest.kt` | FLAC decoder and encoder (port of the unit tests of `rust/src/flac.rs`) |
| `jvmTest/NetworkTest.kt` | URLs and remote records, against a local HTTP server |
| `jvmTest/SignalJvmTest.kt` | an output file that is a hard link to an input file |
| `RecordTest.kt`, `AnnotationsTest.kt` | the high-level API (ports of the high-level parts of `python/tests/test_signals.py`, `test_annotations.py` and `rust/tests/signals.rs`, `annotations.rs`): round trips in every format, bulk reading and writing against the per-frame paths, the bulk annotation encoder against putann, checksums, truncated signal and annotation files, the sort option, record names, legacy mode |
| `jvmTest/CheckCorpusTest.kt` | `checkRecord` on the corpus of `python/tests/check_corpus.py` (an empty diff against its `expected.txt`; skipped with a message without python3) |
| `jvmTest/HighLevelJvmTest.kt` | the top-level functions, the input options and network access (local HTTP server), `checkRecord` without the corpus |
| `jvmTest/ReadmeExamplesTest.kt` | the examples of README.md |

The parts of the Rust tests that use the high-level API (`read_record`,
`write_record`, `read_header`, ...) are written with the C-style
functions in `SignalTest.kt` where they test the library; the high-level
API itself is tested in `RecordTest.kt` and the files after it. Beyond the unit tests, every record of `tests/data`
(`.hea` and EDF) was read with `getvec` in low- and high-resolution mode
and compared, line by line, with `rust/target/release/rdsamp` and
`rdsamp -H`: identical.

## Performance

`benchmarks/run.sh` runs the same operations with the Kotlin, C++
and Rust implementations (and the Python high-level API, for context) on
the same input, and checks that their outputs are identical. The input is a
record of 4 signals of 2,000,000 frames in format 16 (16 MB). The library
operations are timed inside one process, as the best of 5 runs after one
untimed run (which lets the JVM compile the code); `rdsamp` is timed as a
whole process (the tool printing the whole record to a file, 2,000,000
lines), best of 3, and so includes the start-up of the JVM. Times in
milliseconds:

| Operation | Kotlin (JVM) | C++ | Rust | Python |
|---|---:|---:|---:|---:|
| `readRecord` (8 million samples) | 41 | 34 | 33 | 157 |
| `writeRecord` (the same samples, format 16) | 48 | 38 | 44 | 69 |
| `writeAnnotations` (200,000 annotations) | 6.4 | 3.0 | 2.7 | 37 |
| `isigopen` + `getvec` loop (2,000,000 frames) | 105 | 50 | 72 | |
| `rdsamp -r big` (the tool, a new process) | 689 | 142 | 174 | |

The samples read were identical in all implementations (the same digest),
and the files written (`big.hea`, `big.dat` and the annotation file) and
the output of `rdsamp` were byte-identical. Machine: Intel Xeon (2.1 GHz,
4 cores), 15 GB of memory, Linux 6.18; OpenJDK 21.0.12, GCC 13.3 (`-O2`,
the C++ library built in Release mode), Rust 1.97 (release), Python 3.13
with NumPy 2.5.

`readRecord` and `writeRecord` decode and encode the samples in bulk
(`writeRecord` encodes the frames of the common formats in one loop, byte
for byte as `putvec`; `writeAnnotations` encodes the annotations into one
buffer, byte for byte as `putann`); both are tested against the per-frame
paths. Of the 689 ms of `rdsamp`, about 150 ms are the start-up of the JVM;
the launcher also limits the JVM to its first compiler, for a fast start of
the short runs that are typical of the tools (without that limit, the same
`rdsamp` takes about 400 ms).
